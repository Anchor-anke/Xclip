import Foundation
import AppKit
import SQLite3

@main
struct StorageTests {
    static var checks = 0
    static let fm = FileManager.default

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw NSError(domain: "StorageTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1
    }

    static func item(_ content: String, type: ClipboardItemType = .text, date: Date = Date(),
                     data: Data? = nil, favorite: Bool = false, pinned: Bool = false,
                     files: [String]? = nil) -> ClipboardItem {
        ClipboardItem(id: UUID(), content: content, type: type, timestamp: date, data: data,
                      isFavorite: favorite, isPinned: pinned, sourceApp: "Synthetic StorageTests", tags: ["test"], fileURLs: files)
    }

    static func store(_ root: URL, _ name: String, limit: Int = 0, days: Int = 0) -> ClipboardStore {
        ClipboardStore(storageDirectory: root.appendingPathComponent(name), maxItems: limit, getCleanupDays: { days })
    }

    static func main() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("cclip-storage-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        try migrationAndDeletion(root)
        try retentionAndLimits(root)
        try attachmentAndBackup(root)
        try transactionsAndErrors(root)
        try workspaceBackup(root)
        try concurrentStores(root)
        try relocationAndIsolation(root)
        print("StorageTests: \(checks) checks passed; all fixtures isolated under temporary directories.")
    }

