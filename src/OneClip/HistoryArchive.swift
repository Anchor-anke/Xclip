import Foundation
import CryptoKit

/// A single portable JSON file: item metadata plus every referenced file and directory.
/// Paths inside this format are relative to the archive, never to the exporting computer.
struct HistoryArchive: Codable {
    static let currentVersion = 1
    var format = "CClip History Archive"
    var version = currentVersion
    var createdAt = Date()
    var items: [ClipboardItem]
    var files: [ArchivedFile]
    /// Saved workflows can retain item snapshots independently of visible history.
    var additionalItems: [ClipboardItem]?
    /// Opaque, named application configuration blobs. Import never writes these to paths.
    var extraFiles: [String: Data]?

    struct ArchivedFile: Codable {
        var path: String
        var isDirectory: Bool
        var data: Data?
        var sha256: String?
    }

    static func make(items: [ClipboardItem], additionalItems: [ClipboardItem] = [], extraFiles: [String: Data] = [:]) throws -> HistoryArchive {
        var files: [ArchivedFile] = []
        var replacements: [String: String] = [:]
        for path in Set((items + additionalItems).flatMap { ClipboardAttachments.paths(in: $0) }).sorted() {
            let source = ClipboardAttachments.url(for: path)
            let relative = "attachments/\(UUID().uuidString)/\(source.lastPathComponent)"
            try collect(source, relative: relative, into: &files)
            replacements[path] = relative
        }
        return HistoryArchive(
            items: try items.map { try ClipboardAttachments.remap($0, using: replacements) }, files: files,
            additionalItems: additionalItems.isEmpty ? nil : try additionalItems.map { try ClipboardAttachments.remap($0, using: replacements) },
            extraFiles: extraFiles.isEmpty ? nil : extraFiles)
    }

    func validate() throws {
        guard format == "CClip History Archive", version == Self.currentVersion else {
            throw ClipboardStorageError.invalidArchive("不支持的备份格式或版本", "Unsupported backup format or version")
        }
        guard Set(items.map(\.id)).count == items.count else {
            throw ClipboardStorageError.invalidArchive("备份含有重复项目 ID", "The backup contains duplicate item IDs")
        }
        var entries: [String: ArchivedFile] = [:]
        for file in files {
            guard Self.isSafePath(file.path), entries[file.path] == nil else {
                throw ClipboardStorageError.invalidArchive("附件路径无效或重复", "An attachment path is invalid or duplicated")
            }
            if file.isDirectory {
                guard file.data == nil, file.sha256 == nil else {
                    throw ClipboardStorageError.invalidArchive("目录条目不能含有文件数据", "Directory entries cannot contain file data")
                }
            } else {
                guard let bytes = file.data, Self.digest(bytes) == file.sha256 else {
                    throw ClipboardStorageError.invalidArchive("附件校验失败：\(file.path)", "Attachment verification failed: \(file.path)")
                }
            }
            entries[file.path] = file
        }
        for path in entries.keys {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if let ancestor = entries[parent], !ancestor.isDirectory {
                    throw ClipboardStorageError.invalidArchive("附件目录与文件冲突", "An attachment directory conflicts with a file")
                }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        for path in (items + (additionalItems ?? [])).flatMap({ ClipboardAttachments.paths(in: $0) }) {
            guard Self.isSafePath(path), entries[path] != nil else {
                throw ClipboardStorageError.invalidArchive("项目引用了缺失或非便携附件", "An item refers to a missing or nonportable attachment")
            }
        }
    }

    /// The caller owns this fresh staging directory and removes it after commit or failure.
    func unpack(to directory: URL) throws -> [ClipboardItem] {
        try unpackWorkspace(to: directory).items
    }

    func unpackWorkspace(to directory: URL) throws -> BackupImportResult {
        try validate()
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        for file in files.sorted(by: { $0.path.count < $1.path.count }) {
            let target = directory.appendingPathComponent(file.path)
            if file.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data!.write(to: target, options: .withoutOverwriting)
            }
        }
        let paths = Set((items + (additionalItems ?? [])).flatMap { ClipboardAttachments.paths(in: $0) })
        let replacements = Dictionary(uniqueKeysWithValues: paths.map { ($0, directory.appendingPathComponent($0).path) })
        return BackupImportResult(
            items: try items.map { try ClipboardAttachments.remap($0, using: replacements) },
            additionalItems: try (additionalItems ?? []).map { try ClipboardAttachments.remap($0, using: replacements) },
            extraFiles: extraFiles ?? [:])
    }

