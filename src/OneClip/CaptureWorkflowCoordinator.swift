import AppKit

@MainActor
final class CaptureWorkflowCoordinator {
    static let shared = CaptureWorkflowCoordinator()
    private var recognition: [UUID: CaptureRecognitionController] = [:]
    private var clipboardFormulaTask: Task<Void, Never>?
    private var clipboardFormulaGeneration = UUID()
    private init() {
        CaptureScrollingController.shared.onResult = { [weak self] in self?.handle($0) }
        PinnedImageController.shared.onWorkflowAction = { [weak self] in self?.handle($0) }
    }
    func prepare() {}
    func pinClipboard() {
        guard !PrivacyLock.shared.locked else { return }
        clipboardFormulaTask?.cancel(); clipboardFormulaTask = nil
        clipboardFormulaGeneration = UUID(); let token = clipboardFormulaGeneration
        let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let formula = (text.hasPrefix("$$") && text.hasSuffix("$$")) || (text.hasPrefix("\\[") && text.hasSuffix("\\]")) || text.hasPrefix("\\begin{")
        guard formula else { PinnedImageController.shared.showClipboard(); return }
        clipboardFormulaTask = Task { @MainActor in
            let preview = CaptureFormulaPreview(); preview.set(CaptureRecognitionService.cleanFormula(text))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = preview.webView
            defer { preview.close(); window.contentView = nil; window.close(); if token == clipboardFormulaGeneration { clipboardFormulaTask = nil } }
            do {
                var ready = false
                for _ in 0..<50 {
                    try Task.checkCancellation()
                    if (try? await preview.mathML())?.isEmpty == false { ready = true; break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard ready else { throw CaptureMessage("公式无法渲染，已保留为文本贴图。", "The formula could not render; pinned as text.") }
                let data = try await preview.png(); try Task.checkCancellation()
                guard !PrivacyLock.shared.locked else { return }
                PinnedImageController.shared.showRendered(data, originalText: text)
            } catch {
                if !Task.isCancelled && !PrivacyLock.shared.locked { PinnedImageController.shared.showText(text); WorkflowState.shared.status = error.localizedDescription }
            }
        }
    }
    var isLive: Bool { CaptureScrollingController.shared.isActive || CaptureRecordingController.shared.isActive }
    @discardableResult func toggleLive() -> Bool {
        if CaptureRecordingController.shared.isActive { CaptureRecordingController.shared.toggleRecording(); return true }
        if CaptureScrollingController.shared.isActive { CaptureScrollingController.shared.toggle(); return true }
        return false
    }
    func handle(_ result: CaptureAnnotationResult) {
        guard !PrivacyLock.shared.locked else { return }
        switch result.destination {
        case .copy:
            do {
                switch try ClipboardManager.shared.copyScreenshot(result.data) {
                case .success: WorkflowState.shared.status = L("截屏已复制并存入历史。", "Screenshot copied and added to history.")
                case .failure(let error): WorkflowState.shared.status = L("截屏已复制，但存入历史失败：", "Screenshot copied, but saving to history failed: ") + error.localizedDescription
                }
            } catch { WorkflowState.shared.status = error.localizedDescription }
        case .saved(let url): WorkflowState.shared.status = L("截屏已保存：", "Screenshot saved: ") + url.lastPathComponent
        case .action(let action, let region):
            switch action {
            case .pin: PinnedImageController.shared.show(result.data)
            case .longCapture: CaptureScrollingController.shared.start(region: region, initialImage: result.data)
            case .recording: CaptureRecordingController.shared.start(region: region)
            case .ocr, .table, .barcode, .translate, .formula:
                let controller = CaptureRecognitionController(data: result.data, mode: action)
                controller.onClose = { [weak self] id in self?.recognition.removeValue(forKey: id) }
                recognition[controller.id] = controller; controller.show()
            }
        }
    }
    func cancelAll() {
        clipboardFormulaGeneration = UUID()
        clipboardFormulaTask?.cancel(); clipboardFormulaTask = nil
        CaptureScrollingController.shared.cancel(); CaptureRecordingController.shared.cancel()
        let windows = Array(recognition.values); recognition.removeAll()
        windows.forEach { $0.onClose = nil; $0.close() }
    }
}
