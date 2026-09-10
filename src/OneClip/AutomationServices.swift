import Foundation
import Combine
import Security
import JavaScriptCore

func AutomationL(_ chinese: String, _ english: String) -> String {
    AppLanguage.text(chinese, english)
}

enum AutomationError: LocalizedError {
    case invalid(String)
    case localized(String, String)
    static func invalid(_ chinese: String, _ english: String) -> AutomationError { .localized(chinese, english) }
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .localized(let chinese, let english): return AutomationL(chinese, english)
        }
    }
}

/// Retain both translations so changing the interface language also updates existing status messages.
struct AutomationMessage {
    private let resolve: () -> String
    init(_ chinese: String = "", _ english: String = "") {
        resolve = { AutomationL(chinese, english) }
    }
    init(error: Error, chinesePrefix: String = "", englishPrefix: String = "") {
        resolve = { AutomationL(chinesePrefix, englishPrefix) + error.localizedDescription }
    }
    var text: String { resolve() }
    var isEmpty: Bool { text.isEmpty }
}

enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case ollama, compatible
    var id: String { rawValue }
    var title: String { self == .ollama ? "Ollama" : AutomationL("LM Studio / OpenAI 兼容接口", "LM Studio / OpenAI-compatible") }
}

struct AIConfiguration: Codable {
    var provider: AIProvider = .ollama
    var endpoint = "http://127.0.0.1:11434"
    var model = ""
    var temperature = 0.3

    func requestURL() throws -> URL {
        guard var components = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw AutomationError.invalid("请输入不含凭证或查询参数的服务地址。", "Enter an endpoint without credentials or query parameters.")
        }
        let isLocal = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
        guard components.scheme == "https" || (components.scheme == "http" && isLocal) else {
            throw AutomationError.invalid("远程服务需要 HTTPS；本机 Ollama / LM Studio 可使用 HTTP。", "Remote services require HTTPS. Local Ollama / LM Studio can use HTTP.")
        }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if provider == .ollama {
            components.path = path.hasSuffix("api/chat") ? "/" + path : "/" + [path, "api/chat"].filter { !$0.isEmpty }.joined(separator: "/")
        } else {
            components.path = path.hasSuffix("chat/completions") ? "/" + path : "/" + [path.isEmpty ? "v1" : path, "chat/completions"].joined(separator: "/")
        }
        guard let url = components.url else { throw AutomationError.invalid("服务地址无效。", "Invalid service endpoint.") }
        return url
    }
}

enum AutomationKeychain {
    private static let service = "dev.cclip.ai-credentials"
    static func key(for endpoint: String) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: endpoint,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw AutomationError.invalid("无法读取钥匙串凭证（\(status)）。", "Could not read the Keychain credential (\(status)).")
        }
        return value
    }
    static func save(_ key: String, for endpoint: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: endpoint]
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AutomationError.invalid("无法删除钥匙串凭证（\(status)）。", "Could not delete the Keychain credential (\(status)).") }
            return
        }
        let data = Data(key.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(addition as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AutomationError.invalid("无法保存钥匙串凭证（\(status)）。", "Could not save the Keychain credential (\(status)).") }
    }
}

