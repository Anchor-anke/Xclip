import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VisionKit

enum ImageEditTool: String, CaseIterable, Identifiable {
    case crop = "裁剪", pen = "画笔", highlight = "荧光笔", rectangle = "矩形", ellipse = "椭圆", arrow = "箭头", text = "文字", number = "编号", mosaic = "马赛克"
    var id: String { rawValue }
    var title: String {
        let english: String
        switch self {
        case .crop: english = "Crop"
        case .pen: english = "Pen"
        case .highlight: english = "Highlight"
        case .rectangle: english = "Rectangle"
        case .ellipse: english = "Ellipse"
        case .arrow: english = "Arrow"
        case .text: english = "Text"
        case .number: english = "Number"
        case .mosaic: english = "Mosaic"
        }
        return CaptureLocalization.text(rawValue, english)
    }
    var symbol: String {
        switch self {
        case .crop: return "crop"
        case .pen: return "pencil.tip"
        case .highlight: return "highlighter"
        case .ellipse: return "oval"
        case .number: return "number.circle"
        case .rectangle: return "rectangle"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        case .mosaic: return "square.grid.3x3.fill"
        }
    }
}

struct ImageEditorPreferences: Codable, Equatable {
    static let key = "local.cclip.editor.preferences.v1"
    var toolRawValue = ImageEditTool.pen.rawValue
    var red = 1.0
    var green = 0.0
    var blue = 0.0
    var lineWidth = 4.0
    var textSize = 24.0
    var number = 1
    var tool: ImageEditTool { ImageEditTool(rawValue: toolRawValue) ?? .pen }
    var color: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    static func load(from defaults: UserDefaults = .standard) -> ImageEditorPreferences {
        guard let data = defaults.data(forKey: key), var value = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        value.red = value.red.isFinite ? min(1, max(0, value.red)) : 1
        value.green = value.green.isFinite ? min(1, max(0, value.green)) : 0
        value.blue = value.blue.isFinite ? min(1, max(0, value.blue)) : 0
        value.lineWidth = value.lineWidth.isFinite ? min(24, max(2, value.lineWidth)) : 4
        value.textSize = value.textSize.isFinite ? min(144, max(12, value.textSize)) : 24
        value.number = min(999, max(1, value.number))
        return value
    }
    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

struct ImageEditStroke {
    var tool: ImageEditTool
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text: String
    var fontSize: CGFloat? = nil
    var number: Int = 1
    var rect: CGRect {
        guard let first = points.first, let last = points.last else { return .zero }
        return CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
    }
}

enum ImageEditingOperations {
    static func apply(_ stroke: ImageEditStroke, to image: CGImage) throws -> CGImage {
        if stroke.tool == .crop { return try CaptureImageCodec.crop(image, rect: stroke.rect) }
        let context = try CaptureImageCodec.context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if stroke.tool == .mosaic {
            let rect = stroke.rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
            guard rect.width >= 2, rect.height >= 2 else { return image }
            guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { throw CaptureToolError.invalidImage }
            let blockSize = Int(max(8, stroke.width * 3))
            let minX = Int(rect.minX), maxX = Int(rect.maxX), minY = Int(rect.minY), maxY = Int(rect.maxY)
            // Work directly on premultiplied RGBA rows. This is deterministic and works without a GPU.
            for y in stride(from: minY, to: maxY, by: blockSize) {
                for x in stride(from: minX, to: maxX, by: blockSize) {
                    let endX = min(maxX, x + blockSize), endY = min(maxY, y + blockSize)
                    var sum = [Int](repeating: 0, count: 4)
                    for row in y..<endY {
                        for column in x..<endX {
                            let offset = (row * image.width + column) * 4
                            for channel in 0..<4 { sum[channel] += Int(pixels[offset + channel]) }
                        }
                    }
                    let count = (endX - x) * (endY - y)
                    let average = sum.map { UInt8($0 / count) }
                    for row in y..<endY {
                        for column in x..<endX {
                            let offset = (row * image.width + column) * 4
                            for channel in 0..<4 { pixels[offset + channel] = average[channel] }
                        }
                    }
                }
            }
        } else {
            draw(stroke, in: context, imageHeight: CGFloat(image.height))
        }
        guard let result = context.makeImage() else { throw CaptureToolError.invalidImage }
        return result
    }

