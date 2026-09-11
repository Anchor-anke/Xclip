import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CaptureAnnotationSnapshot {
    let frame: CGRect
    let image: CGImage
    let selectsFullImage: Bool
    var windowRegions: [CGRect] = []
    var initialAction: CaptureWorkflowAction? = nil
}

enum CaptureWorkflowAction: String, CaseIterable {
    case pin, ocr, translate, formula, table, barcode, longCapture, recording
    var title: String {
        switch self {
        case .pin: return CaptureLocalization.text("贴图", "Pin")
        case .ocr: return CaptureLocalization.text("识别文字", "Recognize text")
        case .translate: return CaptureLocalization.text("翻译", "Translate")
        case .formula: return CaptureLocalization.text("识别公式", "Recognize formula")
        case .table: return CaptureLocalization.text("识别表格", "Recognize table")
        case .barcode: return CaptureLocalization.text("识别二维码 / 条码", "Read QR / barcode")
        case .longCapture: return CaptureLocalization.text("长截图", "Scrolling capture")
        case .recording: return CaptureLocalization.text("录屏 / 动图", "Record / GIF")
        }
    }
}

enum CaptureAnnotationDestination {
    case copy
    case saved(URL)
    case action(CaptureWorkflowAction, region: CGRect)
}

struct CaptureAnnotationResult {
    let data: Data
    let destination: CaptureAnnotationDestination
}

/// A short-lived, frozen-screen editing session. It never writes the pasteboard itself.
@MainActor
final class CaptureAnnotationController {
    private var panels: [CaptureAnnotationPanel] = []
    private var continuation: CheckedContinuation<CaptureAnnotationResult, Error>?
    private var observers: [NSObjectProtocol] = []
    private var cancelled = false
    private var saving = false
    private var activeSavePanel: NSSavePanel?

    func select(snapshots: [CaptureAnnotationSnapshot]) async throws -> CaptureAnnotationResult {
        try Task.checkCancellation()
        guard !cancelled, !snapshots.isEmpty else { throw CaptureToolError.cancelled }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                for snapshot in snapshots {
                    let panel = CaptureAnnotationPanel(contentRect: snapshot.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    panel.title = CaptureLocalization.text("Xclip 截图标注", "Xclip Capture Annotation")
                    panel.level = .screenSaver
                    panel.backgroundColor = .black
                    panel.isOpaque = true
                    panel.hasShadow = false
                    panel.hidesOnDeactivate = false
                    panel.acceptsMouseMovedEvents = true
                    panel.isReleasedWhenClosed = false
                    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                    let canvas = CaptureAnnotationView(frame: CGRect(origin: .zero, size: snapshot.frame.size),
                                                       image: snapshot.image, selectsFullImage: snapshot.selectsFullImage,
                                                       windowRegions: snapshot.windowRegions, initialAction: snapshot.initialAction)
                    canvas.onCancel = { [weak self] in self?.cancel() }
                    canvas.onCopy = { [weak self] data in self?.finish(.success(.init(data: data, destination: .copy))) }
                    canvas.onSave = { [weak self, weak canvas] data in self?.save(data, canvas: canvas) }
                    canvas.onQuickSave = { [weak self, weak canvas] data in self?.save(data, canvas: canvas, quick: true) }
                    canvas.onAction = { [weak self] action, data, selection in
                        let selection = selection.standardized.integral.intersection(CGRect(x: 0, y: 0, width: snapshot.image.width, height: snapshot.image.height))
                        let top = NSScreen.screens.first?.frame.maxY ?? snapshot.frame.maxY
                        let region = CGRect(x: snapshot.frame.minX + selection.minX / CGFloat(snapshot.image.width) * snapshot.frame.width,
                            y: top - snapshot.frame.maxY + selection.minY / CGFloat(snapshot.image.height) * snapshot.frame.height,
                            width: selection.width / CGFloat(snapshot.image.width) * snapshot.frame.width,
                            height: selection.height / CGFloat(snapshot.image.height) * snapshot.frame.height)
                        self?.finish(.success(.init(data: data, destination: .action(action, region: region))))
                    }
                    canvas.onBeginSelection = { [weak self, weak canvas] in
                        self?.panels.compactMap { $0.contentView as? CaptureAnnotationView }
                            .filter { $0 !== canvas }.forEach { $0.reset() }
                    }
                    panel.contentView = canvas
                    panels.append(panel)
                    panel.orderFrontRegardless()
                }
                NSApp.unhideWithoutActivation()
                NSApp.activate(ignoringOtherApps: true)
                let active = panels.first { $0.frame.contains(NSEvent.mouseLocation) } ?? panels.first
                active?.makeKeyAndOrderFront(nil)
                active?.makeFirstResponder(active?.contentView)
                observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.cancel() }
                })
                observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in if self?.saving == false { self?.cancel() } }
                })
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    func cancel() {
        cancelled = true
        activeSavePanel?.cancel(nil)
        finish(.failure(CaptureToolError.cancelled))
    }

    private func finish(_ result: Result<CaptureAnnotationResult, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        panels.forEach { $0.orderOut(nil); $0.contentView = nil }
        panels.removeAll()
        continuation.resume(with: result)
    }

    private func save(_ data: Data, canvas: CaptureAnnotationView?, quick: Bool = false) {
        guard !saving, continuation != nil else { return }
        saving = true
        panels.forEach { $0.orderOut(nil) }
        let panel = NSSavePanel()
        activeSavePanel = panel
        var savedURL: URL?
        do {
            let allowsWrite = { [weak self] in self?.continuation != nil && self?.cancelled == false }
            savedURL = quick ? try CaptureOutput.quickSave(data, panel: panel, allowsWrite: allowsWrite) : try CaptureOutput.save(data, panel: panel, allowsWrite: allowsWrite)
        } catch { canvas?.showError(error) }
        activeSavePanel = nil
        saving = false
        guard continuation != nil else { return }
        if let url = savedURL {
            finish(.success(.init(data: data, destination: .saved(url))))
            return
        }
        panels.forEach { $0.orderFrontRegardless() }
        canvas?.window?.makeKeyAndOrderFront(nil)
        canvas?.window?.makeFirstResponder(canvas)
    }
}

private final class CaptureAnnotationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Image coordinates always use source pixels with a top-left origin; only this view maps points.
@MainActor
final class CaptureAnnotationView: NSView {
    let document: CaptureAnnotationDocument
    var onCancel: (() -> Void)?
    var onCopy: ((Data) -> Void)?
    var onSave: ((Data) -> Void)?
    var onQuickSave: ((Data) -> Void)?
    var onAction: ((CaptureWorkflowAction, Data, CGRect) -> Void)?
    var onBeginSelection: (() -> Void)?
    private let fitsImage: Bool
    private let windowRegions: [CGRect]
    private var hoverRegion: CGRect?
    private var windowClickCandidate: CGRect?
    private var tool: ImageEditTool?
    private var preferences = ImageEditorPreferences.load()
    private var pending: ImageEditStroke?
    private var mosaicPreview: (CGImage, CGRect)?
    private var effectPreview: CGImage?
    private var effectPreviewRunning = false
    private var effectPreviewGeneration = 0
    private var effectPreviewRequested: ImageEditStroke?
    private var styles: [ImageEditTool: ImageEditStyle] = [:]
    private var annotationText = ""
    private var watermarkText = "Xclip · {date} {time}"
    private var polylineNodes: [CGPoint] = []
    private var copyingObject = false
    private var movingMagnifierSource = false
    private var redactionTask: Task<Void, Never>?
    private var redactionCandidates: [ImageEditStroke] = []
    private var redactionRevision: UInt64?
    private var redactionMessage: String?
    private var lockedAspectRatio: CGFloat?
    private var initialAction: CaptureWorkflowAction?
    private var optionsPopover: NSPopover?
    private var optionsButton = NSButton()
    private var dragStart: CGPoint?
    private var originalSelection: CGRect?
    private var dragHandle: CaptureSelectionHandle?
    private var moving = false
    private var selecting = false
    private var toolbar = NSVisualEffectView()
    private var propertiesBar = NSVisualEffectView()
    private var propertyLabel = NSTextField(labelWithString: "")
    private var mosaicSlider = NSSlider(value: 8, minValue: 3, maxValue: 32, target: nil, action: nil)
    private var mosaicStrength: CGFloat = 8
    private var selectedStroke: Int?
    private var originalStroke: ImageEditStroke?
    private var editingPreview: CGImage?
    private var objectHandle: Int?
    private var editingTextIndex: Int?
    private var pointer: CGPoint?
    private var usesHexColor = false
    private lazy var pixelSampler = NSBitmapImageRep(cgImage: document.source)
    private var toolButtons: [NSButton] = []
    private var colorButtons: [NSButton] = []
    private var undoButton = NSButton()
    private var redoButton = NSButton()
    private var sizeField = NSTextField(labelWithString: "")
    private var hintField = NSTextField(labelWithString: "")
    private var textEditor: CaptureInlineTextView?
    private var textScroll: NSScrollView?
    private var textOrigin: CGPoint?
    private var textStyle: ImageEditStroke?
    private var lineWidthPopup = NSPopUpButton()
    private var textSizePopup = NSPopUpButton()
    private var tracking: NSTrackingArea?
    private var tools: [ImageEditTool?] = [nil] + CaptureToolbarConfiguration.load().map(Optional.some)
    private let keyboardTools: [ImageEditTool?] = [nil, .rectangle, .ellipse, .arrow, .pen, .highlight, .text, .number, .mosaic]
    private let shortcuts = ["v", "r", "o", "a", "p", "h", "t", "n", "m"]
    private let colors: [NSColor] = [.red, .orange, .yellow, .green, .cyan, .blue, .white, .black]