private final class NoAIRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class AIService: ObservableObject {
    static let shared = AIService()
    private let defaults: UserDefaults
    private var notificationObservers: [NSObjectProtocol] = []
    @Published var draftInput = ""
    @Published var draftTaskKind = "summary"
    @Published var configuration: AIConfiguration {
        didSet { if let data = try? JSONEncoder().encode(configuration) { defaults.set(data, forKey: "CClip.AIConfiguration") } }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configuration = defaults.data(forKey: "CClip.AIConfiguration").flatMap { try? JSONDecoder().decode(AIConfiguration.self, from: $0) } ?? AIConfiguration()
        for name in ["CClipAIInput", "CClipTranslateText"] {
            notificationObservers.append(NotificationCenter.default.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] notification in
                guard let text = notification.object as? String else { return }
                self?.draftInput = text
                self?.draftTaskKind = name == "CClipTranslateText" ? "translate" : "summary"
            })
        }
    }
    deinit { notificationObservers.forEach(NotificationCenter.default.removeObserver) }

    /// Called only from an explicit Send action. No clipboard or history reads occur here.
    func generate(input: String, instruction: String, imageData: Data? = nil) async throws -> String {
        let config = configuration
        guard !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AutomationError.invalid("请填写已安装或服务支持的模型名称。", "Enter the name of an installed model or one supported by the service.") }
        guard input.utf8.count <= 1_048_576, (imageData?.count ?? 0) <= 8_388_608 else { throw AutomationError.invalid("文本上限为 1 MB，图片上限为 8 MB。", "Text is limited to 1 MB and images to 8 MB.") }
        var request = URLRequest(url: try config.requestURL())
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = try AutomationKeychain.key(for: config.endpoint)
        if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        let temperature = min(2, max(0, config.temperature))
        var body: [String: Any]
        if config.provider == .ollama {
            var message: [String: Any] = ["role": "user", "content": input]
            if let imageData { message["images"] = [imageData.base64EncodedString()] }
            body = ["model": config.model, "stream": false,
                    "messages": [["role": "system", "content": instruction], message], "options": ["temperature": temperature]]
        } else {
            var content: Any = input
            if let imageData {
                content = [["type": "text", "text": input], ["type": "image_url", "image_url": ["url": "data:image/png;base64," + imageData.base64EncodedString()]]] as [[String: Any]]
            }
            body = ["model": config.model, "stream": false, "temperature": temperature,
                    "messages": [["role": "system", "content": instruction], ["role": "user", "content": content]]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let delegate = NoAIRedirects()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AutomationError.invalid("服务未返回 HTTP 响应。", "The service did not return an HTTP response.") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 4_194_304 else { throw AutomationError.invalid("服务返回超过 4 MB，已停止读取。", "The response exceeded 4 MB. Reading was stopped.") }
            data.append(byte)
        }
        guard (200...299).contains(http.statusCode) else {
            // Never display the raw response: some services echo credentials and submitted text.
            throw AutomationError.invalid("服务返回 HTTP \(http.statusCode)。请检查地址、模型、凭证与服务日志。", "The service returned HTTP \(http.statusCode). Check the endpoint, model, credentials and service logs.")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AutomationError.invalid("服务响应不是支持的 JSON 格式。", "The response is not in a supported JSON format.") }
        let answer: String?
        if config.provider == .ollama { answer = (object["message"] as? [String: Any])?["content"] as? String }
        else { answer = ((object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String }
        guard let answer, !answer.isEmpty else { throw AutomationError.invalid("服务未返回文本结果；请确认模型及接口格式。", "The service returned no text. Check the model and API format.") }
        return answer
    }
}

struct ClipboardScript: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var code: String
    var trigger = "manual"
    var enabled = false

    // Translate only untouched built-in names; custom names are user content.
    var displayName: String { displayName(languageCode: AutomationL("zh", "en")) }
    func displayName(languageCode: String) -> String {
        switch (name, code) {
        case ("去除首尾空白", "input.trim()"), ("Trim whitespace", "input.trim()"):
            return languageCode == "en" ? "Trim whitespace" : "去除首尾空白"
        case ("格式化 JSON", "JSON.stringify(JSON.parse(input), null, 2)"), ("Format JSON", "JSON.stringify(JSON.parse(input), null, 2)"):
            return languageCode == "en" ? "Format JSON" : "格式化 JSON"
        case ("转为大写", "input.toUpperCase()"), ("Uppercase", "input.toUpperCase()"):
            return languageCode == "en" ? "Uppercase" : "转为大写"
        default: return name
        }
    }
}

private struct ScriptRequest: Codable { var text: String; var code: String }
private struct ScriptResponse: Codable {
    var output: String?
    var error: String?
    var errorChinese: String? = nil
    var errorEnglish: String? = nil
}

final class ScriptService: ObservableObject {
    static let shared = ScriptService()
    private let defaults: UserDefaults
    private let configuredHelper: URL?
    @Published var scripts: [ClipboardScript] {
        didSet { if let data = try? JSONEncoder().encode(scripts) { defaults.set(data, forKey: "CClip.Scripts") } }
    }
    init(defaults: UserDefaults = .standard, helperURL: URL? = nil) {
        self.defaults = defaults
        self.configuredHelper = helperURL
        scripts = defaults.data(forKey: "CClip.Scripts").flatMap { try? JSONDecoder().decode([ClipboardScript].self, from: $0) } ?? [
            ClipboardScript(name: "去除首尾空白", code: "input.trim()"),
            ClipboardScript(name: "格式化 JSON", code: "JSON.stringify(JSON.parse(input), null, 2)"),
            ClipboardScript(name: "转为大写", code: "input.toUpperCase()")]
    }

    func transform(_ text: String, trigger: String) throws -> String {
        let selected = scripts.filter { $0.enabled && $0.trigger == trigger }
        guard selected.count <= 4 else { throw AutomationError.invalid("每条自动工作流最多启用 4 个脚本。", "Enable at most 4 scripts per automatic workflow.") }
        return try selected.reduce(text) { try execute($1, input: $0) }
    }

