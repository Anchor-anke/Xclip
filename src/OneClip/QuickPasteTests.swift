import Foundation
import AppKit
import SwiftUI

/// Supplies a test window and point without posting an event to the system.
private final class QuickPasteTestWheelEvent: NSEvent {
    private let source: NSEvent
    private weak var targetWindow: NSWindow?
    private let point: NSPoint

    init(source: NSEvent, window: NSWindow, point: NSPoint) {
        self.source = source
        targetWindow = window
        self.point = point
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("Test events are not archived") }
    override var type: NSEvent.EventType { source.type }
    override var window: NSWindow? { targetWindow }
    override var windowNumber: Int { targetWindow?.windowNumber ?? 0 }
    override var locationInWindow: NSPoint { point }
    override var modifierFlags: NSEvent.ModifierFlags { source.modifierFlags }
    override var scrollingDeltaX: CGFloat { source.scrollingDeltaX }
    override var scrollingDeltaY: CGFloat { source.scrollingDeltaY }
    override var hasPreciseScrollingDeltas: Bool { source.hasPreciseScrollingDeltas }
    override var cgEvent: CGEvent? { source.cgEvent }
}

/// Focused drag and panel regressions. All content and pasteboards belong to this test run.
enum QuickPasteTests {
    private static var checks = 0

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else {
            throw NSError(domain: "CClipQuickPasteTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        checks += 1
        print("PASS quick paste \(checks): \(message)")
        fflush(stdout)
    }

    static func run(manager: ClipboardManager, root: URL) throws {
        guard let isolated = ProcessInfo.processInfo.environment["CCLIP_DATA_DIR"] ?? Bundle.main.object(forInfoDictionaryKey: "CClipTestDataDirectory") as? String,
              !isolated.isEmpty else { throw ClipboardError.accessDenied }
        checks = 0
        let directory = root.appendingPathComponent("quick-paste", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let wheelOnly = ProcessInfo.processInfo.environment["CCLIP_QUICK_PASTE_TEST_SCOPE"] == "wheel"
        if !wheelOnly {
            try payloads(manager: manager, directory: directory)
            try placement()
        }
        try wheelScrolling()
        try wheelPanelIntegration()
        if !wheelOnly { try panelLifecycle() }
        print("QuickPasteTests: \(checks) checks passed (\(wheelOnly ? "wheel" : "full") scope); synthetic data and named pasteboards only.")
    }

    private static func payloads(manager: ClipboardManager, directory: URL) throws {
        let board = NSPasteboard(name: .init("CClip.QuickPasteTests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        func write(_ item: ClipboardItem) throws {
            let writers = try QuickPasteDragPayload.writers(for: item, manager: manager)
            board.clearContents()
            try expect(!writers.isEmpty && board.writeObjects(writers), "Drag writers must be accepted by a named macOS pasteboard")
        }
        func imageFileURL() throws -> URL {
            let images = board.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] ?? []
            let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            try expect(board.pasteboardItems?.count == 1 && images.count == 1 && files.count == 1,
                       "One image drag can be read as one NSImage or one native file without duplicate objects")
            guard let file = files.first, file.isFileURL else { throw ClipboardError.dataCorrupted }
            try expect(file.pathExtension.lowercased() == "png" && FileManager.default.isReadableFile(atPath: file.path),
                       "Image file receivers get a readable PNG file")
            return file
        }

        let text = ClipboardItem(id: UUID(), content: "Drag 文本 → 编辑器\nPreserve line breaks & emoji 🧩", type: .text, timestamp: Date())
        try write(text)
        try expect(board.string(forType: .string) == text.content, "Text drag preserves Unicode and line breaks")

        let rtf = Data("{\\rtf1\\ansi Synthetic \\b rich\\b0  drag}".utf8)
        let html = Data("<p>Synthetic <strong>rich</strong> drag</p>".utf8)
        let appType = NSPasteboard.PasteboardType("com.example.cclip.synthetic-rich-text")
        var rich = ClipboardItem(id: UUID(), content: "Synthetic rich drag", type: .text, timestamp: Date())
        rich.representations = [NSPasteboard.PasteboardType.rtf.rawValue: rtf,
                                NSPasteboard.PasteboardType.html.rawValue: html,
                                appType.rawValue: Data([1, 3, 7]),
                                NSPasteboard.PasteboardType.fileURL.rawValue: Data("file:///synthetic/obsolete.txt".utf8),
                                "org.nspasteboard.ConcealedType": Data(),
                                "org.nspasteboard.TransientType": Data(),
                                "org.nspasteboard.AutoGeneratedType": Data()]
        try write(rich)
        try expect(board.string(forType: .string) == rich.content && board.data(forType: .rtf) == rtf && board.data(forType: .html) == html,
                   "Rich-text drag retains text, RTF and HTML byte-for-byte")
        try expect(board.data(forType: appType) == Data([1, 3, 7]), "Drag retains application-specific representations")
        try expect(board.string(forType: .fileURL) == nil && ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"].allSatisfy { board.data(forType: .init($0)) == nil },
                   "Stale file references and pasteboard control markers do not leak into a text drag")

        let link = "https://example.com/notes?topic=clipboard&lang=zh"
        let urlItem = ClipboardItem(id: UUID(), content: link, type: .text, timestamp: Date(),
                                    representations: [NSPasteboard.PasteboardType.URL.rawValue: Data(link.utf8)])
        try write(urlItem)
        try expect(board.string(forType: .URL) == link && board.string(forType: .string) == link,
                   "A captured URL keeps both its native URL and text representations")
        try write(ClipboardItem(id: UUID(), content: link, type: .text, timestamp: Date()))
        try expect(board.string(forType: .URL) == link && board.string(forType: .string) == link,
                   "A complete web link copied as text can be dragged as a native URL")
        let fileText = "file:///synthetic/private-note.txt"
        try write(ClipboardItem(id: UUID(), content: fileText, type: .text, timestamp: Date()))
        try expect(board.string(forType: .string) == fileText && board.string(forType: .URL) == nil && board.string(forType: .fileURL) == nil,
                   "A file URL written as text is never promoted to a file attachment")

        let code = ClipboardItem(id: UUID(), content: "func paste(_ value: String) {\n    print(value)\n}", type: .code, timestamp: Date())
        try write(code)
        try expect(board.string(forType: .string) == code.content && board.string(forType: .fileURL) == nil,
                   "Code snippets drag as their complete text without an invented file")

        let png = try sampleImageData()
        let picture = ClipboardItem(id: UUID(), content: "Synthetic gradient.png", type: .image, timestamp: Date(), data: png)
        try write(picture)
        try expect(board.data(forType: .png) == png, "Image drag preserves original PNG bytes")
        let memoryImageURL = try imageFileURL()
        try expect(try Data(contentsOf: memoryImageURL) == png, "The exported memory image preserves the original PNG bytes")
        try expect(board.data(forType: .tiff).flatMap(NSImage.init(data:)) != nil,
                   "A PNG drag also supplies a decodable TIFF representation")
        try write(picture)
        try expect(try imageFileURL().standardizedFileURL == memoryImageURL.standardizedFileURL,
                   "Dragging the same memory image again reuses its exported file")

        let imagePath = directory.appendingPathComponent("retained-image.png")
        try png.write(to: imagePath)
        let retainedPicture = ClipboardItem(id: UUID(), content: "Retained image", type: .image, timestamp: Date(), filePath: imagePath.path)
        try write(retainedPicture)
        try expect(board.data(forType: .png) == png, "An image retained on disk still drags as image data")
        let retainedImageURL = try imageFileURL()
        try expect(retainedImageURL.standardizedFileURL != imagePath.standardizedFileURL,
                   "A retained image exports an independent file instead of its history storage path")
        try expect(retainedImageURL.standardizedFileURL == memoryImageURL.standardizedFileURL,
                   "Identical PNG bytes reuse the same export across different history records")
        try FileManager.default.removeItem(at: imagePath)
        board.clearContents()
        try expect(try Data(contentsOf: retainedImageURL) == png,
                   "The exported image stays readable after its source is deleted and the drag pasteboard is cleared")

        guard let jpeg = NSBitmapImageRep(data: png)?.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw ClipboardError.imageProcessingFailed
        }
        try write(ClipboardItem(id: UUID(), content: "Synthetic gradient.jpg", type: .image, timestamp: Date(), data: jpeg))
        let jpegImageURL = try imageFileURL()
        guard let convertedPNG = board.data(forType: .png), let convertedTIFF = board.data(forType: .tiff) else {
            throw ClipboardError.dataCorrupted
        }
        try expect(convertedPNG.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) && NSImage(data: convertedPNG) != nil && NSImage(data: convertedTIFF) != nil,
                   "A JPEG image provides valid PNG and TIFF representations for image receivers")
        try expect(try Data(contentsOf: jpegImageURL) == convertedPNG,
                   "A JPEG file fallback contains the same PNG bytes advertised on the pasteboard")

        let staleImagePath = directory.appendingPathComponent("expired-original.png")
        let staleImageURL = staleImagePath.absoluteString
        var stalePicture = picture
        stalePicture.representations = [NSPasteboard.PasteboardType.fileURL.rawValue: Data(staleImageURL.utf8),
                                        NSPasteboard.PasteboardType.URL.rawValue: Data(staleImageURL.utf8),
                                        "NSFilenamesPboardType": Data(staleImageURL.utf8),
                                        "com.apple.pasteboard.promised-file-url": Data(staleImageURL.utf8)]
        try write(stalePicture)
        try expect(try imageFileURL().standardizedFileURL == memoryImageURL.standardizedFileURL,
                   "An image with an expired captured file URL receives the valid cached export")
        let fileReferenceTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .init("NSFilenamesPboardType"), .init("com.apple.pasteboard.promised-file-url")]
        let staleReferences = [Data(staleImageURL.utf8), Data(staleImagePath.path.utf8)]
        try expect(fileReferenceTypes.allSatisfy { type in
            guard let bytes = board.data(forType: type) else { return true }
            return staleReferences.allSatisfy { bytes.range(of: $0) == nil }
        },
                   "Expired file references do not leak into any image drag representation")
        // AppKit can derive a public.url alias from the new public.file-url.
        let imageURLAlias = board.string(forType: .URL)
        try expect(imageURLAlias == nil || imageURLAlias.flatMap(URL.init(string:))?.standardizedFileURL == memoryImageURL.standardizedFileURL,
                   "Any native URL alias points to the current exported image")

