import AppKit
import SwiftUI

enum CaptureSelectionSizing {
    static func exact(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, ratio: CGFloat?, in bounds: CGRect) -> CGRect {
        guard [x, y, width, height].allSatisfy(\.isFinite), bounds.width >= 2, bounds.height >= 2 else { return .zero }
        var w = min(bounds.width, max(2, width.rounded())), h = min(bounds.height, max(2, height.rounded()))
        if let ratio, ratio.isFinite, ratio > 0 {
            h = w / ratio
            if h > bounds.height { h = bounds.height; w = h * ratio }
            if w < 2 || h < 2 { return .zero }
        }
        return CGRect(x: min(bounds.maxX - w, max(bounds.minX, x.rounded())), y: min(bounds.maxY - h, max(bounds.minY, y.rounded())), width: w, height: h)
    }
    static func constrained(_ proposed: CGRect, ratio: CGFloat?, in bounds: CGRect) -> CGRect {
        guard let ratio else { return CaptureSelectionGeometry.clamped(proposed, to: bounds) }
        return exact(x: proposed.minX, y: proposed.minY, width: proposed.width, height: proposed.height, ratio: ratio, in: bounds)
    }
}

struct CaptureRememberedSelection: Codable, Equatable {
    let x: Double, y: Double, width: Double, height: Double, screenWidth: Double, screenHeight: Double
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
enum CaptureSelectionMemory {
    static let key = "Xclip.capture.recentSelection.v1"
    static func items(in bounds: CGRect, defaults: UserDefaults = .standard) -> [CaptureRememberedSelection] {
        guard let data = defaults.data(forKey: key), let list = try? JSONDecoder().decode([CaptureRememberedSelection].self, from: data) else { return [] }
        return list.filter { $0.screenWidth == bounds.width && $0.screenHeight == bounds.height && bounds.contains($0.rect) && $0.width >= 2 && $0.height >= 2 }
    }
    static func remember(_ rect: CGRect, in bounds: CGRect, defaults: UserDefaults = .standard) {
        let rect = CaptureSelectionGeometry.clamped(rect.integral, to: bounds)
        guard rect.width >= 2, rect.height >= 2 else { return }
        let item = CaptureRememberedSelection(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height, screenWidth: bounds.width, screenHeight: bounds.height)
        var list = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([CaptureRememberedSelection].self, from: $0) } ?? []
        list.removeAll { $0 == item }; list.insert(item, at: 0)
        if let data = try? JSONEncoder().encode(Array(list.prefix(10))) { defaults.set(data, forKey: key) }
    }
}

@MainActor
final class CaptureSelectionOptions {
    static let shared = CaptureSelectionOptions()
    private var popover: NSPopover?
    func show(relativeTo view: NSView, selection: CGRect, bounds: CGRect, ratio: CGFloat?, change: @escaping (CGRect, CGFloat?) -> Void) {
        popover?.close()
        let popover = NSPopover(); popover.behavior = .transient; popover.appearance = NSAppearance(named: .aqua)
        popover.contentViewController = NSHostingController(rootView: CaptureSelectionOptionsView(selection: selection, bounds: bounds, ratio: ratio) { rect, ratio in change(rect, ratio) })
        self.popover = popover
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }
    func close() { popover?.close(); popover = nil }
}

private struct CaptureSelectionOptionsView: View {
    let bounds: CGRect
    let change: (CGRect, CGFloat?) -> Void
    @State private var x: Double
    @State private var y: Double
    @State private var width: Double
    @State private var height: Double
    @State private var ratioName: String
    @State private var ratioWidth = 16.0
    @State private var ratioHeight = 9.0
    init(selection: CGRect, bounds: CGRect, ratio: CGFloat?, change: @escaping (CGRect, CGFloat?) -> Void) {
        self.bounds = bounds; self.change = change
        _x = State(initialValue: selection.minX); _y = State(initialValue: selection.minY)
        _width = State(initialValue: selection.width); _height = State(initialValue: selection.height)
        _ratioName = State(initialValue: ratio == nil ? "free" : "custom")
        _ratioWidth = State(initialValue: ratio ?? 16); _ratioHeight = State(initialValue: ratio == nil ? 9 : 1)
    }
    private var ratio: CGFloat? {
        switch ratioName { case "1:1": return 1; case "4:3": return 4 / 3; case "16:9": return 16 / 9; case "9:16": return 9 / 16; case "custom": return ratioWidth > 0 && ratioHeight > 0 ? ratioWidth / ratioHeight : nil; default: return nil }
    }
    private func apply() {
        let rect = CaptureSelectionSizing.exact(x: x, y: y, width: width, height: height, ratio: ratio, in: bounds)
        guard rect.width >= 2 && rect.height >= 2 else { return }
        x = rect.minX; y = rect.minY; width = rect.width; height = rect.height; change(rect, ratio)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(CaptureLocalization.text("选区尺寸", "Selection size")).font(.headline)
            Grid(alignment: .leading) {
                GridRow { Text("X"); TextField("X", value: $x, format: .number); Text("Y"); TextField("Y", value: $y, format: .number) }
                GridRow { Text(CaptureLocalization.text("宽", "W")); TextField("W", value: $width, format: .number); Text(CaptureLocalization.text("高", "H")); TextField("H", value: $height, format: .number).disabled(ratio != nil) }
            }.textFieldStyle(.roundedBorder)
            Picker(CaptureLocalization.text("比例", "Ratio"), selection: $ratioName) {
                Text(CaptureLocalization.text("自由", "Free")).tag("free")
                ForEach(["1:1", "4:3", "16:9", "9:16"], id: \.self) { Text($0).tag($0) }
                Text(CaptureLocalization.text("自定义", "Custom")).tag("custom")
            }
            if ratioName == "custom" { HStack { TextField("W", value: $ratioWidth, format: .number); Text(":"); TextField("H", value: $ratioHeight, format: .number) }.textFieldStyle(.roundedBorder) }
            HStack { Text("px").font(.caption).foregroundStyle(.secondary); Spacer(); Button(CaptureLocalization.text("应用", "Apply"), action: apply).buttonStyle(.borderedProminent) }
            let recent = CaptureSelectionMemory.items(in: bounds)
            if !recent.isEmpty {
                Divider(); Text(CaptureLocalization.text("最近选区", "Recent regions")).font(.caption).foregroundStyle(.secondary)
                ForEach(Array(recent.prefix(4).enumerated()), id: \.offset) { _, item in
                    Button("\(Int(item.width)) × \(Int(item.height)) · \(Int(item.x)), \(Int(item.y))") {
                        x = item.x; y = item.y; width = item.width; height = item.height; ratioName = "free"; apply()
                    }.buttonStyle(.plain)
                }
            }
        }.padding(16).frame(width: 290)
    }
}
