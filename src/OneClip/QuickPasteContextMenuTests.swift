import AppKit
import SwiftUI

/// Exercises native menu dispatch and the real tray callbacks with isolated synthetic records.
enum QuickPasteContextMenuTests {
    private static var checks = 0

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else {
            throw NSError(domain: "CClipContextMenuTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        checks += 1
        print("PASS context menu \(checks): \(message)")
        fflush(stdout)
    }

    static func run() throws {
        guard let isolated = ProcessInfo.processInfo.environment["CCLIP_DATA_DIR"], !isolated.isEmpty else {
            throw AutomationError.invalid("Set CCLIP_DATA_DIR to an isolated temporary directory before running context-menu tests.")
        }
        checks = 0
        let settings = SettingsManager.shared
        let persistence = settings.enableHistoryPersistence
        let limit = settings.maxItems
        let cleanup = settings.autoCleanupDays
        let wasLocked = PrivacyLock.shared.locked
        defer {
            settings.enableHistoryPersistence = persistence
            settings.maxItems = limit
            settings.autoCleanupDays = cleanup
            PrivacyLock.shared.locked = wasLocked
        }
        PrivacyLock.shared.locked = false
        settings.enableHistoryPersistence = true
        settings.maxItems = 0
        settings.autoCleanupDays = 0
        let root = StoragePaths.dataDirectory.appendingPathComponent("context-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let board = NSPasteboard(name: .init("CClip.ContextMenuTests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let store = ClipboardStore(storageDirectory: root.appendingPathComponent("history"), getCleanupDays: { 0 })
        let manager = ClipboardManager(store: store, board: board, settings: settings)
        try menuSemantics()
        try editing(manager: manager, store: store, root: root)
        settings.enableHistoryPersistence = false
        try panelIntegration()
        print("QuickPasteContextMenuTests: \(checks) checks passed; synthetic records, native menu dispatch, no general clipboard writes or posted events.")
    }

    private static func fixture(_ type: ClipboardItemType = .text) -> ClipboardItem {
        ClipboardItem(id: UUID(), content: "Synthetic context menu \(type.rawValue)", type: type,
                      timestamp: Date(timeIntervalSince1970: 1_780_000_000),
                      sourceApp: "com.synthetic.context-editor", sourceAppName: "合成来源", tags: ["菜单验收"])
    }

    private static func entry(_ action: QuickPasteContextAction, in menu: NSMenu) throws -> NSMenuItem {
        guard let entry = menu.items.first(where: { ($0.representedObject as? String) == action.rawValue }) else {
            throw ClipboardError.dataCorrupted
        }
        return entry
    }

    private static func perform(_ action: QuickPasteContextAction, in menu: NSMenu) throws {
        let entry = try entry(action, in: menu)
        menu.performActionForItem(at: menu.index(of: entry))
        settle()
    }

    private static func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
    }

    private static func menuSemantics() throws {
        let text = fixture()
        var dispatched: [(QuickPasteContextAction, UUID)] = []
        let menu = QuickPasteContextMenu(item: text) { dispatched.append(($0, $1)) }
        try expect(menu.itemID == text.id, "The native menu binds to the clicked record's stable ID")
        try expect(menu.items.filter { !$0.isSeparatorItem }.count == 6,
                   "The menu exposes edit, favorite, pin, copy, paste and delete")
        try expect(try entry(.edit, in: menu).title == L("修改内容…", "Edit content…"),
                   "Text records offer content editing")
        for (item, title) in [(fixture(.image), L("编辑图片…", "Edit image…")),
                              (fixture(.file), L("查看详情…", "View details…")),
                              (fixture(.audio), L("查看详情…", "View details…"))] {
            let typedMenu = QuickPasteContextMenu(item: item) { _, _ in }
            try expect(try entry(.edit, in: typedMenu).title == title,
                       "The \(item.type.rawValue) menu offers the appropriate editor or detail view")
        }
        var organized = text
        organized.isFavorite = true
        organized.isPinned = true
        let organizedMenu = QuickPasteContextMenu(item: organized) { _, _ in }
        try expect(try entry(.favorite, in: organizedMenu).title == L("取消收藏", "Unfavorite")
                   && entry(.pin, in: organizedMenu).title == L("取消置顶", "Unpin"),
                   "Existing favorite and pinned records expose their inverse actions")
        try perform(.favorite, in: menu)
        try expect(dispatched.count == 1 && dispatched.first?.0 == .favorite && dispatched.first?.1 == text.id,
                   "AppKit menu activation forwards the requested action and original record ID")
        PrivacyLock.shared.locked = true
        try perform(.delete, in: menu)
        PrivacyLock.shared.locked = false
        try expect(dispatched.count == 1, "A menu created before locking cannot dispatch a destructive action while locked")
    }

    private static func editing(manager: ClipboardManager, store: ClipboardStore, root: URL) throws {
        var original = fixture()
        original.isFavorite = true
        original.isPinned = true
        original.representations = [NSPasteboard.PasteboardType.html.rawValue: Data("<b>old</b>".utf8)]
        _ = try manager.ingest(original)
        try ClipboardEditing.saveText(id: original.id, content: "修改后的内容\nUnicode 🧩", manager: manager)
        manager.reload()
        guard let saved = manager.clipboardItems.first(where: { $0.id == original.id }) else { throw ClipboardError.dataCorrupted }
        try expect(saved.content == "修改后的内容\nUnicode 🧩" && manager.clipboardItems.count == 1,
                   "Saving text updates the same persisted record with Unicode and line breaks")
        try expect(saved.timestamp == original.timestamp && saved.sourceApp == original.sourceApp
                   && saved.sourceAppName == original.sourceAppName && saved.isFavorite && saved.isPinned && saved.tags == original.tags,
                   "Editing retains capture time, provenance, favorites, pin state and tags")
        try expect(saved.representations == nil && saved.data == nil,
                   "Edited plain text discards stale rich-text representations")
        PrivacyLock.shared.locked = true
        do {
            try ClipboardEditing.saveText(id: saved.id, content: "Should not save", manager: manager)
            throw ClipboardError.dataCorrupted
        } catch ClipboardEditingError.locked { }
        PrivacyLock.shared.locked = false
        try expect(try store.readItems().first(where: { $0.id == saved.id }) == saved,
                   "A save attempted while locked leaves persisted content unchanged")
        manager.deleteItem(saved)
        do {
            try ClipboardEditing.saveText(id: saved.id, content: "Should not resurrect", manager: manager)
            throw ClipboardError.dataCorrupted
        } catch ClipboardEditingError.missingItem { }
        try expect(try store.readItems().allSatisfy { $0.id != saved.id },
                   "Saving a deleted record reports expiration without resurrecting it")

        let snippet = try manager.ingest(fixture(.code))
        try ClipboardEditing.saveText(id: snippet.id, content: "let edited = true", manager: manager)
        try expect(manager.clipboardItems.first(where: { $0.id == snippet.id })?.content == "let edited = true",
                   "Plain code snippets remain editable as text")
        let codeURL = root.appendingPathComponent("synthetic-context.swift")
        try Data("let original = true".utf8).write(to: codeURL)
        var codeFile = fixture(.code)
        codeFile.filePath = codeURL.path
        codeFile.fileURLs = [codeURL.path]
        let retainedCode = try manager.ingest(codeFile)
        try expect(!ClipboardEditing.isTextEditable(retainedCode)
                   && ClipboardEditing.title(for: retainedCode) == L("查看详情", "View details"),
                   "An attached code file is preview-only rather than a text snippet")
        do {
            try ClipboardEditing.saveText(id: retainedCode.id, content: "Should not replace file", manager: manager)
            throw ClipboardError.dataCorrupted
        } catch ClipboardEditingError.notEditable { }
        try expect(try String(contentsOf: codeURL, encoding: .utf8) == "let original = true"
                   && store.readItems().first(where: { $0.id == retainedCode.id }) == retainedCode,
                   "Rejected file editing preserves both its retained record and source file bytes")

        let beforeImage = try imageData(color: .red)
        let afterImage = try imageData(color: .blue)
        var picture = fixture(.image)
        picture.data = beforeImage
        picture.isFavorite = true
        let image = try manager.ingest(picture)
        try ClipboardEditing.saveImage(id: image.id, data: afterImage, manager: manager)
        guard let savedImage = try store.readItems().first(where: { $0.id == image.id }) else { throw ClipboardError.dataCorrupted }
        let savedImageBytes = try savedImage.data ?? savedImage.filePath.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        try expect(savedImageBytes == afterImage && savedImage.sourceAppName == picture.sourceAppName
                   && savedImage.timestamp == picture.timestamp && savedImage.isFavorite && savedImage.tags == picture.tags,
                   "Image edits persist new pixels under the same record while retaining provenance and organization")
        do {
            try ClipboardEditing.saveImage(id: image.id, data: Data("invalid image".utf8), manager: manager)
            throw ClipboardError.dataCorrupted
        } catch ClipboardError.imageProcessingFailed { }
        try expect(try store.readItems().first(where: { $0.id == image.id }) == savedImage,
                   "Invalid image bytes do not replace a valid saved image")
    }

    private static func imageData(color: NSColor) throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw ClipboardError.imageProcessingFailed
        }
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(color, atX: x, y: y) } }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw ClipboardError.imageProcessingFailed }
        return data
    }

    private static func descendants<T: NSView>(_ type: T.Type, of view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, of: $0) }
    }

    private static func panelIntegration() throws {
        guard !NSScreen.screens.isEmpty else { throw ClipboardError.accessDenied }
        let manager = ClipboardManager.shared
        try expect(!manager.isMonitoring, "The isolated integration app has clipboard monitoring disabled")
        let savedItems = manager.clipboardItems
        let savedError = manager.lastError
        let savedSearch = manager.searchText
        let initiallyCanUndo = manager.canUndo
        let target = fixture()
        var neighbor = fixture()
        neighbor.content = "Synthetic neighboring card"
        manager.clipboardItems = [neighbor, target]
        let controller = QuickPastePanelController()
        defer {
            controller.dismissImmediately()
            manager.clipboardItems = savedItems
            manager.lastError = savedError
            manager.searchText = savedSearch
            manager.changed()
        }
        controller.toggle(onOpen: {})
        settle()
        guard let panel = controller.panel, let root = panel.contentView else { throw ClipboardError.dataCorrupted }
        func card() throws -> QuickPasteDragHostingView {
            root.layoutSubtreeIfNeeded()
            guard let card = descendants(QuickPasteDragHostingView.self, of: root).first(where: { $0.item?.id == target.id }) else {
                throw ClipboardError.dataCorrupted
            }
            return card
        }
        func menu() throws -> QuickPasteContextMenu {
            guard let menu = try card().makeContextMenu() else { throw ClipboardError.dataCorrupted }
            return menu
        }
        try expect(try menu().itemID == target.id, "The actual tray card builds a native menu for its own record")
        try perform(.favorite, in: menu())
        try expect(manager.clipboardItems.first(where: { $0.id == target.id })?.isFavorite == true
                   && manager.clipboardItems.first(where: { $0.id == neighbor.id })?.isFavorite == false,
                   "The real card menu favorites the clicked card even when another card was initially selected")
        try expect(try entry(.favorite, in: menu()).title == L("取消收藏", "Unfavorite"),
                   "Reopening a real card menu reads its current favorite state")
        try perform(.pin, in: menu())
        try expect(manager.clipboardItems.first(where: { $0.id == target.id })?.isPinned == true,
                   "The real card menu updates pin state")
        let staleCard = try card()
        let staleMenu = try menu()
        try perform(.delete, in: menu())
        try expect(!manager.clipboardItems.contains(where: { $0.id == target.id }) && manager.canUndo,
                   "The real card menu deletes its record and exposes the existing undo history")
        try expect(staleCard.makeContextMenu() == nil, "A removed card cannot build a menu from a stale SwiftUI snapshot")
        try perform(.favorite, in: staleMenu)
        try expect(!manager.clipboardItems.contains(where: { $0.id == target.id }),
                   "Activating an old menu after deletion cannot recreate the removed record")
        manager.undoDelete()
        settle()
        try expect(manager.clipboardItems.first(where: { $0.id == target.id })?.isFavorite == true
                   && manager.clipboardItems.first(where: { $0.id == target.id })?.isPinned == true
                   && manager.canUndo == initiallyCanUndo,
                   "Undo restores the deleted card including its favorite and pin state")
        try perform(.edit, in: menu())
        guard let editor = controller.editorWindow else { throw ClipboardError.dataCorrupted }
        try expect(editor.isVisible && editor.parent === panel, "The real card edit action opens a child editor attached to the tray")
        controller.dismiss()
        settle()
        try expect(controller.isPresented && editor.isVisible && controller.editorWindow === editor,
                   "Outside-dismiss handling keeps an active editor and its tray alive")
        editor.close()
        settle()
        try expect(controller.editorWindow == nil && controller.isPresented && panel.isVisible,
                   "Closing the editor restores the quick-paste tray")
        try perform(.favorite, in: menu())
        try expect(manager.clipboardItems.first(where: { $0.id == target.id })?.isFavorite == false,
                   "Closing the editor restores card actions instead of leaving editing state stuck")
        var closeCount = 0
        controller.showEditor(target) { closeCount += 1 }
        settle()
        let lockedEditor = controller.editorWindow
        let lockedCard = try card()
        PrivacyLock.shared.locked = true
        try expect(lockedCard.makeContextMenu() == nil, "Locked cards cannot open a context menu")
        controller.dismissImmediately()
        settle()
        try expect(controller.editorWindow == nil && lockedEditor?.isVisible == false
                   && !controller.isPresented && !panel.isVisible && closeCount == 1,
                   "Immediate lock dismissal closes the editor and tray and completes the close callback once")
        PrivacyLock.shared.locked = false
    }
}
