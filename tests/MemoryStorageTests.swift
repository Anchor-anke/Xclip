import Foundation
import SQLite3

@main
struct MemoryStorageTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw NSError(domain: "MemoryStorageTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1
    }
    static func sql(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw ClipboardStorageError.unavailable }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ClipboardStorageError.database(String(cString: sqlite3_errmsg(db))) }
    }
    static func seedLegacy(_ directory: URL, _ items: [ClipboardItem]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("history.sqlite3")
        try sql(url, "CREATE TABLE items(id TEXT PRIMARY KEY, timestamp REAL NOT NULL, favorite INTEGER NOT NULL DEFAULT 0, pinned INTEGER NOT NULL DEFAULT 0, payload BLOB NOT NULL)")
        var db: OpaquePointer?; sqlite3_open(url.path, &db); defer { sqlite3_close(db) }
        for item in items {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO items VALUES (?, ?, 0, 0, ?)", -1, &statement, nil)
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, item.id.uuidString, -1, transient)
            sqlite3_bind_double(statement, 2, item.timestamp.timeIntervalSince1970)
            let bytes = try JSONEncoder().encode(item)
            _ = bytes.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), transient) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw ClipboardStorageError.unavailable }
        }
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xclip-memory-storage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let formats = ["public.tiff": Data(repeating: 42, count: 2 * 1024 * 1024), "com.synthetic.rich": Data([0, 1, 255])]
        let longText = String(repeating: "长文本与école ", count: 5000) + "SEARCH_AT_THE_END"
        let original = ClipboardItem(id: UUID(), content: longText, type: .text, timestamp: Date(), representations: formats)
        let migratedRoot = root.appendingPathComponent("migration")
        try seedLegacy(migratedRoot, [original])
        try Data("{\"stack\":[]}".utf8).write(to: migratedRoot.appendingPathComponent("workflow.json"))
        var store: ClipboardStore? = ClipboardStore(storageDirectory: migratedRoot, getCleanupDays: { 0 })
        let saved = try store!.readItems().first!
        try expect(saved.residentPayloadBytes < 16 * 1024, "Large text and formats must not live in metadata")
        try expect(saved.content == longText && saved.representations == formats, "On-demand reads preserve exact bytes and text")
        try expect(saved.contentReference != nil && saved.representationReferences?.count == 2, "Large content uses references")
        try expect(FileManager.default.fileExists(atPath: migratedRoot.appendingPathComponent("pre-memory-v2.sqlite3").path), "Migration retains a rollback snapshot")
        try expect(try Data(contentsOf: migratedRoot.appendingPathComponent("pre-memory-v2.workflow.json")) == Data("{\"stack\":[]}".utf8), "Migration preserves the previous workflow configuration")
        try expect(try store!.searchItems("SEARCH_AT_THE_END école").map(\.id) == [saved.id], "Search reaches full text beyond the preview")
        let decodes = store!.decodedRecordCount
        _ = store!.getStorageInfo()
        try expect(store!.decodedRecordCount == decodes, "Storage statistics never decode history payloads")
        let exported = root.appendingPathComponent("backup.json")
        try store!.exportBackup(to: exported)
        let restored = ClipboardStore(storageDirectory: root.appendingPathComponent("restored"), getCleanupDays: { 0 })
        let imported = try restored.importBackup(from: exported).first!
        try expect(imported.content == longText && imported.representations == formats, "Version 2 archive round-trips payload references")
        try expect(imported.payloadReferences.allSatisfy { !$0.path.hasPrefix(migratedRoot.path) }, "Restored references belong to the destination")
        store = nil
        store = ClipboardStore(storageDirectory: migratedRoot, getCleanupDays: { 0 })
        try expect(try store!.readItems().first?.representations == formats, "Reopening migrated history preserves original formats")
        let corrupt = saved.representationReferences!["public.tiff"]!
        try Data([9]).write(to: URL(fileURLWithPath: corrupt.path))
        do { _ = try saved.materialized(); throw ClipboardStorageError.database("Expected verification failure") }
        catch ClipboardBlobError.corrupted { checks += 1 }
        try formats["public.tiff"]!.write(to: URL(fileURLWithPath: corrupt.path))
        try expect(try store!.compactIfNeeded(minimumFreeBytes: 0), "Idle compaction reclaims the large free region left by migration")
        try expect(try store!.readItems().first?.representations == formats, "Compaction preserves referenced content")

        let paged = ClipboardStore(storageDirectory: root.appendingPathComponent("paging"), getCleanupDays: { 0 })
        var expected = Set<UUID>()
        let tie = Date(timeIntervalSince1970: 1_700_000_000.1234567)
        for i in 0..<207 {
            var item = ClipboardItem(id: UUID(), content: "index \(i)", type: .text, timestamp: tie, representations: formats)
            item.isPinned = i % 3 == 0; expected.insert(item.id); _ = try paged.upsert(item)
        }
        var cursor: ClipboardStore.PageCursor?, seen: [UUID] = []
        repeat {
            let page = try paged.readPage(after: cursor)
            try expect(page.items.count <= 100, "Pages obey the requested size")
            seen += page.items.map(\.id); cursor = page.next
        } while cursor != nil
        try expect(seen.count == 207 && Set(seen) == expected, "Tied timestamps and pinned boundaries neither skip nor duplicate records")
        let references = try paged.readItems().flatMap { $0.payloadReferences.map(\.path) }
        try expect(Set(references).count == 2, "Identical raw formats share only two content-addressed files")
        try expect(try paged.readItems().reduce(0) { $0 + $1.residentPayloadBytes } < 10_000, "History metadata remains small as item count grows")

        let gc = ClipboardStore(storageDirectory: root.appendingPathComponent("gc"), getCleanupDays: { 0 })
        var lease: ClipboardItem? = try gc.upsert(ClipboardItem(id: UUID(), content: "lease", type: .text, timestamp: Date(), representations: formats))
        let paths = lease!.payloadReferences.map(\.path)
        try gc.removeAllItems(includingProtected: true)
        let now = Date()
        let protected = try gc.maintainAttachments(now: now, grace: 10)
        try expect(protected.candidates == 0 && paths.allSatisfy { FileManager.default.fileExists(atPath: $0) }, "A live undo/task snapshot protects its files")
        lease = nil
        let marked = try gc.maintainAttachments(now: now, grace: 10)
        try expect(marked.candidates == 2 && marked.removed == 0, "First pass marks orphans without deleting them")
        let removed = try gc.maintainAttachments(now: now.addingTimeInterval(11), grace: 10)
        try expect(removed.removed == 2 && paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) }, "Expired unreferenced payloads are reclaimed")

        let badRoot = root.appendingPathComponent("interrupted")
        try seedLegacy(badRoot, [original])
        try sql(badRoot.appendingPathComponent("history.sqlite3"), "INSERT INTO items VALUES ('bad', 0, 0, 0, x'00')")
        var broken: ClipboardStore? = ClipboardStore(storageDirectory: badRoot)
        try expect(broken!.lastError != nil, "A corrupt row aborts migration with a visible error")
        broken = nil
        try sql(badRoot.appendingPathComponent("history.sqlite3"), "DELETE FROM items WHERE id='bad'")
        let resumed = ClipboardStore(storageDirectory: badRoot)
        try expect(try resumed.readItems().first?.representations == formats, "Migration resumes after a failed row without losing committed content")
        let deniedRoot = root.appendingPathComponent("write-failure")
        try seedLegacy(deniedRoot, [original])
        let attachmentRoot = deniedRoot.appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: attachmentRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: attachmentRoot.path)
        var denied: ClipboardStore? = ClipboardStore(storageDirectory: deniedRoot)
        try expect(denied!.lastError != nil, "An unwritable content directory prevents partial migration")
        denied = nil
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: attachmentRoot.path)
        let retried = ClipboardStore(storageDirectory: deniedRoot)
        try expect(try retried.readItems().first?.representations == formats, "A filesystem write failure can be retried without losing the original bytes")
        print("MemoryStorageTests: \(checks) checks passed; isolated fixtures only.")
    }
}
