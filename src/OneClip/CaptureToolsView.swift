import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CaptureToolsView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    private let onCapture: ((Data) -> Void)?
    @StateObject private var captureService = CaptureService.shared
    @State private var mode: CaptureMode = .region
    @State private var delay = 0
    @State private var imageData: Data?
    @State private var recognizedText = ""
    @State private var showEditor = false
    @State private var busy = false
    @State private var isVisible = false
    @State private var status = CaptureMessage("", "")
    @State private var errorMessage: Error?
    @State private var operation: Task<Void, Never>?
    @State private var operationID = UUID()
    @State private var longDirection: CaptureScrollDirection = .vertical
    @State private var longRegion: CGRect?
    @State private var longFrames: [Data] = []
    @State private var totalLongFrames = 0
    @State private var longCanvases: [Data] = []
    @State private var pendingLongFrame: Data?
    @State private var manualOverlap = 100
    @State private var maximumOverlap = 100

    init(onCapture: ((Data) -> Void)? = nil) { self.onCapture = onCapture }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(CaptureLocalization.text("截图与识字", "Capture and OCR")).font(.title2.bold())
                Text(CaptureLocalization.text("截图、图片处理和 OCR 都在本机完成。只有点击截图时才会读取屏幕。", "Capture, image editing and OCR run locally. The screen is read only when you start a capture."))
                    .foregroundStyle(.secondary)
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Picker(CaptureLocalization.text("截图方式", "Capture mode"), selection: $mode) {
                                ForEach(CaptureMode.allCases) { mode in Text(mode.title).tag(mode) }
                            }.pickerStyle(.segmented).frame(maxWidth: 360)
                            Picker(CaptureLocalization.text("延时", "Delay"), selection: $delay) {
                                Text(CaptureLocalization.text("立即", "Now")).tag(0)
                                Text(CaptureLocalization.text("3 秒", "3 seconds")).tag(3)
                                Text(CaptureLocalization.text("5 秒", "5 seconds")).tag(5)
                                Text(CaptureLocalization.text("10 秒", "10 seconds")).tag(10)
                            }.frame(width: 140)
                            Spacer(minLength: 0)
                        }
                        HStack {
                            Button { takeCapture(ocr: false) } label: { Label(CaptureLocalization.text("开始截图", "Capture"), systemImage: "camera.viewfinder") }
                                .buttonStyle(.borderedProminent).disabled(busy)
                            Button { takeCapture(ocr: true) } label: { Label(CaptureLocalization.text("屏幕识字", "Screen OCR"), systemImage: "text.viewfinder") }.disabled(busy)
                            Button { importImage() } label: { Label(CaptureLocalization.text("导入图片…", "Import image…"), systemImage: "photo.badge.plus") }.disabled(busy)
                            Spacer()
                            Button(CaptureLocalization.text("屏幕权限设置", "Screen permissions")) { captureService.openPermissionSettings() }
                        }
                        Text(CaptureLocalization.text("区域：拖动选择，Esc 取消。窗口：点击窗口，Esc 取消。截图时会暂时隐藏 Xclip。", "Region: drag to select. Window: click to select. Esc cancels. Xclip hides while capturing."))
                            .font(.callout).foregroundStyle(.secondary)
                        screenPermissionHelp
                    }.padding(8)
                }
                longCaptureControls
                if busy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(status.isEmpty ? CaptureLocalization.text("正在处理…", "Processing…") : status.text)
                        Spacer()
                        Button(CaptureLocalization.text("取消", "Cancel")) { operation?.cancel(); captureService.cancel() }
                    }.padding(8)
                } else if !status.isEmpty {
                    Text(status.text).font(.callout).foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Label(errorMessage.localizedDescription, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).textSelection(.enabled)
                }
                if let imageData, NSImage(data: imageData) != nil {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(CaptureLocalization.text("当前图片", "Current image")).font(.headline)
                            Spacer()
                            Button(CaptureLocalization.text("编辑", "Edit")) { showEditor = true }.disabled(busy)
                            Button(CaptureLocalization.text("贴图", "Pin image")) { PinnedImageController.shared.show(imageData) }
                            Button(CaptureLocalization.text("识别文字", "Extract text")) { recognize(imageData) }.disabled(busy)
                            Button(CaptureLocalization.text("另存为…", "Save as…")) { save(imageData) }
                            Button(CaptureLocalization.text("复制图片", "Copy image")) { copy(imageData) }.buttonStyle(.borderedProminent)
                        }
                        LiveTextImagePreview(data: imageData, onText: { recognizedText = $0 })
                            .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 340)
                            .background(Color(nsColor: .underPageBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel(CaptureLocalization.text("截图预览", "Capture preview"))
                    }
                }
                if !recognizedText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(CaptureLocalization.text("识别结果 · 可编辑", "Recognized text · Editable")).font(.headline)
                            Spacer()
                            Button(CaptureLocalization.text("复制文字", "Copy text")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(recognizedText, forType: .string)
                                status = CaptureMessage("识别文字已复制。", "Recognized text copied.")
                            }
                            Button(CaptureLocalization.text("保存到历史", "Save to history")) { CaptureTextOutput.send(recognizedText, to: .history) }
                            Button(CaptureLocalization.text("翻译", "Translate")) { CaptureTextOutput.send(recognizedText, to: .translate) }
                            Button("AI") { CaptureTextOutput.send(recognizedText, to: .ai) }
                            Button(CaptureLocalization.text("清空文字", "Clear text")) { recognizedText = "" }
                        }
                        TextEditor(text: $recognizedText).font(.body).frame(minHeight: 150)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.25)))
                        Text(CaptureLocalization.text("OCR 结果可能有识别错误，请在使用前检查。", "OCR may contain errors. Review the result before using it."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }.padding(20)
        }
        .sheet(isPresented: $showEditor) {
            if let imageData {
                ImageEditorView(imageData: imageData) { result in self.imageData = result; copy(result) }
            }
        }
        .environment(\.locale, appLanguage.locale)
        .onAppear { isVisible = true; refreshPermissionStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStatus()
        }
        .onDisappear {
            isVisible = false
            operationID = UUID()
            operation?.cancel(); captureService.cancel(); operation = nil
            showEditor = false; imageData = nil; recognizedText = ""
            longRegion = nil; longFrames.removeAll(); longCanvases.removeAll(); pendingLongFrame = nil
            totalLongFrames = 0; busy = false; status = CaptureMessage("", ""); errorMessage = nil
        }
    }

    private var screenPermissionHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            if captureService.screenPermissionState == .granted {
                Label(CaptureLocalization.text("屏幕录制权限已生效", "Screen Recording access is active"), systemImage: "checkmark.shield")
                    .font(.callout).foregroundStyle(.secondary)
            } else if captureService.screenPermissionState != .unknown {
                Divider()
                Label(CaptureLocalization.text("当前应用的屏幕权限尚未生效", "Screen access is not active for this app"), systemImage: "exclamationmark.shield")
                    .font(.callout.bold())
                Text(CaptureLocalization.text("请在“屏幕与系统音频录制”中允许 Xclip。已开启仍无效时，先完全退出再启动；更新应用后仍无效，请移除旧项并重新添加当前应用。导入图片识字不需要此权限。", "Allow Xclip under Screen & System Audio Recording. If already enabled, fully quit and relaunch. If an update invalidated access, remove the old entry and add the current app. Imported-image OCR does not need this permission."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(Bundle.main.bundleURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(CaptureLocalization.text("重新检查", "Check again")) { refreshPermissionStatus() }
                    Button(CaptureLocalization.text("在 Finder 显示当前应用", "Show current app in Finder")) { captureService.revealCurrentApplication() }
                    Button(CaptureLocalization.text("完全退出 Xclip", "Quit Xclip completely")) { NSApp.terminate(nil) }
                }.disabled(busy)
            }
        }
    }

    private func refreshPermissionStatus() {
        captureService.refreshScreenPermission()
        guard !busy, captureService.screenPermissionState == .granted,
              let permissionError = errorMessage as? CaptureToolError else { return }
        switch permissionError {
        case .permissionDenied, .permissionRestartRequired:
            errorMessage = nil
            status = CaptureMessage("屏幕权限已生效，可以开始截图或屏幕识字。", "Screen permission is active. You can start a capture or Screen OCR.")
        default: break
        }
    }

    private var longCaptureControls: some View {
        GroupBox(CaptureLocalization.text("长截图", "Scrolling capture")) {
            VStack(alignment: .leading, spacing: 12) {
                Picker(CaptureLocalization.text("拼接方向", "Direction"), selection: $longDirection) {
                    ForEach(CaptureScrollDirection.allCases) { direction in Text(direction.title).tag(direction) }
                }.pickerStyle(.segmented).frame(width: 230).disabled(busy)
                    .onChange(of: longDirection) { _, _ in
                        longRegion = nil; longFrames = []; longCanvases = []; totalLongFrames = 0; pendingLongFrame = nil
                        status = CaptureMessage("方向已更改，请重新选择区域。", "Direction changed. Select a new capture region.")
                    }
                Text(longDirection == .vertical
                     ? CaptureLocalization.text("先框选内容，避开固定工具栏；向下滚动时保留上一张底部的部分内容，再捕获下一段。", "Select content without fixed toolbars. Scroll down, retaining some content from the previous frame, then capture again.")
                     : CaptureLocalization.text("先框选内容，避开固定侧栏；向右滚动时保留上一张右侧的部分内容，再捕获下一段。", "Select content without fixed sidebars. Scroll right, retaining some content from the previous frame, then capture again."))
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button(longRegion == nil ? CaptureLocalization.text("选择区域并开始", "Select region and start") : CaptureLocalization.text("重新选择区域", "Select a new region")) { beginLongCapture() }.disabled(busy)
                    Button(CaptureLocalization.text("捕获下一段（延时 3 秒）", "Next frame (3-second delay)")) { appendLongCapture() }.disabled(busy || longRegion == nil)
                    Button(CaptureLocalization.text("撤销上一段", "Undo last frame")) {
                        guard longFrames.count > 1 else { return }
                        longFrames.removeLast(); longCanvases.removeLast(); totalLongFrames -= 1
                        imageData = longCanvases.last; pendingLongFrame = nil
                        status = CaptureMessage("已撤销上一段，现有 \(totalLongFrames) 段。", "Last frame removed. \(totalLongFrames) frames remain.")
                    }.disabled(busy || longFrames.count < 2)
                    Spacer()
                    if !longFrames.isEmpty { Text(CaptureLocalization.text("\(totalLongFrames) 段", "\(totalLongFrames) frames")).monospacedDigit().foregroundStyle(.secondary) }
                }
                if pendingLongFrame != nil {
                    HStack {
                        Text(longDirection == .vertical ? CaptureLocalization.text("手动重叠高度", "Overlap height") : CaptureLocalization.text("手动重叠宽度", "Overlap width"))
                        TextField(CaptureLocalization.text("像素", "Pixels"), value: $manualOverlap, format: .number).frame(width: 65)
                        Stepper("px", value: $manualOverlap, in: 0...maximumOverlap).labelsHidden()
                        Text(CaptureLocalization.text("像素（0–\(maximumOverlap)）", "px (0–\(maximumOverlap))")).foregroundStyle(.secondary)
                        Button(CaptureLocalization.text("按此重叠量拼接", "Join with this overlap")) { joinPendingFrame(manual: manualOverlap) }.disabled(busy)
                        Button(CaptureLocalization.text("丢弃这一段", "Discard frame")) { pendingLongFrame = nil; errorMessage = nil }
                    }
                    Text(CaptureLocalization.text("手动调整新截图顶部或左侧需要去掉的像素数。0 表示直接拼接。", "Set the pixels to remove from the top or left of the next frame. Zero joins without overlap."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.padding(8)
        }
    }

    private func run(status: CaptureMessage, action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; self.status = status; errorMessage = nil
        let identifier = UUID()
        operationID = identifier
        operation = Task { @MainActor in
            defer { if operationID == identifier { busy = false; operation = nil } }
            do { try await action() }
            catch is CancellationError { if isVisible { self.status = CaptureMessage("已取消操作。", "Operation cancelled.") } }
            catch CaptureToolError.cancelled { if isVisible { self.status = CaptureMessage("已取消截图。", "Capture cancelled.") } }
            catch { if isVisible { self.errorMessage = error; self.status = CaptureMessage("", "") } }
        }
    }

    private func withHiddenApp<T>(_ action: @MainActor () async throws -> T) async throws -> T {
        // Keep the app visible for the system consent dialog; hiding happens only after access is active.
        try captureService.prepareForCapture()
        try Task.checkCancellation()
        NSApp.hide(nil)
        defer { if isVisible { NSApp.unhide(nil); NSApp.activate(ignoringOtherApps: true) } }
        try await Task.sleep(nanoseconds: 250_000_000)
        return try await action()
    }

    private func takeCapture(ocr: Bool) {
        run(status: delay > 0 ? CaptureMessage("\(delay) 秒后开始截图，可切换到目标窗口…", "Capturing in \(delay) seconds. Switch to the target window…") : CaptureMessage("选择截图区域，Esc 可取消…", "Choose the capture area. Press Esc to cancel…")) {
            let data = try await withHiddenApp { try await captureService.capture(mode: mode, delay: delay) }
            try Task.checkCancellation()
            guard isVisible else { throw CancellationError() }
            imageData = data; recognizedText = ""; status = CaptureMessage("截图已完成，可编辑、识字或复制。", "Capture ready. Edit, extract text or copy it.")
            if ocr {
                status = CaptureMessage("正在本机识别文字…", "Recognizing text locally…")
                let text = try await captureService.recognizeText(in: data)
                try Task.checkCancellation()
                recognizedText = text; status = CaptureMessage("识别完成。", "Recognition finished.")
            }
        }
    }
    private func recognize(_ data: Data) {
        run(status: CaptureMessage("正在本机识别文字…", "Recognizing text locally…")) {
            let result = try await captureService.recognizeText(in: data)
            try Task.checkCancellation()
            recognizedText = result; status = CaptureMessage("识别完成。", "Recognition finished.")
        }
    }
    private func importImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .bmp, .gif]
        panel.allowsMultipleSelection = false
        panel.title = CaptureLocalization.text("导入图片", "Import image")
        panel.prompt = CaptureLocalization.text("导入", "Import")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            imageData = try CaptureImageCodec.png(CaptureImageCodec.decode(data))
            recognizedText = ""; errorMessage = nil; status = CaptureMessage("已导入 \(url.lastPathComponent)。", "Imported \(url.lastPathComponent).")
        } catch { errorMessage = error }
    }
    private func beginLongCapture() {
        run(status: CaptureMessage("选择固定截图区域…", "Select a fixed capture region…")) {
            let result: (CGRect, Data) = try await withHiddenApp {
                let region = try await captureService.selectRegion()
                NSApp.hide(nil)
                try await Task.sleep(nanoseconds: 350_000_000)
                let data = try await captureService.capture(region: region)
                return (region, data)
            }
            try Task.checkCancellation()
            guard isVisible else { throw CancellationError() }
            longRegion = result.0; longFrames = [result.1]; totalLongFrames = 1; longCanvases = [result.1]; imageData = result.1
            pendingLongFrame = nil; status = CaptureMessage("第 1 段已保存。点击捕获下一段后，在 3 秒内切回页面并按所选方向滚动。", "First frame saved. Capture the next frame, then switch back and scroll in the chosen direction within 3 seconds.")
        }
    }
    private func appendLongCapture() {
        guard let longRegion else { return }
        run(status: CaptureMessage("3 秒后捕获，请切回页面并按所选方向滚动，保留重叠内容…", "Capturing in 3 seconds. Switch back, scroll in the chosen direction, and retain overlap…")) {
            let data = try await withHiddenApp { try await captureService.capture(region: longRegion, delay: 3) }
            try Task.checkCancellation()
            guard isVisible else { throw CancellationError() }
            pendingLongFrame = data
            let next = try CaptureImageCodec.decode(data)
            let span = longDirection == .vertical ? next.height : next.width
            maximumOverlap = span - 1; manualOverlap = min(maximumOverlap, span / 3)
            try await joinPending(manual: nil)
        }
    }
    private func joinPendingFrame(manual: Int) {
        run(status: CaptureMessage("正在拼接…", "Joining frames…")) { try await joinPending(manual: manual) }
    }
    private func joinPending(manual: Int?) async throws {
        guard let data = pendingLongFrame, let canvasData = longCanvases.last, let previousData = longFrames.last else { return }
        let direction = longDirection
        let output = try await Task.detached(priority: .userInitiated) {
            let result = try LongCaptureStitcher.append(canvas: CaptureImageCodec.decode(canvasData), previous: CaptureImageCodec.decode(previousData), next: CaptureImageCodec.decode(data), overlap: manual, direction: direction)
            return (try CaptureImageCodec.png(result.image), result.overlap)
        }.value
        try Task.checkCancellation()
        longFrames.append(data); totalLongFrames += 1; longCanvases.append(output.0); imageData = output.0; pendingLongFrame = nil
        // Bound undo memory while preserving the current and preceding frames.
        var historyBytes = longFrames.reduce(0) { $0 + $1.count } + longCanvases.reduce(0) { $0 + $1.count }
        while longFrames.count > 20 || (historyBytes > 100_000_000 && longFrames.count > 2) {
            historyBytes -= longFrames.removeFirst().count + longCanvases.removeFirst().count
        }
        status = CaptureMessage("已拼接 \(totalLongFrames) 段，去除重叠 \(output.1) 像素。请检查预览，必要时撤销。", "Joined \(totalLongFrames) frames, removing \(output.1) px of overlap. Review the preview and undo if needed.")
    }
    private func copy(_ data: Data) {
        captureService.copyImage(data); onCapture?(data); status = CaptureMessage("图片已复制。", "Image copied.")
    }
    private func save(_ data: Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.title = CaptureLocalization.text("保存截图", "Save capture")
        panel.prompt = CaptureLocalization.text("保存", "Save")
        panel.nameFieldLabel = CaptureLocalization.text("存储为：", "Save As:")
        panel.nameFieldStringValue = CaptureLocalization.text("Xclip-截图.png", "Xclip-Capture.png")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic); status = CaptureMessage("已保存到 \(url.lastPathComponent)。", "Saved to \(url.lastPathComponent).") }
        catch { errorMessage = error }
    }
}