    static func draw(_ stroke: ImageEditStroke, in context: CGContext, imageHeight: CGFloat) {
        guard let first = stroke.points.first else { return }
        let last = stroke.points.last ?? first
        if stroke.tool == .number {
            let radius = max(13, stroke.width * 3)
            let center = CGPoint(x: first.x, y: imageHeight - first.y)
            context.setFillColor(stroke.color.cgColor)
            context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            let rgb = stroke.color.usingColorSpace(.sRGB) ?? .red
            let brightness = rgb.redComponent * 0.2126 + rgb.greenComponent * 0.7152 + rgb.blueComponent * 0.0722
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: radius, weight: .bold), .foregroundColor: brightness > 0.55 ? NSColor.black : NSColor.white]
            let text = String(min(999, max(1, stroke.number))) as NSString
            let size = text.size(withAttributes: attributes)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            text.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        if stroke.tool == .text {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let text = String(stroke.text.prefix(500)) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: stroke.fontSize ?? max(14, stroke.width * 5), weight: .medium), .foregroundColor: stroke.color]
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: first.x, y: imageHeight - first.y - size.height), withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: 0, y: imageHeight)
        context.scaleBy(x: 1, y: -1)
        context.setStrokeColor(stroke.color.cgColor)
        context.setFillColor(stroke.color.cgColor)
        context.setLineWidth(stroke.width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch stroke.tool {
        case .pen, .highlight:
            if stroke.tool == .highlight {
                context.setStrokeColor(stroke.color.withAlphaComponent(0.3).cgColor)
                context.setFillColor(stroke.color.withAlphaComponent(0.3).cgColor)
                context.setLineWidth(max(12, stroke.width * 4))
                context.setLineCap(.square)
            }
            if stroke.points.count == 1 {
                let diameter = stroke.tool == .highlight ? max(12, stroke.width * 4) : stroke.width
                context.fillEllipse(in: CGRect(x: first.x - diameter / 2, y: first.y - diameter / 2, width: diameter, height: diameter))
            } else {
                context.move(to: first)
                stroke.points.dropFirst().forEach { context.addLine(to: $0) }
                context.strokePath()
            }
        case .rectangle: context.stroke(stroke.rect)
        case .ellipse: context.strokeEllipse(in: stroke.rect)
        case .arrow:
            context.move(to: first); context.addLine(to: last); context.strokePath()
            let angle = atan2(last.y - first.y, last.x - first.x)
            let length = max(14, stroke.width * 4)
            context.move(to: CGPoint(x: last.x - length * cos(angle - .pi / 6), y: last.y - length * sin(angle - .pi / 6)))
            context.addLine(to: last)
            context.addLine(to: CGPoint(x: last.x - length * cos(angle + .pi / 6), y: last.y - length * sin(angle + .pi / 6)))
            context.strokePath()
        case .crop, .text, .number, .mosaic: break
        }
    }
}

