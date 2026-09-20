import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision

enum CaptureLocalization {
    static func text(_ chinese: String, _ english: String) -> String {
        AppLanguage.text(chinese, english)
    }
}

/// Keep both translations so an in-progress operation can change language without losing its state.
struct CaptureMessage: LocalizedError {
    let chinese: String
    let english: String
    init(_ chinese: String, _ english: String) { self.chinese = chinese; self.english = english }
    var text: String { CaptureLocalization.text(chinese, english) }
    var isEmpty: Bool { chinese.isEmpty && english.isEmpty }
    var errorDescription: String? { text }
}

enum CaptureScrollDirection: String, CaseIterable, Identifiable {
    case vertical, horizontal
    var id: String { rawValue }
    var title: String { self == .vertical ? CaptureLocalization.text("纵向", "Vertical") : CaptureLocalization.text("横向", "Horizontal") }
}

/// Capture never runs until explicitly requested by a user action.
enum CaptureMode: String, CaseIterable, Identifiable {
    case region = "区域", window = "窗口", fullScreen = "主屏幕"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .region: return CaptureLocalization.text(rawValue, "Region")
        case .window: return CaptureLocalization.text(rawValue, "Window")
        case .fullScreen: return CaptureLocalization.text(rawValue, "Main display")
        }
    }
}

enum CaptureToolError: LocalizedError {
    case permissionDenied, permissionRestartRequired, cancelled, invalidImage, noText, captureFailed, incompatibleFrames, noOverlap, imageTooLarge
    case captureCommandFailed(String)
    var errorDescription: String? {
        switch self {
        case .permissionDenied: return CaptureLocalization.text("当前 Xclip 尚未获得屏幕录制权限。请在系统设置的“屏幕与系统音频录制”中允许当前应用；如果已经开启，请从 Xclip 菜单完全退出后重新启动（关闭窗口不会退出）。更新应用后仍无效时，请移除旧授权项，再添加下方显示的当前应用。", "This Xclip process does not have Screen Recording access. Allow the current app under Screen & System Audio Recording. If already enabled, fully quit Xclip from its menu and launch it again; closing the window does not quit. If access still fails after an update, remove the old entry and add the current app shown below.")
        case .permissionRestartRequired: return CaptureLocalization.text("授权请求已通过，但当前进程尚不能读取屏幕。请完全退出 Xclip，再启动当前应用；关闭窗口不会退出。", "Permission was accepted, but this process cannot yet read the screen. Fully quit Xclip and launch the current app again; closing its window does not quit.")
        case .cancelled: return CaptureLocalization.text("已取消截图。", "Capture cancelled.")
        case .invalidImage: return CaptureLocalization.text("无法读取这张图片，请使用 PNG、JPEG、HEIC 或 TIFF 图片。", "Unable to read this image. Use PNG, JPEG, HEIC or TIFF.")
        case .noText: return CaptureLocalization.text("没有识别到文字，可尝试更清晰的图片或更大的截图区域。", "No text recognized. Try a clearer image or a larger capture area.")
        case .captureFailed: return CaptureLocalization.text("截图失败。请检查屏幕录制权限，并确认所选窗口仍然可见。", "Capture failed. Check Screen Recording permission and ensure the selected window is still visible.")
        case .captureCommandFailed(let detail): return CaptureLocalization.text("截图未完成，请重试并确认所选窗口仍然可见。系统返回：", "Capture did not complete. Retry and ensure the selected window is still visible. System response: ") + detail
        case .incompatibleFrames: return CaptureLocalization.text("截图尺寸不一致。纵向截图需宽度相同，横向截图需高度相同。请保持窗口与截图区域不变。", "Frame sizes differ. Vertical capture requires equal widths; horizontal capture requires equal heights. Keep the capture region fixed.")
        case .noOverlap: return CaptureLocalization.text("未找到可靠的重叠区域。请沿所选方向少滚动一些后重新捕获，或手动指定重叠像素。", "No reliable overlap found. Scroll a shorter distance and retry, or set the overlap manually.")
        case .imageTooLarge: return CaptureLocalization.text("图片超过 6000 万像素限制，请缩小截图范围或分段保存。", "Image exceeds 60 million pixels. Use a smaller area or save separate sections.")
        }
    }
}

enum CaptureScreenPermissionState {
    case unknown, granted, unavailable, restartRequired
}

/// A passive refresh never prompts or captures. Permission requests happen before hiding the app.
@MainActor
final class CaptureScreenPermission {
    private let preflight: () -> Bool
    private let request: () -> Bool
    private(set) var state: CaptureScreenPermissionState = .unknown

