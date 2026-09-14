import AppKit
import UniformTypeIdentifiers

struct PinnedImageContent: Codable {
    enum Kind: String, Codable { case image, text, color, files, formula }
    var originalData: Data
    var kind: Kind = .image
    var text: String?
    var html: String?
    var files: [URL] = []
    var title: String = ""

    @MainActor static func clipboard(_ pasteboard: NSPasteboard) throws -> Self {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), let image = try? CaptureImageCodec.decode(data) {
                return Self(originalData: try CaptureImageCodec.png(image), text: pasteboard.string(forType: .string), html: pasteboard.string(forType: .html))
            }
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            guard urls.count <= 100 else { throw CaptureMessage("一次最多贴出 100 个文件。", "Pin up to 100 files at a time.") }
            if urls.count == 1, UTType(filenameExtension: urls[0].pathExtension)?.conforms(to: .image) == true,
               let size = try? urls[0].resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 * 1024 * 1024,
               let data = try? Data(contentsOf: urls[0]), let image = try? CaptureImageCodec.decode(data) {
                return Self(originalData: try CaptureImageCodec.png(image), files: urls, title: urls[0].lastPathComponent)
            }
            let text = urls.map(\.path).joined(separator: "\n")
            return Self(originalData: try PinnedImageRendering.card(text: urls.prefix(20).map(\.lastPathComponent).joined(separator: "\n") + (urls.count > 20 ? "\n…" : "")), kind: .files, text: text, files: urls,
                        title: CaptureLocalization.text("文件贴图", "Pinned files"))
        }
        if let color = NSColor(from: pasteboard)?.usingColorSpace(.sRGB) {
            return try colorContent(color)
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            throw CaptureMessage("剪贴板中没有可贴出的图片、文字、颜色或文件。", "The clipboard has no image, text, color, or files to pin.")
        }
        guard text.utf8.count <= 2 * 1024 * 1024 else { throw CaptureMessage("文字超过 2 MB，请先缩小内容。", "Text exceeds 2 MB. Reduce its size first.") }
        if let color = PinnedImageRendering.parseColor(text) { return try colorContent(color, original: text) }
        return Self(originalData: try PinnedImageRendering.card(text: text), kind: .text, text: text,
                    html: pasteboard.string(forType: .html), title: CaptureLocalization.text("文字贴图", "Pinned text"))
    }

    @MainActor private static func colorContent(_ color: NSColor, original: String? = nil) throws -> Self {
        let code = PinnedImageRendering.hex(color)
        return Self(originalData: try PinnedImageRendering.card(text: code, color: color), kind: .color,
                    text: original ?? code, title: CaptureLocalization.text("颜色贴图", "Pinned color"))
    }
}

enum PinnedImageRendering {
    static func parseColor(_ value: String) -> NSColor? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("#") else { return nil }
        var hex = String(text.dropFirst())
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, hex.allSatisfy({ $0.isHexDigit }), let bits = UInt32(hex, radix: 16) else { return nil }
        let alpha = hex.count == 8 ? Double(bits & 255) / 255 : 1
        let rgb = hex.count == 8 ? bits >> 8 : bits
        return NSColor(srgbRed: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, alpha: alpha)
    }
    static func hex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
    @MainActor static func card(text: String, color: NSColor? = nil) throws -> Data {
        let displayed = String(text.prefix(12_000)) + (text.count > 12_000 ? "\n…" : "")
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1)]
        let measured = (displayed as NSString).boundingRect(with: CGSize(width: 584, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
        let height = color == nil ? min(1080, max(90, Int(ceil(measured.height)) + 48)) : 228
        let context = try CaptureImageCodec.context(width: 640, height: height)
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 640, height: height))
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        if let color { color.setFill(); CGRect(x: 0, y: 0, width: 640, height: 148).fill() }
        (displayed as NSString).draw(with: CGRect(x: 24, y: color == nil ? 24 : 170, width: 592, height: CGFloat(height) - 48), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
        guard let image = context.makeImage() else { throw CaptureToolError.invalidImage }
        return try CaptureImageCodec.png(image)
    }
    static func flip(_ image: CGImage, horizontal: Bool) throws -> CGImage {
        let context = try CaptureImageCodec.context(width: image.width, height: image.height)
        context.translateBy(x: horizontal ? CGFloat(image.width) : 0, y: horizontal ? 0 : CGFloat(image.height))
        context.scaleBy(x: horizontal ? -1 : 1, y: horizontal ? 1 : -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw CaptureToolError.invalidImage }; return result
    }
    static func scaled(_ image: CGImage, scale: CGFloat, opacity: CGFloat) throws -> CGImage {
        let width = max(1, Int((CGFloat(image.width) * scale).rounded())), height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let context = try CaptureImageCodec.context(width: width, height: height)
        context.interpolationQuality = scale < 1 ? .high : .none
        context.setAlpha(opacity); context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw CaptureToolError.invalidImage }; return result
    }
}

@MainActor
final class PinnedImageModel {
    private(set) var id = UUID()
    let content: PinnedImageContent
    let originalImage: CGImage
    private(set) var image: CGImage
    private(set) var editedData: Data?
    private(set) var rotation = 0
    private(set) var horizontalFlip = false
    private(set) var verticalFlip = false
    private(set) var scale: CGFloat = 1
    private(set) var opacity: CGFloat = 1
    private(set) var thumbnail = false
    private(set) var crop: CGRect?
    private var lastScaleAndOpacity: (CGFloat, CGFloat)?
    var locked = false
    var onTop = true
    var clickThrough = false
    var shadow = true
    var title: String

