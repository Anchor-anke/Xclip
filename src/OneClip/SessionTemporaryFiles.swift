import Foundation
import Darwin

/// Only directories bearing our ownership marker are eligible for crash recovery cleanup.
enum SessionTemporaryFiles {
    private struct Owner: Codable { let pid: Int32; let uid: UInt32; let created: Date }
    static var root: URL {
        if let path = ProcessInfo.processInfo.environment["CCLIP_DATA_DIR"] ?? Bundle.main.object(forInfoDictionaryKey: "CClipTestDataDirectory") as? String {
            return URL(fileURLWithPath: path).appendingPathComponent("session-temporary", isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
    }
    static func create(prefix: String) throws -> URL {
        let directory = root.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do { try mark(directory); return directory }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    static func mark(_ directory: URL) throws {
        try JSONEncoder().encode(Owner(pid: getpid(), uid: getuid(), created: Date()))
            .write(to: directory.appendingPathComponent(".xclip-session-owner"), options: .atomic)
    }
    /// A surviving process, unknown owner, legacy unmarked directory or recent export is never removed.
    static func cleanupOrphans(now: Date = Date()) {
        let fm = FileManager.default
        guard let directories = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        let prefixes = ["cclip-image-drag-", "cclip-paste-", "xclip-edit-", "xclip-pin-history-"]
        for directory in directories where prefixes.contains(where: { directory.lastPathComponent.hasPrefix($0) }) {
            guard let properties = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  properties.isDirectory == true, properties.isSymbolicLink != true else { continue }
            let marker = directory.appendingPathComponent(".xclip-session-owner")
            guard let attributes = try? fm.attributesOfItem(atPath: marker.path), attributes[.type] as? FileAttributeType == .typeRegular,
                  ((attributes[.size] as? NSNumber)?.intValue ?? 4096) < 1024,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  let bytes = try? Data(contentsOf: marker), let owner = try? JSONDecoder().decode(Owner.self, from: bytes),
                  owner.pid > 0, owner.uid == getuid(), kill(owner.pid, 0) == -1, errno == ESRCH else { continue }
            let grace: TimeInterval = directory.lastPathComponent.hasPrefix("cclip-") ? 7 * 86_400 : 86_400
            guard now.timeIntervalSince(owner.created) >= grace else { continue }
            try? fm.removeItem(at: directory)
        }
    }
}