@MainActor
final class ImageEditorModel: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published var failure: Error?
    var errorMessage: String? { failure?.localizedDescription }
    @Published private(set) var undoCount = 0
    @Published private(set) var redoCount = 0
    private var undoImages: [CGImage] = []
    private var redoImages: [CGImage] = []
    init(data: Data) {
        do { image = try CaptureImageCodec.decode(data) } catch { failure = error }
    }
    func edit(_ stroke: ImageEditStroke) {
        guard let image else { return }
        if stroke.tool == .text && stroke.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            failure = CaptureMessage("请先输入标注文字，再点击图片放置。", "Enter annotation text, then click the image to place it."); return
        }
        do { commit(try ImageEditingOperations.apply(stroke, to: image)) }
        catch { failure = error }
    }
    func clear() {
        image = nil; undoImages.removeAll(); redoImages.removeAll(); failure = nil; updateCounts()
    }
    func rotate() {
        guard let image else { return }
        do { commit(try CaptureImageCodec.rotateClockwise(image)) } catch { failure = error }
    }
    private func commit(_ result: CGImage) {
        if let image { undoImages.append(image) }
        var pixels = undoImages.reduce(0) { $0 + $1.width * $1.height }
        while undoImages.count > 20 || (pixels > 100_000_000 && undoImages.count > 1) {
            let first = undoImages.removeFirst(); pixels -= first.width * first.height
        }
        redoImages.removeAll()
        image = result; failure = nil; updateCounts()
    }
    func undo() {
        guard let previous = undoImages.popLast() else { return }
        if let image { redoImages.append(image) }
        image = previous; updateCounts()
    }
    func redo() {
        guard let next = redoImages.popLast() else { return }
        if let image { undoImages.append(image) }
        image = next; updateCounts()
    }
    private func updateCounts() { undoCount = undoImages.count; redoCount = redoImages.count }
    func export() throws -> Data {
        guard let image else { throw CaptureToolError.invalidImage }
        return try CaptureImageCodec.png(image)
    }
}

struct ImageEditorView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ImageEditorModel
    @State private var tool: ImageEditTool = .pen
    @State private var color: Color = .red
    @State private var width = 4.0
    @State private var annotationText = ""
    @State private var textSize = 24.0
    @State private var nextNumber = 1
    private let onExport: (Data) -> Void
    init(imageData: Data, onExport: @escaping (Data) -> Void) {
        _model = StateObject(wrappedValue: ImageEditorModel(data: imageData))
        self.onExport = onExport
        let preferences = ImageEditorPreferences.load()
        _tool = State(initialValue: preferences.tool)
        _color = State(initialValue: Color(nsColor: preferences.color))
        _width = State(initialValue: preferences.lineWidth)
        _textSize = State(initialValue: preferences.textSize)
        _nextNumber = State(initialValue: preferences.number)
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(CaptureLocalization.text("图片编辑", "Image editor")).font(.title2.bold())
                Spacer()
                if let image = model.image { Text("\(image.width) × \(image.height)").foregroundStyle(.secondary).monospacedDigit() }
                Button(CaptureLocalization.text("关闭", "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Picker(CaptureLocalization.text("工具", "Tool"), selection: $tool) {
                    ForEach(ImageEditTool.allCases) { tool in Label(tool.title, systemImage: tool.symbol).tag(tool) }
                }.pickerStyle(.menu).frame(width: 180)
                Text(CaptureLocalization.text("选择工具后在画布上操作", "Choose a tool and use it on the canvas")).foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                ColorPicker(CaptureLocalization.text("颜色", "Color"), selection: $color, supportsOpacity: false).frame(width: 100)
                Text(CaptureLocalization.text("粗细", "Width"))
                Slider(value: $width, in: 2...24, step: 1).frame(width: 100).accessibilityLabel(CaptureLocalization.text("画笔粗细", "Stroke width"))
                Text("\(Int(width)) px").monospacedDigit().frame(width: 42)
                Spacer()
                Button { model.undo() } label: { Label(CaptureLocalization.text("撤销", "Undo"), systemImage: "arrow.uturn.backward") }
                    .disabled(model.undoCount == 0).keyboardShortcut("z", modifiers: .command)
                Button { model.redo() } label: { Label(CaptureLocalization.text("重做", "Redo"), systemImage: "arrow.uturn.forward") }
                    .disabled(model.redoCount == 0).keyboardShortcut("z", modifiers: [.command, .shift])
                Button { model.rotate() } label: { Label(CaptureLocalization.text("旋转", "Rotate"), systemImage: "rotate.right") }.disabled(model.image == nil)
            }
            if tool == .text {
                HStack {
                    TextField(CaptureLocalization.text("标注文字（输入后点击图片放置）", "Enter text, then click the image"), text: $annotationText).textFieldStyle(.roundedBorder)
                    Stepper(CaptureLocalization.text("字号", "Size") + " \(Int(textSize))", value: $textSize, in: 12...144, step: 2).frame(width: 130)
                }
            }
            if tool == .number {
                Stepper(CaptureLocalization.text("下一个编号", "Next number") + " \(nextNumber)", value: $nextNumber, in: 1...999)
            }
            if let image = model.image {
                ImageEditingCanvas(image: image, tool: tool, color: NSColor(color), width: width, text: annotationText, textSize: textSize, number: nextNumber) { stroke in
                    model.edit(stroke)
                    if stroke.tool == .number && model.errorMessage == nil { nextNumber = min(999, nextNumber + 1) }
                }
                    .frame(minHeight: 280, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(CaptureLocalization.text("图片编辑画布。裁剪、形状和马赛克通过拖动绘制；文字通过点击放置。", "Image editing canvas. Drag to crop or draw shapes and mosaics; click to place text."))
            } else { ContentUnavailableView(CaptureLocalization.text("图片不可用", "Image unavailable"), systemImage: "photo.badge.exclamationmark") }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                Text(tool == .mosaic ? CaptureLocalization.text("拖动覆盖区域；马赛克可撤销，导出后会写入图片。", "Drag to cover an area. Mosaic edits can be undone and are included in the exported image.") : CaptureLocalization.text("在图片上拖动应用工具，裁剪与标注均可撤销。", "Drag on the image to use the tool. Crops and annotations can be undone."))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(CaptureLocalization.text("另存为…", "Save as…")) { save() }.disabled(model.image == nil)
                Button(CaptureLocalization.text("完成并复制", "Finish and copy")) {
                    do { onExport(try model.export()); dismiss() } catch { model.failure = error }
                }.buttonStyle(.borderedProminent).disabled(model.image == nil).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(minWidth: 740, idealWidth: 940, minHeight: 530, idealHeight: 720)
        .environment(\.locale, appLanguage.locale)
        .onChange(of: tool) { _, _ in savePreferences() }
        .onChange(of: color) { _, _ in savePreferences() }
        .onChange(of: width) { _, _ in savePreferences() }
        .onChange(of: textSize) { _, _ in savePreferences() }
        .onChange(of: nextNumber) { _, _ in savePreferences() }
        .onDisappear { model.clear(); annotationText = "" }
    }
    private func savePreferences() {
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .red
        ImageEditorPreferences(toolRawValue: tool.rawValue, red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, lineWidth: width, textSize: textSize, number: nextNumber).save()
    }
    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.title = CaptureLocalization.text("保存编辑后的图片", "Save edited image")
        panel.prompt = CaptureLocalization.text("保存", "Save")
        panel.nameFieldLabel = CaptureLocalization.text("存储为：", "Save As:")
        panel.nameFieldStringValue = CaptureLocalization.text("Xclip-编辑.png", "Xclip-Edited.png")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.export().write(to: url, options: .atomic) }
        catch { model.failure = error }
    }
}

