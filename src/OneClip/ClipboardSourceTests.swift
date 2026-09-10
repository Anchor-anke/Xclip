import Foundation
import AppKit

/// Provenance regressions use synthetic content, named pasteboards and isolated stores only.
enum ClipboardSourceTests {
    private static var checks = 0

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else {
            throw NSError(domain: "CClipSourceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        checks += 1
        print("PASS clipboard source \(checks): \(message)")
        fflush(stdout)
    }

    static func run(root: URL, settings: SettingsManager) throws {
        let isolated = ProcessInfo.processInfo.environment["CCLIP_DATA_DIR"] ?? Bundle.main.object(forInfoDictionaryKey: "CClipTestDataDirectory") as? String
        guard let isolated, !isolated.isEmpty else { throw ClipboardError.accessDenied }
        checks = 0
        let directory = root.appendingPathComponent("clipboard-source", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let board = NSPasteboard(name: .init("CClip.SourceTests.Input.\(UUID().uuidString)"))
        let output = NSPasteboard(name: .init("CClip.SourceTests.Output.\(UUID().uuidString)"))
        let originalPersistence = settings.enableHistoryPersistence
        let originalLimit = settings.maxItems
        let originalCleanup = settings.autoCleanupDays
        defer {
            board.releaseGlobally(); output.releaseGlobally()
            settings.enableHistoryPersistence = originalPersistence
            settings.maxItems = originalLimit
            settings.autoCleanupDays = originalCleanup
        }
        settings.enableHistoryPersistence = true; settings.maxItems = 0; settings.autoCleanupDays = 0
        let store = ClipboardStore(storageDirectory: directory.appendingPathComponent("history"), getCleanupDays: { 0 })
        let manager = ClipboardManager(store: store, board: board, settings: settings)
        try captures(manager, store: store, board: board, settings: settings)
        try legacyRecords(store: store)
        try transformedAndQueued(manager, board: board, directory: directory)
        try attachmentsAndBackup(manager, store: store, board: board, output: output, settings: settings, directory: directory)
        print("ClipboardSourceTests: \(checks) checks passed; synthetic application provenance only.")
    }

    private static func captures(_ manager: ClipboardManager, store: ClipboardStore, board: NSPasteboard, settings: SettingsManager) throws {
        board.clearContents()
        try expect(board.setString("Synthetic shared clipboard text", forType: .string), "A named pasteboard accepts the synthetic source fixture")
        let editor = try manager.capture(from: board, sourceApp: "com.synthetic.editor", sourceAppName: "合成编辑器")!
        try expect(editor.sourceApp == "com.synthetic.editor" && editor.sourceAppName == "合成编辑器", "Capture records the observed application identifier and display name together")
        try expect(try manager.capture(from: board, sourceApp: "com.synthetic.editor", sourceAppName: "合成编辑器") == nil,
                   "Repeated identical content from the same application remains deduplicated")
        try expect(try manager.capture(from: board, sourceApp: "com.synthetic.editor", sourceAppName: "Synthetic Editor") == nil,
                   "A localized application name change does not defeat stable-identifier deduplication")
        let browser = try manager.capture(from: board, sourceApp: "com.synthetic.browser", sourceAppName: "合成浏览器")!
        try expect(browser.id != editor.id && browser.content == editor.content && manager.clipboardItems.count == 2,
                   "Identical content copied from a different application creates a new source record")
        let reopened = ClipboardManager(store: store, board: board, settings: settings)
        try expect(reopened.clipboardItems.first(where: { $0.id == editor.id })?.sourceAppName == "合成编辑器",
                   "The saved application name survives a history-store reload")
        try expect(try reopened.capture(from: board, sourceApp: "com.synthetic.browser", sourceAppName: "合成浏览器") == nil,
                   "Same-source deduplication also works after reopening stored history")
        let copiedAgain = try reopened.capture(from: board, sourceApp: "com.synthetic.editor", sourceAppName: "合成编辑器")
        try expect(copiedAgain != nil && reopened.clipboardItems.count == 3,
                   "Returning to a different source after reload retains the new copy event")
        manager.reload()
        try expect(manager.searchItems(with: "合成浏览器").map(\.id) == [browser.id], "Search finds records by their saved application display name")
        board.clearContents(); board.setString("Safari https://example.com/synthetic-source", forType: .string)
        let unknown = try manager.capture(from: board, sourceApp: nil)!
        try expect(unknown.sourceApp == nil && unknown.sourceAppName == nil,
                   "Text containing an application name or URL never invents clipboard provenance")
    }

    private static func legacyRecords(store: ClipboardStore) throws {
        let legacyBytes = Data("""
        {"id":"FD910046-66AD-40AB-9647-0380949F4C45","content":"Synthetic legacy source","type":"text","timestamp":"2026-01-01T00:00:00Z","sourceApp":"com.synthetic.legacy"}
        """.utf8)
        let legacy = try JSONDecoder().decode(ClipboardItem.self, from: legacyBytes)
        try expect(legacy.sourceApp == "com.synthetic.legacy" && legacy.sourceAppName == nil,
                   "Older records without an application display name remain readable")
        _ = try store.upsert(legacy)
        let savedLegacy = try store.readItems().first(where: { $0.id == legacy.id })
        try expect(savedLegacy?.sourceApp == legacy.sourceApp && savedLegacy?.sourceAppName == nil,
                   "Saving an older record preserves its known identifier without fabricating a capture-time name")
    }

    private static func transformedAndQueued(_ manager: ClipboardManager, board: NSPasteboard, directory: URL) throws {
        manager.textTransform = { text, _ in text.uppercased() }
        defer { manager.textTransform = nil }
        board.clearContents(); board.setString("synthetic transformed source", forType: .string)
        board.setData(Data("<p>synthetic transformed source</p>".utf8), forType: .html)
        let transformed = try manager.capture(from: board, sourceApp: "com.synthetic.editor", sourceAppName: "合成编辑器")!
        try expect(transformed.content == "SYNTHETIC TRANSFORMED SOURCE" && transformed.representations == nil
                   && transformed.sourceApp == "com.synthetic.editor" && transformed.sourceAppName == "合成编辑器",
                   "Copy-time text transformation retains the original application's provenance")
        let suite = "CClip.SourceTests.Workflow.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workflowURL = directory.appendingPathComponent("workflow.json")
        let workflow = WorkflowState(fileURL: workflowURL, defaults: defaults)
        workflow.addToStack(transformed); workflow.addToStack(transformed)
        let reloaded = WorkflowState(fileURL: workflowURL, defaults: defaults)
        try expect(reloaded.document.stack.count == 2 && Set(reloaded.document.stack.map(\.id)).count == 2
                   && reloaded.document.stack.allSatisfy { $0.sourceApp == transformed.sourceApp && $0.sourceAppName == transformed.sourceAppName },
                   "Independently queued copies retain application provenance after workflow persistence")
    }

    private static func attachmentsAndBackup(_ manager: ClipboardManager, store: ClipboardStore, board: NSPasteboard,
                                             output: NSPasteboard, settings: SettingsManager, directory: URL) throws {
        let source = directory.appendingPathComponent("synthetic-source.txt")
        try Data("Synthetic source attachment bytes".utf8).write(to: source)
        board.clearContents(); board.writeObjects([source as NSURL])
        let file = try manager.capture(from: board, sourceApp: "com.synthetic.files", sourceAppName: "合成文件管理器")!
        try expect(file.fileURLs?.first != source.path && file.sourceApp == "com.synthetic.files" && file.sourceAppName == "合成文件管理器",
                   "Retaining independent attachment paths preserves the source application's metadata")
        let backupURL = directory.appendingPathComponent("source.oneclipbackup")
        try store.exportBackup(to: backupURL, additionalItems: [file])
        let restoredStore = ClipboardStore(storageDirectory: directory.appendingPathComponent("restored"), getCleanupDays: { 0 })
        let restored = try restoredStore.importWorkspaceBackup(from: backupURL)
        let restoredFile = restored.items.first(where: { $0.id == file.id })!
        try expect(restoredFile.sourceApp == file.sourceApp && restoredFile.sourceAppName == file.sourceAppName
                   && restored.additionalItems.first?.sourceAppName == file.sourceAppName,
                   "Portable history backups preserve provenance in both history and workflow snapshots")
        try expect(try String(contentsOfFile: restoredFile.fileURLs!.first!, encoding: .utf8) == "Synthetic source attachment bytes",
                   "Restored source metadata remains attached to the correct retained file bytes")

        let persistedBefore = try store.readItems()
        settings.enableHistoryPersistence = false
        let memoryManager = ClipboardManager(store: store, board: board, settings: settings)
        let memoryFile = try memoryManager.capture(from: board, sourceApp: "com.synthetic.memory", sourceAppName: "合成临时来源")!
        try expect(memoryFile.sourceApp == "com.synthetic.memory" && memoryFile.sourceAppName == "合成临时来源"
                   && memoryFile.fileURLs == nil,
                   "Session-only attachment capture keeps source metadata while retaining file bytes in memory")
        let memoryArchive = try JSONDecoder().decode(HistoryArchive.self, from: memoryFile.representations!["local.cclip.memory-attachments-v1"]!)
        try expect(memoryArchive.items.first?.sourceApp == memoryFile.sourceApp && memoryArchive.items.first?.sourceAppName == memoryFile.sourceAppName,
                   "The session-only embedded archive also retains the original provenance")
        try FileManager.default.removeItem(at: source)
        try memoryManager.writeToClipboard(memoryFile, board: output)
        let pasted = try ClipboardManager.readItem(from: output)!
        try expect(try String(contentsOfFile: pasted.fileURLs!.first!, encoding: .utf8) == "Synthetic source attachment bytes"
                   && store.readItems() == persistedBefore,
                   "Session-only paste restores attachment bytes without writing source records into persistent history")
    }
}
