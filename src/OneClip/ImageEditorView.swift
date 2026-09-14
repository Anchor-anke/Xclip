import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VisionKit

enum ImageEditTool: String, CaseIterable, Identifiable {
    case crop = "裁剪", pen = "画笔", highlight = "荧光笔", rectangle = "矩形", ellipse = "椭圆", arrow = "箭头", text = "文字", number = "编号", mosaic = "马赛克"
    case line = "直线", polyline = "折线", blur = "模糊", eraser = "橡皮擦", spotlight = "聚光灯", watermark = "水印", magnify = "放大镜", inpaint = "修复擦除"
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
        case .line: english = "Line"
        case .polyline: english = "Polyline"
        case .blur: english = "Blur"
        case .eraser: english = "Eraser"
        case .spotlight: english = "Spotlight"
        case .watermark: english = "Watermark"
        case .magnify: english = "Magnifier"
        case .inpaint: english = "Repair erase"
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
        case .line: return "line.diagonal"
        case .polyline: return "point.topleft.down.curvedto.point.bottomright.up"
        case .blur: return "drop.halffull"
        case .eraser: return "eraser"
        case .spotlight: return "flashlight.on.fill"
        case .watermark: return "text.badge.checkmark"
        case .magnify: return "plus.magnifyingglass"
        case .inpaint: return "bandage"
        }
    }
    var isPixelEffect: Bool { [.mosaic, .blur, .eraser, .inpaint, .magnify].contains(self) }
}

enum ImageEditLineStyle: String, CaseIterable { case solid = "实线", dashed = "虚线", dotted = "点线" }
enum ImageEditArrowStyle: String, CaseIterable { case filled = "实心箭头", open = "直线箭头", doubleEnded = "双向箭头", hollow = "空心箭头", triangle = "三角箭头" }
enum ImageEditSequenceStyle: String, CaseIterable { case decimal = "数字", alphabetic = "字母", roman = "罗马数字" }
enum ImageEditEffectShape: String, CaseIterable { case rectangle = "矩形", brush = "画笔", ellipse = "椭圆" }
enum ImageEditBlendMode: String, CaseIterable { case normal = "半透明", multiply = "正片叠底" }
enum ImageEditTextWrapMode: String, CaseIterable { case none = "不换行", character = "任意位置", word = "单词边界" }
enum ImageEditWatermarkPlacement: String, CaseIterable { case tiled = "平铺", topLeft = "左上", top = "上中", topRight = "右上", left = "左中", center = "居中", right = "右中", bottomLeft = "左下", bottom = "下中", bottomRight = "右下" }
enum ImageEditConnectorStyle: String, CaseIterable { case line = "线段", dotted = "点线", frame = "框线", none = "无连接线" }
enum ImageEditLineCap: String, CaseIterable { case round = "圆形端点", square = "方形端点" }
enum ImageEditLineJoin: String, CaseIterable { case round = "圆角连接", miter = "尖角连接" }
enum ImageEditArrowHead: String, CaseIterable { case none = "无", open = "开放箭头", filled = "实心箭头", circle = "圆点", square = "方块" }

struct ImageEditStyle {
    var lineStyle: ImageEditLineStyle = .solid
    var filled = false
    var cornerRadius: CGFloat = 0
    var rotation: CGFloat = 0
    var arrowStyle: ImageEditArrowStyle = .filled
    var lineCap: ImageEditLineCap = .round
    var lineJoin: ImageEditLineJoin = .round
    var startHead: ImageEditArrowHead = .none
    var endHead: ImageEditArrowHead = .none
    var fontName: String? = nil
    var bold = false
    var italic = false
    var outlineWidth: CGFloat = 0
    var outlineColor: NSColor = .black
    var backgroundColor: NSColor? = nil
    var backgroundPadding: CGFloat = 4
    var backgroundRadius: CGFloat = 4
    var wrapWidth: CGFloat? = nil
    var wrapMode: ImageEditTextWrapMode = .none
    var sequenceStyle: ImageEditSequenceStyle = .decimal
    var effectShape: ImageEditEffectShape = .rectangle
    var effectStrength: CGFloat? = nil
    var blendMode: ImageEditBlendMode = .normal
    var spotlightOpacity: CGFloat = 0.6
    var showsBorder = true
    var watermarkPlacement: ImageEditWatermarkPlacement = .tiled
    var watermarkSpacing: CGFloat = 40
    var magnifierSourceRect: CGRect? = nil
    var magnification: CGFloat = 2
    var connectorStyle: ImageEditConnectorStyle = .line
    var includesAnnotations = true
    var antialias = true
    var shadow = false
    var arcStart: CGFloat = 0
    var arcSweep: CGFloat = .pi * 2
    var arcInnerRatio: CGFloat = 0
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
    var alpha = 1.0
    var tool: ImageEditTool { ImageEditTool(rawValue: toolRawValue) ?? .pen }
    var color: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    private enum CodingKeys: String, CodingKey { case toolRawValue, red, green, blue, lineWidth, textSize, number, alpha }
    init(toolRawValue: String = ImageEditTool.pen.rawValue, red: Double = 1, green: Double = 0, blue: Double = 0,
         lineWidth: Double = 4, textSize: Double = 24, number: Int = 1, alpha: Double = 1) {
        self.toolRawValue = toolRawValue; self.red = red; self.green = green; self.blue = blue
        self.lineWidth = lineWidth; self.textSize = textSize; self.number = number; self.alpha = alpha
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        toolRawValue = try values.decodeIfPresent(String.self, forKey: .toolRawValue) ?? ImageEditTool.pen.rawValue
        red = try values.decodeIfPresent(Double.self, forKey: .red) ?? 1
        green = try values.decodeIfPresent(Double.self, forKey: .green) ?? 0
        blue = try values.decodeIfPresent(Double.self, forKey: .blue) ?? 0
        lineWidth = try values.decodeIfPresent(Double.self, forKey: .lineWidth) ?? 4
        textSize = try values.decodeIfPresent(Double.self, forKey: .textSize) ?? 24
        number = try values.decodeIfPresent(Int.self, forKey: .number) ?? 1
        alpha = try values.decodeIfPresent(Double.self, forKey: .alpha) ?? 1
    }
    static func load(from defaults: UserDefaults = .standard) -> ImageEditorPreferences {
        guard let data = defaults.data(forKey: key), var value = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        value.red = value.red.isFinite ? min(1, max(0, value.red)) : 1
        value.green = value.green.isFinite ? min(1, max(0, value.green)) : 0
        value.blue = value.blue.isFinite ? min(1, max(0, value.blue)) : 0
        value.alpha = value.alpha.isFinite ? min(1, max(0, value.alpha)) : 1
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
    var style = ImageEditStyle()
    init(tool: ImageEditTool, points: [CGPoint], color: NSColor, width: CGFloat, text: String,
         fontSize: CGFloat? = nil, number: Int = 1, style: ImageEditStyle? = nil) {
        self.tool = tool; self.points = points; self.color = color; self.width = width; self.text = text
        self.fontSize = fontSize; self.number = number
        self.style = style ?? ImageEditStyle()
        if style == nil && tool == .highlight { self.style.effectShape = .brush }
    }
    var rect: CGRect {
        guard let first = points.first, let last = points.last else { return .zero }
        return CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
    }
}

enum ImageEditingOperations {
    struct ArrowGeometry {
        let tail: CGPoint
        let tip: CGPoint
        let base: CGPoint
        let headLeft: CGPoint
        let headRight: CGPoint
        let shaftWidth: CGFloat
    }
    static func arrowGeometry(for stroke: ImageEditStroke) -> ArrowGeometry? {
        guard let first = stroke.points.first, let last = stroke.points.last else { return nil }
        let distance = hypot(last.x - first.x, last.y - first.y)
        guard distance.isFinite, distance > 0 else { return nil }
        let direction = CGPoint(x: (last.x - first.x) / distance, y: (last.y - first.y) / distance)
        let headLength = min(max(14, stroke.width * 4), distance * 0.8)
        let headHalfWidth = min(max(6, stroke.width * 1.8), headLength * 0.6)
        let base = CGPoint(x: last.x - direction.x * headLength, y: last.y - direction.y * headLength)
        return ArrowGeometry(tail: first, tip: last, base: base,
            headLeft: CGPoint(x: base.x - direction.y * headHalfWidth, y: base.y + direction.x * headHalfWidth),
            headRight: CGPoint(x: base.x + direction.y * headHalfWidth, y: base.y - direction.x * headHalfWidth),
            shaftWidth: min(stroke.width, distance * 0.3))
    }

