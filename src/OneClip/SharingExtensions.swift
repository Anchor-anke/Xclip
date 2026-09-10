import Foundation
import Combine
import ImageIO
import UniformTypeIdentifiers

enum SharingValidation {
    static func endpoint(_ value: String) throws -> URL {
        guard let parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)), let host = parts.host,
              parts.user == nil, parts.password == nil, parts.fragment == nil, parts.query == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())),
              let url = parts.url else { throw AutomationError.invalid("使用 HTTPS 地址；本机测试允许 HTTP。请勿在地址中加入凭证或查询参数。", "Use HTTPS, or local HTTP for testing. Do not put credentials or query parameters in the URL.") }
        return url
    }
    static func token(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "!#$%&'*+-.^_`|~".contains($0)) }
    }
    static func headers(_ headers: [String: String]) throws {
        let prohibited: Set<String> = ["host", "content-length", "transfer-encoding", "connection", "content-type", "cookie", "origin"]
        guard headers.count <= 20, Set(headers.keys.map { $0.lowercased() }).count == headers.count else { throw AutomationError.invalid("请求头过多或重复。", "Too many or duplicate headers.") }
        for (name, value) in headers {
            guard token(name), !prohibited.contains(name.lowercased()), value.utf8.count <= 4096,
                  value.rangeOfCharacter(from: .controlCharacters) == nil else { throw AutomationError.invalid("附加请求头无效。", "Invalid additional header.") }
        }
    }
    static func dictionary(_ text: String) throws -> [String: String] {
        guard let bytes = text.data(using: .utf8), bytes.count <= 16_384,
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: String] else { throw AutomationError.invalid("请输入 JSON 字符串字典，例如 {\"name\":\"value\"}。", "Enter a JSON string dictionary, such as {\"name\":\"value\"}.") }
        return object
    }
    static func jsonString(_ data: Data, path: String) throws -> String {
        var value: Any = try JSONSerialization.jsonObject(with: data)
        let components = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.count <= 20 else { throw AutomationError.invalid("JSON 路径无效。", "Invalid JSON path.") }
        for key in components {
            if let object = value as? [String: Any], let child = object[key] { value = child }
            else if let array = value as? [Any], let index = Int(key), array.indices.contains(index) { value = array[index] }
            else { throw AutomationError.invalid("响应中没有配置的结果字段：" + path, "Response field not found: " + path) }
        }
        guard let string = value as? String, !string.isEmpty else { throw AutomationError.invalid("结果字段必须是非空字符串。", "The result field must be a nonempty string.") }
        return string
    }
}

private final class SharingNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class SharingHTTPClient {
    private let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration = .ephemeral) { self.configuration = configuration }
    func send(_ request: URLRequest) async throws -> Data {
        let session = URLSession(configuration: configuration, delegate: SharingNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AutomationError.invalid("HTTP 响应无效。", "Invalid HTTP response.") }
        guard (200...299).contains(http.statusCode) else {
            throw AutomationError.invalid("服务返回 HTTP \(http.statusCode)，请检查配置、凭证和服务用量。", "Service returned HTTP \(http.statusCode). Check configuration, credentials and quota.")
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 2_097_152 else { throw AutomationError.invalid("服务响应超过 2 MB。", "Response exceeds 2 MB.") }
            data.append(byte)
        }
        return data
    }
}

struct ImageUploadConfiguration: Codable {
    var endpoint = ""
    var imageField = "image"
    var responseURLPath = "data.url"
    var formFieldsJSON = "{}"
    var credentialLocation = "header"
    var credentialField = "Authorization"
    var credentialPrefix = "Bearer "
    var credentialAccount: String { "upload.credential:" + endpoint }
    var headersAccount: String { "upload.headers:" + endpoint }
}