private struct ImageEditingCanvas: NSViewRepresentable {
    let image: CGImage
    let tool: ImageEditTool
    let color: NSColor
    let width: Double
    let text: String
    let textSize: Double
    let number: Int
    let onStroke: (ImageEditStroke) -> Void
    func makeNSView(context: Context) -> ImageEditingNSView { ImageEditingNSView() }
    func updateNSView(_ view: ImageEditingNSView, context: Context) {
        view.image = image; view.tool = tool; view.strokeColor = color; view.strokeWidth = width; view.annotationText = text; view.textSize = textSize; view.number = number; view.onStroke = onStroke
        view.needsDisplay = true
    }
}

private final class ImageEditingNSView: NSView {
    var image: CGImage?
    var tool: ImageEditTool = .pen
    var strokeColor: NSColor = .red
    var strokeWidth: CGFloat = 4
    var annotationText = ""
    var textSize: CGFloat = 24
    var number = 1
    var onStroke: ((ImageEditStroke) -> Void)?
    private var pending: ImageEditStroke?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var imageRect: CGRect {
        guard let image else { return .zero }
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
    override func resetCursorRects() { addCursorRect(imageRect, cursor: .crosshair) }
    private func imagePoint(_ event: NSEvent, clamped: Bool) -> CGPoint? {
        guard let image else { return nil }
        let location = convert(event.locationInWindow, from: nil), rect = imageRect
        guard clamped || rect.contains(location), rect.width > 0 else { return nil }
        return CGPoint(x: min(CGFloat(image.width), max(0, (location.x - rect.minX) * CGFloat(image.width) / rect.width)),
                       y: min(CGFloat(image.height), max(0, (location.y - rect.minY) * CGFloat(image.height) / rect.height)))
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let rect = imageRect
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            .draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        guard let pending, let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = rect.width / CGFloat(image.width)
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: scale, y: scale)
        if pending.tool == .crop || pending.tool == .mosaic {
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(2 / scale)
            context.setLineDash(phase: 0, lengths: [6 / scale, 4 / scale])
            context.stroke(pending.rect)
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor)
            context.fill(pending.rect)
        } else {
            // Convert the already flipped NSView context back to the image renderer's bottom-left system.
            context.translateBy(x: 0, y: CGFloat(image.height)); context.scaleBy(x: 1, y: -1)
            ImageEditingOperations.draw(pending, in: context, imageHeight: CGFloat(image.height))
        }
        context.restoreGState()
    }
    override func mouseDown(with event: NSEvent) {
        guard let point = imagePoint(event, clamped: false) else { return }
        window?.makeFirstResponder(self)
        pending = ImageEditStroke(tool: tool, points: [point], color: strokeColor, width: strokeWidth, text: annotationText, fontSize: textSize, number: number)
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard var stroke = pending, let point = imagePoint(event, clamped: true) else { return }
        if stroke.tool == .pen || stroke.tool == .highlight { stroke.points.append(point) }
        else if stroke.tool != .text && stroke.tool != .number { stroke.points = [stroke.points[0], point] }
        pending = stroke; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        guard let stroke = pending else { return }
        pending = nil; needsDisplay = true
        if [.crop, .rectangle, .ellipse, .mosaic].contains(stroke.tool), stroke.rect.width < 2 || stroke.rect.height < 2 { return }
        onStroke?(stroke)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { pending = nil; needsDisplay = true } else { super.keyDown(with: event) }
    }
}