    init(content: PinnedImageContent) throws {
        originalImage = try CaptureImageCodec.decode(content.originalData)
        var normalized = content; normalized.originalData = try CaptureImageCodec.png(originalImage); self.content = normalized
        image = originalImage; title = content.title
    }
    private struct Recovery: Codable {
        let id: UUID
        let content: PinnedImageContent
        let image: Data
        let editedData: Data?
        let rotation: Int
        let horizontalFlip: Bool
        let verticalFlip: Bool
        let scale: CGFloat
        let opacity: CGFloat
        let thumbnail: Bool
        let crop: CGRect?
        let previousScale: CGFloat?
        let previousOpacity: CGFloat?
        let locked: Bool
        let onTop: Bool
        let clickThrough: Bool
        let shadow: Bool
        let title: String
    }
    func recoveryData() throws -> Data {
        try JSONEncoder().encode(Recovery(id: id, content: content, image: CaptureImageCodec.png(image), editedData: editedData,
            rotation: rotation, horizontalFlip: horizontalFlip, verticalFlip: verticalFlip, scale: scale, opacity: opacity,
            thumbnail: thumbnail, crop: crop, previousScale: lastScaleAndOpacity?.0, previousOpacity: lastScaleAndOpacity?.1,
            locked: locked, onTop: onTop, clickThrough: clickThrough, shadow: shadow, title: title))
    }
    static func recover(_ data: Data) throws -> PinnedImageModel {
        let saved = try JSONDecoder().decode(Recovery.self, from: data)
        let model = try PinnedImageModel(content: saved.content)
        model.id = saved.id; model.image = try CaptureImageCodec.decode(saved.image); model.editedData = saved.editedData
        model.rotation = saved.rotation; model.horizontalFlip = saved.horizontalFlip; model.verticalFlip = saved.verticalFlip
        model.scale = saved.scale; model.opacity = saved.opacity; model.thumbnail = saved.thumbnail; model.crop = saved.crop
        if let scale = saved.previousScale, let opacity = saved.previousOpacity { model.lastScaleAndOpacity = (scale, opacity) }
        model.locked = saved.locked; model.onTop = saved.onTop; model.clickThrough = saved.clickThrough; model.shadow = saved.shadow; model.title = saved.title
        return model
    }
    var imageBounds: CGRect { CGRect(x: 0, y: 0, width: image.width, height: image.height) }
    var visibleRect: CGRect { thumbnail ? crop?.intersection(imageBounds) ?? imageBounds : imageBounds }
    var displaySize: CGSize { CGSize(width: max(1, visibleRect.width * scale), height: max(1, visibleRect.height * scale)) }
    var retainedBytes: Int {
        content.originalData.count + (editedData?.count ?? 0) + (content.text?.utf8.count ?? 0) + (content.html?.utf8.count ?? 0)
            + originalImage.width * originalImage.height * 4 + (image === originalImage ? 0 : image.width * image.height * 4)
    }
    var canEdit: Bool { !locked }
    func setScale(_ value: CGFloat) {
        guard !locked, value.isFinite else { return }
        let upper = min(8, 8192 / max(CGFloat(image.width), CGFloat(image.height)), sqrt(16_000_000 / max(1, visibleRect.width * visibleRect.height)))
        scale = min(max(0.01, upper), max(0.01, value)); lastScaleAndOpacity = nil
    }
    func setOpacity(_ value: CGFloat) { guard !locked, value.isFinite else { return }; opacity = min(1, max(0.1, value)); lastScaleAndOpacity = nil }
    func toggleOriginalSize() {
        guard !locked else { return }
        if let previous = lastScaleAndOpacity { scale = previous.0; opacity = previous.1; lastScaleAndOpacity = nil }
        else { let previous = (scale, opacity); setScale(1); opacity = 1; lastScaleAndOpacity = previous }
    }
    func rotate(clockwise: Bool) throws {
        guard !locked else { return }
        image = try clockwise ? CaptureImageCodec.rotateClockwise(image) : CaptureImageCodec.rotateCounterClockwise(image)
        rotation = (rotation + (clockwise ? 1 : 3)) % 4; resetCropAfterTransform()
    }
    func flip(horizontal: Bool) throws {
        guard !locked else { return }
        image = try PinnedImageRendering.flip(image, horizontal: horizontal)
        if horizontal { horizontalFlip.toggle() } else { verticalFlip.toggle() }; resetCropAfterTransform()
    }
    private func resetCropAfterTransform() { crop = nil; if thumbnail { thumbnail = false; toggleThumbnail() }; setScale(scale) }
    func resetImage() {
        guard !locked else { return }
        image = originalImage; editedData = nil; rotation = 0; horizontalFlip = false; verticalFlip = false; crop = nil; thumbnail = false
    }
    func toggleThumbnail() {
        guard !locked else { return }
        thumbnail.toggle()
        if thumbnail, crop == nil {
            let width = min(imageBounds.width, max(2, 240 / scale)), height = min(imageBounds.height, max(2, 160 / scale))
            crop = CGRect(x: (imageBounds.width - width) / 2, y: (imageBounds.height - height) / 2, width: width, height: height).integral.intersection(imageBounds)
        }
    }
    func setCrop(_ value: CGRect) {
        guard !locked else { return }
        let safe = value.standardized.integral.intersection(imageBounds)
        guard safe.width >= 2, safe.height >= 2 else { return }; crop = safe; thumbnail = true
    }
    func panCrop(by delta: CGSize) {
        guard !locked, thumbnail, let crop else { return }
        self.crop = CaptureSelectionGeometry.moved(crop, by: delta, within: imageBounds)
    }
    func sourceImage() throws -> CGImage {
        if thumbnail { return try CaptureImageCodec.crop(image, rect: visibleRect) }; return image
    }
    func currentData() throws -> Data { try CaptureImageCodec.png(PinnedImageRendering.scaled(sourceImage(), scale: scale, opacity: opacity)) }
    func applyAnnotation(_ data: Data) throws {
        let edited = try CaptureImageCodec.decode(data)
        image = edited; editedData = data; rotation = 0; horizontalFlip = false; verticalFlip = false; crop = nil; thumbnail = false; setScale(scale)
    }
}

@MainActor
final class PinnedImageSession {
    let model: PinnedImageModel
    let window: NSPanel
    let canvas: PinnedImageCanvas
    var ocrTask: Task<Void, Never>?
    var annotationTask: Task<Void, Never>?
    var annotationController: CaptureAnnotationController?
    var resultWindows: [NSWindow] = []
    var hiddenResultWindows: Set<ObjectIdentifier> = []
    var savePanels: [NSSavePanel] = []
    var savedFrame: CGRect?
    init(model: PinnedImageModel, window: NSPanel, canvas: PinnedImageCanvas) { self.model = model; self.window = window; self.canvas = canvas }
    func cancelWork() {
        ocrTask?.cancel(); ocrTask = nil; annotationTask?.cancel(); annotationTask = nil; annotationController?.cancel(); annotationController = nil
        savePanels.forEach { $0.cancel(nil) }; savePanels.removeAll()
    }
}