    init(preflight: @escaping () -> Bool = CGPreflightScreenCaptureAccess,
         request: @escaping () -> Bool = CGRequestScreenCaptureAccess) {
        self.preflight = preflight; self.request = request
    }

    @discardableResult func refresh() -> CaptureScreenPermissionState {
        if preflight() { state = .granted }
        else if state != .restartRequired { state = .unavailable }
        return state
    }

    func prepareForCapture() throws {
        try Task.checkCancellation()
        if refresh() == .granted { return }
        let accepted = request()
        if refresh() == .granted { return }
        if accepted { state = .restartRequired }
        throw state == .restartRequired ? CaptureToolError.permissionRestartRequired : CaptureToolError.permissionDenied
    }

    func requireAccess() throws {
        try Task.checkCancellation()
        guard refresh() == .granted else {
            throw state == .restartRequired ? CaptureToolError.permissionRestartRequired : CaptureToolError.permissionDenied
        }
    }
}

/// Keep real failures distinct from Escape. A successful image is stronger evidence than preflight.
struct CaptureCommandResult {
    let status: Int32
    let stderr: String
    let imageData: Data?
    let wasCancelled: Bool

    func validatedImage(interactive: Bool, permissionAvailable: Bool) throws -> Data {
        if wasCancelled { throw CaptureToolError.cancelled }
        if status == 0, let imageData, !imageData.isEmpty {
            do { _ = try CaptureImageCodec.decode(imageData) }
            catch { throw CaptureToolError.captureCommandFailed(error.localizedDescription) }
            return imageData
        }
        guard permissionAvailable else { throw CaptureToolError.permissionDenied }
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if interactive, (status == 0 || status == 1), detail.isEmpty, imageData?.isEmpty != false {
            throw CaptureToolError.cancelled
        }
        throw CaptureToolError.captureCommandFailed(detail.isEmpty ? "exit \(status)" : String(detail.prefix(400)))
    }
}

@MainActor
final class CaptureService: ObservableObject {
    static let shared = CaptureService()
    @Published private(set) var isCapturing = false
    @Published private(set) var screenPermissionState: CaptureScreenPermissionState = .unknown
    private let screenPermission = CaptureScreenPermission()
    private var captureWasCancelled = false
    private var process: Process?
    private var selector: CaptureRegionSelector?
    private var annotationController: CaptureAnnotationController?
    private var captureSessionID: UUID?
    private var captureDisplayConfigurationChanged = false
    private var recognitionRequests: [UUID: VNRecognizeTextRequest] = [:]

    func refreshScreenPermission() { screenPermissionState = screenPermission.refresh() }
    func prepareForCapture() throws {
        defer { screenPermissionState = screenPermission.state }
        try screenPermission.prepareForCapture()
    }
    private func requireScreenPermission() throws {
        defer { screenPermissionState = screenPermission.state }
        try screenPermission.requireAccess()
    }
    func revealCurrentApplication() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
    func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func cancel() {
        captureWasCancelled = true
        if let process, process.isRunning { process.terminate() }
        selector?.cancel()
        annotationController?.cancel()
        recognitionRequests.values.forEach { $0.cancel() }
    }

    func selectRegion() async throws -> CGRect {
        guard !isCapturing, selector == nil else { throw CaptureToolError.captureFailed }
        try requireScreenPermission()
        let regionSelector = CaptureRegionSelector()
        selector = regionSelector
        defer { selector = nil }
        return try await regionSelector.select()
    }

    func capture(mode: CaptureMode, delay: Int = 0) async throws -> Data {
        var arguments: [String] = []
        switch mode {
        case .region: arguments = ["-i", "-s"]
        case .window: arguments = ["-i", "-w", "-o"]
        case .fullScreen: arguments = ["-m"]
        }
        return try await capture(arguments: arguments, delay: delay)
    }

    func capture(region: CGRect, delay: Int = 0) async throws -> Data {
        let rect = region.integral
        guard rect.width >= 2, rect.height >= 2 else { throw CaptureToolError.cancelled }
        let argument = "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
        return try await capture(arguments: ["-R", argument], delay: delay)
    }

