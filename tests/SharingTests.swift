#if CCLIP_SHARING_TESTS
import Foundation
import Combine
import AppKit
import ImageIO
import UniformTypeIdentifiers

final class PrivacyLock: ObservableObject { static let shared = PrivacyLock(); @Published var locked = false }
final class ClipboardManager { static let shared = ClipboardManager(); @discardableResult func addText(_ text: String) throws -> String { text } }

final class SharingFixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.unsupportedURL) }
            let (status, data) = try handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct SharingTests {
    static var passed = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw AutomationError.invalid("FAIL: " + label) }; passed += 1; print("PASS: " + label)
    }
    static func rejects(_ label: String, action: () throws -> Void) throws {
        do { try action() } catch { passed += 1; print("PASS: " + label); return }; throw AutomationError.invalid("FAIL: " + label)
    }
    static func main() async throws {
        let defaultsName = "dev.cclip.sharing.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName); SharingFixtureProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SharingFixtureProtocol.self]
        let client = SharingHTTPClient(configuration: configuration)
        let translator = OfficialTranslationService(defaults: defaults, client: client)
        var translateConfig = OfficialTranslationConfiguration()
        translateConfig.sourceLanguage = "en"; translateConfig.targetLanguage = "JA"
        let deepL = try OfficialTranslationService.request(input: "Hello 世界", configuration: translateConfig, credential: "fixture-key")
        try check(deepL.url!.absoluteString == "https://api-free.deepl.com/v2/translate", "Official DeepL Free endpoint")
        try check(deepL.value(forHTTPHeaderField: "Authorization") == "DeepL-Auth-Key fixture-key", "DeepL authentication scheme")
        let deepBody = try JSONSerialization.jsonObject(with: deepL.httpBody!) as! [String: Any]
        try check(deepBody["text"] as? [String] == ["Hello 世界"] && deepBody["source_lang"] as? String == "EN", "DeepL request schema")
        translateConfig.provider = .deepLPro
        try check(try OfficialTranslationService.request(input: "x", configuration: translateConfig, credential: "k").url!.host == "api.deepl.com", "Official DeepL Pro endpoint")
        translateConfig.provider = .googleBasic; translateConfig.targetLanguage = "zh-CN"
        let google = try OfficialTranslationService.request(input: "test", configuration: translateConfig, credential: "fixture-key")
        try check(google.url!.absoluteString == "https://translation.googleapis.com/language/translate/v2", "Official Google Basic endpoint")
        try check(google.value(forHTTPHeaderField: "X-Goog-Api-Key") == "fixture-key" && google.url!.query == nil, "Google credential stays in header")
        let googleBody = try JSONSerialization.jsonObject(with: google.httpBody!) as! [String: Any]
        try check(googleBody["q"] as? [String] == ["test"] && googleBody["format"] as? String == "text", "Google request schema")
        translator.configuration = translateConfig
        SharingFixtureProtocol.handler = { request in
            try check(request.url?.host == "translation.googleapis.com", "Injected Google request reaches protocol fixture")
            return (200, Data(#"{"data":{"translations":[{"translatedText":"测试成功"}]}}"#.utf8))
        }
        let googleResult = try await translator.translate("test", credentialOverride: "fixture-key")
        try check(googleResult == "测试成功", "Google fixture response parsing")
        translator.configuration.provider = .deepLFree
        SharingFixtureProtocol.handler = { _ in (200, Data(#"{"translations":[{"text":"こんにちは"}]}"#.utf8)) }
        let deepResult = try await translator.translate("hello", credentialOverride: "fixture-key")
        try check(deepResult == "こんにちは", "DeepL fixture response parsing")
        SharingFixtureProtocol.handler = { _ in (403, Data("secret must not appear".utf8)) }
        do { _ = try await translator.translate("hello", credentialOverride: "fixture-key"); throw AutomationError.invalid("Expected HTTP error") }
        catch { try check(!error.localizedDescription.contains("secret must not appear") && error.localizedDescription.contains("403"), "HTTP error does not echo response secrets") }
        try rejects("Translation credential header injection") { _ = try OfficialTranslationService.request(input: "hello", configuration: translateConfig, credential: "key\r\nX-Evil:1") }
        try rejects("Translation input bound") { _ = try OfficialTranslationService.request(input: String(repeating: "x", count: 100_001), configuration: translateConfig, credential: "key") }
        try rejects("Remote HTTP upload blocked") { _ = try SharingValidation.endpoint("http://public.example/upload") }
        try rejects("Endpoint embedded credentials blocked") { _ = try SharingValidation.endpoint("https://key@public.example/upload") }
        try rejects("Endpoint query credentials blocked") { _ = try SharingValidation.endpoint("https://public.example/upload?key=secret") }
        try rejects("Reserved upload headers blocked") { try SharingValidation.headers(["Host": "evil.example"]) }
        try rejects("Header newline injection blocked") { try SharingValidation.headers(["X-Token": "a\r\nHost: evil"]) }
        try rejects("Case-insensitive duplicate headers blocked") { try SharingValidation.headers(["X-Key":"a","x-key":"b"]) }
        try check(try SharingValidation.endpoint("http://127.0.0.1:9000/upload").host == "127.0.0.1", "Local fixture endpoint supported")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
        bitmap.setColor(.red, atX: 0, y: 0)
        let imageData = bitmap.representation(using: .png, properties: [:])!
        let image = try SelectedUploadImage.validate(imageData, filename: "photo\"\r\n.png")
        var uploadConfig = ImageUploadConfiguration(); uploadConfig.endpoint = "https://fixture.invalid/upload"
        uploadConfig.imageField = "file"; uploadConfig.formFieldsJSON = "{\"folder\":\"demo\"}"
        let multipart = try ImageUploadService.request(image: image, configuration: uploadConfig, headers: ["X-Mode":"fixture"], credential: "demo")
        let body = String(decoding: multipart.httpBody!, as: UTF8.self)
        try check(body.contains("name=\"file\"") && body.contains("name=\"folder\"") && body.contains("image/png"), "Multipart image and extra fields")
        try check(!body.contains("filename=\"photo\"\r\n"), "Multipart filename sanitized")
        try check(multipart.value(forHTTPHeaderField: "Authorization") == "Bearer demo", "Upload credential header")
        uploadConfig.credentialLocation = "form"; uploadConfig.credentialField = "key"; uploadConfig.credentialPrefix = ""
        let withFormKey = try ImageUploadService.request(image: image, configuration: uploadConfig, headers: [:], credential: "form-secret")
        try check(String(decoding: withFormKey.httpBody!, as: UTF8.self).contains("name=\"key\"\r\n\r\nform-secret"), "Upload form credential supported")
        try check(try SharingValidation.jsonString(Data(#"{"files":[{"url":"https://cdn.example/image.png"}]}"#.utf8), path: "files.0.url") == "https://cdn.example/image.png", "Nested array URL path")
        try rejects("Missing response path fails") { _ = try SharingValidation.jsonString(Data("{}".utf8), path: "data.url") }
        try rejects("Invalid image rejected") { _ = try SelectedUploadImage.validate(Data("not-image".utf8), filename: "x.png") }
        let uploader = ImageUploadService(defaults: defaults, client: client)
        try check(!uploader.enabled, "Upload disabled by default")
        uploader.configuration = uploadConfig
        uploader.enabled = true
        SharingFixtureProtocol.handler = { request in
            try check(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Content-Type")!.hasPrefix("multipart/form-data"), "Upload fixture receives multipart POST")
            return (200, Data(#"{"data":{"url":"https://cdn.example/image.png"}}"#.utf8))
        }
        let uploaded = try await uploader.upload(image, credentialOverride: "", headersOverride: [:])
        try check(uploaded.absoluteString == "https://cdn.example/image.png", "Upload protocol fixture round trip")
        SharingFixtureProtocol.handler = { _ in (200, Data(#"{"data":{"url":"javascript:alert(1)"}}"#.utf8)) }
        do { _ = try await uploader.upload(image, credentialOverride: "", headersOverride: [:]); throw AutomationError.invalid("Expected invalid URL") }
        catch { try check(error.localizedDescription.contains("HTTP"), "Non-HTTP returned links rejected") }
        try check(try SafeNativeTextFunctions.apply(.trim, input: "  text\n") == "text", "Reserved native text functions are pure")
        print("Sharing tests: \(passed) passed; no external services contacted")
    }
}
#endif