@MainActor
enum PinnedImagePresentation {
    static func prepare(isApplicationHidden: Bool, windows: [NSWindow], pins: [NSWindow], unhide: () -> Void) {
        guard isApplicationHidden, !pins.isEmpty else { return }
        let intended = Set(pins.map(ObjectIdentifier.init))
        // Unhiding an app can restore all of its windows. Keep the main window and other
        // workflows hidden, including when a pin itself has had always-on-top turned off.
        windows.filter { !intended.contains(ObjectIdentifier($0)) }.forEach { $0.orderOut(nil) }
        unhide()
    }
}

@MainActor
private final class PinnedImageRecovery {
    private var model: PinnedImageModel?
    private var file: URL?
    init(_ model: PinnedImageModel) { self.model = model }
    var bytes: Int { model?.retainedBytes ?? 0 }
    func read() throws -> PinnedImageModel {
        if let model { return model }
        guard let file else { throw CaptureToolError.invalidImage }
        return try PinnedImageModel.recover(Data(contentsOf: file, options: .mappedIfSafe))
    }
    func spill() throws {
        guard let model else { return }
        let directory = try SessionTemporaryFiles.create(prefix: "xclip-pin-history-")
        let target = directory.appendingPathComponent("snapshot.json")
        do { try model.recoveryData().write(to: target, options: .atomic); file = target; self.model = nil }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    deinit { if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) } }
}

@MainActor
final class PinnedImageController: NSObject, NSWindowDelegate {
    static let shared = PinnedImageController()
    static let didChange = Notification.Name("XclipPinnedImagesChanged")
    private(set) var sessions: [UUID: PinnedImageSession] = [:]
    private var order: [UUID] = []
    private var history: [(PinnedImageRecovery, CGRect)] = []
    var allowsDiskHistory: () -> Bool = { false }
    var historyBudget = 64 * 1024 * 1024
    var historyResidentBytes: Int { history.reduce(0) { $0 + $1.0.bytes } }
    private(set) var isHidden = false
    private(set) var lastError: Error?
    let presentsWindows: Bool
    let pasteboard: NSPasteboard
    var onWorkflowAction: ((CaptureAnnotationResult) -> Void)?
    var historyLimit = 10 { didSet { trimHistory() } }
    private let recognize: (Data) async throws -> String
    private let annotate: ((CGImage, CGRect) async throws -> CaptureAnnotationResult)?
    var activeCount: Int { sessions.count }
    var historyCount: Int { history.count }

    init(presentsWindows: Bool = true, pasteboard: NSPasteboard = .general,
         recognize: @escaping (Data) async throws -> String = { try await CaptureService.shared.recognizeText(in: $0) },
         annotate: ((CGImage, CGRect) async throws -> CaptureAnnotationResult)? = nil) {
        self.presentsWindows = presentsWindows; self.pasteboard = pasteboard; self.recognize = recognize; self.annotate = annotate
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(languageDidChange), name: AppLanguage.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
    }
    @objc private func languageDidChange() { for session in sessions.values { refresh(session, resize: false) } }
    @objc private func screensChanged() { ensureVisible() }
    @objc private func sleeping() { closeAll() }
    private func changed() { NotificationCenter.default.post(name: Self.didChange, object: self) }
    private func prepareVisibility() {
        guard presentsWindows else { return }
        PinnedImagePresentation.prepare(isApplicationHidden: NSApp.isHidden, windows: NSApp.windows,
            pins: sessions.values.flatMap { [$0.window] + $0.resultWindows },
            unhide: { NSApp.unhideWithoutActivation() })
    }

