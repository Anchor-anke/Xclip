import AppKit
import SwiftUI
import ScreenCaptureKit
import ApplicationServices

/// ScreenCaptureKit display dimensions are points. The filter supplies the actual pixel scale.
struct CaptureLiveGeometry {
    let sourceRect: CGRect
    let width: Int
    let height: Int
    init(region: CGRect, display: CGRect, scale: CGFloat) throws {
        guard [region.minX, region.minY, region.width, region.height, scale].allSatisfy(\.isFinite),
              scale > 0, scale <= 8, region.width >= 2, region.height >= 2, display.contains(region) else {
            throw CaptureMessage("请在同一显示器内选择截图区域。", "Select a region within one display.")
        }
        let left = ((region.minX - display.minX) * scale).rounded(.down)
        let top = ((region.minY - display.minY) * scale).rounded(.down)
        let right = ((region.maxX - display.minX) * scale).rounded(.up)
        let bottom = ((region.maxY - display.minY) * scale).rounded(.up)
        guard right - left <= 60_000_000, bottom - top <= 60_000_000,
              (right - left) * (bottom - top) <= 60_000_000 else { throw CaptureToolError.imageTooLarge }
        width = Int(right - left); height = Int(bottom - top)
        sourceRect = CGRect(x: left / scale, y: top / scale, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
    }
}

/// Quartz global desktop points, matching the screenshot selection. Own UI is excluded.
@MainActor
enum CaptureLiveFrame {
    static func image(in region: CGRect) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.frame.contains(region) }) else {
            throw CaptureMessage("选区所在显示器已改变，请重新框选。", "The selected display changed. Select the region again.")
        }
        let excluded = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let geometry = try CaptureLiveGeometry(region: region, display: display.frame, scale: CGFloat(filter.pointPixelScale))
        let config = SCStreamConfiguration()
        config.sourceRect = geometry.sourceRect; config.width = geometry.width; config.height = geometry.height
        config.showsCursor = false; config.scalesToFit = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