    private static func collect(_ source: URL, relative: String, into result: inout [ArchivedFile]) throws {
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true else {
            throw ClipboardStorageError.unsupportedAttachment("备份不跟随符号链接：\(source.lastPathComponent)", "Backups do not follow symbolic links: \(source.lastPathComponent)")
        }
        if values.isDirectory == true {
            result.append(ArchivedFile(path: relative, isDirectory: true))
            for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                try collect(child, relative: relative + "/" + child.lastPathComponent, into: &result)
            }
        } else {
            guard values.isRegularFile == true else {
                throw ClipboardStorageError.unsupportedAttachment("附件不是普通文件：\(source.lastPathComponent)", "The attachment is not a regular file: \(source.lastPathComponent)")
            }
            let bytes = try Data(contentsOf: source)
            result.append(ArchivedFile(path: relative, isDirectory: false, data: bytes, sha256: digest(bytes)))
        }
    }

    private static func isSafePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.contains("\\") && !path.contains("\0") && parts.count >= 3 && parts[0] == "attachments"
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Understands the upstream file-info JSON without turning that JSON itself into a fake file.
enum ClipboardAttachments {
    static func url(for path: String) -> URL {
        if path.hasPrefix("file://"), let url = URL(string: path), url.isFileURL { return url }
        return URL(fileURLWithPath: path)
    }

    static func metadata(in item: ClipboardItem) -> [[String: Any]]? {
        guard item.type != .text, let bytes = item.data,
              let rows = try? JSONSerialization.jsonObject(with: bytes) as? [[String: Any]],
              !rows.isEmpty, rows.allSatisfy({ ($0["path"] as? String)?.isEmpty == false }) else { return nil }
        return rows
    }

    static func legacyTextPaths(in item: ClipboardItem) -> [String]? {
        guard item.type != .text, item.type != .image, metadata(in: item) == nil,
              let data = item.data, let text = String(data: data, encoding: .utf8) else { return nil }
        let paths = text.split(separator: "\n").map(String.init)
        return !paths.isEmpty && paths.allSatisfy { $0.hasPrefix("/") || $0.hasPrefix("file://") } ? paths : nil
    }

    static func paths(in item: ClipboardItem) -> [String] {
        var paths = item.fileURLs ?? []
        if let path = item.filePath, !path.isEmpty { paths.append(path) }
        if let rows = metadata(in: item) { paths += rows.compactMap { $0["path"] as? String } }
        if let legacy = legacyTextPaths(in: item) { paths += legacy }
        return Array(Set(paths)).sorted()
    }

    static func remap(_ item: ClipboardItem, using replacements: [String: String]) throws -> ClipboardItem {
        func mapped(_ path: String) throws -> String {
            guard let replacement = replacements[path] else { throw ClipboardStorageError.invalidArchive("缺少附件：\(path)", "Missing attachment: \(path)") }
            return replacement
        }
        var result = item
        if let path = item.filePath, !path.isEmpty { result.filePath = try mapped(path) }
        if let paths = item.fileURLs { result.fileURLs = try paths.map(mapped) }
        if var rows = metadata(in: item) {
            for i in rows.indices { rows[i]["path"] = try mapped(rows[i]["path"] as! String) }
            result.data = try JSONSerialization.data(withJSONObject: rows, options: .sortedKeys)
            if result.fileURLs == nil { result.fileURLs = rows.compactMap { $0["path"] as? String } }
        } else if let paths = legacyTextPaths(in: item) {
            let updated = try paths.map(mapped)
            result.data = updated.joined(separator: "\n").data(using: .utf8)
            if result.fileURLs == nil { result.fileURLs = updated }
        }
        if var representations = result.representations {
            for (type, bytes) in representations {
                if type == "public.file-url", let text = String(data: bytes, encoding: .utf8) {
                    let original = url(for: text).path
                    if let path = replacements[text] ?? replacements[original] {
                        representations[type] = path.hasPrefix("/") ? URL(fileURLWithPath: path).absoluteString.data(using: .utf8) : path.data(using: .utf8)
                    }
                } else if type == "NSFilenamesPboardType",
                          let paths = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String] {
                    let updated = paths.map { replacements[$0] ?? $0 }
                    representations[type] = try PropertyListSerialization.data(fromPropertyList: updated, format: .binary, options: 0)
                }
            }
            result.representations = representations
        }
        return result
    }
}

enum ClipboardStorageError: LocalizedError {
    // Optional translations leave original SQLite and external diagnostics intact.
    case database(String, String? = nil)
    case invalidArchive(String, String? = nil)
    case unsupportedAttachment(String, String? = nil)
    case itemNotFound
    case unavailable

    var errorDescription: String? {
        switch self {
        case .database(let message, let english):
            return AppLanguage.text("历史数据库错误：", "History database error: ") + AppLanguage.text(message, english ?? message)
        case .invalidArchive(let message, let english):
            return AppLanguage.text("备份无效：", "Invalid backup: ") + AppLanguage.text(message, english ?? message)
        case .unsupportedAttachment(let message, let english): return AppLanguage.text(message, english ?? message)
        case .itemNotFound: return AppLanguage.text("找不到要编辑的历史项目", "The history item to edit could not be found")
        case .unavailable: return AppLanguage.text("历史数据库尚未成功打开", "The history database has not been opened successfully")
        }
    }
}

struct BackupImportResult {
    var items: [ClipboardItem]
    var additionalItems: [ClipboardItem]
    var extraFiles: [String: Data]
}