    static func migrationAndDeletion(_ root: URL) throws {
        let legacy = root.appendingPathComponent("legacy")
        let dateDirectory = legacy.appendingPathComponent("2024-01-02")
        try fm.createDirectory(at: dateDirectory, withIntermediateDirectories: true)
        let a = item("legacy A", date: Date(timeIntervalSince1970: 1_704_153_600), favorite: true)
        let b = item("legacy B", date: Date(timeIntervalSince1970: 1_704_153_601))
        let original = try JSONEncoder().encode([a, b])
        let oldFile = dateDirectory.appendingPathComponent("items.json")
        try original.write(to: oldFile)
        let destination = root.appendingPathComponent("migrated")
        var database: ClipboardStore? = ClipboardStore(storageDirectory: destination, legacyDirectory: legacy, getCleanupDays: { 0 })
        try expect(database!.loadItems().count == 2, "Legacy items must migrate")
        try expect(database!.loadItems().first(where: { $0.id == a.id })?.isFavorite == true, "Migration must preserve favorites")
        database!.deleteItem(b)
        database = nil
        database = ClipboardStore(storageDirectory: destination, legacyDirectory: legacy, getCleanupDays: { 0 })
        try expect(database!.loadItems().map(\.id) == [a.id], "Deleted legacy item must not resurrect after reopening")
        database!.deleteItem(a)
        database = nil
        database = ClipboardStore(storageDirectory: destination, legacyDirectory: legacy, getCleanupDays: { 0 })
        try expect(database!.loadItems().isEmpty, "Deleting last item must persist")
        try expect(try Data(contentsOf: oldFile) == original, "Migration must never mutate legacy JSON")
        let withoutData = "{\"id\":\"\(UUID().uuidString)\",\"content\":\"v1\",\"type\":\"text\",\"timestamp\":\"2024-01-01T00:00:00Z\"}"
        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: Data(withoutData.utf8))
        try expect(decoded.data == nil && !decoded.isPinned && decoded.tags.isEmpty, "Old records without optional keys must decode")
        try expect(decoded.timestamp.timeIntervalSince1970 == 1_704_067_200, "Whole-second ISO dates must preserve exact original time")
        let oldRoot = root.appendingPathComponent("legacy-fake-file")
        let oldDate = oldRoot.appendingPathComponent("2024-01-03")
        try fm.createDirectory(at: oldDate, withIntermediateDirectories: true)
        let actual = root.appendingPathComponent("actual-invoice.pdf")
        try Data("actual PDF payload".utf8).write(to: actual)
        let fakeFile = oldDate.appendingPathComponent("invoice.pdf")
        let fileInfo = try JSONSerialization.data(withJSONObject: [["name": actual.lastPathComponent, "path": actual.path]])
        try fileInfo.write(to: fakeFile)
        var oldItem = item("File metadata stored as PDF", type: .file)
        oldItem.filePath = fakeFile.path
        try JSONEncoder().encode([oldItem]).write(to: oldDate.appendingPathComponent("items.json"))
        let recovered = ClipboardStore(storageDirectory: root.appendingPathComponent("fake-recovered"), legacyDirectory: oldRoot, getCleanupDays: { 0 })
        let recoveredItem = recovered.loadItems().first!
        try expect(recoveredItem.filePath == nil && recoveredItem.fileURLs?.count == 1, "Legacy fake-file JSON must recover the real referenced file")
        try expect(try String(contentsOfFile: recoveredItem.fileURLs!.first!, encoding: .utf8) == "actual PDF payload", "Legacy migration must snapshot actual file bytes instead of JSON masquerading as a PDF")
        try expect(try Data(contentsOf: fakeFile) == fileInfo, "Legacy attachment metadata must remain untouched")
    }

    static func retentionAndLimits(_ root: URL) throws {
        let database = store(root, "limits", days: 1)
        let old = Date().addingTimeInterval(-10 * 86_400)
        let favoriteA = item("Favorite A", date: old, favorite: true)
        let favoriteB = item("Favorite B", date: old, favorite: true)
        let pinned = item("Pinned", date: old, pinned: true)
        let expired = item("Expired", date: old)
        _ = try database.replaceItems([favoriteA, favoriteB, pinned, expired, item("Fresh")])
        database.performRetentionCleanup()
        try expect(database.loadItems().count == 4, "Retention must use timestamp and retain protected entries")
        database.clearAllItems()
        try expect(Set(database.loadItems().map(\.id)) == Set([favoriteA.id, favoriteB.id, pinned.id]), "Clear must retain every favorite and pinned item")
        let lots = (0..<150).map { item("History \($0)", date: Date().addingTimeInterval(Double($0))) }
        _ = try database.replaceItems(lots + [favoriteA, favoriteB, pinned])
        try expect(database.loadItems().count == 153, "Default history must not silently truncate to 100")
        try database.setItemLimit(5)
        try expect(database.loadItems().count == 8, "Limit must retain five normal plus all protected records")
        try expect(database.loadItems().first?.isPinned == true, "Pinned entries must sort first")
        try database.setItemLimit(0)
        let edited = try database.updateItem(id: favoriteA.id, content: "Edited", tags: [" B ", "B", "A"])
        try expect(edited.content == "Edited" && edited.tags == ["A", "B"] && edited.isFavorite, "Editing must persist text and normalized tags without losing protection")
        let reload = store(root, "limits")
        try expect(reload.loadItems().first(where: { $0.id == favoriteA.id })?.content == "Edited", "Editing must survive reopening")
    }

    static func attachmentAndBackup(_ root: URL) throws {
        let sourceA = root.appendingPathComponent("source-a")
        let sourceB = root.appendingPathComponent("source-b")
        try fm.createDirectory(at: sourceA, withIntermediateDirectories: true)
        try fm.createDirectory(at: sourceB, withIntermediateDirectories: true)
        let first = sourceA.appendingPathComponent("same.pdf")
        let second = sourceB.appendingPathComponent("same.pdf")
        try Data("first PDF synthetic".utf8).write(to: first)
        try Data("second PDF synthetic".utf8).write(to: second)
        let folder = sourceA.appendingPathComponent("Folder")
        try fm.createDirectory(at: folder.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data("nested payload".utf8).write(to: folder.appendingPathComponent("nested.txt"))
        let database = store(root, "attachments")
        let metadata = try JSONSerialization.data(withJSONObject: [["name": "same.pdf", "path": first.path], ["name": "same.pdf", "path": second.path]])
        let document = try database.upsert(item("Two same names", type: .document, data: metadata, favorite: true))
        let paths = document.fileURLs!
        try expect(paths.count == 2 && paths[0] != paths[1], "Same-name files must have unique retained paths")
        try expect(paths.allSatisfy { URL(fileURLWithPath: $0).lastPathComponent == "same.pdf" }, "Retained files must preserve names and extensions")
        try expect(try Set(paths.map { try String(contentsOfFile: $0, encoding: .utf8) }) == Set(["first PDF synthetic", "second PDF synthetic"]), "Same-name snapshots must not overwrite")
        let folderItem = try database.upsert(item("Folder", type: .file, files: [folder.path]))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
        let imageBytes = bitmap.tiffRepresentation!
        let picture = try database.upsert(item("Image", type: .image, data: imageBytes, favorite: true))
        try expect(["tiff", "tif"].contains(URL(fileURLWithPath: picture.filePath!).pathExtension), "TIFF bytes must not get a fake PNG extension")
        try expect(try Data(contentsOf: URL(fileURLWithPath: picture.filePath!)) == imageBytes, "Image encoding must be byte-preserved")
        var rich = item("Rich synthetic text")
        rich.representations = ["public.rtf": Data("{\\rtf1 Synthetic}".utf8), "com.example.private-rich": Data([0, 1, 2])]
        _ = try database.upsert(rich)
        database.deleteItem(folderItem)
        try expect(fm.fileExists(atPath: folderItem.fileURLs!.first!), "Delete must keep attachment usable for undo")
        _ = try database.replaceItems(database.loadItems() + [folderItem])
        try fm.removeItem(at: sourceA)
        try fm.removeItem(at: sourceB)
        let archiveURL = root.appendingPathComponent("portable.cclipbackup")
        try database.exportBackup(to: archiveURL)
        let archive = try JSONDecoder().decode(HistoryArchive.self, from: Data(contentsOf: archiveURL))
        try archive.validate()
        try expect(archive.items.flatMap { ClipboardAttachments.paths(in: $0) }.allSatisfy { $0.hasPrefix("attachments/") }, "Archive must use portable paths")
        try expect(!String(decoding: Data(contentsOf: archiveURL), as: UTF8.self).contains(root.path), "Archive must not retain absolute source/store paths")
        let restored = store(root, "restored")
        _ = try restored.importBackup(from: archiveURL, merge: false)
        let restoredItems = restored.loadItems()
        try expect(Set(restoredItems.map(\.id)) == Set(database.loadItems().map(\.id)), "Restore must retain all item identities")
        let restoredImage = restoredItems.first { $0.id == picture.id }!
        try expect(try Data(contentsOf: URL(fileURLWithPath: restoredImage.filePath!)) == imageBytes, "Portable restore must include image bytes")
        let restoredFolder = restoredItems.first { $0.id == folderItem.id }!.fileURLs!.first!
        try expect(fm.fileExists(atPath: restoredFolder + "/empty"), "Portable restore must retain empty directories")
        try expect(try String(contentsOfFile: restoredFolder + "/nested.txt", encoding: .utf8) == "nested payload", "Portable restore must include nested files")
        try expect(restoredItems.first { $0.id == rich.id }!.representations == rich.representations, "Backup must preserve every rich-text representation")
        restored.performManualCleanup()
        let protected = restored.loadItems()
        try expect(protected.count == 2, "Manual cleanup must retain both favorite items")
        try expect(protected.flatMap { ClipboardAttachments.paths(in: $0) }.allSatisfy { fm.fileExists(atPath: $0) }, "Favorite attachment files must survive clearing")
        var badArchive = archive
        if let i = badArchive.files.firstIndex(where: { !$0.isDirectory }) { badArchive.files[i].data = Data("tampered".utf8) }
        let badURL = root.appendingPathComponent("bad.backup")
        try JSONEncoder().encode(badArchive).write(to: badURL)
        do { _ = try restored.importBackup(from: badURL, merge: false); throw NSError(domain: "Expected corrupt archive failure", code: 1) }
        catch ClipboardStorageError.invalidArchive { }
        try expect(restored.lastError != nil, "Bad backup errors must be visible")
        try expect(restored.loadItems() == protected, "Bad backup must not modify existing history")
        badArchive = archive
        badArchive.files[0].path = "attachments/../../escape"
        try JSONEncoder().encode(badArchive).write(to: badURL)
        do { _ = try restored.importBackup(from: badURL, merge: false); throw NSError(domain: "Expected traversal failure", code: 1) }
        catch ClipboardStorageError.invalidArchive { }
        try expect(restored.loadItems() == protected, "Traversal archive must not modify history")
    }

    static func transactionsAndErrors(_ root: URL) throws {
        let database = store(root, "rollback")
        let original = item("Keep me")
        _ = try database.upsert(original)
        let dataItem = item("new.bin", type: .file, data: Data([1, 2, 3]))
        let missing = item("missing", type: .file, files: [root.appendingPathComponent("does-not-exist").path])
        do { _ = try database.replaceItems([dataItem, missing]); throw NSError(domain: "Expected attachment failure", code: 1) }
        catch ClipboardStorageError.unsupportedAttachment { }
        try expect(database.lastError != nil, "Attachment errors must be observable")
        try expect(database.loadItems().map(\.id) == [original.id], "Failed replacement must roll back history deletion")
        let attachments = root.appendingPathComponent("rollback/attachments")
        try expect(try fm.contentsOfDirectory(atPath: attachments.path).isEmpty, "Failed transaction must remove staged attachments")
        let broken = root.appendingPathComponent("broken/2024-01-01")
        try fm.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not JSON".utf8).write(to: broken.appendingPathComponent("items.json"))
        let brokenStore = store(root, "broken")
        try expect(brokenStore.lastError != nil, "Corrupt legacy JSON must report migration failure")
        do { _ = try brokenStore.upsert(item("must not write after failed migration")); throw NSError(domain: "Expected unavailable failure", code: 1) }
        catch ClipboardStorageError.unavailable { checks += 1 }
        let source = root.appendingPathComponent("link-source")
        try Data([7]).write(to: source)
        let link = root.appendingPathComponent("symlink")
        try fm.createSymbolicLink(at: link, withDestinationURL: source)
        do { _ = try database.upsert(item("link", type: .file, files: [link.path])); throw NSError(domain: "Expected symlink rejection", code: 1) }
        catch ClipboardStorageError.unsupportedAttachment { }
        try expect(database.loadItems().map(\.id) == [original.id], "Unsupported attachment must leave existing history intact")
    }

    static func workspaceBackup(_ root: URL) throws {
        let source = store(root, "workspace-source")
        let captured = try source.upsert(item("Captured"))
        let shelf = try source.upsert(item("shelf.bin", type: .file, data: Data([10, 20, 30])))
        source.deleteItem(shelf)
        let backup = root.appendingPathComponent("workspace.backup")
        let settings = Data("{\"language\":\"zh-Hans\"}".utf8)
        try source.exportBackup(to: backup, additionalItems: [shelf], extraFiles: ["settings.json": settings])
        let destination = store(root, "workspace-destination")
        let restored = try destination.importWorkspaceBackup(from: backup, merge: false)
        try expect(restored.items.map(\.id) == [captured.id], "Workspace snapshots must not be inserted into history")
        try expect(restored.additionalItems.count == 1 && restored.additionalItems[0].id == shelf.id, "Workspace backup must restore independently saved item snapshots")
        try expect(restored.extraFiles["settings.json"] == settings, "Workspace backup must preserve named settings bytes")
        let restoredPath = restored.additionalItems[0].filePath!
        try expect(try Data(contentsOf: URL(fileURLWithPath: restoredPath)) == Data([10, 20, 30]), "Workspace snapshot attachments must survive removal from visible history")
        try destination.purgeUnreferencedAttachments(preserving: restored.additionalItems)
        try expect(fm.fileExists(atPath: restoredPath), "Explicit maintenance must preserve provided workflow references")
        try destination.purgeUnreferencedAttachments()
        try expect(!fm.fileExists(atPath: restoredPath), "Explicit maintenance may delete attachments only after all references are removed")
        do { try source.exportBackup(to: root.appendingPathComponent("workspace-source/history.sqlite3")); throw NSError(domain: "Expected reserved-path failure", code: 1) }
        catch ClipboardStorageError.invalidArchive { checks += 1 }
        try expect(source.loadItems().map(\.id) == [captured.id], "Export must not overwrite its own database")
    }

    static func relocationAndIsolation(_ root: URL) throws {
        let existing = store(root, "occupied")
        let sentinel = try existing.upsert(item("Existing destination history"))
        let rejected = ClipboardStore(storageDirectory: root.appendingPathComponent("occupied"), requiresEmptyStore: true, getCleanupDays: { 0 })
        try expect(rejected.lastError != nil, "Directory relocation must reject occupied destination")
        try expect(existing.loadItems().map(\.id) == [sentinel.id], "Rejected relocation must preserve destination data")
        let old = ProcessInfo.processInfo.environment["CCLIP_DATA_DIR"]
        setenv("CCLIP_DATA_DIR", root.appendingPathComponent("isolated-default").path, 1)
        defer {
            if let old { setenv("CCLIP_DATA_DIR", old, 1) } else { unsetenv("CCLIP_DATA_DIR") }
        }
        try expect(StoragePaths.historyDirectory == StoragePaths.dataDirectory, "Test override must take precedence over selected history directory")
        try expect(StoragePaths.cacheDirectory == StoragePaths.dataDirectory.appendingPathComponent("cache", isDirectory: true), "Test override must isolate the cache")
        let defaultStore = ClipboardStore(getCleanupDays: { 0 })
        _ = try defaultStore.upsert(item("Isolated default"))
        try expect(defaultStore.getStorageInfo().cachePath.hasPrefix(root.path), "Default store must respect process test isolation")
    }

    static func concurrentStores(_ root: URL) throws {
        let a = store(root, "concurrent")
        let b = store(root, "concurrent")
        let group = DispatchGroup()
        for i in 0..<20 {
            group.enter()
            DispatchQueue.global().async {
                (i % 2 == 0 ? a : b).saveItem(item("Concurrent \(i)"))
                group.leave()
            }
        }
        group.wait()
        try expect(a.loadItems().count == 20 && b.loadItems().count == 20, "Concurrent store instances must not lose committed updates")
        var sqlite: OpaquePointer?
        sqlite3_open(root.appendingPathComponent("concurrent/history.sqlite3").path, &sqlite)
        defer { sqlite3_close(sqlite) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(sqlite, "PRAGMA journal_mode", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        try expect(sqlite3_step(statement) == SQLITE_ROW && String(cString: sqlite3_column_text(statement, 0)) == "wal", "Database must use SQLite WAL")
    }
}
