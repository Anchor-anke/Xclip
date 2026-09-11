import AppKit
import WebKit
import Combine

/// Offline KaTeX, bundled with fonts and a restrictive content policy. User input is JSON encoded.
@MainActor
final class CaptureFormulaPreview: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published private(set) var error = ""
    private var loaded = false
    private var closed = false
    private var text = ""
    private var revision: UInt64 = 0
    private let directory: URL?
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 260), configuration: configuration)
        directory = Bundle.main.resourceURL?.appendingPathComponent("Formula", isDirectory: true)
        super.init()
        webView.navigationDelegate = self
        if let directory, FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.html").path) {
            webView.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
        } else { error = CaptureLocalization.text("公式渲染资源缺失，请重新安装应用。", "Formula resources are missing. Reinstall the app.") }
    }
    func set(_ text: String) { guard !closed else { return }; self.text = String(text.prefix(20_000)); revision &+= 1; if loaded { render() } }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { guard !closed else { return }; loaded = true; render() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !closed else { return }; loaded = false; self.error = error.localizedDescription
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        decisionHandler(url?.isFileURL == true && url?.deletingLastPathComponent().standardizedFileURL == directory?.standardizedFileURL ? .allow : .cancel)
    }
    private var renderScript: String {
        let json = (try? JSONSerialization.data(withJSONObject: [text])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return "window.renderFormula(\(json)[0])"
    }
    private func render() {
        let token = revision
        webView.evaluateJavaScript(renderScript) { [weak self] value, failure in
            guard let self, token == self.revision else { return }
            self.error = failure?.localizedDescription ?? value as? String ?? ""
        }
    }
    func mathML() async throws -> String {
        let token = try await ready()
        let value = try await webView.evaluateJavaScript("window.formulaMathML()") as? String ?? ""
        try validate(token)
        return value
    }
    private func validate(_ token: UInt64) throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard token == revision else { throw CaptureMessage("公式已更改，请重新导出。", "The formula changed. Export it again.") }
    }
    private func ready() async throws -> UInt64 {
        let token = revision
        try validate(token)
        guard loaded else { throw CaptureMessage(error.isEmpty ? "公式预览还未就绪。" : error, error.isEmpty ? "Formula preview is not ready." : error) }
        let failure = try await webView.evaluateJavaScript(renderScript) as? String ?? ""
        try validate(token)
        guard failure.isEmpty, !text.isEmpty else { throw CaptureMessage(failure.isEmpty ? "请输入 LaTeX 公式。" : failure, failure.isEmpty ? "Enter a LaTeX formula." : failure) }
        _ = try await webView.callAsyncJavaScript("await document.fonts.ready; return true;", arguments: [:], in: nil, contentWorld: .page)
        try validate(token)
        return token
    }
    func png() async throws -> Data {
        let token = try await ready()
        guard let bounds = try await webView.evaluateJavaScript("(()=>{const b=window.formulaBounds(),f=document.getElementById('formula');return {width:Math.max(b.width,f.scrollWidth),height:Math.max(b.height,f.scrollHeight)}})()") as? [String: Double],
              let width = bounds["width"], let height = bounds["height"], width.isFinite, height.isFinite, width > 0, height > 0,
              width * 2 <= 8192, height * 2 <= 8192, ceil(width * 2) * ceil(height * 2) <= 16_000_000 else { throw CaptureMessage("公式尺寸过大，请分行后重试。", "Formula is too large. Split it across lines.") }
        try validate(token)
        let previousSize = webView.frame.size
        webView.setFrameSize(CGSize(width: max(previousSize.width, ceil(width)), height: max(previousSize.height, ceil(height))))
        defer { if !closed { webView.setFrameSize(previousSize) } }
        // A WK snapshot only paints its viewport. Expand it to include overflowing LaTeX before taking the image.
        _ = try await webView.evaluateJavaScript("document.getElementById('formula').getBoundingClientRect().width")
        try validate(token)
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: width, height: height)
        configuration.snapshotWidth = NSNumber(value: width * 2)
        let image = try await webView.takeSnapshot(configuration: configuration)
        try validate(token)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw CaptureToolError.invalidImage }
        return try CaptureImageCodec.png(cg)
    }
    func close() { guard !closed else { return }; closed = true; loaded = false; revision &+= 1; webView.stopLoading(); webView.navigationDelegate = nil; webView.loadHTMLString("", baseURL: nil); text = "" }
}