    static func font(for stroke: ImageEditStroke) -> NSFont {
        let size = stroke.fontSize ?? max(14, stroke.width * 5)
        var font = stroke.style.fontName.flatMap { NSFont(name: $0, size: size) } ?? .systemFont(ofSize: size, weight: .medium)
        if stroke.style.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if stroke.style.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }
    static func textAttributes(for stroke: ImageEditStroke) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .left
        switch stroke.style.wrapMode {
        case .none: paragraph.lineBreakMode = .byClipping
        case .character: paragraph.lineBreakMode = .byCharWrapping
        case .word: paragraph.lineBreakMode = .byWordWrapping
        }
        let font = font(for: stroke)
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: stroke.color, .paragraphStyle: paragraph]
        if stroke.style.outlineWidth > 0 {
            attributes[.strokeColor] = stroke.style.outlineColor
            attributes[.strokeWidth] = -100 * stroke.style.outlineWidth / font.pointSize
        }
        if stroke.style.italic, !NSFontManager.shared.traits(of: font).contains(.italicFontMask) { attributes[.obliqueness] = 0.2 }
        return attributes
    }
    static func textContentBounds(for stroke: ImageEditStroke) -> CGRect {
        guard let first = stroke.points.first else { return .zero }
        return withTextLayout(for: stroke) { layout, container in
            var size = layout.usedRect(for: container).size
            if stroke.text.isEmpty { size.height = layout.defaultLineHeight(for: font(for: stroke)) }
            return CGRect(origin: first, size: CGSize(width: ceil(size.width), height: ceil(size.height)))
        }
    }
    /// The unrotated visible text bounds include background padding and glyph outlines.
    static func textBounds(for stroke: ImageEditStroke) -> CGRect {
        let padding = (stroke.style.backgroundColor == nil ? 0 : stroke.style.backgroundPadding) + stroke.style.outlineWidth
        return textContentBounds(for: stroke).insetBy(dx: -padding, dy: -padding)
    }
    private static func withTextLayout<Result>(for stroke: ImageEditStroke,
        _ body: (NSLayoutManager, NSTextContainer) -> Result) -> Result {
        let storage = NSTextStorage(string: String(stroke.text.prefix(500)), attributes: textAttributes(for: stroke))
        let layout = NSLayoutManager(); layout.usesFontLeading = true
        let width = stroke.style.wrapMode == .none ? CGFloat.greatestFiniteMagnitude : max(1, stroke.style.wrapWidth ?? 400)
        let container = NSTextContainer(size: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0; layout.addTextContainer(container); storage.addLayoutManager(layout); layout.ensureLayout(for: container)
        return withExtendedLifetime(storage) { body(layout, container) }
    }
    static func sequenceLabel(_ number: Int, style: ImageEditSequenceStyle) -> String {
        let number = min(999, max(1, number))
        switch style {
        case .decimal: return String(number)
        case .alphabetic:
            var number = number, letters = ""
            while number > 0 { number -= 1; letters = String(UnicodeScalar(65 + number % 26)!) + letters; number /= 26 }
            return letters
        case .roman:
            let values = [(1000,"M"),(900,"CM"),(500,"D"),(400,"CD"),(100,"C"),(90,"XC"),(50,"L"),(40,"XL"),(10,"X"),(9,"IX"),(5,"V"),(4,"IV"),(1,"I")]
            var number = number, result = ""
            for (value, symbol) in values { while number >= value { result += symbol; number -= value } }
            return result
        }
    }
    static func magnifierSourceRect(for stroke: ImageEditStroke) -> CGRect { stroke.style.magnifierSourceRect ?? stroke.rect }
    static func magnifierDestinationRect(for stroke: ImageEditStroke) -> CGRect {
        let source = magnifierSourceRect(for: stroke), scale = min(8, max(1, stroke.style.magnification))
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: stroke.rect.midX - size.width / 2, y: stroke.rect.midY - size.height / 2, width: size.width, height: size.height)
    }
    static func enclosing(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min() ?? first.x, y: ys.min() ?? first.y, width: (xs.max() ?? first.x) - (xs.min() ?? first.x), height: (ys.max() ?? first.y) - (ys.min() ?? first.y))
    }
    static func unrotatedBounds(for stroke: ImageEditStroke) -> CGRect {
        guard let first = stroke.points.first else { return .zero }
        switch stroke.tool {
        case .text: return textBounds(for: stroke)
        case .number:
            let radius = max(13, stroke.width * 3)
            var result = CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2)
            if stroke.points.count > 1 { result = result.union(enclosing(stroke.points).insetBy(dx: -stroke.width * 2, dy: -stroke.width * 2)) }
            if !stroke.text.isEmpty { result = result.union(textBounds(for: caption(for: stroke))) }
            return result
        case .arrow:
            guard let arrow = arrowGeometry(for: stroke) else { return CGRect(origin: first, size: .zero) }
            if stroke.style.arrowStyle == .triangle {
                let dx = arrow.tip.x - arrow.tail.x, dy = arrow.tip.y - arrow.tail.y, length = hypot(dx, dy)
                let half = min(max(4, stroke.width * 1.6), length * 0.25)
                return enclosing([arrow.tip, CGPoint(x: arrow.tail.x - dy / length * half, y: arrow.tail.y + dx / length * half),
                    CGPoint(x: arrow.tail.x + dy / length * half, y: arrow.tail.y - dx / length * half)])
            }
            var result = enclosing([arrow.tail, arrow.base]).insetBy(dx: -arrow.shaftWidth / 2, dy: -arrow.shaftWidth / 2)
            result = result.union(enclosing([arrow.tip, arrow.headLeft, arrow.headRight]).insetBy(dx: stroke.style.arrowStyle == .open || stroke.style.arrowStyle == .hollow ? -stroke.width / 2 : 0, dy: stroke.style.arrowStyle == .open || stroke.style.arrowStyle == .hollow ? -stroke.width / 2 : 0))
            if stroke.style.arrowStyle == .doubleEnded {
                var reversed = stroke; reversed.points.reverse()
                if let start = arrowGeometry(for: reversed) { result = result.union(enclosing([start.tip, start.headLeft, start.headRight])) }
            }
            if !stroke.text.isEmpty { result = result.union(textBounds(for: caption(for: stroke))) }
            return result
        case .rectangle, .ellipse:
            return stroke.rect.insetBy(dx: stroke.style.filled ? 0 : -stroke.width / 2, dy: stroke.style.filled ? 0 : -stroke.width / 2)
        case .magnify: return magnifierDestinationRect(for: stroke).insetBy(dx: -stroke.width / 2, dy: -stroke.width / 2)
        case .mosaic, .blur, .eraser, .inpaint, .spotlight:
            return stroke.style.effectShape == .brush ? enclosing(stroke.points).insetBy(dx: -stroke.width / 2, dy: -stroke.width / 2) : stroke.rect
        case .pen, .highlight, .line, .polyline:
            let width = stroke.tool == .highlight ? max(12, stroke.width * 4) : stroke.width
            if stroke.tool == .highlight, stroke.style.effectShape != .brush { return stroke.rect }
            let headPadding = stroke.style.startHead != .none || stroke.style.endHead != .none ? max(14, width * 4) : width / 2
            return enclosing(stroke.points).insetBy(dx: -headPadding, dy: -headPadding)
        case .watermark, .crop: return stroke.rect
        }
    }
    static func rotationTransform(for stroke: ImageEditStroke) -> CGAffineTransform {
        let rect = unrotatedBounds(for: stroke)
        return CGAffineTransform(translationX: rect.midX, y: rect.midY).rotated(by: stroke.style.rotation).translatedBy(x: -rect.midX, y: -rect.midY)
    }
    static func shapePath(for stroke: ImageEditStroke) -> CGPath {
        let path = CGMutablePath(), rect = stroke.rect
        if stroke.tool == .rectangle {
            let radius = min(max(0, stroke.style.cornerRadius), min(rect.width, rect.height) / 2)
            path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
        } else {
            let sweep = min(.pi * 2, max(-.pi * 2, stroke.style.arcSweep))
            if abs(sweep) >= .pi * 2 - 0.0001 && stroke.style.arcInnerRatio <= 0 { path.addEllipse(in: rect) }
            else {
                let steps = max(2, Int(abs(sweep) * 30)), center = CGPoint(x: rect.midX, y: rect.midY)
                let outer = (0...steps).map { i -> CGPoint in
                    let angle = stroke.style.arcStart + sweep * CGFloat(i) / CGFloat(steps)
                    return CGPoint(x: center.x + cos(angle) * rect.width / 2, y: center.y + sin(angle) * rect.height / 2)
                }
                path.addLines(between: outer)
                let inner = min(0.99, max(0, stroke.style.arcInnerRatio))
                if inner > 0 {
                    path.addLines(between: outer.reversed().map { CGPoint(x: center.x + ($0.x - center.x) * inner, y: center.y + ($0.y - center.y) * inner) })
                } else { path.addLine(to: center) }
                path.closeSubpath()
            }
        }
        return path
    }
    static func effectPath(for stroke: ImageEditStroke) -> CGPath {
        let path = CGMutablePath()
        switch stroke.style.effectShape {
        case .rectangle:
            let radius = min(max(0, stroke.style.cornerRadius), min(stroke.rect.width, stroke.rect.height) / 2)
            path.addRoundedRect(in: stroke.rect, cornerWidth: radius, cornerHeight: radius)
        case .ellipse: path.addEllipse(in: stroke.rect)
        case .brush:
            if stroke.points.count == 1, let point = stroke.points.first { path.addEllipse(in: CGRect(x: point.x - stroke.width / 2, y: point.y - stroke.width / 2, width: stroke.width, height: stroke.width)) }
            else { path.addLines(between: stroke.points); return path.copy(strokingWithWidth: stroke.width, lineCap: .round, lineJoin: .round, miterLimit: 10) }
        }
        return path
    }
    static func validate(_ stroke: ImageEditStroke) throws {
        let style = stroke.style
        let values = [stroke.width, stroke.fontSize ?? 24, style.cornerRadius, style.rotation, style.outlineWidth, style.backgroundPadding,
                      style.backgroundRadius, style.wrapWidth ?? 400, style.effectStrength ?? stroke.width, style.spotlightOpacity,
                      style.watermarkSpacing, style.magnification, style.arcStart, style.arcSweep, style.arcInnerRatio]
        guard !stroke.points.isEmpty, stroke.points.count <= 100_000, stroke.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1_000_000 && abs($0.y) <= 1_000_000 }),
              values.allSatisfy({ $0.isFinite }), stroke.width > 0, stroke.width <= 2_048,
              stroke.fontSize.map({ $0 > 0 && $0 <= 2_048 }) ?? true,
              style.cornerRadius >= 0, style.cornerRadius <= 100_000, style.outlineWidth >= 0, style.outlineWidth <= 256,
              style.backgroundPadding >= 0, style.backgroundPadding <= 1_024, style.backgroundRadius >= 0,
              style.wrapWidth.map({ $0 > 0 && $0 <= 100_000 }) ?? true,
              style.effectStrength.map({ $0 > 0 && $0 <= 256 }) ?? true,
              (0...1).contains(style.spotlightOpacity), style.watermarkSpacing >= 0, style.watermarkSpacing <= 10_000,
              (1...8).contains(style.magnification), (0...0.99).contains(style.arcInnerRatio) else {
            throw CaptureMessage("标注样式或坐标超出范围，请调整后重试。", "Annotation style or coordinates are out of range.")
        }
        if let rect = style.magnifierSourceRect, (!rect.minX.isFinite || !rect.minY.isFinite || !rect.maxX.isFinite || !rect.maxY.isFinite || rect.width <= 0 || rect.height <= 0) {
            throw CaptureMessage("放大源区域无效。", "The magnifier source area is invalid.")
        }
    }

    static func render(_ strokes: [ImageEditStroke], source: CGImage) throws -> CGImage {
        guard !strokes.isEmpty else { return source }
        let context = try CaptureImageCodec.context(width: source.width, height: source.height)
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        context.draw(source, in: bounds)
        for stroke in strokes {
            try validate(stroke)
            if stroke.tool.isPixelEffect {
                guard let current = context.makeImage() else { throw CaptureToolError.invalidImage }
                let next = try apply(stroke, to: current, source: source)
                context.clear(bounds); context.draw(next, in: bounds)
            } else { draw(stroke, in: context, imageHeight: CGFloat(source.height), imageWidth: CGFloat(source.width)) }
        }
        guard let result = context.makeImage() else { throw CaptureToolError.invalidImage }
        return result
    }

    static func apply(_ stroke: ImageEditStroke, to image: CGImage, source: CGImage? = nil) throws -> CGImage {
        try validate(stroke)
        if stroke.tool == .crop { return try CaptureImageCodec.crop(image, rect: stroke.rect) }
        let context = try CaptureImageCodec.context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if [.mosaic, .blur, .eraser, .inpaint].contains(stroke.tool) {
            try applyPixelEffect(stroke, context: context, image: image, source: source)
        } else if stroke.tool == .magnify {
            try drawMagnifier(stroke, in: context, image: image, source: source)
        } else { draw(stroke, in: context, imageHeight: CGFloat(image.height), imageWidth: CGFloat(image.width)) }
        guard let result = context.makeImage() else { throw CaptureToolError.invalidImage }
        return result
    }

    static func draw(_ stroke: ImageEditStroke, in context: CGContext, imageHeight: CGFloat, imageWidth: CGFloat? = nil) {
        guard let first = stroke.points.first else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.translateBy(x: 0, y: imageHeight); context.scaleBy(x: 1, y: -1)
        if stroke.tool != .watermark && stroke.tool != .spotlight { context.concatenate(rotationTransform(for: stroke)) }
        context.setStrokeColor(stroke.color.cgColor); context.setFillColor(stroke.color.cgColor)
        context.setLineWidth(stroke.width)
        context.setLineCap(stroke.style.lineCap == .round ? .round : .square)
        context.setLineJoin(stroke.style.lineJoin == .round ? .round : .miter)
        setLineStyle(stroke.style.lineStyle, width: stroke.width, in: context)
        switch stroke.tool {
        case .text: drawText(stroke, in: context)
        case .number:
            let radius = max(13, stroke.width * 3)
            if stroke.points.count > 1 { var arrow = stroke; arrow.tool = .arrow; arrow.text = ""; drawArrow(arrow, in: context) }
            context.fillEllipse(in: CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2))
            var label = stroke; label.tool = .text; label.style.rotation = 0; label.style.backgroundColor = nil
            let rgb = stroke.color.usingColorSpace(.sRGB) ?? .red
            label.color = rgb.redComponent * 0.2126 + rgb.greenComponent * 0.7152 + rgb.blueComponent * 0.0722 > 0.55 ? .black : .white
            label.text = sequenceLabel(stroke.number, style: stroke.style.sequenceStyle)
            label.fontSize = min(radius, radius * 3 / CGFloat(max(2, label.text.count))); label.style.bold = true
            label.points = [.zero]
            let size = textContentBounds(for: label).size
            label.points = [CGPoint(x: first.x - size.width / 2, y: first.y - size.height / 2)]
            drawText(label, in: context)
            if !stroke.text.isEmpty { drawText(caption(for: stroke), in: context) }
        case .pen, .highlight, .line, .polyline:
            if stroke.tool == .highlight {
                let color = stroke.color.withAlphaComponent(stroke.color.alphaComponent * (stroke.style.blendMode == .normal ? 0.3 : 1))
                context.setStrokeColor(color.cgColor); context.setFillColor(color.cgColor)
                context.setBlendMode(stroke.style.blendMode == .multiply ? .multiply : .normal)
                if stroke.style.effectShape != .brush { context.addPath(effectPath(for: stroke)); context.fillPath(); return }
                context.setLineWidth(max(12, stroke.width * 4)); context.setLineCap(.square)
            }
            if stroke.points.count == 1 {
                let diameter = stroke.tool == .highlight ? max(12, stroke.width * 4) : stroke.width
                context.fillEllipse(in: CGRect(x: first.x - diameter / 2, y: first.y - diameter / 2, width: diameter, height: diameter))
            } else {
                context.addLines(between: stroke.points); context.strokePath()
                if [.line, .polyline].contains(stroke.tool) {
                    drawEndpoint(stroke.style.startHead, at: stroke.points[0], from: stroke.points[1], stroke: stroke, in: context)
                    drawEndpoint(stroke.style.endHead, at: stroke.points.last!, from: stroke.points[stroke.points.count - 2], stroke: stroke, in: context)
                }
            }
        case .rectangle, .ellipse:
            context.addPath(shapePath(for: stroke)); stroke.style.filled ? context.fillPath() : context.strokePath()
        case .arrow:
            drawArrow(stroke, in: context)
            if !stroke.text.isEmpty { drawText(caption(for: stroke), in: context) }
        case .spotlight:
            let bounds = CGRect(x: 0, y: 0, width: imageWidth ?? CGFloat(context.width), height: imageHeight)
            var transform = rotationTransform(for: stroke)
            let hole = effectPath(for: stroke).copy(using: &transform) ?? effectPath(for: stroke)
            context.saveGState(); context.addRect(bounds); context.addPath(hole); context.clip(using: .evenOdd)
            context.setFillColor(NSColor.black.withAlphaComponent(stroke.style.spotlightOpacity).cgColor); context.fill(bounds); context.restoreGState()
            if stroke.style.showsBorder { context.addPath(hole); context.strokePath() }
        case .watermark: drawWatermark(stroke, in: context, bounds: CGRect(x: 0, y: 0, width: imageWidth ?? CGFloat(context.width), height: imageHeight))
        case .crop, .mosaic, .blur, .eraser, .magnify, .inpaint: break
        }
    }
    private static func setLineStyle(_ style: ImageEditLineStyle, width: CGFloat, in context: CGContext) {
        switch style {
        case .solid: context.setLineDash(phase: 0, lengths: [])
        case .dashed: context.setLineDash(phase: 0, lengths: [max(4, width * 3), max(3, width * 2)])
        case .dotted: context.setLineDash(phase: 0, lengths: [max(1, width * 0.2), max(3, width * 2)])
        }
    }
    private static func drawText(_ stroke: ImageEditStroke, in context: CGContext) {
        guard let first = stroke.points.first else { return }
        if let background = stroke.style.backgroundColor {
            let rect = textContentBounds(for: stroke).insetBy(dx: -stroke.style.backgroundPadding, dy: -stroke.style.backgroundPadding)
            let radius = min(stroke.style.backgroundRadius, min(rect.width, rect.height) / 2)
            context.setFillColor(background.cgColor); context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)); context.fillPath()
        }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        withTextLayout(for: stroke) { layout, container in layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: first) }
    }
    private static func caption(for stroke: ImageEditStroke) -> ImageEditStroke {
        var text = stroke; text.tool = .text; text.style.rotation = 0
        let anchor = stroke.points.first ?? .zero
        let offset = stroke.tool == .number ? max(13, stroke.width * 3) + 8 : 8
        text.points = [CGPoint(x: anchor.x + offset, y: anchor.y + offset)]
        return text
    }
    private static func drawArrow(_ stroke: ImageEditStroke, in context: CGContext) {
        guard let arrow = arrowGeometry(for: stroke) else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.setLineWidth(arrow.shaftWidth)
        if stroke.style.arrowStyle == .triangle {
            let dx = arrow.tip.x - arrow.tail.x, dy = arrow.tip.y - arrow.tail.y, length = hypot(dx, dy)
            let half = min(max(4, stroke.width * 1.6), length * 0.25)
            context.move(to: arrow.tip); context.addLine(to: CGPoint(x: arrow.tail.x - dy / length * half, y: arrow.tail.y + dx / length * half))
            context.addLine(to: CGPoint(x: arrow.tail.x + dy / length * half, y: arrow.tail.y - dx / length * half)); context.closePath(); context.fillPath(); return
        }
        context.move(to: arrow.tail); context.addLine(to: stroke.style.arrowStyle == .open ? arrow.tip : arrow.base); context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
        func head(_ arrow: ArrowGeometry) {
            context.move(to: arrow.headLeft); context.addLine(to: arrow.tip); context.addLine(to: arrow.headRight)
            if stroke.style.arrowStyle != .open { context.closePath() }
            if stroke.style.arrowStyle == .open || stroke.style.arrowStyle == .hollow { context.strokePath() } else { context.fillPath() }
        }
        head(arrow)
        if stroke.style.arrowStyle == .doubleEnded { var reverse = stroke; reverse.points.reverse(); if let backward = arrowGeometry(for: reverse) { head(backward) } }
    }
    private static func drawEndpoint(_ head: ImageEditArrowHead, at point: CGPoint, from previous: CGPoint, stroke: ImageEditStroke, in context: CGContext) {
        guard head != .none else { return }
        context.saveGState(); defer { context.restoreGState() }; context.setLineDash(phase: 0, lengths: [])
        let radius = max(3, stroke.width * 1.5)
        if head == .circle { context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)); return }
        if head == .square { context.fill(CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)); return }
        var arrow = stroke; arrow.points = [previous, point]; arrow.style.arrowStyle = head == .open ? .open : .filled
        guard let geometry = arrowGeometry(for: arrow) else { return }
        context.move(to: geometry.headLeft); context.addLine(to: point); context.addLine(to: geometry.headRight)
        if head == .filled { context.closePath(); context.fillPath() } else { context.strokePath() }
    }
    private static func drawWatermark(_ stroke: ImageEditStroke, in context: CGContext, bounds: CGRect) {
        let area = stroke.rect.width > 0 && stroke.rect.height > 0 ? stroke.rect.intersection(bounds) : bounds
        guard !area.isNull, !stroke.text.isEmpty else { return }
        var text = stroke; text.tool = .text; text.points = [.zero]
        let size = textBounds(for: text).size
        guard size.width > 0, size.height > 0 else { return }
        context.saveGState(); defer { context.restoreGState() }; context.clip(to: area)
        func stamp(at origin: CGPoint) {
            context.saveGState(); context.translateBy(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
            context.rotate(by: stroke.style.rotation); text.points = [CGPoint(x: -size.width / 2, y: -size.height / 2)]
            drawText(text, in: context); context.restoreGState()
        }
        let margin: CGFloat = 12
        if stroke.style.watermarkPlacement == .tiled {
            let spacing = max(8, stroke.style.watermarkSpacing), stepX = size.width + spacing, stepY = size.height + spacing
            var count = 0, row = 0
            for y in stride(from: area.minY + spacing / 2, to: area.maxY + size.height, by: stepY) {
                for x in stride(from: area.minX - (row % 2 == 1 ? stepX / 2 : 0), to: area.maxX + size.width, by: stepX) {
                    stamp(at: CGPoint(x: x, y: y)); count += 1; if count >= 10_000 { return }
                }
                row += 1
            }
        } else {
            let placement = stroke.style.watermarkPlacement
            let x = [.topLeft,.left,.bottomLeft].contains(placement) ? area.minX + margin : [.topRight,.right,.bottomRight].contains(placement) ? area.maxX - size.width - margin : area.midX - size.width / 2
            let y = [.topLeft,.top,.topRight].contains(placement) ? area.minY + margin : [.bottomLeft,.bottom,.bottomRight].contains(placement) ? area.maxY - size.height - margin : area.midY - size.height / 2
            stamp(at: CGPoint(x: max(area.minX, x), y: max(area.minY, y)))
        }
    }
    private static func drawMagnifier(_ stroke: ImageEditStroke, in context: CGContext, image: CGImage, source: CGImage?) throws {
        let input = stroke.style.includesAnnotations ? image : source ?? image
        let sourceRect = magnifierSourceRect(for: stroke).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard sourceRect.width >= 1, sourceRect.height >= 1, let crop = input.cropping(to: sourceRect) else { throw CaptureToolError.invalidImage }
        let destination = magnifierDestinationRect(for: stroke)
        context.saveGState(); defer { context.restoreGState() }
        context.translateBy(x: 0, y: CGFloat(image.height)); context.scaleBy(x: 1, y: -1)
        context.concatenate(rotationTransform(for: stroke)); context.setStrokeColor(stroke.color.cgColor); context.setLineWidth(stroke.width)
        if !destination.intersects(sourceRect), stroke.style.connectorStyle != .none {
            if stroke.style.connectorStyle == .dotted { context.setLineDash(phase: 0, lengths: [2, 4]) }
            let start = CGPoint(x: sourceRect.midX, y: sourceRect.midY), end = CGPoint(x: destination.midX, y: destination.midY)
            context.move(to: start); context.addLine(to: end); context.strokePath(); context.setLineDash(phase: 0, lengths: [])
            if stroke.style.connectorStyle == .frame { context.stroke(sourceRect) }
        }
        let path = stroke.style.effectShape == .ellipse ? CGPath(ellipseIn: destination, transform: nil) : CGPath(roundedRect: destination, cornerWidth: stroke.style.cornerRadius, cornerHeight: stroke.style.cornerRadius, transform: nil)
        if stroke.style.shadow {
            context.saveGState(); context.setShadow(offset: CGSize(width: 2, height: 3), blur: 8, color: NSColor.black.withAlphaComponent(0.4).cgColor)
            context.setFillColor(NSColor.white.cgColor); context.addPath(path); context.fillPath(); context.restoreGState()
        }
        context.saveGState(); context.addPath(path); context.clip()
        context.interpolationQuality = stroke.style.antialias ? .high : .none
        context.translateBy(x: destination.minX, y: destination.maxY); context.scaleBy(x: 1, y: -1)
        context.draw(crop, in: CGRect(origin: .zero, size: destination.size)); context.restoreGState()
        if stroke.style.showsBorder { context.addPath(path); context.strokePath() }
    }

    private static func applyPixelEffect(_ stroke: ImageEditStroke, context: CGContext, image: CGImage, source: CGImage?) throws {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let transform = rotationTransform(for: stroke)
        let affected = unrotatedBounds(for: stroke).applying(transform).intersection(imageBounds).integral
        guard affected.width >= 1, affected.height >= 1 else { return }
        let width = Int(affected.width), height = Int(affected.height)
        guard let maskContext = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let maskBytes = maskContext.data?.assumingMemoryBound(to: UInt8.self), let destination = context.data?.assumingMemoryBound(to: UInt8.self) else { throw CaptureToolError.invalidImage }
        maskContext.translateBy(x: -affected.minX, y: affected.maxY); maskContext.scaleBy(x: 1, y: -1)
        maskContext.concatenate(transform); maskContext.addPath(effectPath(for: stroke)); maskContext.setFillColor(gray: 1, alpha: 1); maskContext.fillPath()
        let mask = Array(UnsafeBufferPointer(start: maskBytes, count: width * height))
        let minX = Int(affected.minX), minY = Int(affected.minY), maxX = minX + width, maxY = minY + height
        let strength = stroke.style.effectStrength ?? stroke.width
        if stroke.tool == .mosaic {
            let block = Int(max(8, min(768, strength * 3)))
            for y in stride(from: minY, to: maxY, by: block) {
                for x in stride(from: minX, to: maxX, by: block) {
                    let endX = min(maxX, x + block), endY = min(maxY, y + block)
                    var sums = [Int](repeating: 0, count: 4)
                    for row in y..<endY { for column in x..<endX { let offset = (row * image.width + column) * 4; for c in 0..<4 { sums[c] += Int(destination[offset + c]) } } }
                    let count = (endX - x) * (endY - y), average = sums.map { UInt8($0 / count) }
                    for row in y..<endY { for column in x..<endX {
                        let amount = Int(mask[(row - minY) * width + column - minX]), offset = (row * image.width + column) * 4
                        for c in 0..<4 { destination[offset + c] = UInt8((Int(destination[offset + c]) * (255 - amount) + Int(average[c]) * amount + 127) / 255) }
                    } }
                }
            }
            return
        }
        if stroke.tool == .eraser {
            guard let source, source.width == image.width, source.height == image.height else {
                throw CaptureMessage("橡皮擦需要这张图的原始图像，请重新打开标注。", "Eraser needs the original image. Reopen annotation.")
            }
            let base = try CaptureImageCodec.context(width: source.width, height: source.height); base.draw(source, in: imageBounds)
            guard let bytes = base.data?.assumingMemoryBound(to: UInt8.self) else { throw CaptureToolError.invalidImage }
            for row in 0..<height { for column in 0..<width {
                let amount = Int(mask[row * width + column]), offset = ((row + minY) * image.width + column + minX) * 4
                for c in 0..<4 { destination[offset + c] = UInt8((Int(destination[offset + c]) * (255 - amount) + Int(bytes[offset + c]) * amount + 127) / 255) }
            } }
            return
        }
        let radius = stroke.tool == .blur ? min(96, max(1, Int(strength))) : 2
        let expanded = affected.insetBy(dx: -CGFloat(radius * 3), dy: -CGFloat(radius * 3)).intersection(imageBounds).integral
        guard let cropped = image.cropping(to: expanded) else { throw CaptureToolError.invalidImage }
        let scratch = try CaptureImageCodec.context(width: cropped.width, height: cropped.height)
        scratch.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        guard let scratchData = scratch.data?.assumingMemoryBound(to: UInt8.self) else { throw CaptureToolError.invalidImage }
        var filtered = Array(UnsafeBufferPointer(start: scratchData, count: cropped.width * cropped.height * 4))
        if stroke.tool == .blur {
            for _ in 0..<3 { filtered = boxBlur(filtered, width: cropped.width, height: cropped.height, radius: radius) }
        } else {
            guard width * height <= 1_000_000 else {
                throw CaptureMessage("修复区域过大，请分成较小区域处理。", "The repair area is too large. Repair smaller areas separately.")
            }
            var localMask = [UInt8](repeating: 0, count: cropped.width * cropped.height)
            for row in 0..<height { for column in 0..<width { localMask[(row + minY - Int(expanded.minY)) * cropped.width + column + minX - Int(expanded.minX)] = mask[row * width + column] } }
            filtered = try inpaint(filtered, mask: localMask, width: cropped.width, height: cropped.height)
        }
        for row in 0..<height { for column in 0..<width {
            let amount = Int(mask[row * width + column]), output = ((row + minY) * image.width + column + minX) * 4
            let input = ((row + minY - Int(expanded.minY)) * cropped.width + column + minX - Int(expanded.minX)) * 4
            for c in 0..<4 { destination[output + c] = UInt8((Int(destination[output + c]) * (255 - amount) + Int(filtered[input + c]) * amount + 127) / 255) }
        } }
    }
    private static func boxBlur(_ bytes: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        var horizontal = [UInt8](repeating: 0, count: bytes.count), result = horizontal
        for y in 0..<height {
            var sum = [Int](repeating: 0, count: 4)
            for x in -radius...radius { let at = (y * width + min(width - 1, max(0, x))) * 4; for c in 0..<4 { sum[c] += Int(bytes[at + c]) } }
            for x in 0..<width {
                let at = (y * width + x) * 4; for c in 0..<4 { horizontal[at + c] = UInt8(sum[c] / (radius * 2 + 1)) }
                let remove = (y * width + max(0, x - radius)) * 4, add = (y * width + min(width - 1, x + radius + 1)) * 4
                for c in 0..<4 { sum[c] += Int(bytes[add + c]) - Int(bytes[remove + c]) }
            }
        }
        for x in 0..<width {
            var sum = [Int](repeating: 0, count: 4)
            for y in -radius...radius { let at = (min(height - 1, max(0, y)) * width + x) * 4; for c in 0..<4 { sum[c] += Int(horizontal[at + c]) } }
            for y in 0..<height {
                let at = (y * width + x) * 4; for c in 0..<4 { result[at + c] = UInt8(sum[c] / (radius * 2 + 1)) }
                let remove = (max(0, y - radius) * width + x) * 4, add = (min(height - 1, y + radius + 1) * width + x) * 4
                for c in 0..<4 { sum[c] += Int(horizontal[add + c]) - Int(horizontal[remove + c]) }
            }
        }
        return result
    }
    /// Deterministic boundary diffusion, not a learned or semantic inpainting model.
    /// Propagates neighbouring texture/colour inward, then solves a local harmonic interpolation.
    private static func inpaint(_ bytes: [UInt8], mask: [UInt8], width: Int, height: Int) throws -> [UInt8] {
        var result = bytes, known = mask.map { $0 == 0 }, queue: [Int] = [], masked: [Int] = []
        func neighbours(_ index: Int) -> [Int] {
            let x = index % width, y = index / width
            return [x > 0 ? index - 1 : -1, x + 1 < width ? index + 1 : -1, y > 0 ? index - width : -1, y + 1 < height ? index + width : -1].filter { $0 >= 0 }
        }
        for index in mask.indices where mask[index] > 0 {
            masked.append(index)
            if neighbours(index).contains(where: { known[$0] }) { queue.append(index) }
        }
        guard !queue.isEmpty else { throw CaptureMessage("修复区域缺少可参考的周围像素，请缩小选区。", "Repair needs surrounding pixels. Reduce the selected area.") }
        var queued = [Bool](repeating: false, count: mask.count); queue.forEach { queued[$0] = true }
        var cursor = 0
        while cursor < queue.count {
            let index = queue[cursor]; cursor += 1
            let adjacent = neighbours(index).filter { known[$0] }
            if !adjacent.isEmpty { for c in 0..<4 { result[index * 4 + c] = UInt8(adjacent.reduce(0) { $0 + Int(result[$1 * 4 + c]) } / adjacent.count) }; known[index] = true }
            for next in neighbours(index) where !known[next] && !queued[next] { queued[next] = true; queue.append(next) }
        }
        for _ in 0..<24 {
            var next = result
            for index in masked {
                let x = index % width, y = index / width
                let left = (x > 0 ? index - 1 : index) * 4, right = (x + 1 < width ? index + 1 : index) * 4
                let up = (y > 0 ? index - width : index) * 4, down = (y + 1 < height ? index + width : index) * 4
                let offset = index * 4
                for c in 0..<4 { next[offset + c] = UInt8((Int(result[left + c]) + Int(result[right + c]) + Int(result[up + c]) + Int(result[down + c])) / 4) }
            }
            result = next
        }
        return result
    }
}

