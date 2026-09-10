import Foundation
import Combine
import Network
import AppKit
import Security
import UniformTypeIdentifiers
import ImageIO
import Darwin

struct LANAttachment: Codable, Equatable {
    var name: String
    var mime: String
    var base64: String
}

struct LANSharedContent: Codable, Equatable {
    var kind: String
    var text: String
    var attachments: [LANAttachment]
    var revision: UUID = UUID()
    var receivedAt: Date = Date()
}

struct LANHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
    static let maximumBody = 12 * 1024 * 1024

    /// Strict, one-request-per-connection parser. Chunked bodies and ambiguous lengths are rejected.
    static func parse(_ bytes: Data) throws -> LANHTTPRequest? {
        guard let separator = bytes.range(of: Data("\r\n\r\n".utf8)) else {
            if bytes.count > 16_384 { throw AutomationError.invalid("HTTP 请求头过大。", "HTTP header too large.") }
            return nil
        }
        guard separator.lowerBound <= 16_384, let header = String(data: bytes[..<separator.lowerBound], encoding: .utf8) else {
            throw AutomationError.invalid("HTTP 请求头无效。", "Invalid HTTP headers.")
        }
        let lines = header.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ")
        guard request.count == 3, request[2] == "HTTP/1.1", ["GET", "POST"].contains(String(request[0])), request[1].hasPrefix("/") else {
            throw AutomationError.invalid("不支持此 HTTP 请求。", "Unsupported HTTP request.")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw AutomationError.invalid("请求头无效。", "Invalid header.") }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }), headers[name] == nil else {
                throw AutomationError.invalid("请求头重复或无效。", "Duplicate or invalid header.")
            }
            headers[name] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil, headers["expect"] == nil else { throw AutomationError.invalid("不支持此传输编码。", "Unsupported transfer encoding.") }
        let length: Int
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }), let parsed = Int(raw), parsed <= maximumBody else { throw AutomationError.invalid("请求正文长度无效。", "Invalid body length.") }
            length = parsed
        } else { length = 0 }
        guard request[0] != "POST" || headers["content-length"] != nil else { throw AutomationError.invalid("缺少请求正文长度。", "Missing body length.") }
        let expected = separator.upperBound + length
        guard bytes.count <= expected else { throw AutomationError.invalid("HTTP 请求后有多余数据。", "Trailing HTTP data.") }
        guard bytes.count == expected else { return nil }
        return LANHTTPRequest(method: String(request[0]), path: String(request[1]), headers: headers, body: bytes.subdata(in: separator.upperBound..<expected))
    }

    static func constantTimeTokenEqual(_ supplied: String, _ expected: String) -> Bool {
        let a = Array(supplied.utf8), b = Array(expected.utf8)
        var difference = UInt64(a.count ^ b.count)
        for index in 0..<64 { difference |= UInt64((index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0)) }
        return difference == 0 && b.count == 64
    }

    static func allowsOrigin(headers: [String: String], authorities: Set<String>) -> Bool {
        guard let host = headers["host"]?.lowercased(), authorities.contains(host) else { return false }
        guard let origin = headers["origin"] else { return true }
        guard let components = URLComponents(string: origin), components.scheme == "http", components.user == nil,
              components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty, let originHost = components.host, let port = components.port else { return false }
        return "\(originHost.lowercased()):\(port)" == host
    }
}

final class LANSyncService: ObservableObject {
    static let shared = LANSyncService()
    @Published private(set) var isRunning = false
    @Published private(set) var links: [String] = []
    @Published private var statusMessage = AutomationMessage("局域网共享未开启。", "LAN sharing is disabled.")
    var status: String { statusMessage.text }
    @Published private var sharedMessage = AutomationMessage("尚未共享任何项目", "Nothing shared yet")
    var sharedDescription: String { sharedMessage.text }
    @Published private(set) var receivedCount = 0
    @Published var shareNewCaptures = false
    @Published var receiveIncoming = false
    @Published private(set) var recentDevices: [String] = []
    private let queue = DispatchQueue(label: "dev.cclip.lan", qos: .utility)
    private var listener: NWListener?
    private var token = ""
    private var authorities: Set<String> = []
    private var current: LANSharedContent?
    private var connections: [UUID: NWConnection] = [:]
    private var generation = UUID()
    private var recentPeers: [String: Date] = [:]
    private var inboundRevisions = Set<UUID>()
    private static let contentLimit = 8 * 1024 * 1024