    init(frame: CGRect, image: CGImage, selectsFullImage: Bool, windowRegions: [CGRect] = [], initialAction: CaptureWorkflowAction? = nil) {
        document = CaptureAnnotationDocument(image: image)
        fitsImage = selectsFullImage
        self.windowRegions = windowRegions
        self.initialAction = initialAction
        super.init(frame: frame)
        if selectsFullImage { document.setSelection(imageBounds) }
        buildToolbar()
        updateUI()
        if selectsFullImage, initialAction != nil { DispatchQueue.main.async { [weak self] in self?.runInitialAction() } }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(CaptureLocalization.text("截图画布。拖动框选，V 调整选区，方向键微调，Enter 复制，Esc 取消。", "Capture canvas. Drag to select, V to adjust, arrow keys to nudge, Return to copy, Escape to cancel."))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { redactionTask?.cancel() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var imageBounds: CGRect { CGRect(x: 0, y: 0, width: document.source.width, height: document.source.height) }
    private var imageRect: CGRect {
        if !fitsImage { return bounds }
        let available = bounds.insetBy(dx: 36, dy: 88)
        let scale = min(available.width / imageBounds.width, available.height / imageBounds.height, 1)
        let size = CGSize(width: imageBounds.width * scale, height: imageBounds.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
    private var scaleX: CGFloat { imageRect.width / imageBounds.width }
    private var scaleY: CGFloat { imageRect.height / imageBounds.height }
    private func displayRect(_ rect: CGRect) -> CGRect {
        CGRect(x: imageRect.minX + rect.minX * scaleX, y: imageRect.minY + rect.minY * scaleY,
               width: rect.width * scaleX, height: rect.height * scaleY)
    }
    private func imagePoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(imageBounds.width, max(0, (point.x - imageRect.minX) / scaleX)),
                y: min(imageBounds.height, max(0, (point.y - imageRect.minY) / scaleY)))
    }

    private func buildToolbar() {
        for bar in [toolbar, propertiesBar] {
            bar.material = .popover; bar.blendingMode = .withinWindow; bar.state = .active
            bar.appearance = NSAppearance(named: .aqua)
            bar.wantsLayer = true; bar.layer?.cornerRadius = 5
            bar.layer?.backgroundColor = NSColor(calibratedWhite: 0.98, alpha: 1).cgColor
            bar.layer?.borderWidth = 1; bar.layer?.borderColor = NSColor.black.withAlphaComponent(0.16).cgColor
            bar.shadow = NSShadow(); bar.layer?.shadowOpacity = 0.2
            bar.layer?.shadowRadius = 5; bar.layer?.shadowOffset = CGSize(width: 0, height: -2)
            addSubview(bar)
        }
        rebuildToolButtons()
        undoButton = makeButton(symbol: "arrow.uturn.backward", title: CaptureLocalization.text("撤销 (⌘Z)", "Undo (⌘Z)"), action: #selector(undo))
        redoButton = makeButton(symbol: "arrow.uturn.forward", title: CaptureLocalization.text("重做 (⇧⌘Z)", "Redo (⇧⌘Z)"), action: #selector(redo))
        let saveButton = makeButton(symbol: "square.and.arrow.down", title: CaptureLocalization.text("保存 (⌘S)", "Save (⌘S)"), action: #selector(save))
        let cancelButton = makeButton(symbol: "xmark", title: CaptureLocalization.text("取消 (Esc)", "Cancel (Esc)"), action: #selector(cancel))
        let copyButton = makeButton(symbol: "checkmark", title: CaptureLocalization.text("完成并复制 (Enter / ⌘C)", "Finish and copy (Return / ⌘C)"), action: #selector(copyCapture))
        copyButton.contentTintColor = .systemGreen
        let pinButton = makeButton(symbol: "pin", title: CaptureLocalization.text("贴图 (⌘P)", "Pin (⌘P)"), action: #selector(workflowAction(_:)))
        pinButton.identifier = NSUserInterfaceItemIdentifier(CaptureWorkflowAction.pin.rawValue)
        let ocrButton = makeButton(symbol: "text.viewfinder", title: CaptureLocalization.text("识别文字 (Q)", "Recognize text (Q)"), action: #selector(workflowAction(_:)))
        ocrButton.identifier = NSUserInterfaceItemIdentifier(CaptureWorkflowAction.ocr.rawValue)
        let longButton = makeButton(symbol: "rectangle.expand.vertical", title: CaptureLocalization.text("长截图", "Scrolling capture"), action: #selector(workflowAction(_:)))
        longButton.identifier = NSUserInterfaceItemIdentifier(CaptureWorkflowAction.longCapture.rawValue)
        let recordButton = makeButton(symbol: "video", title: CaptureLocalization.text("录屏 / 动图", "Record / GIF"), action: #selector(workflowAction(_:)))
        recordButton.identifier = NSUserInterfaceItemIdentifier(CaptureWorkflowAction.recording.rawValue)
        longButton.isEnabled = !fitsImage; recordButton.isEnabled = !fitsImage
        let moreButton = makeButton(symbol: "ellipsis", title: CaptureLocalization.text("更多工具与操作", "More tools and actions"), action: #selector(showMore(_:)))
        for (i, button) in [undoButton, redoButton, pinButton, ocrButton, longButton, recordButton, saveButton, cancelButton, copyButton, moreButton].enumerated() {
            button.tag = 100 + i; toolbar.addSubview(button)
        }
        for (i, color) in colors.enumerated() {
            let button = makeButton(symbol: "circle.fill", title: CaptureLocalization.text("标注颜色", "Annotation color") + " \(i + 1)", action: #selector(chooseColor(_:)))
            button.tag = i; button.contentTintColor = color
            colorButtons.append(button); propertiesBar.addSubview(button)
        }
        let widths = Array(Set([2, 4, 6, 10, 16, Int(preferences.lineWidth)])).sorted()
        lineWidthPopup.addItems(withTitles: widths.map { "\($0) px" })
        lineWidthPopup.selectItem(withTitle: "\(Int(preferences.lineWidth)) px")
        lineWidthPopup.target = self; lineWidthPopup.action = #selector(changeWidth)
        lineWidthPopup.toolTip = CaptureLocalization.text("线条粗细", "Stroke width")
        lineWidthPopup.setAccessibilityLabel(lineWidthPopup.toolTip)
        propertiesBar.addSubview(lineWidthPopup)
        textSizePopup.addItems(withTitles: Array(Set([16, 20, 24, 32, 48, 64, Int(preferences.textSize)])).sorted().map(String.init))
        textSizePopup.selectItem(withTitle: "\(Int(preferences.textSize))")
        textSizePopup.target = self; textSizePopup.action = #selector(changeTextSize)
        textSizePopup.toolTip = CaptureLocalization.text("文字字号", "Text size")
        textSizePopup.setAccessibilityLabel(textSizePopup.toolTip)
        propertiesBar.addSubview(textSizePopup)
        propertyLabel.font = .systemFont(ofSize: 11); propertyLabel.textColor = .darkGray
        propertiesBar.addSubview(propertyLabel)
        mosaicSlider.target = self; mosaicSlider.action = #selector(changeMosaicStrength)
        mosaicSlider.isContinuous = false
        mosaicSlider.setAccessibilityLabel(CaptureLocalization.text("马赛克强度", "Mosaic strength"))
        propertiesBar.addSubview(mosaicSlider)
        optionsButton = makeButton(symbol: "slider.horizontal.3", title: "样式、颜色和工具选项", action: #selector(showOptions(_:)))
        propertiesBar.addSubview(optionsButton)
        sizeField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        sizeField.textColor = .white; sizeField.backgroundColor = NSColor.black.withAlphaComponent(0.82)
        sizeField.drawsBackground = true; sizeField.alignment = .center
        sizeField.wantsLayer = true; sizeField.layer?.cornerRadius = 4
        addSubview(sizeField)
        hintField.font = .systemFont(ofSize: 13, weight: .medium)
        hintField.textColor = .white; hintField.backgroundColor = NSColor.black.withAlphaComponent(0.8)
        hintField.drawsBackground = true; hintField.alignment = .center
        hintField.wantsLayer = true; hintField.layer?.cornerRadius = 7
        addSubview(hintField)
    }

    private func rebuildToolButtons() {
        toolButtons.forEach { $0.removeFromSuperview() }; toolButtons.removeAll()
        for (index, item) in tools.enumerated() {
            let shortcut = keyboardTools.firstIndex(where: { $0 == item }).map { " (\(shortcuts[$0].uppercased()))" } ?? ""
            let title = (item?.title ?? CaptureLocalization.text("调整选区", "Adjust selection")) + shortcut
            let button = makeButton(symbol: item?.symbol ?? "cursorarrow", title: title, action: #selector(chooseTool(_:)))
            if item == .text {
                // SF Symbols localizes textformat; the capture toolbar uses a fixed Latin T.
                button.image = nil; button.imagePosition = .noImage
                button.title = "T"; button.font = .systemFont(ofSize: 21, weight: .medium)
                button.alignment = .center
            }
            button.tag = index; toolButtons.append(button); toolbar.addSubview(button)
        }
    }
    private func customizeToolbar() {
        guard finishPolyline(), commitText() else { return }
        let popover = NSPopover(); popover.behavior = .semitransient; popover.appearance = NSAppearance(named: .aqua)
        popover.contentViewController = NSHostingController(rootView: CaptureToolbarCustomization(selected: tools.compactMap { $0 }, onApply: { [weak self, weak popover] selected in
            guard let self else { return }
            CaptureToolbarConfiguration.save(selected); self.tools = [nil] + CaptureToolbarConfiguration.sanitized(selected).map(Optional.some)
            self.rebuildToolButtons(); popover?.close(); self.window?.makeFirstResponder(self); self.updateUI()
        }, onDismiss: { [weak self, weak popover] in popover?.close(); self?.window?.makeFirstResponder(self) }))
        optionsPopover = popover; popover.show(relativeTo: toolbar.bounds, of: toolbar, preferredEdge: toolbar.frame.midY > bounds.midY ? .minY : .maxY)
    }

    private func makeButton(symbol: String, title: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(), target: self, action: action)
        button.bezelStyle = .regularSquare; button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.image = button.image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        button.toolTip = title; button.setAccessibilityLabel(title)
        button.wantsLayer = true; button.layer?.cornerRadius = 6
        button.contentTintColor = NSColor(calibratedWhite: 0.2, alpha: 1)
        return button
    }

    override func layout() { super.layout(); positionControls() }
    private func positionControls() {
        let toolbarWidth = min(730, max(280, bounds.width - 16))
        let cellWidth = (toolbarWidth - 20) / CGFloat(tools.count + 10)
        for (i, button) in toolButtons.enumerated() {
            button.frame = CGRect(x: 5 + CGFloat(i) * cellWidth, y: 4, width: cellWidth, height: 32)
        }
        for (i, button) in toolbar.subviews.compactMap({ $0 as? NSButton }).filter({ $0.tag >= 100 }).sorted(by: { $0.tag < $1.tag }).enumerated() {
            button.frame = CGRect(x: 15 + CGFloat(i + tools.count) * cellWidth, y: 4, width: cellWidth, height: 32)
        }
        for (i, button) in colorButtons.enumerated() {
            button.frame = CGRect(x: 128 + CGFloat(i) * 27, y: 7, width: 24, height: 26)
        }
        propertyLabel.frame = CGRect(x: 12, y: 12, width: 36, height: 16)
        lineWidthPopup.frame = CGRect(x: 46, y: 7, width: 76, height: 27)
        textSizePopup.frame = lineWidthPopup.frame
        mosaicSlider.frame = CGRect(x: 58, y: 10, width: 226, height: 22)
        optionsButton.frame = CGRect(x: tool == .mosaic ? 291 : 350, y: 5, width: 30, height: 30)
        if let selection = document.selection ?? hoverRegion {
            let rect = displayRect(selection)
            let x = min(bounds.maxX - toolbarWidth - 8, max(8, rect.maxX - toolbarWidth))
            let totalHeight: CGFloat = propertiesBar.isHidden ? 40 : 86
            let below = rect.maxY + totalHeight + 8 <= bounds.maxY - 8
            let above = rect.minY - totalHeight - 8 >= 8
            let y = below ? rect.maxY + 8 : above ? rect.minY - 48 : bounds.maxY - totalHeight - 8
            toolbar.frame = CGRect(x: x, y: max(8, y), width: toolbarWidth, height: 40)
            let propertyWidth: CGFloat = min(tool == .mosaic ? 330 : 388, bounds.width - 16)
            propertiesBar.frame = CGRect(x: min(bounds.maxX - propertyWidth - 8, max(8, toolbar.frame.minX)),
                y: above && !below ? toolbar.frame.minY - 46 : toolbar.frame.maxY + 6,
                width: min(propertyWidth, bounds.width - 16), height: 40)
            propertiesBar.frame.origin.y = min(bounds.maxY - 48, max(8, propertiesBar.frame.minY))
            optionsButton.frame.origin.x = min(optionsButton.frame.minX, propertiesBar.frame.width - 36)
            sizeField.frame = CGRect(x: min(bounds.maxX - 228, max(8, rect.minX)), y: max(8, rect.minY - 26), width: 220, height: 21)
        }
        let hintWidth = min(bounds.width - 32, 600)
        hintField.frame = CGRect(x: (bounds.width - hintWidth) / 2, y: bounds.maxY - 36, width: hintWidth, height: 24)
        hintField.isHidden = document.selection != nil && textEditor == nil && tool != .polyline && tool != .magnify && tool != .inpaint
        if !toolbar.isHidden && hintField.frame.intersects(toolbar.frame) { hintField.isHidden = true }
        if document.selection == nil, let pointer, hintField.frame.intersects(loupeFrame(at: pointer)) { hintField.isHidden = true }
    }

    private func updateUI() {
        toolbar.isHidden = document.selection == nil || selecting || moving || dragHandle != nil
        propertiesBar.isHidden = toolbar.isHidden || tool == nil
        sizeField.isHidden = document.selection == nil && hoverRegion == nil
        if let selection = document.selection ?? hoverRegion { sizeField.stringValue = "\(Int(selection.minX)), \(Int(selection.minY))  \(Int(selection.integral.width)) × \(Int(selection.integral.height))" }
        for (index, button) in toolButtons.enumerated() {
            let selected = tools[index] == tool
            button.layer?.backgroundColor = selected ? NSColor.systemBlue.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
            button.contentTintColor = selected ? .systemBlue : NSColor(calibratedWhite: 0.2, alpha: 1)
            button.setAccessibilityValue(selected ? 1 : 0)
        }
        for (i, button) in colorButtons.enumerated() {
            let selected = colors[i].usingColorSpace(.sRGB) == preferences.color.usingColorSpace(.sRGB)
            button.layer?.borderWidth = selected ? 1 : 0
            button.layer?.borderColor = NSColor.darkGray.cgColor
        }
        undoButton.isEnabled = document.canUndo; redoButton.isEnabled = document.canRedo
        textSizePopup.isHidden = ![ImageEditTool.text, .watermark].contains(tool ?? .crop)
        lineWidthPopup.isHidden = tool == .text || tool == .watermark || tool == .mosaic
        mosaicSlider.isHidden = tool != .mosaic
        colorButtons.forEach { $0.isHidden = tool == .mosaic }
        propertyLabel.stringValue = tool == .text || tool == .watermark ? CaptureLocalization.text("字号", "Size") : tool == .mosaic ? CaptureLocalization.text("强度", "Level") : CaptureLocalization.text("粗细", "Width")
        mosaicSlider.doubleValue = mosaicStrength
        let widthTitle = "\(Int(preferences.lineWidth)) px"
        if lineWidthPopup.item(withTitle: widthTitle) == nil { lineWidthPopup.addItem(withTitle: widthTitle) }
        lineWidthPopup.selectItem(withTitle: widthTitle)
        let fontTitle = "\(Int(preferences.textSize))"
        if textSizePopup.item(withTitle: fontTitle) == nil { textSizePopup.addItem(withTitle: fontTitle) }
        textSizePopup.selectItem(withTitle: fontTitle)
        if document.selection == nil {
            hintField.stringValue = windowRegions.isEmpty
                ? CaptureLocalization.text("拖动框选截图区域 · ⌘A 全选当前屏幕 · Esc 取消", "Drag to select · ⌘A Select this display · Esc Cancel")
                : CaptureLocalization.text("移动鼠标选择窗口 · 单击确认 / 拖动框选 · Esc 取消", "Hover to select a window · Click to confirm / Drag a region · Esc Cancel")
        } else if textEditor != nil {
            hintField.stringValue = CaptureLocalization.text("输入文字 · ⌘Enter 完成文字 · Esc 取消当前文字", "Type text · ⌘Return Commit text · Esc Discard text")
        } else if tool == .polyline {
            hintField.stringValue = "逐点单击 · 双击 / Enter 完成折线 · Shift 对齐 · Delete 删除节点"
        } else if tool == .magnify {
            hintField.stringValue = "拖框采样 · 拖动镜片移动 · Control 拖动采样框 · 样式调整倍率与连接"
        } else if tool == .inpaint {
            hintField.stringValue = "本地修复擦除 · 适合平滑背景 · 选择较小区域以保留周围参考像素"
        } else if tool == .text {
            hintField.stringValue = CaptureLocalization.text("点击选区输入文字 · ⌘Z 撤销 · Enter 复制 · Esc 取消", "Click to add text · ⌘Z Undo · Return Copy · Esc Cancel")
        } else if tool == nil {
            hintField.stringValue = CaptureLocalization.text("拖动选区或控制点调整 · 方向键移动 / Shift 缩小 / Ctrl 扩大 · Enter 复制 · Esc 取消", "Drag selection or handles · Arrows Move / Shift Shrink / Ctrl Expand · Return Copy · Esc Cancel")
        } else {
            hintField.stringValue = CaptureLocalization.text("拖动标注 · Shift 约束形状/箭头 · ⌘Z 撤销 · V 调整选区 · Enter 复制", "Drag to annotate · Shift Constrain · ⌘Z Undo · V Adjust region · Return Copy")
        }
        positionControls()
        if let redactionMessage { hintField.stringValue = redactionMessage; hintField.isHidden = false }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    func reset() {
        discardRedaction(); discardText(); document.resetSelection(); pending = nil; tool = nil
        selecting = false; moving = false; dragHandle = nil; dragStart = nil
        effectPreview = nil; polylineNodes.removeAll(); copyingObject = false; optionsPopover?.close()
        windowClickCandidate = nil; hoverRegion = nil; selectedStroke = nil; editingPreview = nil; originalStroke = nil
        updateUI()
    }
    func showError(_ error: Error) { updateUI(); hintField.stringValue = error.localizedDescription; hintField.isHidden = false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self)
        if let tracking { addTrackingArea(tracking) }
    }
    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        if document.selection == nil, !selecting {
            let point = imagePoint(pointer!)
            hoverRegion = windowRegions.first { $0.contains(point) }
            updateUI()
        } else {
            if tool == .polyline, !polylineNodes.isEmpty, let pointer {
                let point = constrainedPoint(imagePoint(pointer), from: polylineNodes.last!, flags: event.modifierFlags)
                var stroke = makeStroke(.polyline, at: polylineNodes[0]); stroke.points = polylineNodes + [point]; pending = stroke
            }
            needsDisplay = true
        }
    }
    override func resetCursorRects() {
        addCursorRect(imageRect, cursor: .crosshair)
        if let selection = document.selection {
            let rect = displayRect(selection)
            if tool == nil { addCursorRect(rect, cursor: .openHand) }
            if tool == .text { addCursorRect(rect, cursor: .iBeam) }
            addCursorRect(CGRect(x: rect.minX - 5, y: rect.minY, width: 10, height: rect.height), cursor: .resizeLeftRight)
            addCursorRect(CGRect(x: rect.maxX - 5, y: rect.minY, width: 10, height: rect.height), cursor: .resizeLeftRight)
            addCursorRect(CGRect(x: rect.minX, y: rect.minY - 5, width: rect.width, height: 10), cursor: .resizeUpDown)
            addCursorRect(CGRect(x: rect.minX, y: rect.maxY - 5, width: rect.width, height: 10), cursor: .resizeUpDown)
            for (handle, point) in CaptureSelectionGeometry.handles(for: rect) {
                let cursor: NSCursor = [.top, .bottom].contains(handle) ? .resizeUpDown : [.left, .right].contains(handle) ? .resizeLeftRight : .crosshair
                addCursorRect(CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12), cursor: cursor)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        defer { drawLoupe() }
        NSColor(calibratedWhite: 0.06, alpha: 1).setFill(); bounds.fill()
        drawImage(document.source, in: imageRect)
        NSColor.black.withAlphaComponent(0.36).setFill(); bounds.fill()
        guard let selection = document.selection ?? hoverRegion, let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = displayRect(selection)
        context.saveGState(); context.clip(to: rect)
        drawImage(editingPreview ?? effectPreview ?? document.renderedImage, in: imageRect)
        if let (image, area) = mosaicPreview { drawImage(image, in: displayRect(area)) }
        if let pending, !pending.tool.isPixelEffect, originalStroke == nil {
            context.saveGState()
            context.translateBy(x: imageRect.minX, y: imageRect.minY)
            context.scaleBy(x: scaleX, y: scaleY)
            context.translateBy(x: 0, y: imageBounds.height); context.scaleBy(x: 1, y: -1)
            ImageEditingOperations.draw(pending, in: context, imageHeight: imageBounds.height, imageWidth: imageBounds.width)
            context.restoreGState()
        }
        context.restoreGState()
        for candidate in redactionCandidates {
            let outline = NSBezierPath(rect: displayRect(candidate.rect)); outline.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.systemOrange.setStroke(); outline.lineWidth = 1.5; outline.stroke()
        }
        drawObjectSelection()
        NSColor.systemBlue.setStroke()
        let outline = NSBezierPath(rect: rect); outline.lineWidth = 1.5; outline.stroke()
        for (_, point) in document.selection == nil ? [] : CaptureSelectionGeometry.handles(for: rect) {
            let handle = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
            NSColor.systemBlue.setFill(); NSBezierPath(ovalIn: handle).fill()
            NSColor.white.setStroke(); NSBezierPath(ovalIn: handle).stroke()
        }
    }
    private func drawImage(_ image: CGImage, in rect: CGRect) {
        NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
            .draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func mouseDown(with event: NSEvent) {
        if !redactionCandidates.isEmpty { return }
        let local = convert(event.locationInWindow, from: nil)
        pointer = local
        let hitHandle = document.selection.flatMap { selectionHandle(at: local, rect: displayRect($0)) }
        guard imageRect.contains(local) || hitHandle != nil else { return }
        guard commitText() else { return }
        window?.makeKey(); window?.makeFirstResponder(self)
        let point = imagePoint(local)
        if document.selection == nil, let candidate = windowRegions.first(where: { $0.contains(point) }) {
            onBeginSelection?()
            document.setSelection(candidate); windowClickCandidate = candidate; hoverRegion = nil
            dragStart = point; tool = nil; updateUI(); return
        }
        if let selection = document.selection {
            if tool == .polyline, !polylineNodes.isEmpty {
                let next = constrainedPoint(point, from: polylineNodes.last!, flags: event.modifierFlags)
                if hypot(next.x - polylineNodes.last!.x, next.y - polylineNodes.last!.y) > 0.5 { polylineNodes.append(next) }
                if event.clickCount >= 2 { _ = finishPolyline() }
                else { var stroke = makeStroke(.polyline, at: polylineNodes[0]); stroke.points = polylineNodes; pending = stroke; needsDisplay = true }
                return
            }
            if let index = selectedStroke, document.strokes.indices.contains(index), document.strokes[index].tool == .magnify,
               event.modifierFlags.contains(.control), ImageEditingOperations.magnifierSourceRect(for: document.strokes[index]).contains(point) {
                originalStroke = document.strokes[index]; movingMagnifierSource = true; objectHandle = nil; dragStart = point; return
            }
            if let index = selectedStroke, document.strokes.indices.contains(index), let tool,
               document.strokes[index].tool == tool,
               let handle = objectHandles(for: document.strokes[index]).enumerated().first(where: { hypot($0.element.x - local.x, $0.element.y - local.y) <= 8 }) {
                originalStroke = document.strokes[index]; objectHandle = handle.offset; dragStart = point
                updateUI(); return
            }
            if selection.contains(point), let tool,
               let index = document.strokes.indices.reversed().first(where: { document.strokes[$0].tool == tool && CaptureAnnotationGeometry.hitTest(document.strokes[$0], at: point, tolerance: 6 / scaleX) }) {
                selectedStroke = index; syncStyle(document.strokes[index])
                if tool == .text && event.clickCount >= 2 { beginText(at: document.strokes[index].points[0], editing: index); return }
                originalStroke = document.strokes[index]; objectHandle = nil; dragStart = point; copyingObject = event.modifierFlags.contains(.option)
                updateUI(); return
            }
            selectedStroke = nil
            if event.clickCount == 2, tool == nil, displayRect(selection).contains(local) { copyCapture(); return }
            dragHandle = hitHandle
            if dragHandle != nil || tool == nil && selection.contains(point) {
                originalSelection = selection; dragStart = point; moving = dragHandle == nil
                updateUI(); return
            }
            if selection.contains(point), let tool {
                if tool == .text { beginText(at: point); return }
                pending = makeStroke(tool, at: point)
                if tool == .polyline { polylineNodes = [point] }
                needsDisplay = true; return
            }
        }
        onBeginSelection?()
        document.resetSelection(); tool = nil; dragStart = point; selecting = true
        document.setSelection(CGRect(origin: point, size: CGSize(width: 2, height: 2)))
        updateUI()
    }

    override func mouseDragged(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        var point = imagePoint(pointer!)
        if let originalStroke, let start = dragStart, let index = selectedStroke {
            var changed = originalStroke
            let delta = CGSize(width: point.x - start.x, height: point.y - start.y)
            if movingMagnifierSource {
                changed.style.magnifierSourceRect = CaptureSelectionGeometry.moved(ImageEditingOperations.magnifierSourceRect(for: originalStroke), by: delta, within: document.selection ?? imageBounds)
            } else if let objectHandle {
                let transform = ImageEditingOperations.rotationTransform(for: originalStroke)
                point = point.applying(transform.inverted())
                let localStart = start.applying(transform.inverted())
                let localDelta = CGSize(width: point.x - localStart.x, height: point.y - localStart.y)
                if [.arrow, .line, .polyline, .number].contains(changed.tool) {
                    let area = document.selection ?? imageBounds
                    point = CGPoint(x: min(area.maxX, max(area.minX, point.x)), y: min(area.maxY, max(area.minY, point.y)))
                    let endpoint = changed.tool == .polyline ? min(objectHandle, changed.points.count - 1) : objectHandle == 0 ? 0 : changed.points.count - 1
                    if event.modifierFlags.contains(.shift) {
                        let anchor = changed.points[endpoint == 0 ? min(1, changed.points.count - 1) : endpoint - 1]
                        let angle = (atan2(point.y - anchor.y, point.x - anchor.x) / (.pi / 4)).rounded() * (.pi / 4)
                        let length = hypot(point.x - anchor.x, point.y - anchor.y)
                        point = CGPoint(x: min(area.maxX, max(area.minX, anchor.x + length * cos(angle))),
                                        y: min(area.maxY, max(area.minY, anchor.y + length * sin(angle))))
                    }
                    changed.points[endpoint] = point
                } else if changed.tool == .magnify {
                    let source = ImageEditingOperations.magnifierSourceRect(for: changed)
                    let center = CGPoint(x: changed.rect.midX, y: changed.rect.midY)
                    changed.style.magnification = min(8, max(1, max(abs(point.x - center.x) * 2 / max(1, source.width), abs(point.y - center.y) * 2 / max(1, source.height))))
                } else {
                    let handles: [CaptureSelectionHandle] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
                    let rect = CaptureSelectionGeometry.resized(originalStroke.rect, handle: handles[objectHandle], by: localDelta, within: imageBounds.applying(transform.inverted()))
                    changed.points = [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)]
                }
                if changed.style.rotation != 0 {
                    let box = ImageEditingOperations.unrotatedBounds(for: changed), center = CGPoint(x: box.midX, y: box.midY)
                    let mapped = center.applying(transform)
                    changed.points = changed.points.map { CGPoint(x: $0.x + mapped.x - center.x, y: $0.y + mapped.y - center.y) }
                    changed = CaptureAnnotationGeometry.moved(changed, by: .zero, within: document.selection ?? imageBounds)
                }
            } else { changed = CaptureAnnotationGeometry.moved(changed, by: delta, within: document.selection ?? imageBounds) }
            pending = changed
            editingPreview = copyingObject ? try? ImageEditingOperations.apply(changed, to: document.renderedImage, source: document.source) : try? document.preview(replacing: index, with: changed)
            needsDisplay = true; return
        }
        if let start = dragStart {
            let delta = CGSize(width: point.x - start.x, height: point.y - start.y)
            if windowClickCandidate != nil {
                if hypot(delta.width * scaleX, delta.height * scaleY) < 3 { return }
                windowClickCandidate = nil; selecting = true
            }
            if let originalSelection, let dragHandle {
                var resized = CaptureSelectionGeometry.resized(originalSelection, handle: dragHandle, by: delta, within: imageBounds)
                if event.modifierFlags.contains(.shift), [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(dragHandle) {
                    let side = min(resized.width, resized.height)
                    if [.topLeft, .bottomLeft].contains(dragHandle) { resized.origin.x = resized.maxX - side }
                    if [.topLeft, .topRight].contains(dragHandle) { resized.origin.y = resized.maxY - side }
                    resized.size = CGSize(width: side, height: side)
                }
                document.setSelection(CaptureSelectionSizing.constrained(resized, ratio: lockedAspectRatio, in: imageBounds))
            } else if moving, let originalSelection {
                document.setSelection(CaptureSelectionGeometry.moved(originalSelection, by: delta, within: imageBounds))
            } else if selecting {
                if event.modifierFlags.contains(.shift) {
                    let side = min(abs(delta.width), abs(delta.height))
                    point = CGPoint(x: start.x + (delta.width < 0 ? -side : side), y: start.y + (delta.height < 0 ? -side : side))
                }
                document.setSelection(CaptureSelectionSizing.constrained(CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y)), ratio: lockedAspectRatio, in: imageBounds))
            }
            updateUI(); return
        }
        if !polylineNodes.isEmpty { return }
        guard var stroke = pending, let first = stroke.points.first, let selection = document.selection else { return }
        point.x = min(selection.maxX, max(selection.minX, point.x)); point.y = min(selection.maxY, max(selection.minY, point.y))
        if event.modifierFlags.contains(.shift) {
            if [.rectangle, .ellipse].contains(stroke.tool) {
                let side = min(abs(point.x - first.x), abs(point.y - first.y))
                point = CGPoint(x: first.x + (point.x < first.x ? -side : side), y: first.y + (point.y < first.y ? -side : side))
            } else if [.arrow, .line, .number].contains(stroke.tool) {
                let angle = (atan2(point.y - first.y, point.x - first.x) / (.pi / 4)).rounded() * (.pi / 4)
                let length = hypot(point.x - first.x, point.y - first.y)
                point = CGPoint(x: min(selection.maxX, max(selection.minX, first.x + length * cos(angle))),
                                y: min(selection.maxY, max(selection.minY, first.y + length * sin(angle))))
            }
        }
        if usesBrush(stroke) { stroke.points.append(point) }
        else { stroke.points = [first, point] }
        if stroke.tool == .magnify { stroke.style.magnifierSourceRect = stroke.rect }
        pending = stroke
        if stroke.tool.isPixelEffect { updateEffectPreview(stroke) }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if !polylineNodes.isEmpty { return }
        mouseDragged(with: event)
        if originalStroke != nil {
            if let pending, let index = selectedStroke,
               let start = dragStart, hypot(imagePoint(convert(event.locationInWindow, from: nil)).x - start.x, imagePoint(convert(event.locationInWindow, from: nil)).y - start.y) > 0.5 {
                let arrowTooShort = pending.tool == .arrow && hypot(pending.points.last!.x - pending.points.first!.x, pending.points.last!.y - pending.points.first!.y) < 2
                if !arrowTooShort {
                    do {
                        if copyingObject { try document.append(pending); selectedStroke = document.strokes.count - 1 }
                        else { try document.replace(at: index, with: pending) }
                    } catch { showError(error) }
                }
            }
            originalStroke = nil; objectHandle = nil; pending = nil; editingPreview = nil; dragStart = nil; copyingObject = false; movingMagnifierSource = false
            updateUI(); return
        }
        dragStart = nil; originalSelection = nil; moving = false; dragHandle = nil; selecting = false; windowClickCandidate = nil
        var failure: Error?
        defer {
            pending = nil; mosaicPreview = nil; effectPreview = nil; effectPreviewRequested = nil; effectPreviewGeneration += 1; updateUI()
            runInitialAction()
            if let failure { showError(failure) }
        }
        guard let pending else { return }
        if requiresArea(pending), pending.rect.width < 2 || pending.rect.height < 2 { return }
        if [.arrow, .line].contains(pending.tool), let first = pending.points.first, let last = pending.points.last, hypot(last.x - first.x, last.y - first.y) < 2 { return }
        do {
            try document.append(pending)
            if !usesBrush(pending) { selectedStroke = document.strokes.count - 1 }
            if pending.tool == .number { preferences.number = min(999, preferences.number + 1) }
        } catch { failure = error }
    }
    override func rightMouseDown(with event: NSEvent) {
        if redactionTask != nil || !redactionCandidates.isEmpty { discardRedaction(); updateUI() }
        else if !polylineNodes.isEmpty { _ = finishPolyline() }
        else if textEditor != nil { discardText(); updateUI() }
        else if selectedStroke != nil { selectedStroke = nil; updateUI() }
        else if tool != nil { tool = nil; pending = nil; updateUI() }
        else if document.selection != nil { reset() }
        else { cancel() }
    }

    private func updateEffectPreview(_ stroke: ImageEditStroke) {
        effectPreviewGeneration += 1; effectPreviewRequested = stroke
        renderNextEffectPreview()
    }
    private func renderNextEffectPreview() {
        guard !effectPreviewRunning, let stroke = effectPreviewRequested else { return }
        effectPreviewRequested = nil; effectPreviewRunning = true
        let revision = effectPreviewGeneration, image = document.renderedImage, source = document.source
        // Only one worker runs. Fast pointer updates replace the next request instead of queuing bitmaps.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = try? ImageEditingOperations.apply(stroke, to: image, source: source)
            DispatchQueue.main.async {
                guard let self else { return }
                self.effectPreviewRunning = false
                if self.pending?.tool == stroke.tool, self.originalStroke == nil, self.effectPreviewGeneration == revision {
                    self.effectPreview = result; self.needsDisplay = true
                }
                if self.pending != nil { self.renderNextEffectPreview() } else { self.effectPreviewRequested = nil }
            }
        }
    }

    @objc private func workflowAction(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let action = CaptureWorkflowAction(rawValue: id) else { return }
        performAction(action)
    }
    private func performAction(_ action: CaptureWorkflowAction) {
        guard commitRedaction(), finishPolyline(), commitText(), let selection = document.selection else { return }
        do { let data = try document.export(); CaptureSelectionMemory.remember(selection, in: imageBounds); onAction?(action, data, selection) } catch { showError(error) }
    }
    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        if let action = CaptureWorkflowAction(rawValue: value) { performAction(action) }
        else if value == "clear" { clearAnnotations() }
        else if value == "matchingMosaic" { findMatchingMosaics() }
        else if value == "customize" { customizeToolbar() }
        else if value == "quickSave" { quickSave() }
        else if value == "selection", let selection = document.selection {
            CaptureSelectionOptions.shared.show(relativeTo: toolbar, selection: selection, bounds: imageBounds, ratio: lockedAspectRatio) { [weak self] rect, ratio in
                self?.lockedAspectRatio = ratio; self?.document.setSelection(rect); self?.updateUI()
            }
        }
        else if let chosen = ImageEditTool(rawValue: value) { selectTool(chosen) }
    }
    @objc private func showMore(_ sender: NSButton) {
        let menu = NSMenu()
        for item in ImageEditTool.allCases where item != .crop && !tools.contains(where: { $0 == item }) {
            let entry = NSMenuItem(title: item.title, action: #selector(menuAction(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = item.rawValue; entry.state = tool == item ? .on : .off
            entry.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.title)
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let customize = NSMenuItem(title: "自定义常用工具…", action: #selector(menuAction(_:)), keyEquivalent: "")
        customize.target = self; customize.representedObject = "customize"; menu.addItem(customize)
        let matching = NSMenuItem(title: "给相同文字添加马赛克…", action: #selector(menuAction(_:)), keyEquivalent: "")
        matching.target = self; matching.representedObject = "matchingMosaic"
        matching.isEnabled = selectedStroke.map { document.strokes.indices.contains($0) && document.strokes[$0].tool == .mosaic && document.strokes[$0].style.effectShape == .rectangle } ?? false
        menu.addItem(matching)
        let size = NSMenuItem(title: "选区尺寸 / 比例", action: #selector(menuAction(_:)), keyEquivalent: "")
        size.target = self; size.representedObject = "selection"; menu.addItem(size)
        let clear = NSMenuItem(title: "清空标注（可撤销）", action: #selector(menuAction(_:)), keyEquivalent: "")
        clear.target = self; clear.representedObject = "clear"; clear.isEnabled = !document.strokes.isEmpty; menu.addItem(clear)
        menu.addItem(.separator())
        let quick = NSMenuItem(title: CaptureLocalization.text("快速保存", "Quick save"), action: #selector(menuAction(_:)), keyEquivalent: "")
        quick.target = self; quick.representedObject = "quickSave"; menu.addItem(quick)
        for action in [CaptureWorkflowAction.translate, .formula, .table, .barcode] {
            let entry = NSMenuItem(title: action.title, action: #selector(menuAction(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = action.rawValue; menu.addItem(entry)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }

    @objc private func chooseTool(_ sender: NSButton) {
        selectTool(tools[sender.tag])
    }
    @objc private func chooseColor(_ sender: NSButton) {
        let color = (colors[sender.tag].usingColorSpace(.sRGB) ?? .red).withAlphaComponent(preferences.alpha)
        preferences.red = color.redComponent; preferences.green = color.greenComponent; preferences.blue = color.blueComponent
        preferences.save()
        if var style = textStyle { style.color = color; textStyle = style; textEditor?.textColor = color }
        if textEditor == nil {
            modifySelected { $0.color = color }
            window?.makeFirstResponder(self)
        }
        updateUI()
    }
    @objc private func changeWidth() {
        preferences.lineWidth = Double(lineWidthPopup.titleOfSelectedItem?.components(separatedBy: " ").first ?? "4") ?? 4
        preferences.save(); modifySelected { $0.width = preferences.lineWidth }; updateUI(); window?.makeFirstResponder(self)
    }
    @objc private func changeTextSize() {
        preferences.textSize = Double(textSizePopup.titleOfSelectedItem ?? "24") ?? 24; preferences.save()
        if var style = textStyle { style.fontSize = preferences.textSize; textStyle = style; updateTextAttributes(); resizeTextEditor() }
        if textEditor == nil { modifySelected { $0.fontSize = preferences.textSize }; window?.makeFirstResponder(self) }
        updateUI()
    }
    @objc private func changeMosaicStrength() {
        mosaicStrength = CGFloat(mosaicSlider.doubleValue.rounded())
        var style = currentStyle(for: .mosaic); style.effectStrength = mosaicStrength; styles[.mosaic] = style
        modifySelected { $0.style.effectStrength = mosaicStrength; $0.width = mosaicStrength }; updateUI(); window?.makeFirstResponder(self)
    }
    @objc private func undo() {
        discardRedaction()
        if !polylineNodes.isEmpty { polylineNodes.removeLast(); pending?.points = polylineNodes; if polylineNodes.isEmpty { pending = nil }; updateUI(); return }
        guard commitText() else { return }
        selectedStroke = nil; document.undo(); updateUI()
        if let error = document.failure { showError(error) }
    }
    @objc private func redo() {
        discardRedaction()
        guard commitText() else { return }
        selectedStroke = nil; document.redo(); updateUI()
        if let error = document.failure { showError(error) }
    }
    @objc private func copyCapture() { output(saving: false) }
    @objc private func save() { output(saving: true) }
    @objc private func quickSave() { output(saving: true, quick: true) }
    @objc private func cancel() { discardRedaction(); optionsPopover?.close(); CaptureSelectionOptions.shared.close(); discardText(); onCancel?() }
    private func output(saving: Bool, quick: Bool = false) {
        guard commitRedaction(), finishPolyline(), commitText() else { return }
        guard document.selection != nil else { return }
        do {
            let data = try document.export()
            if let selection = document.selection { CaptureSelectionMemory.remember(selection, in: imageBounds) }
            if saving { (quick ? onQuickSave : onSave)?(data) } else { onCopy?(data) }
        } catch { showError(error) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Native text editing owns copy/select-all/undo while entering text, including an IME composition.
        if textEditor != nil { return super.performKeyEquivalent(with: event) }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": copyCapture(); return true
            case "p": performAction(.pin); return true
            case "s": event.modifierFlags.contains(.shift) ? quickSave() : save(); return true
            case "z": event.modifierFlags.contains(.shift) ? redo() : undo(); return true
            case "a": onBeginSelection?(); document.setSelection(imageBounds); tool = nil; selectedStroke = nil; updateUI(); runInitialAction(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            if redactionTask != nil || !redactionCandidates.isEmpty { discardRedaction(); updateUI(); return }
            if !polylineNodes.isEmpty || pending != nil { polylineNodes.removeAll(); pending = nil; effectPreview = nil; updateUI() }
            else { cancel() }; return
        }
        if event.keyCode == 36 || event.keyCode == 76 { if !redactionCandidates.isEmpty { _ = commitRedaction() } else if !polylineNodes.isEmpty { _ = finishPolyline() } else { copyCapture() }; return }
        if event.keyCode == 51 || event.keyCode == 117 {
            if !polylineNodes.isEmpty { undo(); return }
            if let index = selectedStroke { do { try document.remove(at: index); selectedStroke = nil; updateUI() } catch { showError(error) } }
            return
        }
        if event.charactersIgnoringModifiers?.lowercased() == "q", document.selection != nil {
            performAction(event.modifierFlags.contains(.shift) ? .table : .ocr); return
        }
        if event.charactersIgnoringModifiers?.lowercased() == "f", event.modifierFlags.contains(.shift), document.selection != nil { performAction(.formula); return }
        if event.charactersIgnoringModifiers?.lowercased() == "c", document.selection == nil { copyPixelColor(); return }
        if document.selection == nil, event.keyCode == 18, event.modifierFlags.contains(.shift), let remembered = CaptureSelectionMemory.items(in: imageBounds).first {
            onBeginSelection?(); document.setSelection(remembered.rect); updateUI(); runInitialAction(); return
        }
        if event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.command) {
            let pixpinTools: [UInt16: ImageEditTool] = [18: .rectangle, 20: .arrow, 21: .number, 23: .pen, 22: .highlight, 26: .mosaic, 28: .text]
            if let item = pixpinTools[event.keyCode] { selectTool(item); return }
        }
        if let index = shortcuts.firstIndex(of: event.charactersIgnoringModifiers?.lowercased() ?? ""), !event.modifierFlags.contains(.command) {
            selectTool(keyboardTools[index]); return
        }
        if let selection = document.selection, [123, 124, 125, 126].contains(event.keyCode) {
            var delta = CGSize.zero
            if event.keyCode == 123 { delta.width = -1 }
            if event.keyCode == 124 { delta.width = 1 }
            if event.keyCode == 125 { delta.height = 1 }
            if event.keyCode == 126 { delta.height = -1 }
            if let index = selectedStroke {
                do { try document.replace(at: index, with: CaptureAnnotationGeometry.moved(document.strokes[index], by: delta, within: selection)) } catch { showError(error) }
            } else if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.control) {
                let expand = event.modifierFlags.contains(.control)
                let handle: CaptureSelectionHandle = event.keyCode == 123 ? .left : event.keyCode == 124 ? .right : event.keyCode == 125 ? .bottom : .top
                if !expand { delta.width *= -1; delta.height *= -1 }
                document.setSelection(CaptureSelectionSizing.constrained(CaptureSelectionGeometry.resized(selection, handle: handle, by: delta, within: imageBounds), ratio: lockedAspectRatio, in: imageBounds))
            } else { document.setSelection(CaptureSelectionGeometry.moved(selection, by: delta, within: imageBounds)) }
            updateUI(); return
        }
        super.keyDown(with: event)
    }

    private func selectionHandle(at point: CGPoint, rect: CGRect) -> CaptureSelectionHandle? {
        if let corner = CaptureSelectionGeometry.handles(for: rect).first(where: { abs($0.1.x - point.x) <= 7 && abs($0.1.y - point.y) <= 7 }) { return corner.0 }
        guard rect.insetBy(dx: -6, dy: -6).contains(point) else { return nil }
        if abs(point.x - rect.minX) <= 6 { return .left }
        if abs(point.x - rect.maxX) <= 6 { return .right }
        if abs(point.y - rect.minY) <= 6 { return .top }
        if abs(point.y - rect.maxY) <= 6 { return .bottom }
        return nil
    }

    private func objectHandles(for stroke: ImageEditStroke) -> [CGPoint] {
        let points: [CGPoint]
        if [.arrow, .line, .number].contains(stroke.tool), stroke.points.count >= 2 { points = [stroke.points.first!, stroke.points.last!] }
        else if stroke.tool == .polyline { points = stroke.points }
        else if requiresArea(stroke) {
            let rect = stroke.tool == .magnify ? ImageEditingOperations.magnifierDestinationRect(for: stroke) : stroke.rect
            points = [rect.origin, CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        } else { points = [] }
        let transform = ImageEditingOperations.rotationTransform(for: stroke)
        return points.map { displayRect(CGRect(origin: $0.applying(transform), size: .zero)).origin }
    }

    private func drawObjectSelection() {
        guard textEditor == nil, let index = selectedStroke, document.strokes.indices.contains(index) else { return }
        let stroke = originalStroke != nil ? pending ?? document.strokes[index] : document.strokes[index]
        if stroke.tool == .magnify {
            let source = NSBezierPath(rect: displayRect(ImageEditingOperations.magnifierSourceRect(for: stroke)))
            source.setLineDash([4, 3], count: 2, phase: 0); NSColor.systemOrange.setStroke(); source.stroke()
        }
        let rect = displayRect(CaptureAnnotationGeometry.bounds(of: stroke)).insetBy(dx: -3, dy: -3)
        let outline = NSBezierPath(rect: rect)
        outline.setLineDash([3, 3], count: 2, phase: 0); outline.lineWidth = 1
        NSColor.systemBlue.setStroke(); outline.stroke()
        for point in objectHandles(for: stroke) {
            let circle = NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
            NSColor.white.setFill(); circle.fill(); NSColor.systemBlue.setStroke(); circle.stroke()
        }
    }

    private func syncStyle(_ stroke: ImageEditStroke) {
        let color = stroke.color.usingColorSpace(.sRGB) ?? .red
        preferences.red = color.redComponent; preferences.green = color.greenComponent; preferences.blue = color.blueComponent; preferences.alpha = color.alphaComponent
        styles[stroke.tool] = stroke.style
        if stroke.tool == .mosaic { mosaicStrength = stroke.style.effectStrength ?? stroke.width }
        else { preferences.lineWidth = stroke.width }
        if let size = stroke.fontSize { preferences.textSize = size }
    }

    private func modifySelected(_ edit: (inout ImageEditStroke) -> Void) {
        discardRedaction()
        guard let index = selectedStroke, document.strokes.indices.contains(index) else { return }
        var stroke = document.strokes[index]; edit(&stroke)
        do { try document.replace(at: index, with: stroke) } catch { showError(error) }
    }

    private func discardRedaction() {
        redactionTask?.cancel(); redactionTask = nil; redactionCandidates.removeAll(); redactionRevision = nil; redactionMessage = nil
        if textEditor == nil && originalStroke == nil { editingPreview = nil }
    }
    private func findMatchingMosaics() {
        guard commitText(), let index = selectedStroke, document.strokes.indices.contains(index), let selection = document.selection else { return }
        let template = document.strokes[index]
        guard template.tool == .mosaic, template.style.effectShape == .rectangle else { return }
        discardRedaction()
        let source = document.source, revision = document.revision
        redactionMessage = "正在本机查找相同文字… · Esc 取消"; updateUI()
        redactionTask = Task { [weak self] in
            do {
                let matches = try await CaptureRedaction.matches(source: source, sample: template.rect, selection: selection)
                try Task.checkCancellation()
                guard let self else { return }
                self.redactionTask = nil
                guard self.document.revision == revision, self.document.selection == selection else {
                    self.redactionMessage = "选区或标注已改变，请重新查找相同文字。"; self.updateUI(); return
                }
                if matches.isEmpty { self.redactionMessage = "当前选区没有找到其他相同文字。"; self.updateUI(); return }
                let uncovered = matches.filter { match in
                    !self.document.strokes.contains { $0.tool == .mosaic && $0.style.effectShape == .rectangle && $0.style.rotation == 0 && $0.rect.contains(match.rect) }
                }
                guard !uncovered.isEmpty else { self.redactionMessage = "其他相同文字已经位于马赛克区域内。"; self.updateUI(); return }
                let candidates = uncovered.map { match -> ImageEditStroke in
                    var stroke = template; stroke.points = [match.rect.origin, CGPoint(x: match.rect.maxX, y: match.rect.maxY)]; stroke.style.rotation = 0; return stroke
                }
                self.editingPreview = try self.document.preview(appending: candidates)
                self.redactionCandidates = candidates; self.redactionRevision = revision
                self.redactionMessage = "已预览另外 \(candidates.count) 处相同文字 · Enter 应用全部 · Esc 取消 · 请核对橙色区域"
                self.updateUI()
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.redactionTask = nil; self.redactionMessage = error.localizedDescription; self.updateUI()
            }
        }
    }
    @discardableResult private func commitRedaction() -> Bool {
        guard !redactionCandidates.isEmpty else { return true }
        guard redactionRevision == document.revision else { discardRedaction(); showError(CaptureMessage("标注已改变，请重新查找相同文字。", "Annotations changed. Search for matching text again.")); return false }
        do { try document.append(contentsOf: redactionCandidates); discardRedaction(); selectedStroke = nil; updateUI(); return true }
        catch { showError(error); return false }
    }

    private func currentStyle(for tool: ImageEditTool) -> ImageEditStyle {
        if let style = styles[tool] { return style }
        var style = ImageEditStyle()
        if tool == .pen || tool == .highlight || tool == .eraser { style.effectShape = .brush }
        if tool == .mosaic { style.effectStrength = mosaicStrength }
        if tool == .magnify { style.effectShape = .ellipse }
        return style
    }
    private func makeStroke(_ tool: ImageEditTool, at point: CGPoint) -> ImageEditStroke {
        let style = currentStyle(for: tool)
        return ImageEditStroke(tool: tool, points: [point], color: preferences.color,
            width: tool == .mosaic ? mosaicStrength : preferences.lineWidth,
            text: tool == .watermark ? resolvedWatermarkText(watermarkText) : [.number, .arrow].contains(tool) ? annotationText : "",
            fontSize: preferences.textSize, number: preferences.number, style: style)
    }
    private func resolvedWatermarkText(_ text: String) -> String {
        let now = Date(), date = DateFormatter(), time = DateFormatter()
        date.dateFormat = "yyyy-MM-dd"; time.dateFormat = "HH:mm:ss"
        return text.replacingOccurrences(of: "{date}", with: date.string(from: now)).replacingOccurrences(of: "{time}", with: time.string(from: now))
    }
    private func usesBrush(_ stroke: ImageEditStroke) -> Bool {
        stroke.tool == .pen || ([.highlight, .mosaic, .blur, .eraser, .inpaint, .spotlight].contains(stroke.tool) && stroke.style.effectShape == .brush)
    }
    private func requiresArea(_ stroke: ImageEditStroke) -> Bool {
        [.rectangle, .ellipse, .watermark, .magnify].contains(stroke.tool) || ([.mosaic, .blur, .eraser, .inpaint, .spotlight, .highlight].contains(stroke.tool) && !usesBrush(stroke))
    }
    private func constrainedPoint(_ point: CGPoint, from anchor: CGPoint, flags: NSEvent.ModifierFlags) -> CGPoint {
        let area = document.selection ?? imageBounds
        var point = CGPoint(x: min(area.maxX, max(area.minX, point.x)), y: min(area.maxY, max(area.minY, point.y)))
        if flags.contains(.shift) {
            let angle = (atan2(point.y - anchor.y, point.x - anchor.x) / (.pi / 4)).rounded() * (.pi / 4)
            let distance = hypot(point.x - anchor.x, point.y - anchor.y)
            point = CGPoint(x: min(area.maxX, max(area.minX, anchor.x + distance * cos(angle))), y: min(area.maxY, max(area.minY, anchor.y + distance * sin(angle))))
        }
        return point
    }
    @discardableResult private func finishPolyline() -> Bool {
        guard !polylineNodes.isEmpty else { return true }
        guard polylineNodes.count >= 2 else { polylineNodes.removeAll(); pending = nil; updateUI(); return true }
        var stroke = makeStroke(.polyline, at: polylineNodes[0]); stroke.points = polylineNodes
        do { try document.append(stroke); selectedStroke = document.strokes.count - 1 }
        catch { showError(error); return false }
        polylineNodes.removeAll(); pending = nil; updateUI(); return true
    }
    private func selectTool(_ chosen: ImageEditTool?) {
        discardRedaction()
        guard finishPolyline(), commitText() else { return }
        tool = chosen; selectedStroke = nil; pending = nil; mosaicPreview = nil; effectPreview = nil
        optionsPopover?.close(); window?.makeFirstResponder(self); updateUI()
    }
    private func runInitialAction() {
        guard let action = initialAction, let selection = document.selection, selection.width >= 2, selection.height >= 2 else { return }
        initialAction = nil
        performAction(action)
    }
    private func clearAnnotations() {
        discardRedaction()
        guard commitText() else { return }
        polylineNodes.removeAll(); pending = nil; effectPreview = nil
        do { try document.removeAll(); selectedStroke = nil; updateUI() } catch { showError(error) }
    }
    @objc private func showOptions(_ sender: NSButton) {
        guard let tool, finishPolyline(), commitText() else { return }
        var stroke = selectedStroke.flatMap { document.strokes.indices.contains($0) ? document.strokes[$0] : nil }
            ?? makeStroke(tool, at: document.selection?.origin ?? .zero)
        if selectedStroke == nil {
            if tool == .watermark { stroke.text = watermarkText }
            else if [.text, .arrow, .number].contains(tool) { stroke.text = annotationText }
        }
        let index = selectedStroke
        let popover = NSPopover(); popover.behavior = .semitransient; popover.appearance = NSAppearance(named: .aqua)
        popover.contentViewController = NSHostingController(rootView: CaptureAnnotationOptions(stroke: stroke, isExisting: index != nil, onApply: { [weak self, weak popover] updated in
            guard let self else { return }
            do {
                try ImageEditingOperations.validate(updated)
                var committed = updated
                if committed.style.wrapMode != .none && committed.style.wrapWidth == nil { committed.style.wrapWidth = 240 }
                if updated.tool == .watermark { self.watermarkText = updated.text; committed.text = self.resolvedWatermarkText(updated.text) }
                if [.text, .arrow, .number].contains(updated.tool) { self.annotationText = updated.text }
                if let index { try self.document.replace(at: index, with: committed) }
                self.syncStyle(committed)
                self.preferences.number = updated.number
                if let shape = self.styles[.magnify], shape.effectShape == .brush { var corrected = shape; corrected.effectShape = .ellipse; self.styles[.magnify] = corrected }
                self.preferences.save(); popover?.close(); self.window?.makeFirstResponder(self); self.updateUI()
            } catch { self.showError(error) }
        }, onDismiss: { [weak self, weak popover] in popover?.close(); self?.window?.makeFirstResponder(self) }))
        optionsPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: toolbar.frame.midY > bounds.midY ? .minY : .maxY)
    }
    private func updateTextAttributes() {
        guard let editor = textEditor, var stroke = textStyle else { return }
        stroke.fontSize = (stroke.fontSize ?? preferences.textSize) * scaleX
        stroke.style.outlineWidth *= scaleX
        let attributes = ImageEditingOperations.textAttributes(for: stroke)
        editor.typingAttributes = attributes
        editor.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: editor.string.utf16.count))
        editor.font = ImageEditingOperations.font(for: stroke); editor.textColor = stroke.color
        editor.insertionPointColor = stroke.color
        let wraps = stroke.style.wrapMode != .none
        editor.textContainer?.containerSize = CGSize(width: wraps ? (stroke.style.wrapWidth ?? 240) * scaleX : 100_000, height: 100_000)
        editor.isHorizontallyResizable = !wraps
        editor.drawsBackground = stroke.style.backgroundColor != nil
        editor.backgroundColor = stroke.style.backgroundColor ?? .clear
    }

    private func sampledColor() -> NSColor? {
        guard let pointer else { return nil }
        let point = imagePoint(pointer)
        return pixelSampler.colorAt(x: min(document.source.width - 1, max(0, Int(point.x))),
                                    y: min(document.source.height - 1, max(0, Int(point.y))))?.usingColorSpace(.sRGB)
    }

    private func colorValue(_ color: NSColor) -> String {
        let r = Int((color.redComponent * 255).rounded()), g = Int((color.greenComponent * 255).rounded()), b = Int((color.blueComponent * 255).rounded())
        return usesHexColor ? String(format: "#%02X%02X%02X", r, g, b) : "RGB: \(r), \(g), \(b)"
    }

    private func copyPixelColor() {
        guard let color = sampledColor() else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(colorValue(color), forType: .string)
        hintField.stringValue = CaptureLocalization.text("颜色已复制 · Shift 切换 RGB / HEX", "Color copied · Shift switches RGB / HEX")
        hintField.isHidden = false
    }

    override func flagsChanged(with event: NSEvent) {
        if document.selection == nil, event.modifierFlags.contains(.shift) { usesHexColor.toggle(); needsDisplay = true }
        super.flagsChanged(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard tool != nil, textEditor == nil, abs(event.scrollingDeltaY) > 0.1 else { super.scrollWheel(with: event); return }
        let step: CGFloat = event.scrollingDeltaY > 0 ? 1 : -1
        if tool == .text {
            preferences.textSize = min(144, max(12, preferences.textSize + step))
            modifySelected { $0.fontSize = preferences.textSize }
        } else if tool == .mosaic {
            mosaicStrength = min(32, max(3, mosaicStrength + step)); modifySelected { $0.width = mosaicStrength }
        } else {
            preferences.lineWidth = min(24, max(2, preferences.lineWidth + step)); modifySelected { $0.width = preferences.lineWidth }
        }
        preferences.save(); updateUI()
    }

    private func loupeFrame(at pointer: CGPoint) -> CGRect {
        let width: CGFloat = 158, height: CGFloat = 214
        let origin = CGPoint(x: min(bounds.maxX - width - 8, max(8, pointer.x + width + 30 < bounds.maxX ? pointer.x + 24 : pointer.x - width - 24)),
                             y: min(bounds.maxY - height - 8, max(8, pointer.y + 24)))
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    private func drawLoupe() {
        guard let pointer, document.selection == nil || selecting || dragHandle != nil, let color = sampledColor() else { return }
        let point = imagePoint(pointer)
        let x = min(document.source.width - 1, max(0, Int(point.x)))
        let y = min(document.source.height - 1, max(0, Int(point.y)))
        let sampleWidth = min(17, document.source.width), sampleHeight = min(17, document.source.height)
        let crop = CGRect(x: min(document.source.width - sampleWidth, max(0, x - 8)),
                          y: min(document.source.height - sampleHeight, max(0, y - 8)), width: sampleWidth, height: sampleHeight)
        guard let pixels = document.source.cropping(to: crop) else { return }
        let card = loupeFrame(at: pointer)
        let origin = card.origin
        NSColor(calibratedWhite: 0.13, alpha: 0.97).setFill(); NSBezierPath(roundedRect: card, xRadius: 5, yRadius: 5).fill()
        let sample = CGRect(x: origin.x + 5, y: origin.y + 5, width: 148, height: 148)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current?.imageInterpolation = .none
        drawImage(pixels, in: sample); NSGraphicsContext.restoreGraphicsState()
        let center = CGPoint(x: sample.minX + (CGFloat(x) - crop.minX + 0.5) * sample.width / crop.width,
                             y: sample.minY + (CGFloat(y) - crop.minY + 0.5) * sample.height / crop.height)
        let cross = NSBezierPath(); cross.move(to: CGPoint(x: sample.minX, y: center.y)); cross.line(to: CGPoint(x: sample.maxX, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: sample.minY)); cross.line(to: CGPoint(x: center.x, y: sample.maxY))
        NSColor.systemBlue.setStroke(); cross.lineWidth = 1; cross.stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.white]
        ("\(x), \(y)" as NSString).draw(at: CGPoint(x: origin.x + 10, y: origin.y + 159), withAttributes: attributes)
        (colorValue(color) as NSString).draw(at: CGPoint(x: origin.x + 10, y: origin.y + 176), withAttributes: attributes)
        let hint = CaptureLocalization.text("C 复制颜色 · Shift 切换", "C Copy · Shift Format")
        (hint as NSString).draw(at: CGPoint(x: origin.x + 10, y: origin.y + 195), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.lightGray])
    }

    private func beginText(at point: CGPoint, editing index: Int? = nil) {
        guard let selection = document.selection else { return }
        guard selection.contains(point) else {
            showError(CaptureMessage("文字起点已在选区外。请先移动文字或扩大选区，再双击编辑。", "The text origin is outside the capture. Move the text or enlarge the selection before editing."))
            return
        }
        let position = displayRect(CGRect(origin: point, size: .zero)).origin
        let room = displayRect(selection)
        let width = min(520, room.maxX - position.x)
        let height = min(200, room.maxY - position.y)
        guard width >= 24, height >= 20 else {
            showError(CaptureMessage("选区太小，按 V 扩大选区后再输入文字。", "The selection is too small. Press V to enlarge it before adding text."))
            return
        }
        let origin = position
        let anchor = imagePoint(origin)
        textOrigin = anchor
        textStyle = ImageEditStroke(tool: .text, points: [anchor], color: preferences.color, width: preferences.lineWidth,
                                    text: annotationText, fontSize: preferences.textSize, style: currentStyle(for: .text))
        editingTextIndex = index
        if let index {
            textStyle = document.strokes[index]
            editingPreview = try? ImageEditingOperations.render(document.strokes.enumerated().filter { $0.offset != index }.map(\.element), source: document.source)
        }
        let editor = CaptureInlineTextView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        editor.isRichText = false; editor.importsGraphics = false; editor.allowsUndo = true
        editor.font = .systemFont(ofSize: preferences.textSize * scaleX, weight: .medium)
        editor.textColor = preferences.color; editor.insertionPointColor = preferences.color
        editor.drawsBackground = false
        editor.string = textStyle?.text ?? ""
        editor.typingAttributes = ImageEditingOperations.textAttributes(for: textStyle!)
        editor.typingAttributes[.font] = NSFont.systemFont(ofSize: preferences.textSize * scaleX, weight: .medium)
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = CGSize(width: 100_000, height: 100_000)
        editor.isHorizontallyResizable = true; editor.isVerticallyResizable = true
        editor.maxSize = CGSize(width: 100_000, height: 100_000)
        editor.setAccessibilityLabel(CaptureLocalization.text("标注文字", "Annotation text"))
        editor.onCommit = { [weak self] in self?.commitText() }
        editor.onDiscard = { [weak self] in self?.discardText(); self?.updateUI() }
        editor.onChange = { [weak self] in self?.resizeTextEditor() }
        let scroll = NSScrollView(frame: CGRect(origin: origin, size: CGSize(width: width, height: height)))
        scroll.borderType = .noBorder; scroll.drawsBackground = false
        scroll.wantsLayer = true; scroll.layer?.borderWidth = 1; scroll.layer?.borderColor = NSColor.systemBlue.cgColor
        scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
        scroll.documentView = editor
        addSubview(scroll); textScroll = scroll; textEditor = editor
        updateTextAttributes(); resizeTextEditor()
        window?.makeFirstResponder(editor); updateUI()
    }
    private func resizeTextEditor() {
        guard let editor = textEditor, let scroll = textScroll, let selection = document.selection else { return }
        editor.layoutManager?.ensureLayout(for: editor.textContainer!)
        let used = editor.layoutManager?.usedRect(for: editor.textContainer!) ?? .zero
        let room = displayRect(selection)
        let lineHeight = (editor.font?.ascender ?? 14) - (editor.font?.descender ?? -4) + (editor.font?.leading ?? 0)
        let size = CGSize(width: min(room.maxX - scroll.frame.minX, max(48, used.width + 4)),
                          height: min(room.maxY - scroll.frame.minY, max(lineHeight + 4, used.height + 4)))
        scroll.setFrameSize(size); editor.setFrameSize(CGSize(width: max(size.width, used.width + 4), height: max(size.height, used.height + 4)))
    }
    @discardableResult private func commitText() -> Bool {
        guard let editor = textEditor, var stroke = textStyle else { return true }
        // Keep the current composition in the text storage when committing by clicking outside.
        editor.unmarkText()
        stroke.text = String(editor.string.prefix(500))
        if !stroke.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                if let index = editingTextIndex { try document.replace(at: index, with: stroke); selectedStroke = index }
                else { try document.append(stroke); selectedStroke = document.strokes.count - 1 }
            }
            catch { showError(error); return false }
        } else if let index = editingTextIndex {
            do { try document.remove(at: index); selectedStroke = nil }
            catch { showError(error); return false }
        }
        discardText()
        updateUI()
        return true
    }
    private func discardText() {
        textScroll?.removeFromSuperview(); textEditor = nil; textScroll = nil; textOrigin = nil; textStyle = nil
        editingTextIndex = nil; editingPreview = nil
        window?.makeFirstResponder(self)
    }
}

private final class CaptureInlineTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onDiscard: (() -> Void)?
    var onChange: (() -> Void)?
    override func didChangeText() { super.didChangeText(); onChange?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, !hasMarkedText() { onDiscard?(); return }
        if (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.contains(.command), !hasMarkedText() { onCommit?(); return }
        super.keyDown(with: event)
    }
}