/// Undo retains viewport frames and prior extents, never a growing canvas at every step.
final class CaptureScrollDocument {
    private(set) var canvas: CGImage
    private(set) var previous: CGImage
    private(set) var count = 1
    private var history: [(CGSize, CGImage)] = []
    private var historyPixels = 0
    let direction: CaptureScrollDirection
    let maximumPixels: Int
    let historyPixelLimit: Int
    init(image: CGImage, direction: CaptureScrollDirection, maximumPixels: Int = 60_000_000, historyPixelLimit: Int = 16_000_000) throws {
        guard image.width <= maximumPixels / max(1, image.height) else { throw CaptureToolError.imageTooLarge }
        canvas = image; previous = image; self.direction = direction
        self.maximumPixels = maximumPixels; self.historyPixelLimit = historyPixelLimit
    }
    var canUndo: Bool { !history.isEmpty }
    @discardableResult func append(_ image: CGImage, overlap: Int? = nil) throws -> Bool {
        guard previous.width == image.width, previous.height == image.height else { throw CaptureToolError.incompatibleFrames }
        if try Self.identical(image, previous) { return false }
        let overlap = try overlap ?? Self.reliableOverlap(previous: previous, next: image, direction: direction)
        let length = direction == .vertical ? image.height : image.width
        guard overlap >= 0, overlap < length else { throw CaptureToolError.noOverlap }
        let newWidth = canvas.width + (direction == .horizontal ? image.width - overlap : 0)
        let newHeight = canvas.height + (direction == .vertical ? image.height - overlap : 0)
        guard newWidth <= maximumPixels / max(1, newHeight) else { throw CaptureToolError.imageTooLarge }
        let result = try LongCaptureStitcher.append(canvas: canvas, previous: previous, next: image, overlap: overlap, direction: direction)
        history.append((CGSize(width: canvas.width, height: canvas.height), previous))
        historyPixels += previous.width * previous.height
        while historyPixels > historyPixelLimit, history.count > 1 {
            let removed = history.removeFirst(); historyPixels -= removed.1.width * removed.1.height
        }
        canvas = result.image; previous = image; count += 1
        return true
    }
    func undo() throws {
        guard let item = history.last else { return }
        guard let cropped = canvas.cropping(to: CGRect(origin: .zero, size: item.0)) else { throw CaptureToolError.invalidImage }
        history.removeLast(); historyPixels -= item.1.width * item.1.height
        canvas = cropped; previous = item.1; count = max(1, count - 1)
    }
    static func identical(_ a: CGImage, _ b: CGImage) throws -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        // Comparing CGDataProviders is incorrect for cropped CGImages, which can share a provider.
        // Bands keep the temporary memory bounded even for a tall, high-resolution viewport.
        for y in stride(from: 0, to: a.height, by: 64) {
            let height = min(64, a.height - y)
            let rect = CGRect(x: 0, y: y, width: a.width, height: height)
            guard let ac = a.cropping(to: rect), let bc = b.cropping(to: rect) else { throw CaptureToolError.invalidImage }
            let ca = try CaptureImageCodec.context(width: a.width, height: height)
            let cb = try CaptureImageCodec.context(width: a.width, height: height)
            ca.draw(ac, in: CGRect(origin: .zero, size: rect.size)); cb.draw(bc, in: CGRect(origin: .zero, size: rect.size))
            guard let ap = ca.data, let bp = cb.data else { throw CaptureToolError.invalidImage }
            if memcmp(ap, bp, a.width * height * 4) != 0 { return false }
        }
        return true
    }
    /// Reject equally plausible matches (repeating lists/stripes); explicit overlap remains available.
    static func reliableOverlap(previous: CGImage, next: CGImage, direction: CaptureScrollDirection) throws -> Int {
        if direction == .horizontal {
            return try reliableOverlap(previous: CaptureImageCodec.rotateClockwise(previous), next: CaptureImageCodec.rotateClockwise(next), direction: .vertical)
        }
        guard previous.width == next.width, previous.height == next.height else { throw CaptureToolError.incompatibleFrames }
        let width = min(96, previous.width), height = previous.height
        guard height > 8 else { throw CaptureToolError.noOverlap }
        func samples(_ image: CGImage) throws -> [UInt8] {
            let context = try CaptureImageCodec.context(width: width, height: height)
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let data = context.data else { throw CaptureToolError.invalidImage }
            return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        }
        let a = try samples(previous), b = try samples(next)
        var matches: [(Int, Double)] = []
        for overlap in 8..<height {
            var difference = 0, count = 0, minimum = 255, maximum = 0
            for row in stride(from: 0, to: overlap, by: max(1, overlap / 48)) {
                for x in stride(from: 0, to: width, by: 2) {
                    let ai = ((height - overlap + row) * width + x) * 4, bi = (row * width + x) * 4
                    for channel in 0..<3 { difference += abs(Int(a[ai + channel]) - Int(b[bi + channel])); count += 1 }
                    let light = (Int(a[ai]) + Int(a[ai + 1]) + Int(a[ai + 2])) / 3
                    minimum = min(minimum, light); maximum = max(maximum, light)
                }
            }
            let score = Double(difference) / Double(max(1, count))
            if maximum - minimum >= 24, score < 7 { matches.append((overlap, score)) }
        }
        matches.sort { $0.1 < $1.1 }
        guard let best = matches.first else { throw CaptureToolError.noOverlap }
        if matches.dropFirst().contains(where: { abs($0.0 - best.0) > 1 && $0.1 <= best.1 + 0.5 }) { throw CaptureToolError.noOverlap }
        return best.0
    }
}

struct CaptureScrollTarget: Equatable {
    let processID: pid_t
    let windowID: CGWindowID
    let frame: CGRect
}

enum CaptureScrollMode: String, CaseIterable { case manual, automatic }

@MainActor
struct CaptureScrollEnvironment {
    var capture: (CGRect) async throws -> CGImage
    var target: (CGRect) -> CaptureScrollTarget?
    var frontmost: () -> pid_t?
    var pointer: () -> CGPoint
    var canScroll: () -> Bool
    var scroll: (CaptureScrollTarget, CGRect, CaptureScrollDirection) throws -> Void
    var sleep: (UInt64) async throws -> Void
    var annotate: ((CGImage) async throws -> CaptureAnnotationResult)?
    static let live = Self(capture: CaptureLiveFrame.image, target: targetAtRegion,
        frontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        pointer: { CGEvent(source: nil)?.location ?? CGPoint(x: -1_000_000, y: -1_000_000) },
        canScroll: { AXIsProcessTrusted() }, scroll: postScroll,
        sleep: { try await Task.sleep(nanoseconds: $0) }, annotate: nil)