    /// Freeze the screen before showing any annotation windows, and hold the capture lock until export or cancellation.
    func captureAndAnnotate(mode: CaptureMode, delay: Int = 0, action: CaptureWorkflowAction? = nil) async throws -> CaptureAnnotationResult {
        try await performCaptureSession {
            try await self.waitForCapture(delay: delay)
            let layout = try self.captureDisplayLayout()
            let sessionID = self.captureSessionID
            let observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.captureSessionID == sessionID else { return }
                    self.captureDisplayConfigurationChanged = true
                    self.cancel()
                }
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            do {
                let snapshots: [CaptureAnnotationSnapshot]
                switch mode {
                case .region, .window:
                    let windows: [CGRect]
                    if mode == .window {
                        guard let mainDisplay = layout.first(where: { $0.displayID == CGMainDisplayID() }) else {
                            throw CaptureToolError.captureFailed
                        }
                        windows = try self.visibleWindowFrames(mainScreenTop: mainDisplay.frame.maxY)
                    } else {
                        windows = []
                    }
                    let images = try await CaptureDesktopSnapshot.images(for: layout.map(\.displayID))
                    var frozen: [CaptureAnnotationSnapshot] = []
                    for display in layout {
                        guard let image = images[display.displayID] else { throw CaptureToolError.captureFailed }
                        if mode == .window {
                            let regions = self.windowRegions(windows, on: display.frame, image: image)
                            frozen.append(CaptureAnnotationSnapshot(frame: display.frame, image: image,
                                                                    selectsFullImage: false, windowRegions: regions, initialAction: action))
                        } else {
                            frozen.append(CaptureAnnotationSnapshot(frame: display.frame, image: image, selectsFullImage: false, initialAction: action))
                        }
                    }
                    snapshots = frozen
                case .fullScreen:
                    guard let display = layout.first(where: { $0.displayID == CGMainDisplayID() }) else {
                        throw CaptureToolError.captureFailed
                    }
                    let images = try await CaptureDesktopSnapshot.images(for: [display.displayID])
                    guard let image = images[display.displayID] else { throw CaptureToolError.captureFailed }
                    snapshots = [CaptureAnnotationSnapshot(frame: display.frame, image: image, selectsFullImage: true, initialAction: action)]
                }
                guard try self.captureDisplayLayout() == layout else {
                    self.captureDisplayConfigurationChanged = true
                    throw CaptureToolError.cancelled
                }
                try self.checkCaptureCancellation()
                let controller = CaptureAnnotationController()
                self.annotationController = controller
                defer { self.annotationController = nil }
                let result = try await controller.select(snapshots: snapshots)
                try self.checkCaptureCancellation()
                return result
            } catch {
                if self.captureDisplayConfigurationChanged {
                    throw CaptureMessage("显示器设置已变化，截图已取消。请重新截图。", "Display settings changed, so capture was cancelled. Start a new capture.")
                }
                if CaptureDesktopSnapshot.isPermissionDenied(error) {
                    throw CaptureToolError.permissionDenied
                }
                if let snapshotError = error as? CaptureDesktopSnapshotError {
                    switch snapshotError {
                    case .imageTooLarge: throw CaptureToolError.imageTooLarge
                    case .invalidDisplay, .invalidImageSize: throw CaptureToolError.captureFailed
                    }
                }
                throw error
            }
        }
    }

    private struct CaptureDisplayLayout: Equatable {
        let displayID: CGDirectDisplayID
        let captureIndex: Int
        let frame: CGRect
        let scale: CGFloat
    }

    /// WindowServer returns windows from front to back. Retaining that order makes hit testing
    /// choose the foremost normal window and keeps overlays, desktop elements and Xclip out.
    private func visibleWindowFrames(mainScreenTop: CGFloat) throws -> [CGRect] {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { throw CaptureToolError.captureFailed }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return windows.compactMap { window in
            guard let layer = window[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0,
                  let alpha = window[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue > 0,
                  let owner = window[kCGWindowOwnerPID as String] as? NSNumber, owner.int32Value != ownPID,
                  let dictionary = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite,
                  rect.width >= 2, rect.height >= 2 else { return nil }
            // CoreGraphics starts at the top-left of the main display; AppKit starts at its bottom-left.
            return CGRect(x: rect.minX, y: mainScreenTop - rect.maxY, width: rect.width, height: rect.height)
        }
    }

    /// A window suggestion is a crop of this frozen screen's visible pixels, including any occlusion.
    private func windowRegions(_ windows: [CGRect], on screen: CGRect, image: CGImage) -> [CGRect] {
        guard screen.width > 0, screen.height > 0 else { return [] }
        let pixelBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let scaleX = CGFloat(image.width) / screen.width
        let scaleY = CGFloat(image.height) / screen.height
        return windows.compactMap { window in
            let visible = window.intersection(screen)
            guard !visible.isNull, !visible.isEmpty else { return nil }
            let pixels = CGRect(x: (visible.minX - screen.minX) * scaleX,
                                y: (screen.maxY - visible.maxY) * scaleY,
                                width: visible.width * scaleX, height: visible.height * scaleY)
                .integral.intersection(pixelBounds)
            return pixels.width >= 2 && pixels.height >= 2 ? pixels : nil
        }
    }

    private func captureDisplayLayout() throws -> [CaptureDisplayLayout] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { throw CaptureToolError.captureFailed }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displayIDs, &count) == .success else { throw CaptureToolError.captureFailed }
        displayIDs = Array(displayIDs.prefix(Int(count)))
        // CoreGraphics defines the first active display as the main display; screencapture uses one-based display indices.
        guard displayIDs.first == CGMainDisplayID() else { throw CaptureToolError.captureFailed }
        let layout = try NSScreen.screens.map { screen -> CaptureDisplayLayout in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let index = displayIDs.firstIndex(of: number.uint32Value) else { throw CaptureToolError.captureFailed }
            return CaptureDisplayLayout(displayID: number.uint32Value, captureIndex: index + 1, frame: screen.frame, scale: screen.backingScaleFactor)
        }.sorted { $0.captureIndex < $1.captureIndex }
        guard !layout.isEmpty else { throw CaptureToolError.captureFailed }
        return layout
    }

    private func capture(arguments: [String], delay: Int) async throws -> Data {
        try await performCaptureSession {
            try await self.waitForCapture(delay: delay)
            return try await self.runCaptureCommand(arguments: arguments)
        }
    }

    private func performCaptureSession<T>(_ action: @MainActor () async throws -> T) async throws -> T {
        guard !isCapturing, selector == nil, annotationController == nil else { throw CaptureToolError.captureFailed }
        try requireScreenPermission()
        let sessionID = UUID()
        captureSessionID = sessionID
        isCapturing = true
        captureWasCancelled = false
        captureDisplayConfigurationChanged = false
        defer { isCapturing = false; process = nil; captureSessionID = nil }
        return try await withTaskCancellationHandler {
            try await action()
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.captureSessionID == sessionID else { return }
                self.cancel()
            }
        }
    }

    private func waitForCapture(delay: Int) async throws {
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(min(delay, 30)) * 1_000_000_000) }
        try checkCaptureCancellation()
    }

    private func checkCaptureCancellation() throws {
        try Task.checkCancellation()
        guard !captureWasCancelled else { throw CaptureToolError.cancelled }
    }

    private func runCaptureCommand(arguments: [String]) async throws -> Data {
        try checkCaptureCancellation()
        try requireScreenPermission()
        defer { process = nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oneclip-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("capture.png")
        let errorURL = directory.appendingPathComponent("capture-error.txt")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let errorFile = try FileHandle(forWritingTo: errorURL)
        defer { try? errorFile.close() }
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        command.arguments = ["-x", "-t", "png"] + arguments + [destination.path]
        command.standardOutput = FileHandle.nullDevice
        command.standardError = errorFile
        process = command
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            command.terminationHandler = { terminated in continuation.resume(returning: terminated.terminationStatus) }
            do { try command.run() }
            catch { command.terminationHandler = nil; continuation.resume(throwing: error) }
        }
        try Task.checkCancellation()
        let errorReader = try FileHandle(forReadingFrom: errorURL)
        defer { try? errorReader.close() }
        let errorData = (try? errorReader.read(upToCount: 4096)) ?? Data()
        refreshScreenPermission()
        return try CaptureCommandResult(status: status, stderr: String(decoding: errorData, as: UTF8.self),
                                        imageData: try? Data(contentsOf: destination), wasCancelled: captureWasCancelled)
            .validatedImage(interactive: arguments.contains("-i"), permissionAvailable: screenPermissionState == .granted)
    }

    func recognizeText(in data: Data) async throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        let identifier = UUID()
        recognitionRequests[identifier] = request
        defer { recognitionRequests.removeValue(forKey: identifier) }
        do {
            let result = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    let image = try CaptureImageCodec.decode(data)
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    request.automaticallyDetectsLanguage = true
                    let supported = try request.supportedRecognitionLanguages()
                    request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"].filter { supported.contains($0) }
                    let handler = VNImageRequestHandler(cgImage: image)
                    try handler.perform([request])
                    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CaptureToolError.noText }
                    return text
                }.value
            } onCancel: {
                request.cancel()
            }
            try Task.checkCancellation()
            return result
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func copyImage(_ data: Data) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
    }
}

