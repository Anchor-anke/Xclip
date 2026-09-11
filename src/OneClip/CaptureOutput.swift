import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageIO

enum CaptureOutputFormat: String, CaseIterable {
    case png = "PNG", jpeg = "JPEG", heic = "HEIC", tiff = "TIFF", pdf = "PDF"
    var type: UTType { switch self { case .png: return .png; case .jpeg: return .jpeg; case .heic: return .heic; case .tiff: return .tiff; case .pdf: return .pdf } }
    var fileExtension: String { type.preferredFilenameExtension ?? rawValue.lowercased() }
}

@MainActor
final class CapturePreferences: ObservableObject {
    static let shared = CapturePreferences()
    private let defaults: UserDefaults
    @Published var delay: Int { didSet { defaults.set(min(30, max(0, delay)), forKey: "Xclip.capture.delay") } }
    @Published var smartSelection: Bool { didSet { defaults.set(smartSelection, forKey: "Xclip.capture.smartSelection") } }
    @Published var format: CaptureOutputFormat { didSet { defaults.set(format.rawValue, forKey: "Xclip.capture.format") } }
    @Published var quality: Double { didSet { defaults.set(min(1, max(0.1, quality)), forKey: "Xclip.capture.quality") } }
    @Published var cornerRadius: Double { didSet { defaults.set(min(100, max(0, cornerRadius)), forKey: "Xclip.capture.cornerRadius") } }
    @Published var shadow: Bool { didSet { defaults.set(shadow, forKey: "Xclip.capture.shadow") } }
    @Published var directory: String { didSet { defaults.set(directory, forKey: "Xclip.capture.directory") } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        delay = min(30, max(0, defaults.integer(forKey: "Xclip.capture.delay")))
        smartSelection = defaults.object(forKey: "Xclip.capture.smartSelection") as? Bool ?? true
        format = CaptureOutputFormat(rawValue: defaults.string(forKey: "Xclip.capture.format") ?? "") ?? .png
        quality = min(1, max(0.1, defaults.object(forKey: "Xclip.capture.quality") as? Double ?? 0.92))
        cornerRadius = min(100, max(0, defaults.double(forKey: "Xclip.capture.cornerRadius")))
        shadow = defaults.bool(forKey: "Xclip.capture.shadow")
        directory = defaults.string(forKey: "Xclip.capture.directory") ?? ""
    }
}