@MainActor
private final class EditorCheckpoint {
    private(set) var image: CGImage?
    private var file: URL?
    init(_ image: CGImage) { self.image = image }
    var bytes: Int { image.map { $0.bytesPerRow * $0.height } ?? 0 }
    func read() throws -> CGImage {
        if let image { return image }
        guard let file else { throw CaptureToolError.invalidImage }
        // Loaded checkpoints are owned by the current model, not cached indefinitely here.
        return try CaptureImageCodec.decode(Data(contentsOf: file, options: .mappedIfSafe))
    }
    func spill() throws {
        guard let image else { return }
        if file == nil {
            let directory = try SessionTemporaryFiles.create(prefix: "xclip-edit-")
            let target = directory.appendingPathComponent("checkpoint.png")
            do { try CaptureImageCodec.png(image).write(to: target, options: .atomic); file = target }
            catch { try? FileManager.default.removeItem(at: directory); throw error }
        }
        self.image = nil
    }
    deinit { if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) } }
}

@MainActor
final class ImageEditorModel: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published var failure: Error?
    var errorMessage: String? { failure?.localizedDescription }
    @Published private(set) var undoCount = 0
    @Published private(set) var redoCount = 0
    private struct Frame { let image: EditorCheckpoint; let source: EditorCheckpoint }
    private var undoFrames: [Frame] = [], redoFrames: [Frame] = []
    private var immutableSource: CGImage?
    private let allowsDiskHistory: () -> Bool
    let historyBudget: Int
    init(data: Data, allowsDiskHistory: Bool = false, historyBudget: Int = 128 * 1024 * 1024, diskPermission: (() -> Bool)? = nil) {
        self.allowsDiskHistory = diskPermission ?? { allowsDiskHistory }; self.historyBudget = max(0, historyBudget)
        do { image = try CaptureImageCodec.decode(data); immutableSource = image } catch { failure = error }
    }
    private func checkpoint(_ image: CGImage) -> EditorCheckpoint {
        for frame in undoFrames + redoFrames {
            if frame.image.image === image { return frame.image }
            if frame.source.image === image { return frame.source }
        }
        return EditorCheckpoint(image)
    }
    private func currentFrame() -> Frame? {
        guard let image, let immutableSource else { return nil }
        let value = checkpoint(image)
        return Frame(image: value, source: image === immutableSource ? value : checkpoint(immutableSource))
    }
    var historyResidentBytes: Int {
        var seen = Set<ObjectIdentifier>()
        return (undoFrames + redoFrames).flatMap { [$0.image, $0.source] }.reduce(0) { sum, checkpoint in
            guard let candidate = checkpoint.image, candidate !== image, candidate !== immutableSource,
                  seen.insert(ObjectIdentifier(candidate)).inserted else { return sum }
            return sum + checkpoint.bytes
        }
    }
    func edit(_ stroke: ImageEditStroke) {
        guard let image else { return }
        if [.text, .watermark].contains(stroke.tool) && stroke.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            failure = CaptureMessage("请先输入标注文字，再点击图片放置。", "Enter annotation text, then click the image to place it."); return
        }
        do {
            let result = try ImageEditingOperations.apply(stroke, to: image, source: immutableSource)
            let source = stroke.tool == .crop ? try immutableSource.map { try ImageEditingOperations.apply(stroke, to: $0) } : immutableSource
            commit(result, source: source)
        } catch { failure = error }
    }
    func clear() {
        image = nil; immutableSource = nil; undoFrames.removeAll(); redoFrames.removeAll(); failure = nil; updateCounts()
    }
    func rotate() {
        guard let image else { return }
        do { commit(try CaptureImageCodec.rotateClockwise(image), source: try immutableSource.map(CaptureImageCodec.rotateClockwise)) } catch { failure = error }
    }
    private func commit(_ result: CGImage, source: CGImage?) {
        if let frame = currentFrame() { undoFrames.append(frame) }
        redoFrames.removeAll(); immutableSource = source; image = result; failure = nil
        trimHistory(); updateCounts()
    }
    private func trimHistory() {
        while undoFrames.count > 20 { undoFrames.removeFirst() }
        if allowsDiskHistory() {
            do {
                for checkpoint in (undoFrames + redoFrames).flatMap({ [$0.image, $0.source] }) where historyResidentBytes > historyBudget {
                    if checkpoint.image !== image && checkpoint.image !== immutableSource { try checkpoint.spill() }
                }
            } catch { failure = error }
        }
        // No disk writes in memory-only mode, including on a spill failure.
        while historyResidentBytes > historyBudget {
            if !undoFrames.isEmpty { undoFrames.removeFirst() }
            else if !redoFrames.isEmpty { redoFrames.removeFirst() }
            else { break }
        }
    }
    func undo() {
        guard let previous = undoFrames.last else { return }
        do {
            let restored = try previous.image.read(), source = try previous.source === previous.image ? restored : previous.source.read()
            if let current = currentFrame() { redoFrames.append(current) }
            undoFrames.removeLast(); image = restored; immutableSource = source; failure = nil
            trimHistory(); updateCounts()
        } catch { failure = error }
    }
    func redo() {
        guard let next = redoFrames.last else { return }
        do {
            let restored = try next.image.read(), source = try next.source === next.image ? restored : next.source.read()
            if let current = currentFrame() { undoFrames.append(current) }
            redoFrames.removeLast(); image = restored; immutableSource = source; failure = nil
            trimHistory(); updateCounts()
        } catch { failure = error }
    }
    private func updateCounts() { undoCount = undoFrames.count; redoCount = redoFrames.count }
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
    init(imageData: Data, allowsDiskHistory: @escaping () -> Bool = { false }, onExport: @escaping (Data) -> Void) {
        _model = StateObject(wrappedValue: ImageEditorModel(data: imageData, diskPermission: allowsDiskHistory))
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
                ColorPicker(CaptureLocalization.text("颜色", "Color"), selection: $color, supportsOpacity: true).frame(width: 100)
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
            if tool == .text || tool == .watermark {
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
        ImageEditorPreferences(toolRawValue: tool.rawValue, red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, lineWidth: width, textSize: textSize, number: nextNumber, alpha: rgb.alphaComponent).save()
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
        if pending.tool == .crop || pending.tool.isPixelEffect {
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
