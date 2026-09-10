import Foundation
import AppKit

/// Real app-core checks using synthetic data and named pasteboards; no permission requests or network calls.
enum AppSmokeTests {
    private static var checks = 0
    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw NSError(domain: "CClipSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1
        print("PASS \(checks): " + message)
        fflush(stdout)
    }
    @MainActor static func run() throws {
        let isolated = ProcessInfo.processInfo.environment["CCLIP_DATA_DIR"] ?? Bundle.main.object(forInfoDictionaryKey: "CClipTestDataDirectory") as? String
        guard let isolated, !isolated.isEmpty else { throw AutomationError.invalid("Set CCLIP_DATA_DIR to an empty temporary directory before running smoke tests.") }
        let root = StoragePaths.dataDirectory.appendingPathComponent("smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let board = NSPasteboard(name: .init("CClip.SyntheticSmoke.Input.\(UUID().uuidString)"))
        let output = NSPasteboard(name: .init("CClip.SyntheticSmoke.Output.\(UUID().uuidString)"))
        defer { board.releaseGlobally(); output.releaseGlobally() }
        let settings = SettingsManager.shared
        settings.enableHistoryPersistence = true; settings.maxItems = 0; settings.autoCleanupDays = 0
        let store = ClipboardStore(storageDirectory: root.appendingPathComponent("history"), getCleanupDays: { 0 })
        let manager = ClipboardManager(store: store, board: board, settings: settings)
        try captureAndFormats(manager, board, output)
        try undo(manager)
        try files(manager, board, output, root)
        try sessionOnly(store, board, output, settings, root)
        settings.enableHistoryPersistence = true; settings.maxItems = 0
        try readFailures(board, settings, root)
        try workflowReadProtection(root, store: manager.store)
        try workspace(manager, settings, root)
        try routes()
        try LanguageTests.run()
        try QuickPasteTests.run(manager: manager, root: root)
        try QuickPasteContextMenuTests.run()
        try ClipboardSourceTests.run(root: root, settings: settings)
        print("AppSmokeTests: \(checks) checks passed. Synthetic named pasteboards; no general clipboard, permissions or network requests.")
    }
    private static func captureAndFormats(_ manager: ClipboardManager, _ board: NSPasteboard, _ output: NSPasteboard) throws {
        let rich = Data("{\\rtf1\\ansi Synthetic rich text}".utf8)
        let html = Data("<b>Synthetic rich text</b>".utf8)
        let privateFormat = NSPasteboard.PasteboardType("com.example.synthetic-format")
        board.clearContents()
        try expect(board.setString("Synthetic rich text", forType: .string), "Named macOS pasteboard service must be accessible")
        board.setData(rich, forType: .rtf); board.setData(html, forType: .html); board.setData(Data([0, 2, 4]), forType: privateFormat)
        let saved = try manager.capture(from: board, sourceApp: "com.synthetic.source")!
        try expect(saved.sourceApp == "com.synthetic.source", "Capture must preserve source application")
        try manager.writeToClipboard(saved, board: output)
        try expect(output.string(forType: .string) == "Synthetic rich text", "Plain-text representation must round trip")
        try expect(output.data(forType: .rtf) == rich && output.data(forType: .html) == html, "RTF and HTML must round trip byte-for-byte")
        try expect(output.data(forType: privateFormat) == Data([0, 2, 4]), "Application-specific representations must round trip")
        try manager.writeToClipboard(saved, plainText: true, board: output)
        try expect(output.data(forType: .rtf) == nil && output.string(forType: .string) == saved.content, "Plain-text paste must omit rich formats")
        var edited = saved; edited.content = "Synthetic edited text"
        manager.update(edited)
        let updated = manager.clipboardItems.first(where: { $0.id == edited.id })!
        try manager.writeToClipboard(updated, board: output)
        try expect(output.string(forType: .string) == edited.content && output.data(forType: .rtf) == nil, "Editing rich text must invalidate obsolete formatted representations")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
        let png = bitmap.representation(using: .png, properties: [:])!
        let picture = try manager.addImage(png)
        try manager.writeToClipboard(picture, board: output)
        try expect(output.data(forType: .png) == png, "Stored PNG must paste without changing its image bytes")
        let count = manager.clipboardItems.count
        board.clearContents(); board.setString("Synthetic concealed", forType: .string)
        board.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        try expect(try manager.capture(from: board, sourceApp: "com.synthetic.source") == nil, "Concealed content must be excluded")
        board.clearContents(); board.setString("Synthetic excluded app", forType: .string)
        manager.excludedApplications = ["com.synthetic.excluded"]
        try expect(try manager.capture(from: board, sourceApp: "com.synthetic.excluded") == nil, "Excluded applications must not be captured")
        manager.sensitivePatterns = ["SYNTHETIC_SECRET_[0-9]+"]
        board.clearContents(); board.setString("SYNTHETIC_SECRET_123", forType: .string)
        try expect(try manager.capture(from: board, sourceApp: "com.synthetic.source") == nil, "Sensitive regex must be applied before saving")
        manager.captureAllowed = { false }
        try expect(try manager.capture(from: board, sourceApp: nil) == nil, "Locked capture must be skipped")
        try expect(manager.clipboardItems.count == count, "Excluded and locked captures must not change history")
        manager.captureAllowed = { true }; manager.sensitivePatterns = []; manager.excludedApplications = []
        manager.textTransform = { _, _ in throw AutomationError.invalid("Synthetic script failure") }
        board.clearContents(); board.setString("Synthetic unchanged fallback", forType: .string)
        let fallback = try manager.capture(from: board, sourceApp: "com.synthetic.source")!
        try expect(fallback.content == "Synthetic unchanged fallback" && manager.lastError != nil, "Copy script errors must preserve original text and be visible")
        try manager.writeToClipboard(fallback, board: output)
        try expect(output.string(forType: .string) == fallback.content && manager.lastError != nil, "Paste script errors must fall back to original text")
        manager.textTransform = nil
    }
    private static func undo(_ manager: ClipboardManager) throws {
        let a = try manager.addText("Synthetic undo A"), b = try manager.addText("Synthetic undo B")
        manager.deleteItem(a)
        let c = try manager.addText("Synthetic captured after delete")
        manager.undoDelete()
        try expect([a.id, b.id, c.id].allSatisfy { id in manager.clipboardItems.contains(where: { $0.id == id }) }, "Undo must retain content captured after deletion")
        manager.clearAllItems()
        let d = try manager.addText("Synthetic captured after clear")
        manager.undoDelete()
        try expect([a.id, b.id, c.id, d.id].allSatisfy { id in manager.clipboardItems.contains(where: { $0.id == id }) }, "Undo clear must merge the removed snapshot with subsequent captures")
        manager.deleteItems([a, b])
        let e = try manager.addText("Synthetic capture after batch deletion")
        manager.undoDelete()
        try expect([a.id, b.id, e.id].allSatisfy { id in manager.clipboardItems.contains(where: { $0.id == id }) }, "One undo must restore the entire deletion batch and retain later captures")
    }
    private static func files(_ manager: ClipboardManager, _ board: NSPasteboard, _ output: NSPasteboard, _ root: URL) throws {
        let a = root.appendingPathComponent("sourceA"), b = root.appendingPathComponent("sourceB")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let one = a.appendingPathComponent("same.txt"), two = b.appendingPathComponent("same.txt")
        try Data("Synthetic first file".utf8).write(to: one)
        try Data("Synthetic second file".utf8).write(to: two)
        var callback: ClipboardItem?
        manager.onCapture = { callback = $0 }
        board.clearContents(); board.writeObjects([one as NSURL, two as NSURL])
        let saved = try manager.capture(from: board, sourceApp: "com.synthetic.finder")!
        try expect(saved.fileURLs?.count == 2, "Multi-file capture must retain every selected file")
        try expect(callback?.fileURLs == saved.fileURLs && callback?.fileURLs?.contains(one.path) == false, "Capture callback must expose owned snapshots")
        try expect(try manager.capture(from: board, sourceApp: "com.synthetic.finder") == nil, "Repeated file capture must recognize the original content despite retained path changes")
        try FileManager.default.removeItem(at: a); try FileManager.default.removeItem(at: b)
        try manager.writeToClipboard(saved, board: output)
        let roundtrip = try ClipboardManager.readItem(from: output)!
        try expect(roundtrip.fileURLs?.count == 2, "Multi-file paste must write both file URLs")
        let contents = try Set(roundtrip.fileURLs!.map { try String(contentsOfFile: $0, encoding: .utf8) })
        try expect(contents == ["Synthetic first file", "Synthetic second file"], "Same-name file bytes must remain distinct after source deletion")
        let picture = manager.clipboardItems.first(where: { $0.type == .image && ($0.fileURLs ?? []).isEmpty })!
        let png = try Data(contentsOf: URL(fileURLWithPath: picture.filePath!))
        try manager.writeItemsToClipboard([saved, picture], board: output)
        let objects = output.pasteboardItems ?? []
        let urls = objects.compactMap { $0.string(forType: .fileURL) }.compactMap(URL.init(string:))
        try expect(urls.count == 2 && objects.contains(where: { $0.data(forType: .png) == png }), "Mixed file/image batches must retain both file URLs and original image data")
        try expect(try Set(urls.map { try String(contentsOf: $0, encoding: .utf8) }) == contents, "Batch copying must preserve each selected file's bytes")
        let firstText = ClipboardItem(id: UUID(), content: "Synthetic batch one", type: .text, timestamp: Date())
        let secondText = ClipboardItem(id: UUID(), content: "Synthetic batch two", type: .text, timestamp: Date())
        try manager.writeItemsToClipboard([firstText, secondText], separator: " | ", board: output)
        try expect(output.string(forType: .string) == "Synthetic batch one | Synthetic batch two", "Text batches must honor the selected separator")
        manager.onCapture = nil
    }
    private static func sessionOnly(_ store: ClipboardStore, _ board: NSPasteboard, _ output: NSPasteboard, _ settings: SettingsManager, _ root: URL) throws {
        let persistentBefore = try store.readItems()
        settings.enableHistoryPersistence = false
        let manager = ClipboardManager(store: store, board: board, settings: settings)
        try expect(manager.clipboardItems.isEmpty, "A session-only manager must not load persisted history")
        let a = try manager.addText("Synthetic RAM A")
        manager.deleteItem(a)
        let b = try manager.addText("Synthetic RAM B")
        manager.undoDelete(); manager.clearAllItems(); manager.undoDelete(); manager.reload()
        try expect(Set(manager.clipboardItems.map(\.id)) == [a.id, b.id], "Session-only delete, undo, clear and reload must preserve RAM semantics")
        try expect(try store.readItems() == persistentBefore, "Session-only actions must never write the history database")
        let source = root.appendingPathComponent("ram-file.txt")
        try Data("Synthetic RAM file bytes".utf8).write(to: source)
        let item = ClipboardItem(id: UUID(), content: "ram-file.txt", type: .file, timestamp: Date(), filePath: source.path, fileURLs: [source.path])
        let saved = try manager.ingest(item)
        try FileManager.default.removeItem(at: source)
        try expect(saved.filePath == nil && saved.fileURLs == nil, "Session-only file snapshots must not depend on source paths")
        try manager.writeToClipboard(saved, board: output)
        let pasted = try ClipboardManager.readItem(from: output)!
        try expect(try String(contentsOfFile: pasted.fileURLs!.first!, encoding: .utf8) == "Synthetic RAM file bytes", "Session-only file bytes must survive source deletion and materialize on paste")
        try expect(try store.readItems() == persistentBefore, "Session-only file capture and paste must not persist history")
    }
    private static func readFailures(_ board: NSPasteboard, _ settings: SettingsManager, _ root: URL) throws {
        let broken = root.appendingPathComponent("broken/2024-01-01")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("bad JSON fixture".utf8).write(to: broken.appendingPathComponent("items.json"))
        let store = ClipboardStore(storageDirectory: broken.deletingLastPathComponent(), getCleanupDays: { 0 })
        let manager = ClipboardManager(store: store, board: board, settings: settings)
        let sentinel = ClipboardItem(id: UUID(), content: "Synthetic last known item", type: .text, timestamp: Date())
        manager.clipboardItems = [sentinel]
        manager.reload()
        try expect(manager.clipboardItems == [sentinel] && manager.lastError != nil, "Read failure must preserve the last known memory snapshot and show an error")
    }
    private static func workflowReadProtection(_ root: URL, store: ClipboardStore) throws {
        let suite = "CClip.WorkflowSmoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var sample = ClipboardItem(id: UUID(), content: "Synthetic legacy workflow item", type: .text, timestamp: Date(), sourceApp: "com.synthetic.old", tags: ["Synthetic tag"])
        sample.representations = ["public.utf8-plain-text": Data(sample.content.utf8)]
        let encodedItem = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sample))
        let legacy: [String: Any] = ["language": "en", "stack": [encodedItem],
            "replies": [["title": "Synthetic legacy reply", "item": encodedItem]],
            "categories": [["name": "Synthetic legacy category"]]]
        let legacyBytes = try JSONSerialization.data(withJSONObject: legacy)
        let legacyURL = root.appendingPathComponent("legacy-workflow.json")
        try legacyBytes.write(to: legacyURL)
        let state = WorkflowState(fileURL: legacyURL, defaults: defaults)
        try expect(state.storageReadError == nil && state.document.stack.count == 1 && state.document.language == "en", "Older workflow documents must load when newer fields are missing")
        try expect(state.document.layout == "list" && state.document.shelf.isEmpty && !state.document.automaticBackup && state.document.autoRecognizeImages == nil, "Missing workflow fields must use safe defaults")
        try expect(state.document.replies.first?.group == "" && state.document.categories.first?.color == "blue", "Older reply and category records must decode missing optional fields")
        try expect(try Data(contentsOf: legacyURL) == legacyBytes, "Reading a legacy workflow must not rewrite its original file")
        state.document.layout = "horizontal"
        let stableReplyID = state.document.replies[0].id
        let reopened = WorkflowState(fileURL: legacyURL, defaults: defaults)
        try expect(reopened.document.layout == "horizontal" && reopened.document.replies[0].id == stableReplyID, "Saving a migrated workflow must retain content and generated record identities")
        state.addToStack(sample); state.addToStack(sample)
        let repeated = Array(state.document.stack.suffix(2))
        try expect(repeated[0].id != repeated[1].id && repeated.allSatisfy { $0.id != sample.id }, "Repeated stack entries must have independent identities")
        try expect(repeated.allSatisfy { $0.content == sample.content && $0.representations == sample.representations && $0.tags == sample.tags }, "Repeated stack entries must retain complete original metadata")
        let corruptURL = root.appendingPathComponent("corrupt-workflow.json")
        let corruptBytes = Data("{\"stack\":\"invalid synthetic type\"}".utf8)
        try corruptBytes.write(to: corruptURL)
        let damaged = WorkflowState(fileURL: corruptURL, defaults: defaults)
        try expect(damaged.storageReadError != nil && !damaged.status.isEmpty, "Malformed workflow data must expose a read error")
        damaged.document.language = "en"; damaged.addToStack(sample); damaged.save()
        try expect(try Data(contentsOf: corruptURL) == corruptBytes, "Edits after a failed workflow read must never overwrite the unread original")
        var replyArchive = try HistoryArchive.make(items: [])
        replyArchive.extraFiles = ["replies.json": Data("[]".utf8)]
        let repliesURL = root.appendingPathComponent("protected-replies.backup")
        try JSONEncoder().encode(replyArchive).write(to: repliesURL)
        let historyCount = try store.readItems().count
        do { try damaged.importReplies(from: repliesURL, using: store); throw AutomationError.invalid("Protected workflow import unexpectedly succeeded") }
        catch let error as NSError where error.domain == "CClip.Workflow" { checks += 1 }
        try expect(try Data(contentsOf: corruptURL) == corruptBytes && store.readItems().count == historyCount, "Reply import must respect workflow protection before any persistence changes")
        try Data("{\"language\":\"zh\"}".utf8).write(to: corruptURL)
        try damaged.reloadFromDisk()
        damaged.document.layout = "horizontal"
        let repaired = try JSONDecoder().decode(WorkflowDocument.self, from: Data(contentsOf: corruptURL))
        try expect(damaged.storageReadError == nil && damaged.status.isEmpty && repaired.layout == "horizontal", "Successful explicit reload after repair must restore saving")
        let absentURL = root.appendingPathComponent("new-workflow.json")
        let fresh = WorkflowState(fileURL: absentURL, defaults: defaults)
        try expect(fresh.storageReadError == nil && !FileManager.default.fileExists(atPath: absentURL.path), "A new workflow starts safely without an unnecessary initialization write")
        fresh.document.language = "en"
        try expect(FileManager.default.fileExists(atPath: absentURL.path), "New workflow edits must persist normally")
    }

    private static func routes() throws {
        let query = "你好 & spaces + symbols"
        var parts = URLComponents()
        parts.scheme = "xclip"; parts.host = "search"; parts.queryItems = [URLQueryItem(name: "q", value: query)]
        try expect(try ClipRoute.parse(parts.url!) == .search(query), "URL route must decode Chinese and reserved query characters")
        try expect(try ClipRoute.parse(URL(string: "cclip://show")!) == .show, "Previous CClip URL alias must remain compatible")
        try expect(try ClipRoute.parse(URL(string: "oneclip-dev://show")!) == .show, "Development URL alias must parse")
        let invalid = ["https://show", "xclip://unknown", "xclip://add?text=a&text=b", "xclip://user:password@show", "cclip://unknown", "cclip://add?text=a&text=b", "cclip://add?text=", "cclip://add", "cclip://user:password@show"]
        for source in invalid {
            do { _ = try ClipRoute.parse(URL(string: source)!); throw AutomationError.invalid("An invalid synthetic route was accepted") }
            catch ClipboardError.dataCorrupted { checks += 1 }
        }
        parts.host = "add"; parts.queryItems = [URLQueryItem(name: "text", value: String(repeating: "x", count: 1_048_577))]
        do { _ = try ClipRoute.parse(parts.url!); throw AutomationError.invalid("Oversized synthetic route was accepted") }
        catch ClipboardError.dataCorrupted { checks += 1 }
    }

    private static func workspace(_ manager: ClipboardManager, _ settings: SettingsManager, _ root: URL) throws {
        let suite = "CClip.SyntheticSmoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let scripts = ScriptService(defaults: defaults), ai = AIService(defaults: defaults)
        let workflow = WorkflowState.shared
        let fileItem = manager.clipboardItems.first(where: { ($0.fileURLs?.count ?? 0) > 0 })!
        var document = WorkflowDocument()
        document.stack = [fileItem]; document.shelf = [fileItem]
        let folder = root.appendingPathComponent("template-folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Synthetic nested template".utf8).write(to: folder.appendingPathComponent("nested.txt"))
        let folderItem = try manager.ingest(ClipboardItem(id: UUID(), content: "Synthetic directory template", type: .file, timestamp: Date(), fileURLs: [folder.path]))
        try FileManager.default.removeItem(at: folder)
        var reply = QuickReply(title: "Synthetic reply", item: folderItem)
        reply.hotkey = ShortcutSpec(keyCode: 18, modifiers: NSEvent.ModifierFlags.command.rawValue, label: "Synthetic shortcut")
        document.replies = [reply]; document.automaticBackup = true
        document.categories = [ClipCategory(name: "Synthetic category", pattern: "Synthetic")]
        document.excludedPatterns = "SYNTHETIC_PRIVATE"; document.language = "en"; document.layout = "horizontal"
        workflow.document = document
        settings.showLineNumbers = true
        scripts.scripts = [ClipboardScript(name: "Synthetic script", code: "input.toUpperCase()", trigger: "copy", enabled: true)]
        ai.configuration = AIConfiguration(provider: .ollama, endpoint: "http://127.0.0.1:11434", model: "synthetic-model", temperature: 0.4)
        let backup = WorkspaceBackup(clipboard: manager, workflow: workflow, settings: settings, scripts: scripts, ai: ai, defaults: defaults)
        let destination = root.appendingPathComponent("workspace.oneclipbackup")
        try backup.export(to: destination)
        let archive = try JSONDecoder().decode(HistoryArchive.self, from: Data(contentsOf: destination))
        let portable = try JSONDecoder().decode(WorkflowDocument.self, from: archive.extraFiles!["workflow.json"]!)
        try expect(portable.stack[0].fileURLs!.allSatisfy { $0.hasPrefix("attachments/") }, "Workflow backup must contain portable attachment paths")
        try expect(archive.extraFiles?["scripts.json"] != nil && archive.extraFiles?["ai-configuration.json"] != nil, "Backup must include current script and AI configuration")
        let historyIDs = Set(manager.clipboardItems.map(\.id))
        try manager.store.removeAllItems(includingProtected: true); manager.reload()
        workflow.document = WorkflowDocument(); settings.showLineNumbers = false; scripts.scripts = []; ai.configuration = AIConfiguration()
        try backup.restore(from: destination)
        try expect(Set(manager.clipboardItems.map(\.id)) == historyIDs, "Workspace restore must restore history")
        try expect(settings.showLineNumbers, "Workspace restore must apply ordinary UI settings")
        try expect(workflow.document.layout == "horizontal", "Horizontal layout must round trip through workspace backup")
        try expect(scripts.scripts.count == 1 && !scripts.scripts[0].enabled, "Imported scripts must be restored disabled")
        try expect(ai.configuration.model == "synthetic-model", "AI provider settings must restore without sending a request")
        try expect(workflow.document.replies.count == 1 && workflow.document.replies[0].hotkey == nil && !workflow.document.automaticBackup, "Imported templates must not activate shortcuts or automatic backups")
        try expect(workflow.document.stack[0].fileURLs!.allSatisfy { FileManager.default.fileExists(atPath: $0) }, "Restored workflow paths must reference retained attachments")
        try backup.restore(from: destination)
        try expect(workflow.document.stack.count == 1 && workflow.document.shelf.count == 1, "Repeated backup merge must not duplicate workflow snapshots")
        var malformed = archive
        malformed.extraFiles?["scripts.json"] = Data("invalid configuration".utf8)
        let bad = root.appendingPathComponent("malformed.oneclipbackup")
        try JSONEncoder().encode(malformed).write(to: bad)
        do { try backup.restore(from: bad); throw AutomationError.invalid("Malformed configuration was accepted") }
        catch is DecodingError { checks += 1 }
        try expect(Set(manager.clipboardItems.map(\.id)) == historyIDs, "Invalid configuration must fail before changing history")
        let repliesURL = root.appendingPathComponent("replies.oneclipbackup")
        try workflow.exportReplies(to: repliesURL)
        let count = try manager.store.readItems().count
        try workflow.importReplies(from: repliesURL, using: manager.store)
        try expect(workflow.document.replies.count == 2, "Portable reply import must append the template")
        let folderPath = workflow.document.replies.last!.item.fileURLs!.first!
        try expect(try String(contentsOfFile: folderPath + "/nested.txt", encoding: .utf8) == "Synthetic nested template", "Reply backups must support directories with nested attachments")
        try expect(try manager.store.readItems().count == count, "Reply import must not pollute ordinary clipboard history")
        let source = manager.store.getStorageInfo().cachePath
        let target = root.appendingPathComponent("moved-history")
        try backup.relocate(to: target)
        try expect(FileManager.default.fileExists(atPath: source + "/history.sqlite3"), "Relocation must retain its source database")
        try expect(Set(manager.clipboardItems.map(\.id)) == historyIDs && defaults.string(forKey: "local.cclip.historyDirectory") == target.path, "Relocation must select the imported destination without losing history")
    }
}