    static func targetAtRegion(_ region: CGRect) -> CaptureScrollTarget? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return target(in: windows, region: region, excluding: ProcessInfo.processInfo.processIdentifier)
    }
    static func target(in windows: [[String: Any]], region: CGRect, excluding ownPID: pid_t) -> CaptureScrollTarget? {
        for item in windows {
            guard let pid = item[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  let layer = item[kCGWindowLayer as String] as? Int, layer == 0,
                  let id = item[kCGWindowNumber as String] as? UInt32,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.intersects(region),
                  (item[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            // The entire crop must remain in the same window. A different front window is not skipped.
            guard frame.contains(region) else { return nil }
            return .init(processID: pid, windowID: id, frame: frame)
        }
        return nil
    }
    static func postScroll(_ target: CaptureScrollTarget, _ region: CGRect, _ direction: CaptureScrollDirection) throws {
        // Validate again at dispatch; never send a global scroll or move the user's cursor.
        guard AXIsProcessTrusted(), NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID,
              targetAtRegion(region) == target, let point = CGEvent(source: nil)?.location, region.contains(point) else {
            throw CaptureMessage("自动滚动已暂停：请回到原窗口，并把光标放在蓝色选区内。", "Automatic scrolling paused. Return to the original window and place the pointer inside the blue region.")
        }
        let amount = Int32(max(1, min(240, (direction == .vertical ? region.height : region.width) * 0.25)))
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: direction == .vertical ? -amount : 0,
                                  wheel2: direction == .horizontal ? -amount : 0, wheel3: 0) else { throw CaptureToolError.captureFailed }
        event.location = point
        event.postToPid(target.processID)
    }
}

@MainActor
final class CaptureScrollingController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = CaptureScrollingController()
    @Published private(set) var preview: NSImage?
    @Published private(set) var status = ""
    @Published private(set) var running = false
    @Published private(set) var preparing = false
    @Published private(set) var editingImage = false
    @Published private(set) var count = 0
    @Published private(set) var needsRetry = false
    @Published var direction: CaptureScrollDirection = .vertical {
        didSet {
            if oldValue != direction, !running, let document, document.count == 1 {
                self.document = try? CaptureScrollDocument(image: document.previous, direction: direction)
            }
        }
    }
    @Published var mode: CaptureScrollMode = .manual
    @Published var manualOverlap = 0
    private(set) var document: CaptureScrollDocument?
    private(set) var panel: NSPanel?
    private var region = CGRect.zero
    private var originalTarget: CaptureScrollTarget?
    private var border: NSPanel?
    private var task: Task<Void, Never>?
    private var editingTask: Task<Void, Never>?
    private var editing: CaptureAnnotationController?
    private var savePanel: NSSavePanel?
    private var generation: UInt64 = 0
    private var observations: [NSObjectProtocol] = []
    private var hiddenWindows: [NSWindow] = []
    private let environment: CaptureScrollEnvironment
    private let presentsWindows: Bool
    var isActive: Bool { panel != nil }
    var canUndo: Bool { document?.canUndo == true && !running && !preparing && !editingImage }
    var canExport: Bool { document != nil && !preparing && !editingImage && savePanel == nil }
    var onResult: ((CaptureAnnotationResult) -> Void)?

    init(environment: CaptureScrollEnvironment? = nil, presentsWindows: Bool = true) {
        self.environment = environment ?? .live; self.presentsWindows = presentsWindows
        super.init()
        observations.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenConfigurationChanged() }
        })
        observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        })
    }
    deinit {
        for observer in observations { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        task?.cancel(); editingTask?.cancel()
    }
    func start(region: CGRect, initialImage: Data) {
        cancel()
        guard region.width >= 2, region.height >= 2, [region.minX, region.minY, region.width, region.height].allSatisfy(\.isFinite) else {
            status = CaptureToolError.captureFailed.localizedDescription; return
        }
        self.region = region; direction = .vertical; mode = .manual; manualOverlap = 0; count = 0
        originalTarget = environment.target(region)
        // A frozen screenshot may include annotations and have a different fitted scale. Preview only.
        if let image = try? CaptureImageCodec.decode(initialImage) { preview = NSImage(cgImage: image, size: .zero) }
        createWindows()
        prepare()
    }
    private func createWindows() {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let appRect = CGRect(x: region.minX, y: top - region.maxY, width: region.width, height: region.height)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(appRect) })?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let size = CGSize(width: min(306, screen.width - 16), height: min(468, screen.height - 16))
        var x = appRect.maxX + 12
        if x + size.width > screen.maxX { x = appRect.minX - size.width - 12 }
        let frame = CGRect(x: max(screen.minX + 8, min(screen.maxX - size.width - 8, x)),
                           y: max(screen.minY + 8, min(screen.maxY - size.height - 8, appRect.maxY - size.height)), width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        panel.title = CaptureLocalization.text("长截图", "Scrolling capture"); panel.level = .floating
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: CaptureScrollingView(controller: self)); self.panel = panel
        let border = NSPanel(contentRect: appRect.insetBy(dx: -3, dy: -3), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        border.isOpaque = false; border.backgroundColor = .clear; border.ignoresMouseEvents = true
        border.level = .floating; border.hidesOnDeactivate = false; border.isReleasedWhenClosed = false; border.collectionBehavior = panel.collectionBehavior
        let outline = NSView(frame: CGRect(origin: .zero, size: border.frame.size)); outline.wantsLayer = true
        outline.layer?.borderWidth = 2; outline.layer?.borderColor = NSColor.systemBlue.cgColor
        border.contentView = outline; self.border = border
        if presentsWindows {
            hiddenWindows = NSApp.windows.filter { $0.isVisible && $0.level == .normal && $0 !== panel && $0 !== border }
            hiddenWindows.forEach { $0.orderOut(nil) }
            NSApp.unhideWithoutActivation(); border.orderFrontRegardless(); panel.orderFrontRegardless()
        }
    }
    private func prepare() {
        pause(); guard isActive else { return }
        document = nil; count = 0; preparing = true; needsRetry = false
        status = CaptureLocalization.text("正在重新读取原页面…", "Reading the original page…")
        let token = generation
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await environment.sleep(180_000_000)
                try verifyTarget(requireFocus: false, requirePointer: false)
                let frame = try await environment.capture(region)
                try Task.checkCancellation()
                guard isActive, token == generation else { return }
                try verifyTarget(requireFocus: false, requirePointer: false)
                document = try CaptureScrollDocument(image: frame, direction: direction)
                preparing = false; updatePreview()
                status = CaptureLocalization.text("首帧已就绪。点击开始，回到原窗口缓慢滚动。", "First frame ready. Start, return to the original window, and scroll slowly.")
            } catch is CancellationError { return }
            catch { guard isActive, token == generation else { return }; fail(error) }
        }
    }
    func toggle() { running || preparing ? pause() : begin() }
    func begin() {
        guard isActive, !running, !preparing, !editingImage else { return }
        guard let document else { prepare(); return }
        guard manualOverlap >= 0 else { fail(CaptureToolError.noOverlap); return }
        guard document.direction == direction else {
            status = CaptureLocalization.text("方向已改变，请点击“重新取首帧”后开始。", "Direction changed. Read a new first frame before starting."); return
        }
        if mode == .automatic, !environment.canScroll() {
            needsRetry = true
            status = CaptureLocalization.text("自动滚动需要辅助功能权限。可在系统设置中开启 Xclip，或切换“手动滚动”继续。", "Automatic scrolling needs Accessibility access. Allow Xclip in System Settings, or continue in manual mode.")
            return
        }
        running = true; needsRetry = false; generation &+= 1; let token = generation
        status = CaptureLocalization.text("请在 2 秒内回到原窗口；自动模式需将光标放在选区内。", "Return to the original window within 2 seconds; automatic mode also needs the pointer inside the region.")
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await environment.sleep(2_000_000_000)
                var stationaryFrames = 0
                // Capture before scrolling on resume, so a manual correction is never skipped.
                var scrollBeforeCapture = false
                while isActive, token == generation, running {
                    try Task.checkCancellation()
                    try verifyTarget(requireFocus: true, requirePointer: mode == .automatic)
                    if mode == .automatic, scrollBeforeCapture {
                        guard let target = originalTarget else { throw CaptureToolError.captureFailed }
                        try environment.scroll(target, region, direction)
                        try await environment.sleep(550_000_000)
                        try verifyTarget(requireFocus: true, requirePointer: true)
                    }
                    let image = try await environment.capture(region)
                    try Task.checkCancellation()
                    guard isActive, token == generation, running, let document = self.document else { return }
                    try verifyTarget(requireFocus: true, requirePointer: mode == .automatic)
                    let appended = try document.append(image, overlap: manualOverlap > 0 ? manualOverlap : nil)
                    if appended { stationaryFrames = 0; updatePreview(); status = pixelStatus }
                    else if mode == .automatic, scrollBeforeCapture {
                        stationaryFrames += 1
                        if stationaryFrames >= 3 {
                            pause(); status = CaptureLocalization.text("页面已停止变化，自动滚动已暂停。可继续、裁剪或导出。", "The page stopped changing. Automatic scrolling paused; continue, crop, or export."); return
                        }
                    }
                    scrollBeforeCapture = true
                    try await environment.sleep(450_000_000)
                }
            } catch is CancellationError { return }
            catch { guard isActive, token == generation else { return }; fail(error) }
        }
    }
    private func verifyTarget(requireFocus: Bool, requirePointer: Bool) throws {
        guard let target = originalTarget, environment.target(region) == target else {
            throw CaptureMessage("原窗口已移动、遮挡或关闭。请恢复原窗口与选区后重试。", "The original window moved, was covered, or closed. Restore the window and region, then retry.")
        }
        if requireFocus, environment.frontmost() != target.processID {
            throw CaptureMessage("已暂停：请回到原窗口后继续。", "Paused. Return to the original window to continue.")
        }
        if requirePointer, !region.contains(environment.pointer()) {
            throw CaptureMessage("自动滚动已暂停：请把光标放回蓝色选区内后继续。", "Automatic scrolling paused. Move the pointer back inside the blue region to continue.")
        }
    }
    private func fail(_ error: Error) { pause(); needsRetry = true; status = error.localizedDescription }
    func pause() { running = false; preparing = false; generation &+= 1; task?.cancel(); task = nil }
    func undo() {
        guard !editingImage else { return }; pause()
        do { try document?.undo(); updatePreview(); needsRetry = false; status = pixelStatus } catch { fail(error) }
    }
    func reset() { guard !editingImage else { return }; prepare() }
    private var pixelStatus: String {
        guard let document else { return "" }
        return "\(document.canvas.width) × \(document.canvas.height) px · " + CaptureLocalization.text("已拼接", "stitched")
    }
    private func updatePreview() {
        if let document { preview = NSImage(cgImage: document.canvas, size: CGSize(width: document.canvas.width, height: document.canvas.height)); count = document.count }
    }
    func finish(_ action: CaptureWorkflowAction? = nil) {
        guard canExport else { return }; pause()
        do {
            guard let image = document?.canvas else { return }
            let data = try CaptureImageCodec.png(image)
            let result = CaptureAnnotationResult(data: data, destination: action.map { .action($0, region: region) } ?? .copy)
            cancel(); onResult?(result)
        } catch { status = error.localizedDescription }
    }
    func save() {
        guard canExport, let image = document?.canvas, let panel, savePanel == nil else { return }; pause()
        let save = NSSavePanel(); savePanel = save; panel.level = .normal
        let token = generation
        defer { savePanel = nil; if isActive { panel.level = .floating } }
        do {
            if let url = try CaptureOutput.save(CaptureImageCodec.png(image), panel: save, allowsWrite: { [weak self] in self?.isActive == true && self?.generation == token }), isActive {
                status = CaptureLocalization.text("已保存：", "Saved: ") + url.lastPathComponent
            }
        } catch { if isActive { status = error.localizedDescription } }
    }
    func annotate() {
        guard canExport, let image = document?.canvas else { return }; pause(); editingImage = true
        panel?.orderOut(nil); border?.orderOut(nil)
        let token = generation
        editingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if token == generation, isActive {
                    editing = nil; editingTask = nil; editingImage = false
                    if presentsWindows { panel?.orderFrontRegardless(); border?.orderFrontRegardless() }
                }
            }
            do {
                let result: CaptureAnnotationResult
                if let annotate = environment.annotate { result = try await annotate(image) }
                else {
                    guard let screen = NSScreen.main else { throw CaptureToolError.captureFailed }
                    let editor = CaptureAnnotationController(); editing = editor
                    result = try await editor.select(snapshots: [.init(frame: screen.frame, image: image, selectsFullImage: true)])
                }
                try Task.checkCancellation()
                guard isActive, token == generation else { return }
                if case .action(let action, _) = result.destination, action == .longCapture || action == .recording {
                    status = CaptureLocalization.text("长图没有对应的实时屏幕区域。请从新的截屏选区启动长截图或录屏。", "A stitched image has no live screen region. Start scrolling capture or recording from a new screen selection.")
                    return
                }
                cancel(); onResult?(result)
            } catch is CancellationError {}
            catch CaptureToolError.cancelled {}
            catch { if isActive, token == generation { status = error.localizedDescription } }
        }
    }
    func screenConfigurationChanged() {
        guard isActive else { return }; cancel()
        status = CaptureLocalization.text("显示器布局或缩放已改变，长截图已取消。请重新框选。", "Display layout or scale changed. Scrolling capture cancelled; select the region again.")
    }
    func cancel() {
        pause(); editingTask?.cancel(); editingTask = nil; editing?.cancel(); editing = nil; editingImage = false
        if let save = savePanel {
            save.cancel(nil)
            if NSApp.modalWindow === save { NSApp.abortModal() }
            if let parent = save.sheetParent { parent.endSheet(save, returnCode: .cancel) }
            save.close()
        }; savePanel = nil
        let old = panel; panel = nil; old?.delegate = nil; old?.close(); old?.contentView = nil
        border?.close(); border?.contentView = nil; border = nil; document = nil; preview = nil; count = 0; needsRetry = false; originalTarget = nil
        let restore = hiddenWindows; hiddenWindows.removeAll()
        if presentsWindows { restore.forEach { if !$0.isMiniaturized { $0.orderFront(nil) } } }
    }
    func windowWillClose(_ notification: Notification) { cancel() }
}