    @discardableResult func show(_ data: Data, at frame: CGRect? = nil) -> UUID? {
        do { return try present(PinnedImageModel(content: PinnedImageContent(originalData: data)), at: frame) }
        catch { report(error); return nil }
    }
    @discardableResult func showClipboard() -> UUID? {
        do { return try present(PinnedImageModel(content: PinnedImageContent.clipboard(pasteboard)), at: nil) }
        catch { report(error); return nil }
    }
    @discardableResult func showText(_ text: String) -> UUID? {
        do {
            guard text.utf8.count <= 2 * 1024 * 1024 else { throw CaptureMessage("文字超过 2 MB。", "Text exceeds 2 MB.") }
            let content = PinnedImageContent(originalData: try PinnedImageRendering.card(text: text), kind: .text, text: text, title: CaptureLocalization.text("文字贴图", "Pinned text"))
            return try present(PinnedImageModel(content: content), at: nil)
        } catch { report(error); return nil }
    }
    @discardableResult func showRendered(_ data: Data, originalText: String) -> UUID? {
        do { return try present(PinnedImageModel(content: PinnedImageContent(originalData: data, kind: .formula, text: originalText)), at: nil) }
        catch { report(error); return nil }
    }
    @discardableResult private func present(_ model: PinnedImageModel, at requestedFrame: CGRect?, restoring: Bool = false) throws -> UUID {
        guard sessions.count < 20, sessions.values.reduce(model.retainedBytes, { $0 + $1.model.retainedBytes }) < 384 * 1024 * 1024 else {
            throw CaptureMessage("贴图较多或图片过大，请先关闭部分贴图。", "Too many or oversized pins. Close some pins first.")
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        if !restoring {
            let available = requestedFrame?.size ?? CGSize(width: visible.width * 0.7, height: visible.height * 0.7)
            model.setScale(min(1, available.width / CGFloat(model.image.width), available.height / CGFloat(model.image.height)))
        }
        let size = model.displaySize
        let origin = requestedFrame.map { CGPoint(x: $0.midX - size.width / 2, y: $0.midY - size.height / 2) }
            ?? CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        let panel = PinnedImagePanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = model.shadow
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.acceptsMouseMovedEvents = true
        panel.delegate = self
        let canvas = PinnedImageCanvas(model: model, owner: self)
        panel.contentView = canvas; panel.makeFirstResponder(canvas)
        let session = PinnedImageSession(model: model, window: panel, canvas: canvas)
        sessions[model.id] = session; order.append(model.id)
        if isHidden { toggleAll() }
        refresh(session, resize: false)
        if presentsWindows { prepareVisibility(); panel.makeKeyAndOrderFront(nil) }
        changed(); return model.id
    }
    @discardableResult func restoreLast() -> Bool {
        guard let (recovery, frame) = history.popLast() else { return false }
        do { let model = try recovery.read(); model.clickThrough = false; _ = try present(model, at: frame, restoring: true); return true }
        catch { history.append((recovery, frame)); report(error); return false }
    }
    func toggleAll() {
        isHidden.toggle()
        if presentsWindows {
            if !isHidden { prepareVisibility() }
            for session in sessions.values {
                if isHidden {
                    session.hiddenResultWindows = Set(session.resultWindows.filter(\.isVisible).map(ObjectIdentifier.init))
                    session.window.orderOut(nil); session.resultWindows.forEach { $0.orderOut(nil) }
                }
                else {
                    session.window.orderFrontRegardless()
                    session.resultWindows.forEach { if session.hiddenResultWindows.contains(ObjectIdentifier($0)) { $0.orderFrontRegardless() } }
                    session.hiddenResultWindows.removeAll()
                }
            }
        }
        changed()
    }
    func resetClickThrough() {
        for session in sessions.values { session.model.clickThrough = false; refresh(session, resize: false) }
        if isHidden { toggleAll() }
        else if presentsWindows {
            prepareVisibility(); sessions.values.forEach { $0.window.orderFrontRegardless() }
        }
        ensureVisible(); changed()
    }
    func ensureVisible() {
        guard presentsWindows, let fallback = NSScreen.main?.visibleFrame else { return }
        for session in sessions.values where !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(session.window.frame) }) {
            session.window.setFrameOrigin(CGPoint(x: fallback.midX - session.window.frame.width / 2, y: fallback.midY - session.window.frame.height / 2))
        }
    }
    func closeVisible() { for id in order { close(id, remember: true) } }
    /// Privacy destruction: no closed history, tasks, or result windows survive this call.
    func closeAll() {
        history.removeAll()
        for id in order { close(id, remember: false) }
        order.removeAll(); isHidden = false; lastError = nil; changed()
    }
    func close(_ id: UUID, remember: Bool = true) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }; session.cancelWork()
        session.resultWindows.forEach { if let sheet = $0.attachedSheet { $0.endSheet(sheet, returnCode: .cancel) }; $0.orderOut(nil); $0.contentView = nil; $0.close() }; session.resultWindows.removeAll()
        if remember { history.append((PinnedImageRecovery(session.model), session.window.frame)); trimHistory() }
        session.window.delegate = nil; session.window.orderOut(nil); session.window.contentView = nil; session.window.close()
        changed()
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let id = sessions.first(where: { $0.value.window === window })?.key { close(id) }
        else {
            for session in sessions.values {
                if let index = session.resultWindows.firstIndex(where: { $0 === window }) {
                    session.resultWindows.remove(at: index); window.contentView = nil; break
                }
            }
        }
    }
    private func trimHistory() {
        while history.count > max(0, min(50, historyLimit)) { history.removeFirst() }
        if allowsDiskHistory() {
            do { for entry in history where historyResidentBytes > historyBudget { try entry.0.spill() } }
            catch { report(error) }
        }
        while historyResidentBytes > max(0, historyBudget), !history.isEmpty { history.removeFirst() }
    }
    func refresh(_ session: PinnedImageSession, resize: Bool = true, frameOrigin: CGPoint? = nil) {
        let model = session.model, window = session.window
        if resize {
            let old = window.frame, size = model.displaySize
            window.setFrame(CGRect(origin: frameOrigin ?? CGPoint(x: old.midX - size.width / 2, y: old.midY - size.height / 2), size: size), display: true)
        }
        window.alphaValue = model.opacity; window.level = model.onTop ? .floating : .normal
        window.ignoresMouseEvents = model.clickThrough; window.hasShadow = model.shadow
        window.title = model.title.isEmpty ? CaptureLocalization.text("Xclip 贴图", "Xclip Pinned Image") : model.title
        session.canvas.toolTip = CaptureLocalization.text("拖动移动 · Ctrl 拖出（右键取消）· 滚轮缩放 · Ctrl 滚轮透明度 · 空格标注 · 右键更多", "Drag Move · Ctrl Drag Out (Right-click Cancel) · Wheel Zoom · Ctrl Wheel Opacity · Space Annotate · Right-click More")
        session.canvas.setAccessibilityLabel(window.title + ", " + (model.locked ? CaptureLocalization.text("已锁定", "Locked") : CaptureLocalization.text("可移动", "Movable")))
        session.canvas.needsDisplay = true
        window.invalidateCursorRects(for: session.canvas)
    }
    func change(_ id: UUID, _ edit: (PinnedImageModel) throws -> Void) {
        guard let session = sessions[id] else { return }
        do { try edit(session.model); refresh(session) }
        catch { session.canvas.feedback(error.localizedDescription) }
    }
    func copy(_ id: UUID, original: Bool = false) {
        guard let model = sessions[id]?.model else { return }
        do {
            let data = original ? model.content.originalData : try model.currentData()
            pasteboard.clearContents(); pasteboard.setData(data, forType: .png)
            sessions[id]?.canvas.feedback(CaptureLocalization.text("图片已复制", "Image copied"))
        } catch { sessions[id]?.canvas.feedback(error.localizedDescription) }
    }
    func copySource(_ id: UUID, html: Bool = false) {
        guard let content = sessions[id]?.model.content else { return }
        pasteboard.clearContents()
        if html, let value = content.html { pasteboard.setString(value, forType: .html); if let text = content.text { pasteboard.setString(text, forType: .string) } }
        else if content.kind == .files { pasteboard.writeObjects(content.files as [NSURL]) }
        else if let text = content.text { pasteboard.setString(text, forType: .string) }
    }
    func save(_ id: UUID, original: Bool = false) {
        guard let session = sessions[id], session.savePanels.isEmpty else { return }
        do {
            let data = original ? session.model.content.originalData : try session.model.currentData()
            if !original {
                let panel = NSSavePanel(); session.savePanels.append(panel)
                defer { session.savePanels.removeAll { $0 === panel } }
                if let url = try CaptureOutput.save(data, panel: panel, allowsWrite: { [weak self, weak session] in self?.sessions[id] === session && session != nil }) {
                    session.canvas.feedback(CaptureLocalization.text("已保存：", "Saved: ") + url.lastPathComponent)
                }
                return
            }
            let panel = NSSavePanel(); panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "Xclip-pin.png"; panel.title = CaptureLocalization.text("保存贴图", "Save pinned image")
            session.savePanels.append(panel)
            panel.begin { [weak self] response in
                self?.sessions[id]?.savePanels.removeAll { $0 === panel }
                guard response == .OK, let url = panel.url, self?.sessions[id] != nil else { return }
                do { try data.write(to: url, options: .atomic) }
                catch { self?.sessions[id]?.canvas.feedback(error.localizedDescription) }
            }
        } catch { session.canvas.feedback(error.localizedDescription) }
    }
    func recognizeText(_ id: UUID) {
        guard let session = sessions[id], session.ocrTask == nil else { return }
        do {
            let data = try CaptureImageCodec.png(session.model.sourceImage())
            session.canvas.feedback(CaptureLocalization.text("正在识别文字…", "Recognizing text…"))
            session.ocrTask = Task { [weak self, weak session] in
                guard let self, let session else { return }
                defer { session.ocrTask = nil }
                do {
                    let text = try await recognize(data); try Task.checkCancellation()
                    guard sessions[id] === session else { return }
                    showTextResult(text, for: id)
                } catch is CancellationError { }
                catch { if sessions[id] === session { session.canvas.feedback(error.localizedDescription) } }
            }
        } catch { session.canvas.feedback(error.localizedDescription) }
    }
    func annotateImage(_ id: UUID) {
        guard let session = sessions[id], !session.model.locked, session.annotationTask == nil else { return }
        do {
            let image = try session.model.sourceImage()
            let frame = session.window.screen?.frame ?? NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
            session.savedFrame = session.window.frame
            if presentsWindows { session.window.orderOut(nil) }
            session.annotationTask = Task { [weak self, weak session] in
                guard let self, let session else { return }
                defer {
                    session.annotationTask = nil; session.annotationController = nil
                    if sessions[id] === session { refresh(session); if presentsWindows && !isHidden { prepareVisibility(); session.window.makeKeyAndOrderFront(nil) } }
                }
                do {
                    let result: CaptureAnnotationResult
                    if let annotate { result = try await annotate(image, frame) }
                    else {
                        let editor = CaptureAnnotationController(); session.annotationController = editor
                        result = try await editor.select(snapshots: [.init(frame: frame, image: image, selectsFullImage: true)])
                    }
                    try Task.checkCancellation(); guard sessions[id] === session else { return }
                    try session.model.applyAnnotation(result.data)
                    switch result.destination {
                    case .copy, .saved: break
                    case .action(let action, _):
                        if action == .pin { break }
                        if action == .ocr { recognizeText(id) }
                        else if action == .longCapture || action == .recording { session.canvas.feedback(CaptureLocalization.text("长截图和录屏请从截屏选区启动。", "Start scrolling capture or recording from a screen selection.")) }
                        else if let onWorkflowAction { onWorkflowAction(result) }
                        else { session.canvas.feedback(CaptureLocalization.text("该处理流程尚未连接。", "This image workflow is not connected.")) }
                    }
                } catch is CancellationError { }
                catch CaptureToolError.cancelled { }
                catch { if sessions[id] === session { session.canvas.feedback(error.localizedDescription) } }
            }
        } catch { session.canvas.feedback(error.localizedDescription) }
    }
    func workflow(_ action: CaptureWorkflowAction, for id: UUID) {
        guard let model = sessions[id]?.model, let onWorkflowAction else { return }
        do { onWorkflowAction(.init(data: try CaptureImageCodec.png(model.sourceImage()), destination: .action(action, region: .zero))) }
        catch { sessions[id]?.canvas.feedback(error.localizedDescription) }
    }
    func showTextResult(_ text: String, for id: UUID) {
        guard let session = sessions[id] else { return }
        let window = NSPanel(contentRect: CGRect(x: session.window.frame.minX, y: session.window.frame.minY, width: 560, height: 380), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = CaptureLocalization.text("贴图文字 · 可编辑", "Pinned text · Editable")
        window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false; window.level = .floating
        window.delegate = self
        window.contentView = PinnedTextResultView(text: text, pasteboard: pasteboard, pin: { [weak self] in self?.showText($0) })
        session.resultWindows.append(window)
        if presentsWindows { prepareVisibility(); window.makeKeyAndOrderFront(nil) }
    }
    private func report(_ error: Error) {
        lastError = error
        guard presentsWindows else { return }
        let alert = NSAlert(); alert.messageText = CaptureLocalization.text("无法贴图", "Unable to pin")
        alert.informativeText = error.localizedDescription; alert.addButton(withTitle: CaptureLocalization.text("好", "OK")); alert.runModal()
    }
}

