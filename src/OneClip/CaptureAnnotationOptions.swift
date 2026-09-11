import AppKit
import SwiftUI

/// A temporary inspector. Changes become one document command when Apply is pressed.
struct CaptureAnnotationOptions: View {
    @State var stroke: ImageEditStroke
    let isExisting: Bool
    let onApply: (ImageEditStroke) -> Void
    let onDismiss: () -> Void
    private let fonts = ["系统字体", "PingFangSC-Regular", "Helvetica", "Arial", "TimesNewRomanPSMT", "Menlo-Regular"]
    private var textTools: Bool { [.text, .watermark, .number, .arrow].contains(stroke.tool) }
    private var shapeTools: Bool { [.rectangle, .ellipse].contains(stroke.tool) }
    private var lineTools: Bool { [.line, .polyline, .pen, .arrow, .rectangle, .ellipse].contains(stroke.tool) }
    private var maskTools: Bool { [.mosaic, .blur, .eraser, .inpaint, .highlight, .spotlight, .magnify].contains(stroke.tool) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Label(stroke.tool.title + " · 样式", systemImage: stroke.tool.symbol).font(.headline); Spacer(); Button("关闭", action: onDismiss) }
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    ColorPicker("颜色 / 不透明度", selection: Binding(get: { Color(nsColor: stroke.color) }, set: { stroke.color = NSColor($0) }), supportsOpacity: true)
                    number("粗细", value: $stroke.width, range: 1...128, unit: "px")
                    if lineTools {
                        picker("线型", selection: $stroke.style.lineStyle)
                        picker("端点", selection: $stroke.style.lineCap)
                        picker("连接", selection: $stroke.style.lineJoin)
                    }
                    if [.line, .polyline].contains(stroke.tool) {
                        picker("起点标记", selection: $stroke.style.startHead)
                        picker("终点标记", selection: $stroke.style.endHead)
                        Text("折线：逐点单击，双击 / Enter 完成；Shift 对齐 45°；Delete 删除上一节点。完成后可拖动任一节点。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if shapeTools {
                        Toggle("填充形状", isOn: $stroke.style.filled)
                        if stroke.tool == .rectangle { number("圆角", value: $stroke.style.cornerRadius, range: 0...100, unit: "px") }
                        if stroke.tool == .ellipse {
                            degrees("起始角度", value: $stroke.style.arcStart, range: -180...180)
                            degrees("圆弧角度", value: $stroke.style.arcSweep, range: 1...360)
                            number("内圆比例", value: $stroke.style.arcInnerRatio, range: 0...0.95, unit: "")
                        }
                    }
                    if stroke.tool == .arrow { picker("箭头样式", selection: $stroke.style.arrowStyle) }
                    if stroke.tool == .number {
                        picker("序号样式", selection: $stroke.style.sequenceStyle)
                        Stepper("起始编号：\(stroke.number)", value: $stroke.number, in: 1...999)
                        Text("单击放置编号，拖动附加指向箭头；下一个编号自动递增。") .font(.caption).foregroundStyle(.secondary)
                    }
                    if maskTools {
                        Picker("作用区域", selection: $stroke.style.effectShape) {
                            ForEach(ImageEditEffectShape.allCases.filter { stroke.tool != .magnify || $0 != .brush }, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        if [.mosaic, .blur].contains(stroke.tool) {
                            number("效果强度", value: Binding(get: { stroke.style.effectStrength ?? stroke.width }, set: { stroke.style.effectStrength = $0 }), range: 1...64, unit: "")
                        }
                        if stroke.tool == .highlight { picker("混合模式", selection: $stroke.style.blendMode) }
                        if stroke.tool == .eraser { Text("恢复截图原始像素。橡皮擦之后新增的标注仍然保留；可撤销恢复。") .font(.caption).foregroundStyle(.secondary) }
                        if stroke.tool == .inpaint { Text("本地修复擦除根据周围像素扩散补全，适合平滑背景。复杂纹理与文字内容不会被语义重建。单次区域上限 100 万像素。") .font(.caption).foregroundStyle(.secondary) }
                    }
                    if stroke.tool == .spotlight {
                        number("背景暗度", value: $stroke.style.spotlightOpacity, range: 0...0.95, unit: "")
                        Toggle("显示边框", isOn: $stroke.style.showsBorder)
                    }
                    if stroke.tool == .magnify {
                        number("放大倍数", value: $stroke.style.magnification, range: 1...8, unit: "×")
                        picker("连接样式", selection: $stroke.style.connectorStyle)
                        Toggle("包含下层标注", isOn: $stroke.style.includesAnnotations)
                        Toggle("抗锯齿", isOn: $stroke.style.antialias)
                        Toggle("边框", isOn: $stroke.style.showsBorder)
                        Toggle("阴影", isOn: $stroke.style.shadow)
                        Text("拖框选择采样区域后放置镜片。拖动镜片移动放大内容；按住 Control 拖动采样框移动源区域，角点调整镜片倍率。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if textTools {
                        Divider()
                        Text(stroke.tool == .text ? "文字内容" : stroke.tool == .watermark ? "水印内容" : "附注文字").font(.subheadline)
                        TextEditor(text: $stroke.text).font(.system(size: 13)).frame(minHeight: 66, maxHeight: 100)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.gray.opacity(0.3)))
                        number("字号", value: Binding(get: { stroke.fontSize ?? 24 }, set: { stroke.fontSize = $0 }), range: 8...180, unit: "px")
                        Picker("字体", selection: Binding(get: { stroke.style.fontName ?? "系统字体" }, set: { stroke.style.fontName = $0 == "系统字体" ? nil : $0 })) {
                            ForEach(fonts, id: \.self) { Text($0).tag($0) }
                            if let custom = stroke.style.fontName, !fonts.contains(custom) { Text(custom).tag(custom) }
                        }
                        TextField("字体 PostScript 名称（空白为系统字体）", text: Binding(get: { stroke.style.fontName ?? "" }, set: { stroke.style.fontName = $0.isEmpty ? nil : $0 })).textFieldStyle(.roundedBorder)
                        HStack { Toggle("粗体", isOn: $stroke.style.bold); Toggle("斜体", isOn: $stroke.style.italic) }
                        number("描边粗细", value: $stroke.style.outlineWidth, range: 0...8, unit: "px")
                        ColorPicker("描边颜色", selection: Binding(get: { Color(nsColor: stroke.style.outlineColor) }, set: { stroke.style.outlineColor = NSColor($0) }))
                        Toggle("文字背景", isOn: Binding(get: { stroke.style.backgroundColor != nil }, set: { stroke.style.backgroundColor = $0 ? .white : nil }))
                        if stroke.style.backgroundColor != nil {
                            ColorPicker("背景颜色", selection: Binding(get: { Color(nsColor: stroke.style.backgroundColor ?? .white) }, set: { stroke.style.backgroundColor = NSColor($0) }))
                            number("背景留白", value: $stroke.style.backgroundPadding, range: 0...30, unit: "px")
                            number("背景圆角", value: $stroke.style.backgroundRadius, range: 0...30, unit: "px")
                        }
                        picker("自动换行", selection: $stroke.style.wrapMode)
                        if stroke.style.wrapMode != .none { number("换行宽度", value: Binding(get: { stroke.style.wrapWidth ?? 240 }, set: { stroke.style.wrapWidth = $0 }), range: 40...1200, unit: "px") }
                    }
                    if stroke.tool == .watermark {
                        picker("水印位置", selection: $stroke.style.watermarkPlacement)
                        number("平铺间距", value: $stroke.style.watermarkSpacing, range: 0...300, unit: "px")
                        Text("拖框指定水印区域。{date} 替换为当天日期，{time} 替换为当前时分秒，在应用时固定。") .font(.caption).foregroundStyle(.secondary)
                    }
                    if !stroke.tool.isPixelEffect || stroke.tool == .magnify { degrees("旋转", value: $stroke.style.rotation, range: -180...180) }
                }.padding(.trailing, 8)
            }
            HStack { Spacer(); Button(isExisting ? "应用到标注" : "应用并继续绘制") { onApply(stroke) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }
        }.padding(14).frame(width: 350, height: 520).environment(\.colorScheme, .light)
    }
    private func picker<T: RawRepresentable & CaseIterable & Hashable>(_ title: String, selection: Binding<T>) -> some View where T.RawValue == String, T.AllCases: RandomAccessCollection {
        Picker(title, selection: selection) { ForEach(Array(T.allCases), id: \.self) { Text($0.rawValue).tag($0) } }
    }
    private func number(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, unit: String) -> some View {
        HStack { Text(title).frame(width: 80, alignment: .leading); Slider(value: value, in: range); TextField("", value: value, formatter: Self.formatter).frame(width: 48).textFieldStyle(.roundedBorder); Text(unit).font(.caption) }
    }
    private func degrees(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        number(title, value: Binding(get: { value.wrappedValue * 180 / .pi }, set: { value.wrappedValue = $0 * .pi / 180 }), range: range, unit: "°")
    }
    private static let formatter: NumberFormatter = { let f = NumberFormatter(); f.maximumFractionDigits = 2; f.minimumFractionDigits = 0; return f }()
}