private struct CaptureScrollingView: View {
    @ObservedObject var controller: CaptureScrollingController
    var body: some View {
        VStack(spacing: 10) {
            Picker(CaptureLocalization.text("方向", "Direction"), selection: $controller.direction) {
                ForEach(CaptureScrollDirection.allCases) { Text($0.title).tag($0) }
            }.disabled(controller.running || controller.preparing || controller.count > 1 || controller.editingImage)
            Picker(CaptureLocalization.text("滚动方式", "Scrolling"), selection: $controller.mode) {
                Text(CaptureLocalization.text("手动滚动", "Manual")).tag(CaptureScrollMode.manual)
                Text(CaptureLocalization.text("自动滚动", "Automatic")).tag(CaptureScrollMode.automatic)
            }.pickerStyle(.segmented).disabled(controller.running || controller.preparing || controller.editingImage)
            if let image = controller.preview { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black.opacity(0.04)) }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            Text(controller.status).font(.caption).foregroundStyle(.secondary).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("scrolling.status")
            HStack {
                Text(CaptureLocalization.text("重叠像素", "Overlap px")).font(.caption)
                TextField("0 = Auto", value: $controller.manualOverlap, formatter: NumberFormatter()).frame(width: 66).disabled(controller.running || controller.preparing)
                Spacer(); Text(CaptureLocalization.text("\(controller.count) 帧", "\(controller.count) frames")).monospacedDigit()
            }
            HStack {
                Button(controller.running ? CaptureLocalization.text("暂停", "Pause") : controller.needsRetry ? CaptureLocalization.text("重试 / 继续", "Retry / resume") : CaptureLocalization.text("开始 / 继续", "Start / resume")) { controller.toggle() }.buttonStyle(.borderedProminent).disabled(controller.preparing || controller.editingImage)
                Button(CaptureLocalization.text("撤回", "Undo")) { controller.undo() }.disabled(!controller.canUndo)
                Button(CaptureLocalization.text("重新取首帧", "New first frame")) { controller.reset() }.disabled(controller.preparing || controller.editingImage)
            }.font(.caption)
            HStack {
                Button(CaptureLocalization.text("裁剪 / 标注", "Crop / annotate")) { controller.annotate() }
                Button(CaptureLocalization.text("贴图", "Pin")) { controller.finish(.pin) }
                Button(CaptureLocalization.text("保存", "Save")) { controller.save() }
                Button(CaptureLocalization.text("复制", "Copy")) { controller.finish() }
            }.font(.caption).disabled(!controller.canExport)
        }.padding(12).frame(minWidth: 282, minHeight: 420)
    }
}