@MainActor
final class PinnedImageController: NSObject, NSWindowDelegate {
    static let shared = PinnedImageController()
    private var windows: [NSWindow] = []
    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(languageDidChange), name: AppLanguage.didChange, object: nil)
    }
    @objc private func languageDidChange() {
        windows.forEach { $0.title = CaptureLocalization.text("Xclip 贴图", "Xclip Pinned Image") }
    }
    func closeAll() {
        let existing = windows
        windows.removeAll()
        existing.forEach { $0.close(); $0.contentView = nil }
    }
    func show(_ data: Data) {
        guard let image = NSImage(data: data) else { return }
        let window = NSPanel(contentRect: CGRect(x: 200, y: 200, width: 480, height: 420), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        window.title = CaptureLocalization.text("Xclip 贴图", "Xclip Pinned Image")
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: PinnedImageView(image: image, data: data, setOpacity: { [weak window] value in window?.alphaValue = value }))
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows.removeAll { $0 === window }
    }
}

private struct PinnedImageView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    let image: NSImage
    let data: Data
    let setOpacity: (Double) -> Void
    @State private var opacity = 1.0
    @State private var text = ""
    @State private var recognizing = false
    @State private var recognitionTask: Task<Void, Never>?
    @State private var error: Error?
    var body: some View {
        VStack(spacing: 8) {
            LiveTextImagePreview(data: data, onText: { text = $0 }).frame(maxWidth: .infinity, maxHeight: .infinity)
            if !text.isEmpty { TextEditor(text: $text).frame(height: 100).font(.body) }
            if let error { Text(error.localizedDescription).foregroundStyle(.red).font(.callout) }
            HStack {
                Text(CaptureLocalization.text("透明度", "Opacity"))
                Slider(value: $opacity, in: 0.25...1).onChange(of: opacity) { _, value in setOpacity(value) }
                Button(recognizing ? CaptureLocalization.text("识别中…", "Recognizing…") : CaptureLocalization.text("提取文字", "Extract text")) {
                    recognizing = true; error = nil
                    recognitionTask = Task {
                        defer { recognizing = false; recognitionTask = nil }
                        do {
                            let result = try await CaptureService.shared.recognizeText(in: data)
                            try Task.checkCancellation()
                            text = result
                        }
                        catch is CancellationError { }
                        catch { self.error = error }
                    }
                }.disabled(recognizing)
                Button(CaptureLocalization.text("复制", "Copy")) { CaptureService.shared.copyImage(data) }
            }
        }.padding(12).frame(minWidth: 280, minHeight: 220)
        .environment(\.locale, appLanguage.locale)
        .onDisappear { recognitionTask?.cancel(); recognitionTask = nil; text = ""; error = nil }
    }
}

