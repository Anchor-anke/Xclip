import Foundation

/// Development builds never share the upstream OneClip data or cache directory.
enum StoragePaths {
    private static var testDirectory: String? {
        if let path = ProcessInfo.processInfo.environment["CCLIP_DATA_DIR"], !path.isEmpty { return path }
        if let path = Bundle.main.object(forInfoDictionaryKey: "CClipTestDataDirectory") as? String, !path.isEmpty { return path }
        return nil
    }
    static var dataDirectory: URL {
        if let override = testDirectory {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("CClip", isDirectory: true)
    }

    /// Only history and retained attachments move; configuration remains in dataDirectory.
    static var historyDirectory: URL {
        if testDirectory != nil { return dataDirectory }
        if let path = UserDefaults.standard.string(forKey: "local.cclip.historyDirectory"), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        return dataDirectory
    }

    static var cacheDirectory: URL {
        if testDirectory != nil {
            return dataDirectory.appendingPathComponent("cache", isDirectory: true)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("CClip", isDirectory: true)
    }
}