/// Shared deterministic image functions, also exercised with synthetic images in tests/CaptureTests.swift.
enum CaptureImageCodec {
    static let maximumPixels = 60_000_000
    static func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw CaptureToolError.invalidImage }
        guard width > 0, height > 0, width <= maximumPixels / height else { throw CaptureToolError.imageTooLarge }
        // Applying orientation also fixes portrait phone photos before OCR and editing.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: max(width, height)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw CaptureToolError.invalidImage }
        return image
    }

    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw CaptureToolError.invalidImage }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureToolError.invalidImage }
        return data as Data
    }

    static func context(width: Int, height: Int) throws -> CGContext {
        guard width > 0, height > 0, width <= maximumPixels / height else { throw CaptureToolError.imageTooLarge }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureToolError.invalidImage }
        return context
    }

    static func crop(_ image: CGImage, rect: CGRect) throws -> CGImage {
        let safe = rect.standardized.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard safe.width >= 2, safe.height >= 2, let result = image.cropping(to: safe) else { throw CaptureToolError.invalidImage }
        return result
    }

    static func rotateCounterClockwise(_ image: CGImage) throws -> CGImage {
        let context = try context(width: image.height, height: image.width)
        context.translateBy(x: CGFloat(image.height) / 2, y: CGFloat(image.width) / 2)
        context.rotate(by: .pi / 2)
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2, width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let result = context.makeImage() else { throw CaptureToolError.invalidImage }
        return result
    }

    static func rotateClockwise(_ image: CGImage) throws -> CGImage {
        let context = try context(width: image.height, height: image.width)
        context.translateBy(x: CGFloat(image.height) / 2, y: CGFloat(image.width) / 2)
        context.rotate(by: -.pi / 2)
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2, width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let result = context.makeImage() else { throw CaptureToolError.invalidImage }
        return result
    }
}