    func execute(_ script: ClipboardScript, input: String, helperURL: URL? = nil, timeout: TimeInterval = 0.75) throws -> String {
        guard input.utf8.count <= 1_048_576, script.code.utf8.count <= 65_536 else { throw AutomationError.invalid("脚本输入上限为 1 MB，脚本源码上限为 64 KB。", "Script input is limited to 1 MB and source code to 64 KB.") }
        let runner = helperURL ?? configuredHelper ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CClipScriptRunner")
        guard FileManager.default.isExecutableFile(atPath: runner.path) else { throw AutomationError.invalid("缺少脚本运行组件。请使用完整构建的 Xclip.app。", "The script runner is missing. Use a complete build of Xclip.app.") }
        let process = Process()
        process.executableURL = runner
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        let inputPipe = Pipe(), outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        let readFinished = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var result = Data()
        var oversized = false
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { readFinished.signal() }
            while true {
                let chunk = outputPipe.fileHandleForReading.readData(ofLength: 65536)
                if chunk.isEmpty { break }
                resultLock.lock()
                if result.count + chunk.count > 2_097_152 { oversized = true; resultLock.unlock(); kill(process.processIdentifier, SIGKILL); break }
                result.append(chunk)
                resultLock.unlock()
            }
        }
        inputPipe.fileHandleForWriting.write(try JSONEncoder().encode(ScriptRequest(text: input, code: script.code)))
        try? inputPipe.fileHandleForWriting.close()
        if finished.wait(timeout: .now() + max(0.05, timeout)) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 0.5)
            _ = readFinished.wait(timeout: .now() + 0.5)
            throw AutomationError.invalid("脚本「\(script.displayName(languageCode: "zh"))」超过执行时限，已终止。", "Script “\(script.displayName(languageCode: "en"))” exceeded its time limit and was stopped.")
        }
        guard readFinished.wait(timeout: .now() + 0.5) == .success else { throw AutomationError.invalid("脚本输出读取超时。", "Reading the script output timed out.") }
        resultLock.lock()
        let payload = result, tooLarge = oversized
        resultLock.unlock()
        guard !tooLarge else { throw AutomationError.invalid("脚本输出超过 2 MB。", "Script output exceeds 2 MB.") }
        guard process.terminationStatus == 0, let response = try? JSONDecoder().decode(ScriptResponse.self, from: payload) else {
            throw AutomationError.invalid("脚本进程异常结束。", "The script process ended unexpectedly.")
        }
        if let chinese = response.errorChinese, let english = response.errorEnglish {
            throw AutomationError.invalid("脚本「\(script.displayName(languageCode: "zh"))」：\(chinese)", "Script “\(script.displayName(languageCode: "en"))”: \(english)")
        }
        if let error = response.error { throw AutomationError.invalid("脚本「\(script.displayName(languageCode: "zh"))」：\(error)", "Script “\(script.displayName(languageCode: "en"))”: \(error)") }
        guard let output = response.output else { throw AutomationError.invalid("脚本必须返回字符串。", "The script must return a string.") }
        return output
    }
}

#if CCLIP_SCRIPT_HELPER
@main enum CClipScriptRunner {
    static func main() {
        let response: ScriptResponse
        do {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard data.count <= 1_200_000 else { throw AutomationError.invalid("输入过大。", "Input is too large.") }
            let request = try JSONDecoder().decode(ScriptRequest.self, from: data)
            guard let context = JSContext() else { throw AutomationError.invalid("JavaScript 引擎启动失败。", "Could not start the JavaScript engine.") }
            // A fresh JavaScriptCore context has no filesystem, process, network, AppKit or Objective-C bridge.
            context.setObject(request.text, forKeyedSubscript: "input" as NSString)
            let result = context.evaluateScript("(function(input) { 'use strict'; return (\n" + request.code + "\n); })(input)")
            if let exception = context.exception { throw AutomationError.invalid(String((exception.toString() ?? AutomationL("JavaScript 错误", "JavaScript error")).prefix(400))) }
            guard let result, result.isString, let output = result.toString() else { throw AutomationError.invalid("表达式必须返回字符串。", "The expression must return a string.") }
            guard output.utf8.count <= 1_048_576 else { throw AutomationError.invalid("输出过大。", "Output is too large.") }
            response = ScriptResponse(output: output, error: nil)
        } catch AutomationError.localized(let chinese, let english) {
            response = ScriptResponse(output: nil, error: nil, errorChinese: chinese, errorEnglish: english)
        } catch { response = ScriptResponse(output: nil, error: error.localizedDescription) }
        if let data = try? JSONEncoder().encode(response) { FileHandle.standardOutput.write(data) }
    }
}
#endif