struct SelectedUploadImage {
    let data: Data
    let filename: String
    let mime: String
    static func read(_ url: URL) throws -> SelectedUploadImage {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 8_388_608 else { throw AutomationError.invalid("图片超过 8 MB。", "Image exceeds 8 MB.") }
        return try validate(Data(contentsOf: url, options: .mappedIfSafe), filename: url.lastPathComponent)
    }
    static func validate(_ data: Data, filename: String) throws -> SelectedUploadImage {
        guard data.count <= 8_388_608, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 32_000_000,
              let type = CGImageSourceGetType(source) else { throw AutomationError.invalid("请选择 8 MB、3200 万像素以内的有效图片。", "Choose a valid image up to 8 MB and 32 million pixels.") }
        // ImageIO's detected type is authoritative; avoid a LaunchServices registry dependency for these standard raster types.
        let knownMIME = ["public.png": "image/png", "public.jpeg": "image/jpeg", "public.tiff": "image/tiff",
            "com.compuserve.gif": "image/gif", "public.heic": "image/heic", "public.heif": "image/heif", "org.webmproject.webp": "image/webp"]
        guard let mime = knownMIME[type as String] else { throw AutomationError.invalid("不支持此图片格式。", "Unsupported image format.") }
        let clean = filename.components(separatedBy: CharacterSet(charactersIn: "/\\\"\r\n").union(.controlCharacters)).joined(separator: "_")
        return SelectedUploadImage(data: data, filename: String(clean.prefix(120)), mime: mime)
    }
}

final class ImageUploadService: ObservableObject {
    static let shared = ImageUploadService()
    private let defaults: UserDefaults
    private let client: SharingHTTPClient
    @Published var enabled = false
    @Published var configuration: ImageUploadConfiguration {
        didSet { if let data = try? JSONEncoder().encode(configuration) { defaults.set(data, forKey: "CClip.ImageUpload") } }
    }
    init(defaults: UserDefaults = .standard, client: SharingHTTPClient = SharingHTTPClient()) {
        self.defaults = defaults; self.client = client
        configuration = defaults.data(forKey: "CClip.ImageUpload").flatMap { try? JSONDecoder().decode(ImageUploadConfiguration.self, from: $0) } ?? ImageUploadConfiguration()
    }
    static func request(image: SelectedUploadImage, configuration: ImageUploadConfiguration, headers: [String: String], credential: String) throws -> URLRequest {
        let image = try SelectedUploadImage.validate(image.data, filename: image.filename)
        var request = URLRequest(url: try SharingValidation.endpoint(configuration.endpoint))
        try SharingValidation.headers(headers)
        guard SharingValidation.token(configuration.imageField), !configuration.responseURLPath.isEmpty else { throw AutomationError.invalid("上传字段或响应路径无效。", "Invalid upload field or response path.") }
        var fields = try SharingValidation.dictionary(configuration.formFieldsJSON)
        for (name, value) in fields { guard SharingValidation.token(name), value.utf8.count <= 16_384 else { throw AutomationError.invalid("表单字段无效。", "Invalid form field.") } }
        var allHeaders = headers
        if !credential.isEmpty {
            guard SharingValidation.token(configuration.credentialField), configuration.credentialPrefix.rangeOfCharacter(from: .controlCharacters) == nil else { throw AutomationError.invalid("凭证配置无效。", "Invalid credential configuration.") }
            if configuration.credentialLocation == "form" { fields[configuration.credentialField] = configuration.credentialPrefix + credential }
            else {
                allHeaders[configuration.credentialField] = configuration.credentialPrefix + credential
                try SharingValidation.headers(allHeaders)
            }
        }
        guard fields[configuration.imageField] == nil else { throw AutomationError.invalid("图片字段与其他表单字段冲突。", "Image field conflicts with another form field.") }
        let boundary = "CClip-" + UUID().uuidString
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(configuration.imageField)\"; filename=\"\(image.filename)\"\r\nContent-Type: \(image.mime)\r\n\r\n")
        body.append(image.data); append("\r\n--\(boundary)--\r\n")
        request.httpMethod = "POST"; request.timeoutInterval = 90; request.httpBody = body
        for (name, value) in allHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return request
    }
    func upload(_ image: SelectedUploadImage, credentialOverride: String? = nil, headersOverride: [String: String]? = nil) async throws -> URL {
        guard enabled else { throw AutomationError.invalid("请先启用图片上传。", "Enable image upload first.") }
        let config = configuration
        let headers: [String: String]
        if let headersOverride { headers = headersOverride }
        else {
            let headerText = try AutomationKeychain.key(for: config.headersAccount)
            headers = try SharingValidation.dictionary(headerText.isEmpty ? "{}" : headerText)
        }
        let key = try credentialOverride ?? AutomationKeychain.key(for: config.credentialAccount)
        let data = try await client.send(Self.request(image: image, configuration: config, headers: headers, credential: key))
        let value = try SharingValidation.jsonString(data, path: config.responseURLPath)
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw AutomationError.invalid("服务未返回有效的图片 HTTP 链接。", "The service did not return a valid HTTP image URL.") }
        return url
    }
}