struct LongCaptureJoin {
    let image: CGImage
    let overlap: Int
}

enum LongCaptureStitcher {
    /// Caller retains the previous frame; only its bottom overlaps the next frame's top.
    static func append(canvas: CGImage, previous: CGImage, next: CGImage, overlap manualOverlap: Int? = nil, direction: CaptureScrollDirection = .vertical) throws -> LongCaptureJoin {
        if direction == .horizontal {
            let result = try append(canvas: CaptureImageCodec.rotateClockwise(canvas),
                                    previous: CaptureImageCodec.rotateClockwise(previous), next: CaptureImageCodec.rotateClockwise(next), overlap: manualOverlap)
            return LongCaptureJoin(image: try CaptureImageCodec.rotateCounterClockwise(result.image), overlap: result.overlap)
        }
        guard canvas.width == next.width, previous.width == next.width else { throw CaptureToolError.incompatibleFrames }
        let overlap: Int
        if let manualOverlap {
            guard manualOverlap >= 0, manualOverlap < min(previous.height, next.height) else { throw CaptureToolError.noOverlap }
            overlap = manualOverlap
        } else {
            overlap = try detectOverlap(previous: previous, next: next)
        }
        let extraHeight = next.height - overlap
        let height = canvas.height + extraHeight
        let context = try CaptureImageCodec.context(width: canvas.width, height: height)
        context.draw(canvas, in: CGRect(x: 0, y: extraHeight, width: canvas.width, height: canvas.height))
        if let bottom = next.cropping(to: CGRect(x: 0, y: overlap, width: next.width, height: extraHeight)) {
            context.draw(bottom, in: CGRect(x: 0, y: 0, width: next.width, height: extraHeight))
        } else { throw CaptureToolError.invalidImage }
        guard let result = context.makeImage() else { throw CaptureToolError.invalidImage }
        return LongCaptureJoin(image: result, overlap: overlap)
    }