/// Uses the system's local Live Text interface on an image explicitly provided by the user.
struct LiveTextImagePreview: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    let data: Data
    var onText: (String) -> Void = { _ in }
    @State private var enabled = false
    @State private var status = CaptureMessage("", "")
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(CaptureLocalization.text("实况文字", "Live Text"), isOn: $enabled)
                    .toggleStyle(.switch).controlSize(.small).disabled(!ImageAnalyzer.isSupported)
                if !ImageAnalyzer.isSupported {
                    Text(CaptureLocalization.text("此设备不支持实况文字，可使用识别文字。", "Live Text is unavailable; use Extract text instead.")).font(.caption).foregroundStyle(.secondary)
                } else if enabled {
                    Text(status.text).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            LiveTextImageSurface(data: data, enabled: enabled, onText: onText, onStatus: { status = $0 })
                .frame(minHeight: 140, maxHeight: .infinity)
        }
        .environment(\.locale, appLanguage.locale)
    }
}

private struct LiveTextImageSurface: NSViewRepresentable {
    let data: Data
    let enabled: Bool
    let onText: (String) -> Void
    let onStatus: (CaptureMessage) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> LiveTextImageNSView { LiveTextImageNSView() }
    func updateNSView(_ view: LiveTextImageNSView, context: Context) {
        let coordinator = context.coordinator
        let changed = coordinator.data != data
        if changed { view.image = NSImage(data: data) }
        guard changed || coordinator.enabled != enabled else { return }
        coordinator.data = data; coordinator.enabled = enabled
        coordinator.task?.cancel(); view.overlay.analysis = nil
        view.overlay.preferredInteractionTypes = enabled ? [.textSelection] : []
        guard enabled, ImageAnalyzer.isSupported, let image = view.image else { return }
        coordinator.task = Task { @MainActor [weak view, weak coordinator] in
            onStatus(CaptureMessage("正在本机分析…", "Analyzing locally…"))
            do {
                let analysis = try await ImageAnalyzer().analyze(image, orientation: .up, configuration: .init(.text))
                try Task.checkCancellation()
                guard let view, let coordinator, coordinator.enabled, coordinator.data == data else { return }
                view.overlay.analysis = analysis
                let text = analysis.transcript
                onStatus(text.isEmpty ? CaptureMessage("没有检测到文字。", "No text detected.") : CaptureMessage("在图片上拖动选择文字。", "Drag across text in the image to select it."))
                if !text.isEmpty { onText(text) }
            } catch is CancellationError { }
            catch { onStatus(CaptureMessage("实况文字分析失败，请使用识别文字。", "Live Text failed; use Extract text instead.")) }
        }
    }
    static func dismantleNSView(_ view: LiveTextImageNSView, coordinator: Coordinator) {
        coordinator.task?.cancel(); view.overlay.analysis = nil
    }
    @MainActor final class Coordinator {
        var data: Data?
        var enabled = false
        var task: Task<Void, Never>?
    }
}

private final class LiveTextImageNSView: NSImageView {
    let overlay = ImageAnalysisOverlayView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageScaling = .scaleProportionallyUpOrDown
        imageAlignment = .alignCenter
        isEditable = false
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.trackingImageView = self
        overlay.preferredInteractionTypes = []
        addSubview(overlay)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
