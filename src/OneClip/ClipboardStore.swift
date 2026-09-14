import Foundation
import Combine
import SQLite3
import ImageIO
import UniformTypeIdentifiers
import Darwin

/// SQLite is authoritative. Legacy JSON is read once and is never rewritten or deleted.
/// A recursive lock serializes callers, and BEGIN IMMEDIATE serializes separate store instances.
final class ClipboardStore: ObservableObject {
    struct StorageInfo {
        let itemCount: Int
        let totalSize: Int64
        let cachePath: String
    }

    @Published private(set) var lastError: String?
    private var lastFailure: Error?
    private var languageObserver: NSObjectProtocol?
    private let fileManager = FileManager.default
    private let storeLock = NSRecursiveLock()
    private let storageDirectory: URL
    private let attachmentDirectory: URL
    private let getCleanupDays: () -> Int
    private var maxItems: Int
    private var database: OpaquePointer?
    private var cleanupTimer: Timer?
    private var createdDirectories: [URL] = []
    private(set) var decodedRecordCount = 0
    private var orphanCandidates: [String: Date] = [:]
    private var usageLock: Int32 = -1
    private let rollbackName = "pre-memory-v2.sqlite3"
    struct PageCursor { let pinned: Bool; let timestamp: Date; let id: UUID }
    struct Page { let items: [ClipboardItem]; let next: PageCursor? }
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(storageDirectory: URL? = nil, legacyDirectory: URL? = nil, maxItems: Int = 0,
         requiresEmptyStore: Bool = false, getCleanupDays: @escaping () -> Int = { 30 }) {
        let directory = (storageDirectory ?? StoragePaths.historyDirectory).standardizedFileURL
        self.storageDirectory = directory
        self.attachmentDirectory = directory.appendingPathComponent("attachments", isDirectory: true)
        self.maxItems = max(0, maxItems)
        self.getCleanupDays = getCleanupDays
        languageObserver = NotificationCenter.default.addObserver(forName: AppLanguage.didChange, object: AppLanguage.shared, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.lastError = self.lastFailure?.localizedDescription
        }
        do {
            try fileManager.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
            usageLock = open(directory.appendingPathComponent(".xclip-usage-lock").path, O_CREAT | O_RDWR, 0o600)
            guard usageLock >= 0, flock(usageLock, LOCK_SH) == 0 else { throw ClipboardStorageError.unavailable }
            var handle: OpaquePointer?
            let status = sqlite3_open_v2(directory.appendingPathComponent("history.sqlite3").path, &handle,
                                         SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
            database = handle
            guard status == SQLITE_OK else { throw dbError() }
            sqlite3_busy_timeout(handle, 5000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA foreign_keys=ON")
            try execute("CREATE TABLE IF NOT EXISTS items (id TEXT PRIMARY KEY, timestamp REAL NOT NULL, favorite INTEGER NOT NULL DEFAULT 0, pinned INTEGER NOT NULL DEFAULT 0, payload BLOB NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS items_order ON items(pinned DESC, timestamp DESC)")
            try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            if requiresEmptyStore {
                guard try readItemsUnsafe().isEmpty else {
                    throw ClipboardStorageError.invalidArchive("目标目录已有历史数据，请选择空目录", "The destination already contains history. Choose an empty directory")
                }
                let children = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                guard !children.contains(where: { fileManager.fileExists(atPath: $0.appendingPathComponent("items.json").path) }) else {
                    throw ClipboardStorageError.invalidArchive("目标目录含有旧版历史数据，请选择空目录", "The destination contains legacy history. Choose an empty directory")
                }
            }
            try installPayloadSchema()
            try migrateLegacyDirectory(from: legacyDirectory ?? directory)
            try migrateInlinePayloads()
            // Settings can enable cleanup after launch, so always schedule and check dynamically.
            cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                self?.performRetentionCleanup()
            }
        } catch {
            // A failed migration must not leave a writable, partially initialized store that
            // could later re-import deleted records when the migration is retried.
            if let database { sqlite3_close_v2(database) }
            database = nil
            report(error)
        }
    }

    deinit {
        cleanupTimer?.invalidate()
        if usageLock >= 0 { flock(usageLock, LOCK_UN); close(usageLock) }
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
        if let database { sqlite3_close_v2(database) }
    }

    // MARK: Compatibility API

    func saveItem(_ item: ClipboardItem) {
        do { _ = try upsert(item) } catch { report(error) }
    }

    func loadItems() -> [ClipboardItem] {
        do { return try readItems() } catch { report(error); return [] }
    }

    func deleteItem(_ item: ClipboardItem) {
        do { try deleteItems(ids: [item.id]) } catch { report(error) }
    }

    /// Favorites and pinned items are protected from routine clearing and retention.
    func clearAllItems() {
        do { try removeAllItems(includingProtected: false) } catch { report(error) }
    }

    func performManualCleanup() { clearAllItems() }

    // MARK: Throwing API used by editing, undo, import and integrations

    func readItems() throws -> [ClipboardItem] {
        try locked {
            let result = try readItemsUnsafe()
            clearError()
            return result
        }
    }

    @discardableResult
    func upsert(_ item: ClipboardItem) throws -> ClipboardItem {
        try observed {
            try transaction {
                let stored = try persistAttachments(for: item)
                try write(stored)
                try enforceLimit()
                return stored
            }
        }
    }

    @discardableResult
    func updateItem(id: UUID, content: String? = nil, isFavorite: Bool? = nil,
                    isPinned: Bool? = nil, tags: [String]? = nil) throws -> ClipboardItem {
        try observed {
            try transaction {
                guard var item = try readItemUnsafe(id: id) else {
                    throw ClipboardStorageError.itemNotFound
                }
                if let content {
                    item.content = content
                    // Editing text invalidates older rich-text representations of that text.
                    if item.type == .text { item.data = nil; item.representations = nil }
                }
                if let isFavorite { item.isFavorite = isFavorite }
                if let isPinned { item.isPinned = isPinned }
                if let tags { item.tags = Array(Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted() }
                let stored = try persistAttachments(for: item)
                try write(stored)
                return stored
            }
        }
    }

    /// Replaces the entire history atomically. Attachments remain available to undo and saved workflows.
    @discardableResult
    func replaceItems(_ items: [ClipboardItem]) throws -> [ClipboardItem] {
        try observed {
            guard Set(items.map(\.id)).count == items.count else {
                throw ClipboardStorageError.invalidArchive("不能保存重复的项目 ID", "Cannot save duplicate item IDs")
            }
            return try transaction {
                let prepared = try items.map { try persistAttachments(for: $0) }
                try execute("DELETE FROM items")
                for item in prepared { try write(item) }
                try enforceLimit()
                return try readItemsUnsafe()
            }
        }
    }

    @discardableResult
    func restoreItems(_ items: [ClipboardItem]) throws -> [ClipboardItem] { try replaceItems(items) }

    func deleteItems(ids: [UUID]) throws {
        try observed {
            try transaction {
                for id in ids {
                    let statement = try prepare("DELETE FROM items WHERE id = ?")
                    defer { sqlite3_finalize(statement) }
                    try bind(id.uuidString, at: 1, to: statement)
                    try stepDone(statement)
                }
            }
        }
    }

    func removeAllItems(includingProtected: Bool = false) throws {
        try observed {
            try transaction {
                try execute(includingProtected ? "DELETE FROM items" : "DELETE FROM items WHERE favorite = 0 AND pinned = 0")
            }
        }
    }

    /// Zero means unlimited. Protected entries never count against the unprotected allowance.
    func setItemLimit(_ limit: Int) throws {
        try observed {
            let previous = maxItems
            maxItems = max(0, limit)
            do { try transaction { try enforceLimit() } }
            catch { maxItems = previous; throw error }
        }
    }

    func performRetentionCleanup() {
        guard getCleanupDays() > 0 else { return }
        do {
            try observed {
                try transaction {
                    let cutoff = Date().addingTimeInterval(-Double(getCleanupDays()) * 86_400)
                    let statement = try prepare("DELETE FROM items WHERE favorite = 0 AND pinned = 0 AND timestamp < ?")
                    defer { sqlite3_finalize(statement) }
                    guard sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970) == SQLITE_OK else { throw dbError() }
                    try stepDone(statement)
                }
            }
        } catch { report(error) }
    }

    // MARK: Portable backup and non-destructive legacy migration

    func exportBackup(to url: URL, additionalItems: [ClipboardItem] = [], extraFiles: [String: Data] = [:]) throws {
        try observed {
            let target = url.standardizedFileURL.resolvingSymlinksInPath().path
            let reserved = storageDirectory.resolvingSymlinksInPath().path
            guard !target.hasPrefix(reserved + "/") else {
                throw ClipboardStorageError.invalidArchive("请将备份导出到应用数据目录之外", "Export the backup outside the application data directory")
            }
            // A transaction keeps the metadata snapshot consistent across store instances.
            try transaction {
                try HistoryArchive.write(items: readItemsUnsafe(), additionalItems: additionalItems, to: url) { _ in extraFiles }
            }
        }
    }

    @discardableResult
    func importBackup(from url: URL, merge: Bool = true) throws -> [ClipboardItem] {
        try importWorkspaceBackup(from: url, merge: merge).items
    }

    @discardableResult
    func importWorkspaceBackup(from url: URL, merge: Bool = true) throws -> BackupImportResult {
        try observed {
            let archive = try JSONDecoder().decode(HistoryArchive.self, from: Data(contentsOf: url))
            try archive.validate() // No history or attachments have changed yet.
            let stage = storageDirectory.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: stage) }
            let imported = try archive.unpackWorkspace(to: stage)
            return try transaction {
                let prepared = try imported.items.map { try persistAttachments(for: $0) }
                let additional = try imported.additionalItems.map { try persistAttachments(for: $0) }
                if !merge { try execute("DELETE FROM items") }
                for item in prepared { try write(item) }
                // Explicit restore preserves all archived records, even above a configured capture limit.
                return BackupImportResult(items: try readItemsUnsafe(), additionalItems: additional, extraFiles: imported.extraFiles)
            }
        }
    }

    func migrateLegacyDirectory(from directory: URL) throws {
        try observed {
            let marker = "legacy_json_v1:" + directory.standardizedFileURL.resolvingSymlinksInPath().path
            try transaction {
                if try metadataExists(marker) { return }
                var items: [UUID: ClipboardItem] = [:]
                let children = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
                for child in children where child.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
                    let source = child.appendingPathComponent("items.json")
                    guard fileManager.fileExists(atPath: source.path) else { continue }
                    for item in try JSONDecoder().decode([ClipboardItem].self, from: Data(contentsOf: source)) {
                        if let previous = items[item.id] {
                            var winner = previous.timestamp > item.timestamp ? previous : item
                            winner.isFavorite = previous.isFavorite || item.isFavorite
                            winner.isPinned = previous.isPinned || item.isPinned
                            items[item.id] = winner
                        } else { items[item.id] = item }
                    }
                }
                let existing = Set(try readItemsUnsafe().map(\.id))
                for item in items.values where !existing.contains(item.id) {
                    try write(persistAttachments(for: item))
                }
                let statement = try prepare("INSERT INTO metadata(key, value) VALUES (?, ?)")
                defer { sqlite3_finalize(statement) }
                try bind(marker, at: 1, to: statement)
                try bind(ISO8601DateFormatter().string(from: Date()), at: 2, to: statement)
                try stepDone(statement)
            }
        }
    }

    /// Explicit maintenance only: callers must include undo, favorites, shelf, stack and reply references.
    /// This is intentionally never called from delete, replace, or retention cleanup.
    func purgeUnreferencedAttachments(preserving additionalItems: [ClipboardItem] = []) throws {
        try observed {
            try transaction {
                let references = Set((try readItemsUnsafe() + additionalItems).flatMap { ClipboardAttachments.paths(in: $0) }.map { ClipboardAttachments.url(for: $0).standardizedFileURL.resolvingSymlinksInPath().path })
                for directory in try fileManager.contentsOfDirectory(at: attachmentDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
                    let canonicalPath = directory.standardizedFileURL.resolvingSymlinksInPath().path
                    let prefix = canonicalPath + "/"
                    if !references.contains(where: { $0 == canonicalPath || $0.hasPrefix(prefix) }) {
                        try fileManager.removeItem(at: directory)
                    }
                }
            }
        }
    }

    struct MaintenanceResult { let candidates: Int; let removed: Int; let reclaimedBytes: Int64 }
    /// Mark then sweep with a grace period. Live snapshots protect undo, views and asynchronous readers.
    func maintainAttachments(preserving additionalItems: [ClipboardItem] = [], now: Date = Date(), grace: TimeInterval = 86_400) throws -> MaintenanceResult {
        try observed {
            guard usageLock >= 0 else { return .init(candidates: 0, removed: 0, reclaimedBytes: 0) }
            guard flock(usageLock, LOCK_EX | LOCK_NB) == 0 else {
                _ = flock(usageLock, LOCK_SH)
                return .init(candidates: 0, removed: 0, reclaimedBytes: 0)
            }
            defer { flock(usageLock, LOCK_SH) }
            return try transaction {
                let records = try readItemsUnsafe() + additionalItems
                let paths = Set(records.flatMap { ClipboardAttachments.paths(in: $0) }).union(ClipboardAttachmentLease.livePaths)
                    .map { ClipboardAttachments.url(for: $0).standardizedFileURL.resolvingSymlinksInPath().path }
                var protectedDirectories = Set<String>()
                if fileManager.fileExists(atPath: storageDirectory.appendingPathComponent(rollbackName).path) {
                    let bytes = try Data(contentsOf: storageDirectory.appendingPathComponent(rollbackName + ".attachments.json"))
                    protectedDirectories = Set(try JSONDecoder().decode([String].self, from: bytes))
                }
                let directories = try fileManager.contentsOfDirectory(at: attachmentDirectory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                var candidates: [String: Date] = [:], removed = 0, reclaimed: Int64 = 0
                for directory in directories {
                    let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isDirectory == true, values.isSymbolicLink != true, !protectedDirectories.contains(directory.lastPathComponent) else { continue }
                    let path = directory.resolvingSymlinksInPath().path
                    guard !paths.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) else { continue }
                    let firstSeen = orphanCandidates[path] ?? now
                    candidates[path] = firstSeen
                    guard now.timeIntervalSince(firstSeen) >= max(0, grace), removed < 256 else { continue }
                    var size: Int64 = 0
                    if let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                        for case let file as URL in enumerator {
                            if let v = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true { size += Int64(v.fileSize ?? 0) }
                        }
                    }
                    try fileManager.removeItem(at: directory)
                    removed += 1; reclaimed += size; candidates.removeValue(forKey: path)
                }
                orphanCandidates = candidates
                return .init(candidates: candidates.count, removed: removed, reclaimedBytes: reclaimed)
            }
        }
    }
    /// Reclaim SQLite free pages only when the app is idle and a substantial part of the file is unused.
    @discardableResult func compactIfNeeded(minimumFreeBytes: Int = 32 * 1024 * 1024) throws -> Bool {
        try observed {
            guard usageLock >= 0 else { return false }
            guard flock(usageLock, LOCK_EX | LOCK_NB) == 0 else { _ = flock(usageLock, LOCK_SH); return false }
            defer { flock(usageLock, LOCK_SH) }
            let pages = try scalarInt("PRAGMA page_count"), free = try scalarInt("PRAGMA freelist_count"), size = try scalarInt("PRAGMA page_size")
            guard free > 0, free * size >= minimumFreeBytes, free * 3 >= pages else { return false }
            let capacity = try storageDirectory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
            guard capacity > pages * size * 2 else { return false }
            try execute("VACUUM")
            if let database { sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil) }
            return true
        }
    }
    func checkpointWhenIdle() {
        locked { if let database { sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil) } }
    }

    func getStorageInfo() -> StorageInfo {
        storeLock.lock()
        defer { storeLock.unlock() }
        var size: Int64 = 0
        if let enumerator = fileManager.enumerator(at: storageDirectory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let file as URL in enumerator {
                if let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true {
                    size += Int64(values.fileSize ?? 0)
                }
            }
        }
        let count = (try? scalarInt("SELECT count(*) FROM items")) ?? 0
        return StorageInfo(itemCount: count, totalSize: size, cachePath: storageDirectory.path)
    }

    // MARK: Attachment snapshots

    private func persistAttachments(for original: ClipboardItem) throws -> ClipboardItem {
        var item = original
        // Early OneClip stored file-info JSON as if it were the file's actual bytes,
        // then cleared `data`. Recover those references before taking snapshots.
        if item.type != .text, item.data == nil, item.fileURLs == nil, let path = item.filePath {
            let source = ClipboardAttachments.url(for: path)
            if let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size <= 8 * 1024 * 1024, let bytes = try? Data(contentsOf: source) {
                var candidate = item
                candidate.data = bytes
                if ClipboardAttachments.metadata(in: candidate) != nil || ClipboardAttachments.legacyTextPaths(in: candidate) != nil {
                    item.data = bytes
                    item.filePath = nil
                }
            }
        }
        var replacements: [String: String] = [:]
        for path in ClipboardAttachments.paths(in: item) {
            let source = ClipboardAttachments.url(for: path).standardizedFileURL
            guard fileManager.fileExists(atPath: source.path) else {
                throw ClipboardStorageError.unsupportedAttachment("附件不存在：\(source.lastPathComponent)", "The attachment does not exist: \(source.lastPathComponent)")
            }
            if isManaged(source) {
                replacements[path] = source.path
            } else if let reference = item.payloadReferences.first(where: { $0.path == path }) {
                replacements[path] = try persistBlob(reference.read()).path
            } else {
                try validateAttachmentTree(source)
                let directory = try createAttachmentDirectory()
                let destination = directory.appendingPathComponent(source.lastPathComponent)
                try fileManager.copyItem(at: source, to: destination)
                replacements[path] = destination.path
            }
        }
        item = try ClipboardAttachments.remap(item, using: replacements)
        if let bytes = item.data, item.type != .text,
           ClipboardAttachments.metadata(in: item) == nil, ClipboardAttachments.legacyTextPaths(in: item) == nil,
           (item.fileURLs ?? []).isEmpty {
            // A filePath may refer to a previous revision: new bytes always get a fresh location.
            if item.type == .image {
                item.filePath = try persistBlob(bytes).path
            } else {
                let directory = try createAttachmentDirectory()
                let name = blobName(for: item, bytes: bytes)
                let destination = directory.appendingPathComponent(name)
                try bytes.write(to: destination, options: .withoutOverwriting)
                item.filePath = destination.path
            }
            item.data = nil
            if item.type != .image, let path = item.filePath { item.fileURLs = [path] }
        }
        try item.externalizePayload(write: persistBlob)
        return item
    }

    private func persistBlob(_ bytes: Data) throws -> ClipboardBlobReference {
        let digest = ClipboardBlobReference.digest(bytes)
        let directory = attachmentDirectory.appendingPathComponent("blob-" + digest, isDirectory: true)
        var filename = "content"
        if let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           let type = CGImageSourceGetType(source), let ext = UTType(type as String)?.preferredFilenameExtension { filename += "." + ext }
        let destination = directory.appendingPathComponent(filename)
        let reference = ClipboardBlobReference(path: destination.path, byteCount: bytes.count, sha256: digest)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try reference.read()
            return reference
        }
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            createdDirectories.append(directory)
        }
        try bytes.write(to: destination, options: .atomic)
        _ = try reference.read() // A reference is committed only after bytes are verified.
        return reference
    }

    private func createAttachmentDirectory() throws -> URL {
        let directory = attachmentDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        createdDirectories.append(directory)
        return directory
    }

    private func blobName(for item: ClipboardItem, bytes: Data) -> String {
        if item.type == .image, let source = CGImageSourceCreateWithData(bytes as CFData, nil),
           let type = CGImageSourceGetType(source), let ext = UTType(type as String)?.preferredFilenameExtension {
            return "image." + ext
        }
        if let path = item.filePath, !URL(fileURLWithPath: path).pathExtension.isEmpty {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        let candidate = URL(fileURLWithPath: item.content).lastPathComponent
        if !candidate.isEmpty, !URL(fileURLWithPath: candidate).pathExtension.isEmpty,
           !candidate.contains(":"), candidate.utf8.count < 200 { return candidate }
        return item.type == .image ? "image.bin" : "attachment.bin"
    }

    private func isManaged(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().path.hasPrefix(attachmentDirectory.resolvingSymlinksInPath().path + "/")
    }

    private func validateAttachmentTree(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        guard values.isSymbolicLink != true else {
            throw ClipboardStorageError.unsupportedAttachment("暂不保存符号链接：\(url.lastPathComponent)", "Symbolic links cannot be saved: \(url.lastPathComponent)")
        }
        if values.isDirectory == true {
            for child in try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try validateAttachmentTree(child)
            }
        } else if values.isRegularFile != true {
            throw ClipboardStorageError.unsupportedAttachment("附件不是普通文件：\(url.lastPathComponent)", "The attachment is not a regular file: \(url.lastPathComponent)")
        }
    }

    // MARK: SQLite and error handling

    func readItem(id: UUID) throws -> ClipboardItem? { try locked { try readItemUnsafe(id: id) } }
    private func readItemUnsafe(id: UUID) throws -> ClipboardItem? {
        let statement = try prepare("SELECT payload FROM items WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, at: 1, to: statement)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw dbError() }
        return try decodeRecord(statement)
    }
    private func decodeRecord(_ statement: OpaquePointer) throws -> ClipboardItem {
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard let blob = sqlite3_column_blob(statement, 0), count > 0 else { throw ClipboardStorageError.database("项目数据为空", "Item data is empty") }
        decodedRecordCount += 1
        return try autoreleasepool { try JSONDecoder().decode(ClipboardItem.self, from: Data(bytes: blob, count: count)) }
    }
    func readPage(after cursor: PageCursor? = nil, limit: Int = 100, query: String = "") throws -> Page {
        try locked {
            let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
            var clauses = words.map { _ in "xclip_contains(search_text, ?) = 1" }
            if cursor != nil { clauses.append("(pinned < ? OR (pinned = ? AND (timestamp < ? OR (timestamp = ? AND id > ?))))") }
            let sql = "SELECT payload, pinned, timestamp, id FROM items" + (clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND "))
                + " ORDER BY pinned DESC, timestamp DESC, id ASC LIMIT ?"
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            var index: Int32 = 1
            for word in words { try bind(word, at: index, to: statement); index += 1 }
            if let cursor {
                sqlite3_bind_int(statement, index, cursor.pinned ? 1 : 0); index += 1
                sqlite3_bind_int(statement, index, cursor.pinned ? 1 : 0); index += 1
                sqlite3_bind_double(statement, index, cursor.timestamp.timeIntervalSince1970); index += 1
                sqlite3_bind_double(statement, index, cursor.timestamp.timeIntervalSince1970); index += 1
                try bind(cursor.id.uuidString, at: index, to: statement); index += 1
            }
            let pageSize = max(1, min(1000, limit))
            sqlite3_bind_int(statement, index, Int32(pageSize))
            var items: [ClipboardItem] = []
            var lastCursor: PageCursor?
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw dbError() }
                let item = try decodeRecord(statement)
                items.append(item)
                lastCursor = PageCursor(pinned: sqlite3_column_int(statement, 1) != 0,
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)), id: item.id)
            }
            let next = items.count == pageSize ? lastCursor : nil
            return Page(items: items, next: next)
        }
    }
    func searchItems(_ query: String) throws -> [ClipboardItem] { try locked { try readItemsUnsafe(query: query) } }
    private func readItemsUnsafe(query: String = "") throws -> [ClipboardItem] {
        var result: [ClipboardItem] = [], cursor: PageCursor?
        repeat {
            let page = try readPage(after: cursor, query: query)
            result.append(contentsOf: page.items); cursor = page.next
        } while cursor != nil
        return result
    }
    func dataVersion() throws -> Int { try locked { try scalarInt("PRAGMA data_version") } }
    func itemIDs() throws -> Set<UUID> {
        try locked {
            let statement = try prepare("SELECT id FROM items")
            defer { sqlite3_finalize(statement) }
            var ids = Set<UUID>()
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return ids }
                guard status == SQLITE_ROW, let text = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: text)) else { throw dbError() }
                ids.insert(id)
            }
        }
    }
    private func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw dbError() }
        return Int(sqlite3_column_int64(statement, 0))
    }
    private func installPayloadSchema() throws {
        let statement = try prepare("PRAGMA table_info(items)")
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW { if let name = sqlite3_column_text(statement, 1) { columns.insert(String(cString: name)) } }
        sqlite3_finalize(statement)
        if !columns.contains("payload_version") { try execute("ALTER TABLE items ADD COLUMN payload_version INTEGER NOT NULL DEFAULT 0") }
        if !columns.contains("search_text") { try execute("ALTER TABLE items ADD COLUMN search_text TEXT NOT NULL DEFAULT ''") }
        guard sqlite3_create_function_v2(database, "xclip_contains", 2, SQLITE_UTF8, nil, { context, count, values in
            guard count == 2, let values, let source = sqlite3_value_text(values[0]), let word = sqlite3_value_text(values[1]) else { sqlite3_result_int(context, 0); return }
            sqlite3_result_int(context, String(cString: source).localizedStandardContains(String(cString: word)) ? 1 : 0)
        }, nil, nil, nil) == SQLITE_OK else { throw dbError() }
    }
    private func migrateInlinePayloads() throws {
        guard try scalarInt("SELECT count(*) FROM items WHERE payload_version < 2") > 0 else { return }
        try createMigrationSnapshot()
        while true {
            // One record per transaction keeps the migration bounded and restartable.
            let statement = try prepare("SELECT payload FROM items WHERE payload_version < 2 LIMIT 1")
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { sqlite3_finalize(statement); break }
            guard status == SQLITE_ROW else { sqlite3_finalize(statement); throw dbError() }
            let item: ClipboardItem
            do { item = try decodeRecord(statement); sqlite3_finalize(statement) }
            catch { sqlite3_finalize(statement); throw error }
            try autoreleasepool { try transaction { try write(persistAttachments(for: item)) } }
        }
    }
    private func createMigrationSnapshot() throws {
        let destination = storageDirectory.appendingPathComponent(rollbackName)
        if fileManager.fileExists(atPath: destination.path) { return }
        let stage = storageDirectory.appendingPathComponent(rollbackName + ".partial")
        try? fileManager.removeItem(at: stage)
        var snapshot: OpaquePointer?
        guard sqlite3_open(stage.path, &snapshot) == SQLITE_OK, let snapshot else { throw dbError() }
        var succeeded = false
        defer { sqlite3_close(snapshot); if !succeeded { try? fileManager.removeItem(at: stage) } }
        guard let backup = sqlite3_backup_init(snapshot, "main", database, "main") else { throw dbError() }
        let step = sqlite3_backup_step(backup, -1), finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else { throw ClipboardStorageError.database("迁移前快照失败", "Pre-migration snapshot failed") }
        let directories = try fileManager.contentsOfDirectory(atPath: attachmentDirectory.path)
        try JSONEncoder().encode(directories).write(to: storageDirectory.appendingPathComponent(rollbackName + ".attachments.json"), options: .atomic)
        let configurationDirectory = storageDirectory.standardizedFileURL == StoragePaths.historyDirectory.standardizedFileURL
            ? StoragePaths.dataDirectory : storageDirectory
        for name in ["workflow.json", "settings.json"] {
            let source = configurationDirectory.appendingPathComponent(name)
            let backup = storageDirectory.appendingPathComponent("pre-memory-v2." + name)
            if fileManager.fileExists(atPath: source.path), !fileManager.fileExists(atPath: backup.path) {
                try fileManager.copyItem(at: source, to: backup)
            }
        }
        try fileManager.moveItem(at: stage, to: destination)
        succeeded = true
    }

    private func write(_ item: ClipboardItem) throws {
        let bytes = try JSONEncoder().encode(item)
        let statement = try prepare("INSERT INTO items(id, timestamp, favorite, pinned, payload, payload_version, search_text) VALUES (?, ?, ?, ?, ?, 2, ?) ON CONFLICT(id) DO UPDATE SET timestamp=excluded.timestamp, favorite=excluded.favorite, pinned=excluded.pinned, payload=excluded.payload, payload_version=2, search_text=excluded.search_text")
        defer { sqlite3_finalize(statement) }
        try bind(item.id.uuidString, at: 1, to: statement)
        guard sqlite3_bind_double(statement, 2, item.timestamp.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_bind_int(statement, 3, item.isFavorite ? 1 : 0) == SQLITE_OK,
              sqlite3_bind_int(statement, 4, item.isPinned ? 1 : 0) == SQLITE_OK else { throw dbError() }
        let status = bytes.withUnsafeBytes { sqlite3_bind_blob(statement, 5, $0.baseAddress, Int32($0.count), sqliteTransient) }
        guard status == SQLITE_OK else { throw dbError() }
        let searchable = ([try item.fullContent(), item.sourceApp ?? "", item.sourceAppName ?? ""] + item.tags).joined(separator: " ")
        try bind(searchable, at: 6, to: statement)
        try stepDone(statement)
    }

    private func enforceLimit() throws {
        guard maxItems > 0 else { return }
        try execute("DELETE FROM items WHERE id IN (SELECT id FROM items WHERE favorite = 0 AND pinned = 0 ORDER BY timestamp DESC, id ASC LIMIT -1 OFFSET \(maxItems))")
    }

    private func metadataExists(_ key: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM metadata WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, to: statement)
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw dbError() }
        return status == SQLITE_ROW
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        createdDirectories = []
        do {
            let result = try body()
            try execute("COMMIT")
            createdDirectories = []
            return result
        } catch {
            try? execute("ROLLBACK")
            for directory in createdDirectories { try? fileManager.removeItem(at: directory) }
            createdDirectories = []
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else { throw ClipboardStorageError.unavailable }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw dbError() }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw ClipboardStorageError.unavailable }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw dbError() }
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, value, -1, sqliteTransient) == SQLITE_OK else { throw dbError() }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw dbError() }
    }

    private func dbError() -> ClipboardStorageError {
        if let database { return .database(String(cString: sqlite3_errmsg(database))) }
        return .database("数据库未打开", "The database is not open")
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        storeLock.lock()
        defer { storeLock.unlock() }
        return try body()
    }

    private func observed<T>(_ body: () throws -> T) throws -> T {
        try locked {
            do {
                let result = try body()
                clearError()
                return result
            } catch { report(error); throw error }
        }
    }

    private func report(_ error: Error) {
        if Thread.isMainThread { lastFailure = error; lastError = error.localizedDescription }
        else { DispatchQueue.main.async { [weak self] in self?.lastFailure = error; self?.lastError = error.localizedDescription } }
    }

    private func clearError() {
        if Thread.isMainThread { lastFailure = nil; lastError = nil }
        else { DispatchQueue.main.async { [weak self] in self?.lastFailure = nil; self?.lastError = nil } }
    }
}