        let nativeImagePath = directory.appendingPathComponent("native-file-image.png")
        try png.write(to: nativeImagePath)
        try write(ClipboardItem(id: UUID(), content: "Native image attachment", type: .image, timestamp: Date(), fileURLs: [nativeImagePath.path]))
        let nativeImageURLs = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        try expect(nativeImageURLs.map(\.standardizedFileURL) == [nativeImagePath.standardizedFileURL] && board.pasteboardItems?.count == 1,
                   "An image already retained as a native file keeps its original file URL")
        try expect(board.data(forType: .png) == nil && board.data(forType: .tiff) == nil,
                   "A native file drag is not converted into an extra image payload")

        let firstDirectory = directory.appendingPathComponent("first"), secondDirectory = directory.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let first = firstDirectory.appendingPathComponent("同名笔记.txt"), second = secondDirectory.appendingPathComponent("同名笔记.txt")
        try Data("Synthetic first attachment".utf8).write(to: first)
        try Data("Synthetic second attachment".utf8).write(to: second)
        let files = ClipboardItem(id: UUID(), content: "Two same-name files", type: .file, timestamp: Date(), fileURLs: [first.path, second.path])
        try write(files)
        let urls = (board.pasteboardItems ?? []).compactMap { $0.string(forType: .fileURL) }.compactMap(URL.init(string:))
        try expect(urls.count == 2 && Set(urls.map(\.standardizedFileURL)) == Set([first, second].map(\.standardizedFileURL)),
                   "A multi-file drag exposes every selected file as a separate native file URL")
        try expect(try Set(urls.map { try String(contentsOf: $0, encoding: .utf8) }) == ["Synthetic first attachment", "Synthetic second attachment"],
                   "Same-name dragged files retain distinct bytes")