private final class PinnedImagePanel: NSPanel {
    override var canBecomeKey: Bool { !ignoresMouseEvents }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PinnedImageCanvas: NSView, NSDraggingSource {
    let model: PinnedImageModel
    weak var owner: PinnedImageController?
    private var dragStart: CGPoint?
    private var startingFrame: CGRect?
    private var startingCrop: CGRect?
    private var cropHandle: CaptureSelectionHandle?
    private var rightStart: CGPoint?
    private var rightSelection: CGRect?
    private var contentDragStarted = false
    private var cancellationToken: UUID?
    private var message = ""
    private var messageUntil = Date.distantPast

    init(model: PinnedImageModel, owner: PinnedImageController) {
        self.model = model; self.owner = owner
        super.init(frame: CGRect(origin: .zero, size: model.displaySize))
        autoresizingMask = [.width, .height]
        setAccessibilityElement(true); setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    func feedback(_ text: String) {
        message = text; messageUntil = Date().addingTimeInterval(2); needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) { [weak self] in self?.needsDisplay = true }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); bounds.fill(using: .copy)
        if let image = try? model.sourceImage() {
            NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
                .draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if model.locked || model.clickThrough || window?.isKeyWindow == true {
            (model.clickThrough ? NSColor.systemGreen : model.locked ? .systemOrange : .systemBlue).setStroke()
            let outline = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)); outline.lineWidth = 1; outline.stroke()
        }
        if let selection = rightSelection {
            NSColor.systemBlue.withAlphaComponent(0.15).setFill(); selection.fill()
            NSColor.systemBlue.setStroke(); NSBezierPath(rect: selection).stroke()
        }
        if Date() < messageUntil && !message.isEmpty {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white, .paragraphStyle: paragraph]
            let rect = CGRect(x: 5, y: max(4, bounds.height - 29), width: max(1, bounds.width - 10), height: 24)
            NSColor.black.withAlphaComponent(0.78).setFill(); NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            (message as NSString).draw(in: rect.insetBy(dx: 6, dy: 4), withAttributes: attributes)
        }
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: model.locked ? .arrow : .openHand)
        if model.thumbnail && !model.locked {
            addCursorRect(CGRect(x: 0, y: 0, width: 5, height: bounds.height), cursor: .resizeLeftRight)
            addCursorRect(CGRect(x: bounds.maxX - 5, y: 0, width: 5, height: bounds.height), cursor: .resizeLeftRight)
            addCursorRect(CGRect(x: 0, y: 0, width: bounds.width, height: 5), cursor: .resizeUpDown)
            addCursorRect(CGRect(x: 0, y: bounds.maxY - 5, width: bounds.width, height: 5), cursor: .resizeUpDown)
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard cancellationToken == nil, DragCancellationController.shared.canBeginDrag else { return }
        contentDragStarted = false
        if owner?.presentsWindows == true { window?.makeKeyAndOrderFront(nil) }; window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            if event.modifierFlags.contains(.shift) { owner?.change(model.id) { $0.toggleThumbnail() } }
            else { owner?.close(model.id) }
            return
        }
        if event.modifierFlags.contains(.control) { beginContentDrag(event); return }
        guard !model.locked, let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        dragStart = window.convertPoint(toScreen: event.locationInWindow); startingFrame = window.frame
        startingCrop = model.thumbnail ? model.visibleRect : nil
        cropHandle = nil
        if model.thumbnail && !event.modifierFlags.contains(.shift) {
            if point.x < 5 { cropHandle = point.y < 5 ? .topLeft : point.y > bounds.maxY - 5 ? .bottomLeft : .left }
            else if point.x > bounds.maxX - 5 { cropHandle = point.y < 5 ? .topRight : point.y > bounds.maxY - 5 ? .bottomRight : .right }
            else if point.y < 5 { cropHandle = .top }
            else if point.y > bounds.maxY - 5 { cropHandle = .bottom }
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard !contentDragStarted, DragCancellationController.shared.canBeginDrag,
              !model.locked, let window, let start = dragStart, let frame = startingFrame else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let delta = CGSize(width: point.x - start.x, height: point.y - start.y)
        if let crop = startingCrop, let handle = cropHandle {
            let changed = CaptureSelectionGeometry.resized(crop, handle: handle, by: CGSize(width: delta.width / model.scale, height: -delta.height / model.scale), within: model.imageBounds)
            model.setCrop(changed)
            let origin = CGPoint(x: frame.minX + (changed.minX - crop.minX) * model.scale,
                                 y: frame.maxY - (changed.minY - crop.minY) * model.scale - model.displaySize.height)
            if let session = owner?.sessions[model.id] { owner?.refresh(session, frameOrigin: origin) }
        } else if let crop = startingCrop, event.modifierFlags.contains(.shift) {
            model.setCrop(CaptureSelectionGeometry.moved(crop, by: CGSize(width: -delta.width / model.scale, height: delta.height / model.scale), within: model.imageBounds))
            needsDisplay = true
        } else { window.setFrameOrigin(CGPoint(x: frame.minX + delta.width, y: frame.minY + delta.height)) }
    }
    override func mouseUp(with event: NSEvent) { dragStart = nil; startingFrame = nil; startingCrop = nil; cropHandle = nil }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { owner?.change(model.id) { $0.toggleOriginalSize() } }
    }
    override func scrollWheel(with event: NSEvent) {
        guard !model.locked, abs(event.scrollingDeltaY) > 0.01 else { return }
        let amount = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 20 : event.scrollingDeltaY
        owner?.change(model.id) {
            if event.modifierFlags.contains(.control) { $0.setOpacity($0.opacity + amount * 0.05) }
            else { $0.setScale($0.scale * pow(1.08, min(5, max(-5, amount)))) }
        }
        feedback(String(format: "%.0f%% · %@ %.0f%%", model.scale * 100, CaptureLocalization.text("不透明度", "Opacity"), model.opacity * 100))
    }
    override func rightMouseDown(with event: NSEvent) {
        rightStart = convert(event.locationInWindow, from: nil); rightSelection = nil; startingCrop = model.visibleRect
    }
    override func rightMouseDragged(with event: NSEvent) {
        guard !model.locked, let start = rightStart else { return }
        let current = convert(event.locationInWindow, from: nil)
        rightSelection = CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y)).intersection(bounds)
        needsDisplay = true
    }
    override func rightMouseUp(with event: NSEvent) {
        defer { rightStart = nil; rightSelection = nil; startingCrop = nil; needsDisplay = true }
        if !model.locked, let rect = rightSelection, rect.width >= 4, rect.height >= 4, let source = startingCrop {
            let selected = CGRect(x: source.minX + rect.minX / model.scale, y: source.minY + rect.minY / model.scale, width: rect.width / model.scale, height: rect.height / model.scale)
            owner?.change(model.id) { $0.setCrop(selected) }
        } else if owner?.presentsWindows == true { NSMenu.popUpContextMenu(contextMenu(), with: event, for: self) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "w": owner?.close(model.id); return true
        case "d": owner?.close(model.id, remember: false); return true
        case "c": owner?.copy(model.id, original: event.modifierFlags.contains(.option)); return true
        case "s": owner?.save(model.id, original: event.modifierFlags.contains(.shift)); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { owner?.close(model.id); return }
        if event.keyCode == 49 { owner?.annotateImage(model.id); return }
        if [123, 124, 125, 126].contains(event.keyCode), !model.locked, let window {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let delta = CGPoint(x: event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0, y: event.keyCode == 125 ? -step : event.keyCode == 126 ? step : 0)
            window.setFrameOrigin(CGPoint(x: window.frame.minX + delta.x, y: window.frame.minY + delta.y)); return
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "l": perform(.lock)
        case "t": perform(.top)
        case "r": perform(.thumbnail)
        case "1": perform(.rotateRight)
        case "2": perform(.rotateLeft)
        case "3": perform(.flipHorizontal)
        case "4": perform(.flipVertical)
        case "0": perform(.resetImage)
        case "c" where event.modifierFlags.contains(.shift): owner?.recognizeText(model.id)
        default: super.keyDown(with: event)
        }
    }
    enum Action: Int {
        case copyCurrent = 1, copyOriginal, saveCurrent, saveOriginal, copySource, copyHTML, viewText, ocr, annotate, lock, top, passthrough, shadow, thumbnail, rotateRight, rotateLeft, flipHorizontal, flipVertical, resetImage, close, destroy, restoreLast, toggleAll, resetPassthrough, showFiles, copyPaths, translate, formula, table, barcode
    }
    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Action, key: String = "", checked: Bool? = nil, enabled: Bool = true, to destination: NSMenu? = nil) {
            let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: key)
            item.target = self; item.tag = action.rawValue; item.isEnabled = enabled
            if let checked { item.state = checked ? .on : .off }
            (destination ?? menu).addItem(item)
        }
        menu.autoenablesItems = false
        for (title, original) in [(CaptureLocalization.text("当前图像", "Current image"), false), (CaptureLocalization.text("原始图像", "Original image"), true)] {
            let group = NSMenuItem(title: title, action: nil, keyEquivalent: ""), submenu = NSMenu(); submenu.autoenablesItems = false
            add(CaptureLocalization.text("复制", "Copy"), original ? .copyOriginal : .copyCurrent, to: submenu)
            add(CaptureLocalization.text("保存为…", "Save as…"), original ? .saveOriginal : .saveCurrent, to: submenu)
            group.submenu = submenu; menu.addItem(group)
        }
        if model.content.text != nil {
            add(model.content.kind == .files ? CaptureLocalization.text("复制文件", "Copy files") : CaptureLocalization.text("复制原始内容", "Copy original content"), .copySource)
            add(CaptureLocalization.text("查看文字…", "View text…"), .viewText)
        }
        if model.content.html != nil { add(CaptureLocalization.text("复制 HTML", "Copy HTML"), .copyHTML) }
        if !model.content.files.isEmpty {
            add(CaptureLocalization.text("在访达中显示文件", "Reveal files in Finder"), .showFiles)
            add(CaptureLocalization.text("复制所有文件路径", "Copy all file paths"), .copyPaths)
            let files = NSMenuItem(title: CaptureLocalization.text("打开文件", "Open file"), action: nil, keyEquivalent: ""), submenu = NSMenu()
            for (index, url) in model.content.files.enumerated() {
                let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openFile(_:)), keyEquivalent: ""); item.target = self; item.tag = index; submenu.addItem(item)
            }
            files.submenu = submenu; menu.addItem(files)
        }
        menu.addItem(.separator())
        add(CaptureLocalization.text("标注…（空格）", "Annotate… (Space)"), .annotate, enabled: !model.locked && owner?.sessions[model.id]?.annotationTask == nil)
        let busy = owner?.sessions[model.id]?.ocrTask != nil
        add(busy ? CaptureLocalization.text("识别中…", "Recognizing…") : CaptureLocalization.text("识别文字…", "Recognize text…"), .ocr, enabled: !busy)
        if owner?.onWorkflowAction != nil {
            add(CaptureLocalization.text("翻译…", "Translate…"), .translate)
            add(CaptureLocalization.text("识别公式…", "Recognize formula…"), .formula)
            add(CaptureLocalization.text("识别表格…", "Recognize table…"), .table)
            add(CaptureLocalization.text("识别二维码 / 条码…", "Read QR / barcode…"), .barcode)
        }
        menu.addItem(.separator())
        add(CaptureLocalization.text("锁定（L）", "Lock (L)"), .lock, checked: model.locked)
        add(CaptureLocalization.text("置顶（T）", "Always on top (T)"), .top, checked: model.onTop)
        add(CaptureLocalization.text("鼠标穿透", "Click through"), .passthrough, checked: model.clickThrough)
        add(CaptureLocalization.text("阴影", "Shadow"), .shadow, checked: model.shadow)
        add(CaptureLocalization.text("缩略图（R）", "Thumbnail (R)"), .thumbnail, checked: model.thumbnail, enabled: !model.locked)
        let transform = NSMenuItem(title: CaptureLocalization.text("图像处理", "Image adjustments"), action: nil, keyEquivalent: ""), adjustments = NSMenu(); adjustments.autoenablesItems = false
        for (title, action) in [(CaptureLocalization.text("向右旋转 90°（1）", "Rotate right 90° (1)"), Action.rotateRight), (CaptureLocalization.text("向左旋转 90°（2）", "Rotate left 90° (2)"), .rotateLeft), (CaptureLocalization.text("水平翻转（3）", "Flip horizontally (3)"), .flipHorizontal), (CaptureLocalization.text("垂直翻转（4）", "Flip vertically (4)"), .flipVertical), (CaptureLocalization.text("恢复原图（0）", "Restore original (0)"), .resetImage)] {
            add(title, action, enabled: !model.locked, to: adjustments)
        }
        transform.submenu = adjustments; menu.addItem(transform)
        menu.addItem(.separator())
        add(CaptureLocalization.text("关闭贴图（可恢复）", "Close pin (restorable)"), .close, key: "w")
        add(CaptureLocalization.text("销毁贴图（不可恢复）", "Destroy pin (permanent)"), .destroy)
        add(CaptureLocalization.text("恢复最近关闭的贴图", "Restore last closed pin"), .restoreLast, enabled: (owner?.historyCount ?? 0) > 0)
        add(CaptureLocalization.text("隐藏 / 显示全部贴图", "Hide / show all pins"), .toggleAll)
        add(CaptureLocalization.text("取消全部鼠标穿透", "Reset click through for all pins"), .resetPassthrough)
        return menu
    }
    @objc private func menuAction(_ item: NSMenuItem) { if let action = Action(rawValue: item.tag) { perform(action) } }
    @objc private func openFile(_ item: NSMenuItem) { if model.content.files.indices.contains(item.tag) { NSWorkspace.shared.open(model.content.files[item.tag]) } }
    func perform(_ action: Action) {
        switch action {
        case .copyCurrent: owner?.copy(model.id)
        case .copyOriginal: owner?.copy(model.id, original: true)
        case .saveCurrent: owner?.save(model.id)
        case .saveOriginal: owner?.save(model.id, original: true)
        case .copySource: owner?.copySource(model.id)
        case .copyHTML: owner?.copySource(model.id, html: true)
        case .viewText: owner?.showTextResult(model.content.text ?? "", for: model.id)
        case .ocr: owner?.recognizeText(model.id)
        case .annotate: owner?.annotateImage(model.id)
        case .lock: model.locked.toggle(); feedback(model.locked ? CaptureLocalization.text("已锁定 · L 解锁", "Locked · L to unlock") : CaptureLocalization.text("已解锁", "Unlocked"))
        case .top: model.onTop.toggle(); feedback(model.onTop ? CaptureLocalization.text("已置顶", "Always on top") : CaptureLocalization.text("已取消置顶", "Normal window level"))
        case .passthrough: model.clickThrough.toggle(); feedback(CaptureLocalization.text("Xclip 菜单可恢复鼠标交互", "Restore mouse interaction from the Xclip menu"))
        case .shadow: model.shadow.toggle()
        case .thumbnail: owner?.change(model.id) { $0.toggleThumbnail() }
        case .rotateRight: owner?.change(model.id) { try $0.rotate(clockwise: true) }
        case .rotateLeft: owner?.change(model.id) { try $0.rotate(clockwise: false) }
        case .flipHorizontal: owner?.change(model.id) { try $0.flip(horizontal: true) }
        case .flipVertical: owner?.change(model.id) { try $0.flip(horizontal: false) }
        case .resetImage: owner?.change(model.id) { $0.resetImage() }
        case .close: owner?.close(model.id)
        case .destroy: owner?.close(model.id, remember: false)
        case .restoreLast: _ = owner?.restoreLast()
        case .toggleAll: owner?.toggleAll()
        case .resetPassthrough: owner?.resetClickThrough()
        case .showFiles: NSWorkspace.shared.activateFileViewerSelecting(model.content.files)
        case .copyPaths:
            owner?.pasteboard.clearContents(); owner?.pasteboard.setString(model.content.files.map(\.path).joined(separator: "\n"), forType: .string)
        case .translate: owner?.workflow(.translate, for: model.id)
        case .formula: owner?.workflow(.formula, for: model.id)
        case .table: owner?.workflow(.table, for: model.id)
        case .barcode: owner?.workflow(.barcode, for: model.id)
        }
        if let session = owner?.sessions[model.id] { owner?.refresh(session, resize: false) }
    }
    private func beginContentDrag(_ event: NSEvent) {
        guard !contentDragStarted, !PrivacyLock.shared.locked, DragCancellationController.shared.canBeginDrag,
              let owner, owner.presentsWindows else { return }
        do {
            let writers: [NSPasteboardWriting]
            if model.content.kind == .files { writers = model.content.files as [NSURL] }
            else {
                let item = NSPasteboardItem()
                if let text = model.content.text, model.content.kind == .text || model.content.kind == .color { item.setString(text, forType: .string) }
                else { item.setData(try model.currentData(), forType: .png) }
                writers = [item]
            }
            let preview = NSImage(cgImage: try model.sourceImage(), size: bounds.size)
            let items = writers.map { writer -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: writer); item.setDraggingFrame(bounds, contents: preview); return item
            }
            guard !items.isEmpty else { return }
            dragStart = nil; startingFrame = nil; startingCrop = nil; cropHandle = nil
            rightStart = nil; rightSelection = nil
            contentDragStarted = true
            beginDraggingSession(with: items, event: event, source: self)
        } catch { feedback(error.localizedDescription) }
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        PrivacyLock.shared.locked || DragCancellationController.shared.isCancelled(cancellationToken) ? [] : .copy
    }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        cancellationToken = DragCancellationController.shared.begin()
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        _ = DragCancellationController.shared.end(cancellationToken)
        cancellationToken = nil
        // Do not turn remaining left-drag events into a window move or crop adjustment.
        dragStart = nil; startingFrame = nil; startingCrop = nil; cropHandle = nil
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