enum OfficialTranslationProvider: String, Codable, CaseIterable, Identifiable {
    case deepLFree, deepLPro, googleBasic
    var id: String { rawValue }
    var title: String { switch self { case .deepLFree: return "DeepL API Free"; case .deepLPro: return "DeepL API Pro"; case .googleBasic: return "Google Cloud Translation Basic" } }
    var endpoint: String { switch self { case .deepLFree: return "https://api-free.deepl.com/v2/translate"; case .deepLPro: return "https://api.deepl.com/v2/translate"; case .googleBasic: return "https://translation.googleapis.com/language/translate/v2" } }
    var credentialAccount: String { "official.translation:" + rawValue }
}

struct OfficialTranslationConfiguration: Codable {
    var provider = OfficialTranslationProvider.deepLFree
    var sourceLanguage = ""
    var targetLanguage = "ZH"
}

final class OfficialTranslationService: ObservableObject {
    static let shared = OfficialTranslationService()
    private let defaults: UserDefaults
    private let client: SharingHTTPClient
    @Published var configuration: OfficialTranslationConfiguration {
        didSet { if let data = try? JSONEncoder().encode(configuration) { defaults.set(data, forKey: "CClip.OfficialTranslation") } }
    }
    init(defaults: UserDefaults = .standard, client: SharingHTTPClient = SharingHTTPClient()) {
        self.defaults = defaults; self.client = client
        configuration = defaults.data(forKey: "CClip.OfficialTranslation").flatMap { try? JSONDecoder().decode(OfficialTranslationConfiguration.self, from: $0) } ?? OfficialTranslationConfiguration()
    }
    static func request(input: String, configuration: OfficialTranslationConfiguration, credential: String) throws -> URLRequest {
        guard !input.isEmpty, input.utf8.count <= 100_000, !credential.isEmpty,
              credential.rangeOfCharacter(from: .controlCharacters) == nil else { throw AutomationError.invalid("请输入文本（最多 100 KB）并保存 API 凭证。", "Enter text (up to 100 KB) and save an API credential.") }
        let source = configuration.sourceLanguage.trimmingCharacters(in: .whitespaces)
        let target = configuration.targetLanguage.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty, (source + target).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { throw AutomationError.invalid("请输入服务支持的语言代码。", "Enter language codes supported by the service.") }
        var request = URLRequest(url: URL(string: configuration.provider.endpoint)!)
        request.httpMethod = "POST"; request.timeoutInterval = 60
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var body: [String: Any]
        if configuration.provider == .googleBasic {
            request.setValue(credential, forHTTPHeaderField: "X-Goog-Api-Key")
            body = ["q": [input], "target": target, "format": "text"]
            if !source.isEmpty { body["source"] = source }
        } else {
            request.setValue("DeepL-Auth-Key " + credential, forHTTPHeaderField: "Authorization")
            body = ["text": [input], "target_lang": target.uppercased()]
            if !source.isEmpty { body["source_lang"] = source.uppercased() }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        guard request.httpBody!.count <= 131_072 else { throw AutomationError.invalid("翻译请求超过 128 KiB。", "Translation request exceeds 128 KiB.") }
        return request
    }
    func translate(_ input: String, credentialOverride: String? = nil) async throws -> String {
        let config = configuration
        let key = try credentialOverride ?? AutomationKeychain.key(for: config.provider.credentialAccount)
        let data = try await client.send(Self.request(input: input, configuration: config, credential: key))
        return try SharingValidation.jsonString(data, path: config.provider == .googleBasic ? "data.translations.0.translatedText" : "translations.0.text")
    }
}

/// Future native extensions must consume explicit input and return a value; no JS registration exists here.
enum SafeNativeTextOperation: String { case trim, uppercase, lowercase }
enum SafeNativeTextFunctions {
    static func apply(_ operation: SafeNativeTextOperation, input: String) throws -> String {
        guard input.utf8.count <= 1_048_576 else { throw AutomationError.invalid("文本超过 1 MB。", "Text exceeds 1 MB.") }
        switch operation { case .trim: return input.trimmingCharacters(in: .whitespacesAndNewlines); case .uppercase: return input.uppercased(); case .lowercase: return input.lowercased() }
    }
}