    static func detectOverlap(previous: CGImage, next: CGImage, direction: CaptureScrollDirection = .vertical) throws -> Int {
        if direction == .horizontal {
            return try detectOverlap(previous: CaptureImageCodec.rotateClockwise(previous), next: CaptureImageCodec.rotateClockwise(next))
        }
        guard previous.width == next.width else { throw CaptureToolError.incompatibleFrames }
        let sampleWidth = min(64, previous.width)
        func pixels(_ image: CGImage) throws -> [UInt8] {
            let context = try CaptureImageCodec.context(width: sampleWidth, height: image.height)
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: image.height))
            guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { throw CaptureToolError.invalidImage }
            return Array(UnsafeBufferPointer(start: bytes, count: sampleWidth * image.height * 4))
        }
        let a = try pixels(previous), b = try pixels(next)
        if previous.height == next.height && a == b { throw CaptureToolError.noOverlap }
        let maxOverlap = min(previous.height, next.height) - 1
        guard maxOverlap >= 8 else { throw CaptureToolError.noOverlap }
        var bestOverlap = 0, bestScore = Double.greatestFiniteMagnitude
        // Bitmap memory follows image row order, from top to bottom.
        for overlap in 8...maxOverlap {
            let rowStep = max(1, overlap / 32)
            var error = 0.0, count = 0, minimum = 255, maximum = 0
            for row in stride(from: 0, to: overlap, by: rowStep) {
                for x in stride(from: 0, to: sampleWidth, by: 2) {
                    let ai = ((previous.height - overlap + row) * sampleWidth + x) * 4
                    let bi = (row * sampleWidth + x) * 4
                    for channel in 0..<3 {
                        let av = Int(a[ai + channel]), bv = Int(b[bi + channel])
                        error += Double(abs(av - bv)); count += 1
                    }
                    let brightness = (Int(a[ai]) + Int(a[ai + 1]) + Int(a[ai + 2])) / 3
                    minimum = min(minimum, brightness); maximum = max(maximum, brightness)
                }
            }
            let score = error / Double(max(1, count))
            // A flat background alone cannot establish a trustworthy match.
            if maximum - minimum >= 24, score < bestScore - 0.05 || (abs(score - bestScore) <= 0.05 && overlap > bestOverlap) {
                bestScore = score; bestOverlap = overlap
            }
        }
        guard bestOverlap > 0, bestScore < 7 else { throw CaptureToolError.noOverlap }
        return bestOverlap
    }
}

@MainActor
private final class CaptureRegionSelector {
    private var panels: [NSPanel] = []
    private var continuation: CheckedContinuation<CGRect, Error>?
    func select() async throws -> CGRect {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            for screen in NSScreen.screens {
                let panel = RegionSelectionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                panel.level = .screenSaver
                panel.backgroundColor = .clear
                panel.isOpaque = false
                panel.hasShadow = false
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                let view = CaptureSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
                view.selection = { [weak self] localRect in
                    let global = localRect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                    let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
                    self?.finish(.success(CGRect(x: global.minX, y: mainHeight - global.maxY, width: global.width, height: global.height)))
                }
                view.cancelSelection = { [weak self] in self?.cancel() }
                panel.contentView = view
                panels.append(panel)
                panel.makeKeyAndOrderFront(nil)
                panel.makeFirstResponder(view)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    func cancel() { finish(.failure(CaptureToolError.cancelled)) }
    private func finish(_ result: Result<CGRect, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        continuation.resume(with: result)
    }
}

private final class RegionSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class CaptureSelectionView: NSView {
    var selection: ((CGRect) -> Void)?
    var cancelSelection: (() -> Void)?
    private var start: CGPoint?
    private var selectionRect: CGRect?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(self, selector: #selector(languageDidChange), name: AppLanguage.didChange, object: nil)
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    @objc private func languageDidChange() { needsDisplay = true }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill(); bounds.fill()
        if let rect = selectionRect {
            NSColor.white.withAlphaComponent(0.12).setFill(); rect.fill()
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(rect: rect); outline.lineWidth = 2; outline.stroke()
        }
        let label = CaptureLocalization.text("拖动选择固定截图区域 · 按 Esc 取消", "Drag to select a fixed capture region · Press Esc to cancel")
        label.draw(at: CGPoint(x: 32, y: bounds.height - 60), withAttributes: [.font: NSFont.systemFont(ofSize: 20, weight: .medium), .foregroundColor: NSColor.white])
    }
    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        selectionRect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        guard let rect = selectionRect, rect.width >= 2, rect.height >= 2 else { cancelSelection?(); return }
        selection?(rect)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelSelection?() } else { super.keyDown(with: event) }
    }
}


enum CaptureTextOutput {
    enum Destination: String { case history = "CClipOCRText", translate = "CClipTranslateText", ai = "CClipAIInput" }
    static func send(_ text: String, to destination: Destination) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        NotificationCenter.default.post(name: Notification.Name(destination.rawValue), object: text, userInfo: ["text": text])
    }
}