enum CaptureOutputCodec {
    static func writeNew(_ data: Data, to url: URL) throws {
        let staging = url.deletingLastPathComponent().appendingPathComponent(".xclip-export-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: staging) }
        try data.write(to: staging, options: .atomic)
        // moveItem refuses an existing destination; atomic + withoutOverwriting is an invalid NSData option pair.
        try FileManager.default.moveItem(at: staging, to: url)
    }
    static func encode(_ image: CGImage, format: CaptureOutputFormat, quality: Double = 0.92) throws -> Data {
        if format == .pdf {
            let data = NSMutableData()
            guard let consumer = CGDataConsumer(data: data) else { throw CaptureToolError.invalidImage }
            var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw CaptureToolError.invalidImage }
            context.beginPDFPage(nil); context.draw(image, in: box); context.endPDFPage(); context.closePDF()
            return data as Data
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else { throw CaptureMessage("系统无法编码所选格式。", "The system cannot encode this format.") }
        // Flatten against white for JPEG; alpha otherwise remains intact.
        var output = image
        if format == .jpeg {
            let context = try CaptureImageCodec.context(width: image.width, height: image.height)
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let flattened = context.makeImage() else { throw CaptureToolError.invalidImage }; output = flattened
        }
        CGImageDestinationAddImage(destination, output, [kCGImageDestinationLossyCompressionQuality: min(1, max(0.1, quality))] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CaptureMessage("图片导出失败。", "Image export failed.") }
        return data as Data
    }
    static func decorated(_ image: CGImage, radius: CGFloat, shadow: Bool) throws -> CGImage {
        guard radius > 0 || shadow else { return image }
        let margin = shadow ? 24 : 0
        let context = try CaptureImageCodec.context(width: image.width + margin * 2, height: image.height + margin * 2)
        let rect = CGRect(x: margin, y: margin, width: image.width, height: image.height)
        let path = CGPath(roundedRect: rect, cornerWidth: min(radius, rect.width / 2), cornerHeight: min(radius, rect.height / 2), transform: nil)
        if shadow {
            context.saveGState(); context.setShadow(offset: CGSize(width: 0, height: -4), blur: 12, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            context.setFillColor(NSColor.white.cgColor); context.addPath(path); context.fillPath(); context.restoreGState()
        }
        context.addPath(path); context.clip(); context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw CaptureToolError.invalidImage }; return result
    }
}

@MainActor
enum CaptureOutput {
    static func image(_ png: Data, decorated: Bool = true) throws -> CGImage {
        let image = try CaptureImageCodec.decode(png), p = CapturePreferences.shared
        return decorated ? try CaptureOutputCodec.decorated(image, radius: p.cornerRadius, shadow: p.shadow) : image
    }
    static func save(_ png: Data, panel suppliedPanel: NSSavePanel? = nil, allowsWrite: () -> Bool = { true }) throws -> URL? {
        let panel = suppliedPanel ?? NSSavePanel()
        let p = CapturePreferences.shared
        panel.title = CaptureLocalization.text("保存截图", "Save capture")
        panel.allowedContentTypes = [p.format.type]
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        panel.nameFieldStringValue = "Xclip-\(formatter.string(from: Date())).\(p.format.fileExtension)"
        if !p.directory.isEmpty { panel.directoryURL = URL(fileURLWithPath: p.directory, isDirectory: true) }
        let accessory = CaptureSaveAccessory(panel: panel, preferences: p)
        panel.accessoryView = accessory
        guard panel.runModal() == .OK, let url = panel.url, allowsWrite() else { return nil }
        let data = try CaptureOutputCodec.encode(image(png), format: p.format, quality: p.quality)
        guard allowsWrite() else { return nil }
        try data.write(to: url, options: .atomic)
        p.directory = url.deletingLastPathComponent().path
        return url
    }
    static func quickSave(_ png: Data, panel: NSSavePanel? = nil, allowsWrite: () -> Bool = { true }) throws -> URL? {
        let p = CapturePreferences.shared
        guard allowsWrite() else { return nil }
        guard !p.directory.isEmpty else { return try save(png, panel: panel, allowsWrite: allowsWrite) }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        let url = URL(fileURLWithPath: p.directory, isDirectory: true).appendingPathComponent("Xclip-\(formatter.string(from: Date())).\(p.format.fileExtension)")
        let data = try CaptureOutputCodec.encode(image(png), format: p.format, quality: p.quality)
        guard allowsWrite() else { return nil }
        try CaptureOutputCodec.writeNew(data, to: url); return url
    }
}

private final class CaptureSaveAccessory: NSView {
    private weak var panel: NSSavePanel?
    private let preferences: CapturePreferences
    private let formats = NSPopUpButton()
    private let quality = NSSlider(value: 0.92, minValue: 0.1, maxValue: 1, target: nil, action: nil)
    init(panel: NSSavePanel, preferences: CapturePreferences) {
        self.panel = panel; self.preferences = preferences
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: 40))
        let label = NSTextField(labelWithString: CaptureLocalization.text("格式", "Format")); label.frame = CGRect(x: 0, y: 12, width: 45, height: 20); addSubview(label)
        formats.addItems(withTitles: CaptureOutputFormat.allCases.map(\.rawValue)); formats.selectItem(withTitle: preferences.format.rawValue)
        formats.target = self; formats.action = #selector(change); formats.frame = CGRect(x: 48, y: 6, width: 100, height: 30); addSubview(formats)
        let qualityLabel = NSTextField(labelWithString: CaptureLocalization.text("质量", "Quality")); qualityLabel.frame = CGRect(x: 164, y: 12, width: 50, height: 20); addSubview(qualityLabel)
        quality.doubleValue = preferences.quality; quality.frame = CGRect(x: 218, y: 8, width: 170, height: 25)
        quality.target = self; quality.action = #selector(change); addSubview(quality); update()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func change() {
        preferences.format = CaptureOutputFormat(rawValue: formats.titleOfSelectedItem ?? "") ?? .png
        preferences.quality = quality.doubleValue; update()
    }
    private func update() {
        quality.isEnabled = [.jpeg, .heic].contains(preferences.format)
        panel?.allowedContentTypes = [preferences.format.type]
        if let old = panel?.nameFieldStringValue { panel?.nameFieldStringValue = (old as NSString).deletingPathExtension + "." + preferences.format.fileExtension }
    }
}

