import Foundation
import Combine
import SQLite3
import ImageIO
import UniformTypeIdentifiers

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
            try migrateLegacyDirectory(from: legacyDirectory ?? directory)
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
                guard var item = try readItemsUnsafe().first(where: { $0.id == id }) else {
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
                try write(item)
                return item
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
                let archive = try HistoryArchive.make(items: readItemsUnsafe(), additionalItems: additionalItems, extraFiles: extraFiles)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                try encoder.encode(archive).write(to: url, options: .atomic)
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
        let items = loadItems()
        return StorageInfo(itemCount: items.count, totalSize: size, cachePath: storageDirectory.path)
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
            let directory = try createAttachmentDirectory()
            let name = blobName(for: item, bytes: bytes)
            let destination = directory.appendingPathComponent(name)
            try bytes.write(to: destination, options: .withoutOverwriting)
            item.filePath = destination.path
            item.data = nil
            if item.type != .image { item.fileURLs = [destination.path] }
        }
        return item
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

    private func readItemsUnsafe() throws -> [ClipboardItem] {
        let statement = try prepare("SELECT payload FROM items ORDER BY pinned DESC, timestamp DESC, id ASC")
        defer { sqlite3_finalize(statement) }
        var result: [ClipboardItem] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw dbError() }
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard let blob = sqlite3_column_blob(statement, 0), count > 0 else { throw ClipboardStorageError.database("项目数据为空", "Item data is empty") }
            result.append(try JSONDecoder().decode(ClipboardItem.self, from: Data(bytes: blob, count: count)))
        }
    }

    private func write(_ item: ClipboardItem) throws {
        let bytes = try JSONEncoder().encode(item)
        let statement = try prepare("INSERT INTO items(id, timestamp, favorite, pinned, payload) VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET timestamp=excluded.timestamp, favorite=excluded.favorite, pinned=excluded.pinned, payload=excluded.payload")
        defer { sqlite3_finalize(statement) }
        try bind(item.id.uuidString, at: 1, to: statement)
        guard sqlite3_bind_double(statement, 2, item.timestamp.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_bind_int(statement, 3, item.isFavorite ? 1 : 0) == SQLITE_OK,
              sqlite3_bind_int(statement, 4, item.isPinned ? 1 : 0) == SQLITE_OK else { throw dbError() }
        let status = bytes.withUnsafeBytes { sqlite3_bind_blob(statement, 5, $0.baseAddress, Int32($0.count), sqliteTransient) }
        guard status == SQLITE_OK else { throw dbError() }
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