enum CaptureToolbarConfiguration {
    static let key = "Xclip.capture.toolbarTools.v1"
    static let defaults: [ImageEditTool] = [.rectangle, .ellipse, .arrow, .pen, .highlight, .text, .number, .mosaic]
    static func sanitized(_ tools: [ImageEditTool]) -> [ImageEditTool] {
        var seen = Set<ImageEditTool>()
        return Array(tools.filter { $0 != .crop && seen.insert($0).inserted }.prefix(8))
    }
    static func load(from preferences: UserDefaults = .standard) -> [ImageEditTool] {
        guard let values = preferences.stringArray(forKey: key) else { return defaults }
        return sanitized(values.compactMap(ImageEditTool.init(rawValue:)))
    }
    static func save(_ tools: [ImageEditTool], to preferences: UserDefaults = .standard) { preferences.set(sanitized(tools).map(\.rawValue), forKey: key) }
}

struct CaptureToolbarCustomization: View {
    @State var selected: [ImageEditTool]
    let onApply: ([ImageEditTool]) -> Void
    let onDismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("自定义常用工具").font(.headline); Spacer(); Button("关闭", action: onDismiss) }
            Text("调整选区始终保留，最多另选 8 个标注工具。其他工具仍可在“更多”中使用。").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(Array(selected.enumerated()), id: \.element) { index, tool in
                        HStack {
                            Toggle(isOn: Binding(get: { selected.contains(tool) }, set: { if !$0 { selected.removeAll { $0 == tool } } })) { Label(tool.title, systemImage: tool.symbol) }
                            Spacer()
                            Button { selected.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0).help("上移")
                            Button { selected.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }.disabled(index == selected.count - 1).help("下移")
                        }
                    }
                    Divider()
                    ForEach(ImageEditTool.allCases.filter { $0 != .crop && !selected.contains($0) }) { tool in
                        Toggle(isOn: Binding(get: { selected.contains(tool) }, set: { if $0 && selected.count < 8 { selected.append(tool) } })) { Label(tool.title, systemImage: tool.symbol) }
                            .disabled(selected.count >= 8)
                    }
                }.padding(.trailing, 8)
            }
            HStack {
                Button("恢复默认") { selected = CaptureToolbarConfiguration.defaults }
                Spacer(); Button("应用") { onApply(selected) }.buttonStyle(.borderedProminent)
            }
        }.padding(14).frame(width: 340, height: 500).environment(\.colorScheme, .light)
    }
}