struct CaptureSettingsView: View {
    @ObservedObject var preferences = CapturePreferences.shared
    var body: some View {
        Group {
            Section(CaptureLocalization.text("截屏", "Screenshot")) {
                Stepper(CaptureLocalization.text("延时", "Delay") + "：\(preferences.delay) s", value: $preferences.delay, in: 0...30)
                Toggle(CaptureLocalization.text("自动吸附窗口选区", "Detect window regions"), isOn: $preferences.smartSelection)
                Text(CaptureLocalization.text("截图、长截图、录屏和贴图快捷键统一在“快捷键”中修改。", "Edit screenshot, scrolling capture, recording and pin shortcuts in Shortcuts.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(CaptureLocalization.text("保存与导出", "Save and export")) {
                Picker(CaptureLocalization.text("默认格式", "Default format"), selection: $preferences.format) { ForEach(CaptureOutputFormat.allCases, id: \.rawValue) { Text($0.rawValue).tag($0) } }
                Slider(value: $preferences.quality, in: 0.1...1) { Text(CaptureLocalization.text("JPEG / HEIC 质量", "JPEG / HEIC quality")) }
                Stepper(CaptureLocalization.text("导出圆角", "Export corner radius") + "：\(Int(preferences.cornerRadius)) px", value: $preferences.cornerRadius, in: 0...100, step: 2)
                Toggle(CaptureLocalization.text("导出时添加阴影", "Add shadow when exporting"), isOn: $preferences.shadow)
                HStack {
                    Text(preferences.directory.isEmpty ? CaptureLocalization.text("保存时选择文件夹", "Choose a folder when saving") : preferences.directory).font(.caption).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button(CaptureLocalization.text("更改文件夹…", "Choose folder…")) {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url { preferences.directory = url.path }
                    }
                }
            }
        }
    }
}

@MainActor
final class CaptureCountdown: ObservableObject {
    static let shared = CaptureCountdown()
    @Published private(set) var remaining = 0
    private var panel: NSPanel?
    private var cancelAction: (() -> Void)?
    func wait(seconds: Int, cancel: @escaping () -> Void) async throws {
        guard seconds > 0 else { return }
        remaining = min(30, seconds); cancelAction = cancel
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let panel = NSPanel(contentRect: CGRect(x: frame.midX - 100, y: frame.maxY - 90, width: 200, height: 54), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: CaptureCountdownView(controller: self)); self.panel = panel
        NSApp.unhideWithoutActivation(); panel.orderFrontRegardless()
        defer { panel.orderOut(nil); panel.contentView = nil; self.panel = nil; cancelAction = nil }
        for value in stride(from: remaining, through: 1, by: -1) { remaining = value; try await Task.sleep(nanoseconds: 1_000_000_000) }
    }
    func cancel() { cancelAction?() }
}
private struct CaptureCountdownView: View {
    @ObservedObject var controller: CaptureCountdown
    var body: some View { HStack { Image(systemName: "timer"); Text("\(controller.remaining) s").monospacedDigit(); Spacer(); Button(CaptureLocalization.text("取消", "Cancel")) { controller.cancel() } }.padding(14).background(.regularMaterial) }
}