@MainActor
private final class PinnedTextResultView: NSView {
    private let editor = NSTextView()
    private let pasteboard: NSPasteboard
    private let pin: (String) -> Void
    private var savePanel: NSSavePanel?
    init(text: String, pasteboard: NSPasteboard, pin: @escaping (String) -> Void) {
        self.pasteboard = pasteboard; self.pin = pin
        super.init(frame: CGRect(x: 0, y: 0, width: 560, height: 380))
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        editor.string = text; editor.font = .systemFont(ofSize: 15); editor.isRichText = false; editor.allowsUndo = true
        editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true; editor.textContainerInset = CGSize(width: 10, height: 10)
        editor.setAccessibilityLabel(CaptureLocalization.text("识别文字，可编辑", "Recognized text, editable")); scroll.documentView = editor
        let copy = NSButton(title: CaptureLocalization.text("复制文字", "Copy text"), target: self, action: #selector(copyText))
        let save = NSButton(title: CaptureLocalization.text("保存文字…", "Save text…"), target: self, action: #selector(saveText))
        let pin = NSButton(title: CaptureLocalization.text("贴出文字", "Pin text"), target: self, action: #selector(pinText))
        let row = NSStackView(views: [copy, save, pin]); row.spacing = 8
        for view in [scroll, row] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 12), scroll.bottomAnchor.constraint(equalTo: row.topAnchor, constant: -12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { savePanel?.cancel(nil); savePanel = nil }; super.viewWillMove(toWindow: newWindow)
    }
    @objc private func copyText() { pasteboard.clearContents(); pasteboard.setString(editor.string, forType: .string) }
    @objc private func pinText() { pin(editor.string) }
    @objc private func saveText() {
        guard savePanel == nil else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "Xclip-text.txt"; savePanel = panel
        panel.begin { [weak self] response in
            guard let self else { return }; self.savePanel = nil
            guard response == .OK, let url = panel.url, self.window != nil else { return }
            do { try self.editor.string.write(to: url, atomically: true, encoding: .utf8) }
            catch { let alert = NSAlert(error: error); if let window = self.window { alert.beginSheetModal(for: window) } }
        }
    }
}