        var memoryFile = files
        memoryFile.fileURLs = nil
        memoryFile.representations = ["local.cclip.memory-attachments-v1": try JSONEncoder().encode(HistoryArchive.make(items: [files]))]
        try FileManager.default.removeItem(at: firstDirectory)
        try FileManager.default.removeItem(at: secondDirectory)
        try write(memoryFile)
        let memoryURLs = (board.pasteboardItems ?? []).compactMap { $0.string(forType: .fileURL) }.compactMap(URL.init(string:))
        try expect(memoryURLs.count == 2 && Set(memoryURLs.map(\.path)).isDisjoint(with: [first.path, second.path]),
                   "A session-only attachment drag materializes independent native file URLs")
        try expect(try Set(memoryURLs.map { try String(contentsOf: $0, encoding: .utf8) }) == ["Synthetic first attachment", "Synthetic second attachment"],
                   "Session-only attachment drag preserves all original bytes")

        let missing = ClipboardItem(id: UUID(), content: "Missing attachment", type: .file, timestamp: Date(), fileURLs: [directory.appendingPathComponent("does-not-exist.txt").path])
        let brokenImage = ClipboardItem(id: UUID(), content: "Invalid image", type: .image, timestamp: Date(), data: Data([1, 2, 3]))
        for item in [missing, brokenImage] {
            do {
                _ = try QuickPasteDragPayload.writers(for: item, manager: manager)
                throw NSError(domain: "CClipQuickPasteTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid drag payload was accepted: \(item.content)"])
            } catch ClipboardError.dataCorrupted {
                try expect(true, "\(item.content) fails before a drag session can start")
            }
        }

        manager.cleanupImageDragFiles()
        try expect([memoryImageURL, jpegImageURL].allSatisfy { !FileManager.default.fileExists(atPath: $0.path) },
                   "Session cleanup removes exported image files")
        try write(picture)
        let recreatedImageURL = try imageFileURL()
        try expect(try Data(contentsOf: recreatedImageURL) == png,
                   "Dragging after session cleanup recreates a readable image instead of returning a stale cached path")
    }

    private static func placement() throws {
        for screen in [NSRect(x: 0, y: 24, width: 1920, height: 1032),
                       NSRect(x: -1280, y: 0, width: 1280, height: 720),
                       NSRect(x: 1920, y: -300, width: 592, height: 330)] {
            let frame = QuickPastePanelController.frame(in: screen)
            try expect(screen.contains(frame) && frame.width > 0 && frame.height > 0, "The quick panel stays within the available display, including offset monitors")
            try expect(abs(frame.midX - screen.midX) < 0.5 && abs(frame.minY - screen.minY - 12) < 0.5,
                       "The quick panel is centered at the bottom of the available display")
            try expect(frame.width <= 1440 && frame.width <= screen.width - 32 && frame.height <= 330,
                       "The quick panel respects its maximum size and display margins")
        }
    }

    private static func settleAnimations() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.36))
    }

    private static func wheelEvent(vertical: Int32, horizontal: Int32 = 0,
                                   precise: Bool = false, flags: CGEventFlags = [], momentum: Int64 = 0) throws -> NSEvent {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
                                  wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0) else {
            throw ClipboardError.dataCorrupted
        }
        event.flags = flags
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        guard let result = NSEvent(cgEvent: event) else { throw ClipboardError.dataCorrupted }
        return result
    }

    private static func wheelScrolling() throws {
        for delta: Int32 in [-3, 3] {
            let original = try wheelEvent(vertical: delta)
            guard let movement = QuickPasteWheelScrollView.horizontalMovement(for: original, lineScroll: 16) else { throw ClipboardError.dataCorrupted }
            try expect(movement == -CGFloat(delta) * 16,
                       "An ordinary wheel moves horizontally in the requested direction at the native line-scroll distance")
            try expect(original.scrollingDeltaX == 0 && original.scrollingDeltaY != 0,
                       "Wheel conversion does not mutate the incoming event")
        }
        let precise = try wheelEvent(vertical: -27, precise: true, momentum: 2)
        try expect(QuickPasteWheelScrollView.horizontalMovement(for: precise, lineScroll: 16) == 27,
                   "High-resolution vertical scrolling uses its point distance without line-scroll scaling")
        for event in [try wheelEvent(vertical: 0, horizontal: -2),
                      try wheelEvent(vertical: -3, horizontal: -2),
                      try wheelEvent(vertical: -27, horizontal: -8, precise: true)] {
            try expect(QuickPasteWheelScrollView.horizontalMovement(for: event, lineScroll: 16) == nil,
                       "Native horizontal and diagonal gestures are left to AppKit")
        }
        for flags: CGEventFlags in [.maskCommand, .maskControl, .maskAlternate, .maskShift] {
            try expect(QuickPasteWheelScrollView.horizontalMovement(for: try wheelEvent(vertical: -3, flags: flags), lineScroll: 16) == nil,
                       "A modified wheel gesture retains its native AppKit behavior")
        }
        try expect(QuickPasteWheelScrollView.horizontalMovement(for: try wheelEvent(vertical: 0), lineScroll: 16) == nil,
                   "An empty wheel event is not consumed")

        let wasLocked = PrivacyLock.shared.locked
        PrivacyLock.shared.locked = false
        let window = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 420, height: 220),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 40, width: 380, height: 140))
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 120))
        let anchor = QuickPasteWheelScrollView(frame: document.bounds)
        document.addSubview(anchor)
        scroll.documentView = document
        window.contentView?.addSubview(scroll)
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        defer { anchor.stopMonitoring(); window.orderOut(nil); PrivacyLock.shared.locked = wasLocked }
        let inside = scroll.contentView.convert(NSPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY), to: nil)
        func input(_ delta: Int32, point: NSPoint? = nil, target: NSWindow? = nil) throws -> NSEvent {
            QuickPasteTestWheelEvent(source: try wheelEvent(vertical: delta), window: target ?? window, point: point ?? inside)
        }
        func position(_ x: CGFloat) {
            scroll.contentView.scroll(to: NSPoint(x: x, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        position(0)
        try expect(anchor.enclosingScrollView === scroll && anchor.hitTest(.zero) == nil,
                   "The wheel bridge locates its scroll view without taking mouse hits from cards")
        try expect(anchor.handle(try input(-3)), "The visible card viewport accepts a vertical wheel event")
        settleAnimations()
        let movedRight = scroll.contentView.bounds.minX
        try expect(movedRight > 0, "A downward wheel event moves real native scroll content to the right")
        _ = anchor.handle(try input(3))
        settleAnimations()
        try expect(scroll.contentView.bounds.minX < movedRight, "The opposite wheel direction moves real native content back to the left")
        position(0)
        _ = anchor.handle(try input(100))
        settleAnimations()
        try expect(abs(scroll.contentView.bounds.minX) < 0.5, "Wheel scrolling cannot move beyond the first card")
        let end = document.bounds.width - scroll.contentView.bounds.width
        position(end)
        _ = anchor.handle(try input(-100))
        settleAnimations()
        try expect(abs(scroll.contentView.bounds.minX - end) < 0.5, "Wheel scrolling cannot move beyond the final card")
        position(100)
        try expect(!anchor.handle(try input(-3, point: NSPoint(x: 10, y: 10))),
                   "A wheel event outside the card viewport is left untouched")
        anchor.isEnabled = false
        try expect(!anchor.handle(try input(-3)), "Disabling the bridge during dragging leaves the wheel event untouched")
        anchor.isEnabled = true
        let otherWindow = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        try expect(!anchor.handle(try input(-3, target: otherWindow)), "Another window cannot scroll the quick-paste content")
        PrivacyLock.shared.locked = true
        try expect(!anchor.handle(try input(-3)), "A privacy-locked clipboard cannot respond to wheel navigation")
        PrivacyLock.shared.locked = false
        window.orderOut(nil)
        try expect(!anchor.handle(try input(-3)), "A hidden quick-paste window does not consume wheel events")
        anchor.removeFromSuperview()
        try expect(!anchor.handle(try input(-3)), "A detached bridge cannot consume subsequent wheel events")
    }

    private static func wheelPanelIntegration() throws {
        // QuickPasteView observes the shared manager, not the separate manager
        // used by the payload tests. Both use this run's isolated data directory.
        let manager = ClipboardManager.shared
        let savedItems = manager.clipboardItems
        let wasLocked = PrivacyLock.shared.locked
        PrivacyLock.shared.locked = false
        manager.clipboardItems = (0..<16).map {
            ClipboardItem(id: UUID(), content: "Synthetic wheel card \($0)", type: .text, timestamp: Date())
        }
        let controller = QuickPastePanelController()
        defer { controller.dismissImmediately(); manager.clipboardItems = savedItems; PrivacyLock.shared.locked = wasLocked }
        controller.toggle(onOpen: {})
        settleAnimations()
        guard let panel = controller.panel, let root = panel.contentView else { throw ClipboardError.dataCorrupted }
        root.layoutSubtreeIfNeeded()
        func descendants<T: NSView>(_ type: T.Type, of view: NSView) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, of: $0) }
        }
        let anchors = descendants(QuickPasteWheelScrollView.self, of: root)
        if anchors.first?.enclosingScrollView == nil {
            func dump(_ view: NSView, depth: Int = 0) {
                print(String(repeating: " ", count: depth) + String(describing: type(of: view)) + " " + NSStringFromRect(view.frame))
                for child in view.subviews { dump(child, depth: depth + 1) }
            }
            dump(root)
        }
        try expect(!anchors.isEmpty, "The actual card strip creates the wheel bridge")
        guard let anchor = anchors.first else { throw ClipboardError.dataCorrupted }
        try expect(anchor.enclosingScrollView != nil, "The wheel bridge can find the actual card strip's native scroll view")
        guard let scroll = anchor.enclosingScrollView else { throw ClipboardError.dataCorrupted }
        try expect(anchor.window === panel && scroll.documentView != nil,
                   "The actual SwiftUI card strip installs the wheel bridge inside its native scroll view")
        let cards = descendants(QuickPasteDragHostingView.self, of: root).map { $0.convert($0.bounds, to: nil) }.sorted { $0.minX < $1.minX }
        guard cards.count >= 2 else { throw ClipboardError.dataCorrupted }
        let gap = NSPoint(x: (cards[0].maxX + cards[1].minX) / 2, y: cards[0].midY)
        try expect(cards[1].minX > cards[0].maxX && !cards.contains(where: { $0.contains(gap) }),
                   "The integration wheel point lies in the empty spacing between two cards")
        let start = scroll.contentView.bounds.minX
        let event = QuickPasteTestWheelEvent(source: try wheelEvent(vertical: -3), window: panel, point: gap)
        try expect(anchor.handle(event), "A wheel event between cards reaches the same scroll bridge")
        settleAnimations()
        try expect(scroll.contentView.bounds.minX > start, "Wheel scrolling in a card gap moves the actual quick-paste card strip")
    }

    private static func panelLifecycle() throws {
        guard !NSScreen.screens.isEmpty else { throw ClipboardError.accessDenied }
        let privacy = PrivacyLock.shared
        let wasLocked = privacy.locked
        privacy.locked = false
        let controller = QuickPastePanelController()
        defer { controller.dismissImmediately(); privacy.locked = wasLocked }

        controller.toggle(onOpen: {})
        settleAnimations()
        guard let panel = controller.panel else { throw ClipboardError.dataCorrupted }
        try expect(panel.isVisible && panel.alphaValue > 0.99 && controller.isPresented, "The quick-paste shortcut opens a fully visible panel")
        try surfaceComposition(in: panel)
        controller.beginDrag()
        settleAnimations()
        try expect(controller.isDragging && (!panel.isVisible || panel.alphaValue < 0.01), "Starting a drag hides the panel while retaining the drag session")
        controller.endDrag(false)
        settleAnimations()
        try expect(!controller.isDragging && panel.isVisible && panel.alphaValue > 0.99 && controller.isPresented,
                   "Cancelling a drag restores the panel for another selection")
        controller.beginDrag()
        controller.endDrag(false)
        settleAnimations()
        try expect(panel.isVisible && panel.alphaValue > 0.99 && controller.isPresented,
                   "A drag cancelled before its hide animation finishes remains restored")

        controller.beginDrag()
        controller.endDrag(true)
        settleAnimations()
        try expect(!controller.isDragging && !panel.isVisible && !controller.isPresented, "A completed drop leaves the panel closed")
        controller.endDrag(false)
        settleAnimations()
        try expect(!panel.isVisible && !controller.isPresented, "A duplicate drag-end callback cannot reopen a completed drop")

        controller.toggle(onOpen: {})
        settleAnimations()
        controller.toggle(onOpen: {})
        controller.toggle(onOpen: {})
        settleAnimations()
        try expect(panel.isVisible && panel.alphaValue > 0.99 && controller.isPresented,
                   "Rapid close and reopen cannot be undone by an older hide animation")

        controller.beginDrag()
        controller.dismissImmediately()
        controller.endDrag(false)
        settleAnimations()
        try expect(!panel.isVisible && !controller.isDragging && !controller.isPresented,
                   "A late drag-cancel callback cannot restore a panel explicitly dismissed during dragging")

        controller.toggle(onOpen: {})
        settleAnimations()
        controller.beginDrag()
        privacy.locked = true
        controller.dismissImmediately()
        controller.endDrag(false)
        settleAnimations()
        try expect(!panel.isVisible && !controller.isPresented, "Lock dismissal remains closed after a late drag callback")
        controller.toggle(onOpen: {})
        settleAnimations()
        try expect(!panel.isVisible && !controller.isPresented, "A locked quick-paste shortcut cannot reveal clipboard cards")
    }

    private static func surfaceComposition(in panel: NSPanel) throws {
        try expect(!panel.isOpaque && panel.backgroundColor.alphaComponent == 0,
                   "The actual quick-paste panel preserves a transparent window backdrop")
        try expect(panel.contentView is QuickPasteSurface<QuickPasteView>,
                   "The actual quick-paste panel installs the native material surface")
        guard let surface = panel.contentView as? QuickPasteSurface<QuickPasteView> else { throw ClipboardError.dataCorrupted }
        surface.layoutSubtreeIfNeeded()
        try expect(surface.bounds.width > 0 && surface.bounds.height > 0 && surface.materialView.frame == surface.bounds,
                   "The native material fills the presented quick-paste panel")
        try expect(!surface.isOpaque && !surface.hostingView.isOpaque && (surface.hostingView.layer?.backgroundColor?.alpha ?? 0) < 1,
                   "The SwiftUI hosting root has no opaque backing color over the native material")

        if #available(macOS 26.0, *) {
            try expect(surface.materialView is NSGlassEffectView, "macOS 26 uses Apple's native glass effect view")
            guard let glass = surface.materialView as? NSGlassEffectView else { throw ClipboardError.dataCorrupted }
            try expect(glass.contentView === surface.hostingView && surface.hostingView.isDescendant(of: glass),
                       "Native glass owns the live SwiftUI content instead of sitting behind a separate host")
            try expect(glass.style == .regular && glass.cornerRadius > 0,
                       "Native glass uses the regular readable style and rounded edges")
        } else {
            try expect(surface.materialView is NSVisualEffectView, "Earlier macOS uses the native visual-effect fallback")
            guard let material = surface.materialView as? NSVisualEffectView else { throw ClipboardError.dataCorrupted }
            try expect(material.blendingMode == .behindWindow && surface.hostingView.isDescendant(of: material),
                       "The fallback composites behind the window and owns the live SwiftUI content")
        }

        func containsCoveringMaterial(_ view: NSView) -> Bool {
            view.subviews.contains { child in
                if child is NSVisualEffectView {
                    let frame = child.convert(child.bounds, to: surface.hostingView)
                    if frame.intersection(surface.hostingView.bounds).width >= surface.hostingView.bounds.width * 0.95 &&
                        frame.intersection(surface.hostingView.bounds).height >= surface.hostingView.bounds.height * 0.95 { return true }
                }
                return containsCoveringMaterial(child)
            }
        }
        try expect(!containsCoveringMaterial(surface.hostingView),
                   "SwiftUI content does not place a second full-panel visual material over native glass")
    }

    /// A local, deterministic preview image; no network or user assets are read.
    static func sampleImageData() throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 480, pixelsHigh: 320,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 480 * 4, bitsPerPixel: 32),
              let pixels = bitmap.bitmapData else { throw ClipboardError.imageProcessingFailed }
        for y in 0..<320 {
            for x in 0..<480 {
                let offset = y * bitmap.bytesPerRow + x * 4
                let sky = y < 192
                let sun = (x - 350) * (x - 350) + (y - 88) * (y - 88) < 38 * 38
                let hill = y > 150 + Int(48 * sin(Double(x) / 96))
                pixels[offset] = sun ? 255 : (hill ? 57 : (sky ? UInt8(140 + x / 8) : 54))
                pixels[offset + 1] = sun ? 228 : (hill ? UInt8(132 + y / 8) : (sky ? 202 : 151))
                pixels[offset + 2] = sun ? 149 : (hill ? 151 : (sky ? 230 : 184))
                pixels[offset + 3] = 255
            }
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw ClipboardError.imageProcessingFailed }
        return data
    }
}
