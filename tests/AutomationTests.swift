// Standalone tests: compile with -D CCLIP_AUTOMATION_TESTS alongside AutomationServices,
// LANSyncService, ClipboardItem and StoragePaths, then pass the built helper path.
#if CCLIP_AUTOMATION_TESTS
import Foundation
import AppKit
import Combine

final class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()
    var captureAllowed: () -> Bool = { true }
    @Published var clipboardItems: [ClipboardItem] = []
    @discardableResult func addText(_ text: String) throws -> ClipboardItem {
        try ingest(ClipboardItem(id: UUID(), content: text, type: .text, timestamp: Date()))
    }
    @discardableResult func addImage(_ data: Data) throws -> ClipboardItem {
        try ingest(ClipboardItem(id: UUID(), content: "image", type: .image, timestamp: Date(), data: data))
    }
    @discardableResult func ingest(_ item: ClipboardItem) throws -> ClipboardItem { clipboardItems.append(item); return item }
}

final class PrivacyLock: ObservableObject {
    static let shared = PrivacyLock()
    @Published var locked = false
}

@main struct AutomationTests {
    static var passed = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try condition() else { throw AutomationError.invalid("FAIL: " + name) }
        passed += 1
        print("PASS: " + name)
    }
    static func rejects(_ name: String, _ action: () throws -> Void) throws {
        do { try action() } catch { passed += 1; print("PASS: " + name); return }
        throw AutomationError.invalid("FAIL: expected rejection for " + name)
    }

    static func main() throws {
        guard CommandLine.arguments.count >= 2 else { throw AutomationError.invalid("Pass CClipScriptRunner path") }
        let helper = URL(fileURLWithPath: CommandLine.arguments[1])
        let suite = "dev.cclip.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let scripts = ScriptService(defaults: defaults, helperURL: helper)
        try check(try scripts.execute(ClipboardScript(name: "Unicode", code: "input.trim().toUpperCase()"), input: "  Hello 世界  ") == "HELLO 世界", "Unicode text transform")
        let untrustedText = "\"; throw new Error('injected'); //\n世界"
        try check(try scripts.execute(ClipboardScript(name: "Escape", code: "input"), input: untrustedText) == untrustedText, "Input cannot inject JavaScript source")
        try check(try scripts.execute(ClipboardScript(name: "No bridges", code: "[typeof fetch, typeof require, typeof readFile, typeof ObjC, typeof process].join(',')"), input: "") == "undefined,undefined,undefined,undefined,undefined", "Worker has no native or network bridges")
        try rejects("Non-string output") { _ = try scripts.execute(ClipboardScript(name: "Bad", code: "({value: 1})"), input: "") }
        try rejects("JavaScript exception") { _ = try scripts.execute(ClipboardScript(name: "Bad", code: "JSON.parse(input)"), input: "not json") }
        let before = Date()
        try rejects("Infinite loop killed") { _ = try scripts.execute(ClipboardScript(name: "Loop", code: "(() => { while(true) {} })()"), input: "", timeout: 0.15) }
        try check(Date().timeIntervalSince(before) < 2, "Infinite loop termination is bounded")
        try check(try scripts.execute(ClipboardScript(name: "Recover", code: "input + ' OK'"), input: "After timeout") == "After timeout OK", "Engine recovers after timeout")
        scripts.scripts = [ClipboardScript(name: "Trim", code: "input.trim()", trigger: "copy", enabled: true), ClipboardScript(name: "Upper", code: "input.toUpperCase()", trigger: "copy", enabled: true)]
        try check(try scripts.transform("  hello  ", trigger: "copy") == "HELLO", "Ordered copy chain")
        try check(try scripts.transform("  hello  ", trigger: "paste") == "  hello  ", "Triggers are isolated")
        try check(ScriptService(defaults: defaults).scripts == scripts.scripts, "Script persistence")
        let ai = AIService(defaults: defaults)
        NotificationCenter.default.post(name: .init("CClipTranslateText"), object: "prefill before UI")
        try check(ai.draftInput == "prefill before UI" && ai.draftTaskKind == "translate", "Translate notification retained before UI mounts")
        try rejects("Input size limit") { _ = try scripts.transform(String(repeating: "a", count: 1_048_577), trigger: "copy") }
        var configuration = AIConfiguration()
        try check(try configuration.requestURL().absoluteString == "http://127.0.0.1:11434/api/chat", "Ollama URL")
        configuration.provider = .compatible; configuration.endpoint = "http://localhost:1234/v1"
        try check(try configuration.requestURL().absoluteString == "http://localhost:1234/v1/chat/completions", "LM Studio URL")
        configuration.endpoint = "https://example.invalid/v1/chat/completions"
        try check(try configuration.requestURL().absoluteString == configuration.endpoint, "Complete compatible endpoint not duplicated")
        configuration.endpoint = "http://example.invalid/v1"
        try rejects("Remote plaintext AI endpoint") { _ = try configuration.requestURL() }
        configuration.endpoint = "https://secret@example.invalid/v1"
        try rejects("URL embedded credentials") { _ = try configuration.requestURL() }
        configuration.endpoint = "https://example.invalid/v1?key=secret"
        try rejects("Credentials in URL query") { _ = try configuration.requestURL() }
        let token = String(repeating: "a", count: 64)
        try check(LANHTTPRequest.constantTimeTokenEqual(token, token), "Matching token")
        try check(!LANHTTPRequest.constantTimeTokenEqual(token + "a", token), "Token suffix rejected")
        try check(!LANHTTPRequest.constantTimeTokenEqual(String(repeating: "b", count: 64), token), "Wrong token rejected")
        let authority: Set<String> = ["192.168.1.10:9000"]
        try check(LANHTTPRequest.allowsOrigin(headers: ["host": "192.168.1.10:9000", "origin": "http://192.168.1.10:9000"], authorities: authority), "Same origin accepted")
        try check(!LANHTTPRequest.allowsOrigin(headers: ["host": "192.168.1.10:9000", "origin": "https://evil.example"], authorities: authority), "Cross origin rejected")
        try check(!LANHTTPRequest.allowsOrigin(headers: ["host": "evil.example:9000"], authorities: authority), "DNS rebinding Host rejected")
        try check(!LANHTTPRequest.allowsOrigin(headers: ["host": "192.168.1.10:9000", "origin": "null"], authorities: authority), "Opaque origin rejected")
        let valid = Data("POST /api/upload HTTP/1.1\r\nHost: localhost:9000\r\nContent-Length: 2\r\n\r\n{}".utf8)
        try check(try LANHTTPRequest.parse(valid)?.body == Data("{}".utf8), "HTTP body parsing")
        try check(try LANHTTPRequest.parse(valid.dropLast()) == nil, "Partial body waits for completion")
        try rejects("Duplicate length rejected") { _ = try LANHTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n".utf8)) }
        try rejects("Chunked encoding rejected") { _ = try LANHTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) }
        try rejects("Pipelined trailing data rejected") { _ = try LANHTTPRequest.parse(valid + Data("GET / HTTP/1.1\r\n\r\n".utf8)) }
        try rejects("Oversized declared body rejected") { _ = try LANHTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n".utf8)) }
        try check(!LANSyncService.safeFilename("../../private\\test\n.txt").contains("/"), "Upload filename cannot traverse")
        try check(!LANSyncService.browserPage.contains("innerHTML"), "Browser renders shared text without HTML injection")
        if CommandLine.arguments.contains("--network") { try networkRoundTrip() }
        print("Automation tests: \(passed) passed")
    }

    static func pump(until condition: () -> Bool, seconds: TimeInterval = 5) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        guard condition() else { throw AutomationError.invalid("Timed out waiting for local network test") }
    }

    static func fetch(_ url: URL, token: String? = nil, content: LANSharedContent? = nil, origin: String? = nil) throws -> (Int, Data) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        if let token { request.setValue(token, forHTTPHeaderField: "X-CClip-Token") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        if let content {
            request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(content)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let lock = NSLock()
        var result: Result<(Int, Data), Error>?
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            lock.lock(); defer { lock.unlock() }
            if let error { result = .failure(error) }
            else { result = .success(((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())) }
        }
        task.resume()
        try pump(until: { lock.lock(); defer { lock.unlock() }; return result != nil })
        lock.lock(); let final = result!; lock.unlock()
        return try final.get()
    }

    static func networkRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CClip-LAN-Test-" + UUID().uuidString, isDirectory: true)
        setenv("CCLIP_DATA_DIR", root.path, 1)
        defer { unsetenv("CCLIP_DATA_DIR"); try? FileManager.default.removeItem(at: root) }
        let service = LANSyncService()
        service.start()
        defer { service.stop() }
        try pump(until: { service.isRunning })
        try check(!service.shareNewCaptures && !service.receiveIncoming, "Automatic directions default disabled")
        let link = service.links[0]
        let token = URLComponents(string: link)!.fragment!
        var components = URLComponents(string: link)!
        components.host = "127.0.0.1"; components.fragment = nil
        let base = components.url!
        let read = base.appendingPathComponent("api/shared")
        let write = base.appendingPathComponent("api/upload")
        try check(try fetch(base).0 == 200, "Actual HTTP browser page")
        try check(try fetch(read).0 == 401, "Actual HTTP request requires token")
        try check(try fetch(read, token: token).1 == Data("null".utf8), "No implicit history sharing")
        try service.publishText("<img src=x onerror=alert(1)> & 世界")
        let published = try fetch(read, token: token)
        try check(try JSONDecoder().decode(LANSharedContent.self, from: published.1).text == "<img src=x onerror=alert(1)> & 世界", "Published text survives HTTP safely")
        try check(try fetch(read, token: token, origin: "https://evil.invalid").0 == 403, "Actual cross-origin HTTP rejection")
        ClipboardManager.shared.captureAllowed = { false }
        try check(try fetch(read, token: token).0 == 423, "Lock hides already shared content")
        ClipboardManager.shared.captureAllowed = { true }
        let upload = LANSharedContent(kind: "text", text: "phone → Mac", attachments: [])
        try check(try fetch(write, token: token, content: upload).0 == 422, "Receive toggle rejects uploads when disabled")
        service.receiveIncoming = true
        try check(try fetch(write, token: token, content: upload).0 == 200, "Actual browser upload HTTP response")
        try check(ClipboardManager.shared.clipboardItems.last?.content == "phone → Mac", "Browser upload reaches clipboard coordinator")
        let count = ClipboardManager.shared.clipboardItems.count
        try check(try fetch(write, token: token, content: upload).0 == 200 && ClipboardManager.shared.clipboardItems.count == count, "Retry revision does not duplicate imported items")
        service.shareNewCaptures = true
        service.sendCaptured(ClipboardItem(id: UUID(), content: "automatic capture", type: .text, timestamp: Date()))
        try check(try JSONDecoder().decode(LANSharedContent.self, from: fetch(read, token: token).1).text == "automatic capture", "Explicit automatic capture sharing")
        service.sendCaptured(ClipboardItem(id: UUID(), content: "incoming no echo", type: .text, timestamp: Date(), sourceApp: "CClip LAN"))
        try check(try JSONDecoder().decode(LANSharedContent.self, from: fetch(read, token: token).1).text == "automatic capture", "Received content is not sent back")
        let file = LANSharedContent(kind: "files", text: "", attachments: [LANAttachment(name: "../hello.txt", mime: "text/plain", base64: Data("file bytes".utf8).base64EncodedString())])
        try check(try fetch(write, token: token, content: file).0 == 200, "Actual file upload")
        let path = ClipboardManager.shared.clipboardItems.last!.filePath!
        try check(path.hasPrefix(root.path) && (try Data(contentsOf: URL(fileURLWithPath: path))) == Data("file bytes".utf8), "Uploaded file retained under isolated local directory")
        service.stop()
        try pump(until: { !service.isRunning })
        service.start()
        try pump(until: { service.isRunning })
        try check(URLComponents(string: service.links[0])!.fragment != token, "Restart rotates access token")
        try check(service.sharedDescription == "尚未共享任何项目", "Restart clears shared content")
        try check(!service.shareNewCaptures && !service.receiveIncoming, "Restart resets automatic directions")
    }
}
#endif