    /// Only the UI Enable action calls this method; no preferences automatically restart a listener.
    func start() {
        guard !isRunning else { return }
        statusMessage = AutomationMessage("正在启动本机共享…", "Starting local sharing…")
        queue.async { [weak self] in
            guard let self, self.listener == nil else { return }
            do {
                var random = [UInt8](repeating: 0, count: 32)
                guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw AutomationError.invalid("无法生成安全令牌。", "Could not generate a secure token.") }
                self.token = random.map { String(format: "%02x", $0) }.joined()
                self.current = nil; self.generation = UUID(); self.inboundRevisions = []; self.recentPeers = [:]
                let session = self.generation
                let listener = try NWListener(using: .tcp, on: .any)
                self.listener = listener
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection, generation: session) }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self, self.generation == session else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port?.rawValue else { return }
                        let ips = Self.localIPv4Addresses()
                        self.authorities = Set((ips + ["127.0.0.1", "localhost"]).map { "\($0):\(port)" })
                        let links = (ips.isEmpty ? ["127.0.0.1"] : ips).map { "http://\($0):\(port)/#\(self.token)" }
                        DispatchQueue.main.async {
                            self.links = links; self.isRunning = true; self.receivedCount = 0
                            self.sharedMessage = AutomationMessage("尚未共享任何项目", "Nothing shared yet")
                            self.statusMessage = AutomationMessage("共享已开启。只有主动共享的内容可供持有链接的人读取。", "Sharing is enabled. People with the link can read only content you explicitly share.")
                        }
                    case .failed(let error):
                        self.stopOnQueue()
                        DispatchQueue.main.async { self.statusMessage = AutomationMessage(error: error, chinesePrefix: "共享启动失败：", englishPrefix: "Could not start sharing: ") }
                    default: break
                    }
                }
                listener.start(queue: self.queue)
            } catch { self.stopOnQueue(); DispatchQueue.main.async { self.statusMessage = AutomationMessage(error: error) } }
        }
    }

    func stop() { queue.async { self.stopOnQueue() } }
    private func stopOnQueue() {
        generation = UUID()
        listener?.cancel(); listener = nil
        connections.values.forEach { $0.cancel() }; connections.removeAll()
        token = ""; current = nil; authorities = []; recentPeers = [:]; inboundRevisions = []
        DispatchQueue.main.async {
            self.isRunning = false; self.links = []; self.sharedMessage = AutomationMessage("尚未共享任何项目", "Nothing shared yet")
            self.shareNewCaptures = false; self.receiveIncoming = false; self.recentDevices = []
            self.statusMessage = AutomationMessage("共享已关闭，原链接已失效。", "Sharing stopped. Previous links are no longer valid.")
        }
    }

    func clearSharedContent() {
        queue.async { self.current = nil; DispatchQueue.main.async { self.sharedMessage = AutomationMessage("尚未共享任何项目", "Nothing shared yet") } }
    }

    /// Must be invoked for a specifically selected item; never enumerate or expose clipboard history.
    func publish(item: ClipboardItem) throws {
        guard isRunning else { throw AutomationError.invalid("请先在局域网共享中开启服务。", "Enable LAN sharing first.") }
        guard ClipboardManager.shared.captureAllowed() else { throw AutomationError.invalid("历史已锁定。", "History is locked.") }
        var content = LANSharedContent(kind: "text", text: item.content, attachments: [])
        let paths = item.fileURLs ?? item.filePath.map { [$0] } ?? []
        if !paths.isEmpty {
            guard paths.count <= 16 else { throw AutomationError.invalid("每次最多共享 16 个文件。", "Share at most 16 files at a time.") }
            content.kind = "files"
            var total = 0
            for path in paths {
                let url = URL(fileURLWithPath: path)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, let size = values.fileSize, size <= Self.contentLimit - total else {
                    throw AutomationError.invalid("只支持总计不超过 8 MB 的普通文件；文件夹请先压缩。", "Only regular files totaling up to 8 MB are supported. Compress folders first.")
                }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                total += data.count
                guard total <= Self.contentLimit else { throw AutomationError.invalid("文件总计超过 8 MB。", "The files exceed 8 MB in total.") }
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                content.attachments.append(LANAttachment(name: url.lastPathComponent, mime: mime, base64: data.base64EncodedString()))
            }
        } else if item.type == .image, let data = item.data {
            guard data.count <= Self.contentLimit else { throw AutomationError.invalid("图片超过 8 MB。", "The image exceeds 8 MB.") }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), let identifier = CGImageSourceGetType(source) else { throw AutomationError.invalid("无法读取图片。", "Could not read the image.") }
            let type = UTType(identifier as String)
            content.kind = "image"
            content.attachments = [LANAttachment(name: "shared-image." + (type?.preferredFilenameExtension ?? "png"), mime: type?.preferredMIMEType ?? "image/png", base64: data.base64EncodedString())]
        } else {
            guard content.text.utf8.count <= Self.contentLimit else { throw AutomationError.invalid("文本超过 8 MB。", "The text exceeds 8 MB.") }
        }
        let ready = content
        queue.async {
            guard self.listener != nil else { return }
            self.current = ready
            DispatchQueue.main.async { self.sharedMessage = ready.kind == "text" ? AutomationMessage("已共享一条文本（\(ready.text.count) 字）", "Sharing one text item (\(ready.text.count) characters)") : AutomationMessage("已共享 \(ready.attachments.count) 个附件", "Sharing \(ready.attachments.count) attachments") }
        }
    }

    func publishText(_ text: String) throws {
        try publish(item: ClipboardItem(id: UUID(), content: text, type: .text, timestamp: Date()))
    }

    /// Wire to ClipboardManager.onCapture. Receiving never writes NSPasteboard or invokes this callback.
    func sendCaptured(_ item: ClipboardItem) {
        guard isRunning, shareNewCaptures, item.sourceApp != "CClip LAN" else { return }
        do { try publish(item: item) }
        catch { statusMessage = AutomationMessage(error: error, chinesePrefix: "自动共享失败：", englishPrefix: "Automatic sharing failed: ") }
    }

    private func accept(_ connection: NWConnection, generation: UUID) {
        guard self.generation == generation, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 20) { [weak self, weak connection] in
            connection?.cancel(); self?.connections.removeValue(forKey: id)
        }
        receive(connection, id: id, generation: generation, buffer: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, generation: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, self.generation == generation else { connection.cancel(); return }
            var bytes = buffer
            if let data { bytes.append(data) }
            guard bytes.count <= LANHTTPRequest.maximumBody + 16_388 else { self.respond(connection, id: id, status: 413, body: Data(AutomationL("内容过大", "Too large").utf8)); return }
            do {
                if let request = try LANHTTPRequest.parse(bytes) { self.handle(request, connection: connection, id: id, generation: generation); return }
                if complete || error != nil { connection.cancel(); self.connections.removeValue(forKey: id); return }
                self.receive(connection, id: id, generation: generation, buffer: bytes)
            } catch { self.respond(connection, id: id, status: 400, body: Data(AutomationL("请求无效", "Invalid request").utf8)) }
        }
    }

    private func handle(_ request: LANHTTPRequest, connection: NWConnection, id: UUID, generation: UUID) {
        guard LANHTTPRequest.allowsOrigin(headers: request.headers, authorities: authorities) else { respond(connection, id: id, status: 403, body: Data(AutomationL("来源不被允许", "Forbidden origin").utf8)); return }
        if request.method == "GET", request.path == "/" {
            respond(connection, id: id, status: 200, body: Data(Self.browserPage.utf8), contentType: "text/html; charset=utf-8"); return
        }
        guard LANHTTPRequest.constantTimeTokenEqual(request.headers["x-cclip-token"] ?? "", token) else {
            respond(connection, id: id, status: 401, body: Data(AutomationL("共享链接无效或已过期", "Invalid or expired sharing link").utf8)); return
        }
        if case .hostPort(let host, _) = connection.endpoint {
            recentPeers[host.debugDescription] = Date()
            recentPeers = recentPeers.filter { Date().timeIntervalSince($0.value) < 90 }
            let devices = recentPeers.keys.sorted()
            DispatchQueue.main.async { self.recentDevices = devices }
        }
        // Recheck the lock before each authenticated operation; revocation hides already selected content too.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let unlocked = ClipboardManager.shared.captureAllowed()
            self.queue.async {
                guard self.generation == generation else { connection.cancel(); return }
                guard unlocked else { self.respond(connection, id: id, status: 423, body: Data(AutomationL("历史已锁定", "History is locked").utf8)); return }
                if request.method == "GET", request.path == "/api/shared" {
                    let data = self.current.flatMap { try? JSONEncoder().encode($0) } ?? Data("null".utf8)
                    self.respond(connection, id: id, status: 200, body: data, contentType: "application/json"); return
                }
                if request.method == "POST", request.path == "/api/upload" {
                    guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true,
                          let content = try? JSONDecoder().decode(LANSharedContent.self, from: request.body) else {
                        self.respond(connection, id: id, status: 400, body: Data(AutomationL("内容无效", "Invalid content").utf8)); return
                    }
                    if self.inboundRevisions.contains(content.revision) {
                        self.respond(connection, id: id, status: 200, body: Data("{\"ok\":true,\"duplicate\":true}".utf8), contentType: "application/json"); return
                    }
                    if self.inboundRevisions.count >= 512 { self.inboundRevisions.removeAll() }
                    self.inboundRevisions.insert(content.revision)
                    self.importContent(content, connection: connection, id: id, generation: generation); return
                }
                self.respond(connection, id: id, status: 404, body: Data(AutomationL("未找到内容", "Not found").utf8))
            }
        }
    }

    private func importContent(_ content: LANSharedContent, connection: NWConnection, id: UUID, generation: UUID) {
        do {
            guard ["text", "image", "files"].contains(content.kind), content.text.utf8.count <= Self.contentLimit,
                  content.attachments.count <= 16, content.kind != "text" || content.attachments.isEmpty else { throw AutomationError.invalid("内容无效。", "Invalid content.") }
            var total = content.text.utf8.count
            var decoded: [(String, Data)] = []
            for attachment in content.attachments {
                guard let data = Data(base64Encoded: attachment.base64), data.count <= Self.contentLimit - total else { throw AutomationError.invalid("附件超过大小限制。", "Attachment exceeds limit.") }
                total += data.count
                let name = Self.safeFilename(attachment.name)
                decoded.append((name, data))
            }
            guard content.kind == "text" || !decoded.isEmpty else { throw AutomationError.invalid("缺少附件。", "No attachment.") }
            let attachments = decoded
            DispatchQueue.main.async {
                do {
                    guard self.queue.sync(execute: { self.generation == generation }) else { throw AutomationError.invalid("共享会话已结束。", "Sharing session ended.") }
                    guard self.receiveIncoming else { throw AutomationError.invalid("接收开关已关闭。", "Receiving is disabled.") }
                    guard ClipboardManager.shared.captureAllowed() else { throw AutomationError.invalid("历史已锁定。", "History is locked.") }
                    if content.kind == "text" { try ClipboardManager.shared.addText(content.text) }
                    else if content.kind == "image", attachments.count == 1 {
                        guard let source = CGImageSourceCreateWithData(attachments[0].1 as CFData, nil),
                              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                              let width = properties[kCGImagePropertyPixelWidth] as? Int,
                              let height = properties[kCGImagePropertyPixelHeight] as? Int,
                              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 32_000_000 else { throw AutomationError.invalid("不支持此图片尺寸。", "Unsupported image dimensions.") }
                        try ClipboardManager.shared.addImage(attachments[0].1)
                    } else {
                        let folder = StoragePaths.dataDirectory.appendingPathComponent("LANInbox", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        do {
                            var paths: [String] = []
                            for (index, attachment) in attachments.enumerated() {
                                let path = folder.appendingPathComponent("\(index)-\(attachment.0)")
                                try attachment.1.write(to: path, options: .atomic)
                                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                                paths.append(path.path)
                            }
                            let item = ClipboardItem(id: UUID(), content: attachments.map { $0.0 }.joined(separator: "\n"), type: .file,
                                timestamp: Date(), filePath: paths.first, sourceApp: "CClip LAN", sourceAppName: "Xclip LAN", fileURLs: paths)
                            try ClipboardManager.shared.ingest(item)
                        } catch { try? FileManager.default.removeItem(at: folder); throw error }
                    }
                    self.receivedCount += 1
                    self.statusMessage = AutomationMessage("收到来自共享页面的内容，已保存到历史。", "Content received from the sharing page and saved to history.")
                    self.queue.async {
                        guard self.generation == generation else { connection.cancel(); return }
                        self.respond(connection, id: id, status: 200, body: Data("{\"ok\":true}".utf8), contentType: "application/json")
                    }
                } catch {
                    self.statusMessage = AutomationMessage(error: error, chinesePrefix: "接收失败：", englishPrefix: "Receiving failed: ")
                    self.queue.async { self.inboundRevisions.remove(content.revision); self.respond(connection, id: id, status: 422, body: Data(AutomationL("导入失败，请查看 Xclip 中的状态", "Import failed; inspect Xclip status").utf8)) }
                }
            }
        } catch { inboundRevisions.remove(content.revision); respond(connection, id: id, status: 413, body: Data(AutomationL("内容不受支持或超过大小限制", "Unsupported or oversized content").utf8)) }
    }

    static func safeFilename(_ name: String) -> String {
        let stripped = name.components(separatedBy: CharacterSet(charactersIn: "/\\").union(.controlCharacters)).joined(separator: "_")
        let safe = String(stripped.prefix(120)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return safe.isEmpty ? "shared-file" : safe
    }

    private func respond(_ connection: NWConnection, id: UUID, status: Int, body: Data, contentType: String = "text/plain; charset=utf-8") {
        let header = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src blob:; base-uri 'none'; frame-ancestors 'none'; form-action 'none'\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { [weak self] _ in connection.cancel(); self?.connections.removeValue(forKey: id) })
    }

    private static func localIPv4Addresses() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = cursor {
            let item = pointer.pointee
            if let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), (item.ifa_flags & UInt32(IFF_LOOPBACK)) == 0, (item.ifa_flags & UInt32(IFF_UP)) != 0 {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 { addresses.append(String(cString: buffer)) }
            }
            cursor = item.ifa_next
        }
        return Array(Set(addresses)).sorted()
    }

    static var browserPage: String { #"""
    <!doctype html><html lang="\#(AutomationL("zh-CN", "en"))"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>\#(AutomationL("Xclip 局域网共享", "Xclip LAN sharing"))</title>
    <style>:root{color-scheme:light dark;font:16px system-ui}body{max-width:720px;margin:32px auto;padding:0 20px;line-height:1.6}h1{font-size:26px}section{border:1px solid #8886;border-radius:12px;padding:18px;margin:20px 0}textarea{box-sizing:border-box;width:100%;min-height:140px;padding:12px;font:inherit}button,a{display:inline-block;padding:10px 14px;margin:8px 8px 0 0}button{cursor:pointer}pre{white-space:pre-wrap;overflow-wrap:anywhere}img{max-width:100%;max-height:360px}#status{min-height:1.5em}small{opacity:.75}</style>
    <h1>\#(AutomationL("Xclip 局域网共享", "Xclip LAN sharing"))</h1><p>\#(AutomationL("仅展示 Mac 主动共享的当前项目。连接使用 HTTP，请在可信局域网使用；持有此链接的人可以查看和发送内容。", "Only the item explicitly shared by your Mac is shown. This connection uses HTTP; use a trusted local network. Anyone with this link can view and send content."))</p>
    <section><h2>\#(AutomationL("Mac 共享的内容", "Content shared by your Mac"))</h2><button id="refresh">\#(AutomationL("刷新", "Refresh"))</button><div id="shared">\#(AutomationL("尚无共享内容", "Nothing shared yet"))</div></section>
    <section><h2>\#(AutomationL("发送到 Mac 历史", "Send to your Mac history"))</h2><label for="text">\#(AutomationL("文本内容", "Text"))</label><textarea id="text"></textarea><button id="sendText">\#(AutomationL("发送文本", "Send text"))</button><hr><label for="files">\#(AutomationL("图片或文件（总计最多 8 MB）", "Images or files (up to 8 MB total)"))</label><br><input id="files" type="file" multiple hidden><button id="chooseFiles">\#(AutomationL("选择文件…", "Choose files…"))</button><span id="fileSelection">\#(AutomationL("未选择文件", "No files selected"))</span><button id="sendFiles">\#(AutomationL("发送文件", "Send files"))</button></section><p id="status" role="status"></p><small>\#(AutomationL("关闭 Mac 上的共享后，此链接立即失效。不会自动读取手机剪贴板。", "This link expires as soon as sharing stops on your Mac. Your phone clipboard is never read automatically."))</small>
    <script>
    'use strict';const token=location.hash.slice(1),status=document.getElementById('status'),shared=document.getElementById('shared');let urls=[],last='',busy=false;
    async function api(path,options={}){const response=await fetch(path,{...options,cache:'no-store',headers:{'X-CClip-Token':token,'Content-Type':'application/json',...options.headers}});if(!response.ok)throw new Error('\#(AutomationL("请求失败 ", "Request failed "))'+response.status+'\#(AutomationL("；确认共享已开启且链接有效。", ". Check that sharing is enabled and the link is valid."))');return response.json()}
    function message(value){status.textContent=value}
    function revision(){const b=new Uint8Array(16);crypto.getRandomValues(b);b[6]=(b[6]&15)|64;b[8]=(b[8]&63)|128;const h=Array.from(b,x=>x.toString(16).padStart(2,'0')).join('');return h.slice(0,8)+'-'+h.slice(8,12)+'-'+h.slice(12,16)+'-'+h.slice(16,20)+'-'+h.slice(20)}
    async function refresh(){try{const value=await api('/api/shared');if(JSON.stringify(value)===last)return;last=JSON.stringify(value);urls.forEach(URL.revokeObjectURL);urls=[];shared.replaceChildren();if(!value){shared.textContent='\#(AutomationL("尚无共享内容", "Nothing shared yet"))';return}if(value.kind==='text'){const p=document.createElement('pre');p.textContent=value.text;shared.append(p);return}for(const item of value.attachments){const bytes=Uint8Array.from(atob(item.base64),c=>c.charCodeAt(0));const url=URL.createObjectURL(new Blob([bytes],{type:item.mime}));urls.push(url);if(item.mime.startsWith('image/')&&!item.mime.includes('svg')){const img=document.createElement('img');img.src=url;img.alt=item.name;shared.append(img)}const a=document.createElement('a');a.href=url;a.download=item.name;a.textContent='\#(AutomationL("下载 ", "Download "))'+item.name;shared.append(a)}}catch(error){message(error.message)}}
    async function send(value){if(busy)return;busy=true;document.querySelectorAll('button').forEach(b=>b.disabled=true);message('\#(AutomationL("发送中…", "Sending…"))');try{await api('/api/upload',{method:'POST',body:JSON.stringify({...value,revision:revision(),receivedAt:0})});message('\#(AutomationL("已保存到 Mac 历史。", "Saved to your Mac history."))')}catch(error){message(error.message)}finally{busy=false;document.querySelectorAll('button').forEach(b=>b.disabled=false)}}
    document.getElementById('chooseFiles').onclick=()=>document.getElementById('files').click();document.getElementById('files').onchange=()=>{const files=[...document.getElementById('files').files];document.getElementById('fileSelection').textContent=files.length?files.map(file=>file.name).join(', '):'\#(AutomationL("未选择文件", "No files selected"))'};
    document.getElementById('refresh').onclick=refresh;document.getElementById('sendText').onclick=()=>{const text=document.getElementById('text').value;if(text)send({kind:'text',text,attachments:[]})};document.getElementById('sendFiles').onclick=async()=>{try{const files=[...document.getElementById('files').files];if(!files.length)return;if(files.length>16||files.reduce((n,f)=>n+f.size,0)>8*1024*1024)throw new Error('\#(AutomationL("每次最多 16 个文件，总计最多 8 MB。", "At most 16 files and 8 MB total per upload."))');const attachments=[];for(const file of files){const data=new Uint8Array(await file.arrayBuffer());let binary='';for(let i=0;i<data.length;i+=32768)binary+=String.fromCharCode(...data.subarray(i,i+32768));attachments.push({name:file.name,mime:file.type||'application/octet-stream',base64:btoa(binary)})}send({kind:'files',text:'',attachments})}catch(error){message(error.message)}};if(token.length===64){refresh();setInterval(()=>{if(!document.hidden&&!busy)refresh()},2000)}else{message('\#(AutomationL("缺少令牌，请使用 Mac 中的完整共享链接。", "Access token missing. Use the full sharing link from your Mac."))')}
    </script></html>
    """# }
}
