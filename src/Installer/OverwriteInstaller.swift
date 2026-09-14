import AppKit
import CoreServices
import CryptoKit
import Darwin
import Foundation
import Security

struct InstalledAppInfo {
    let url: URL
    let version: String
}

enum OverwriteInstallError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}

enum OverwriteInstaller {
    static let bundleIdentifier = "local.cclip.app"
    struct Environment {
        var signature: (URL) throws -> Data
        var active: (URL) -> Bool
        var quit: @MainActor (URL) async throws -> Void
        var register: (URL) throws -> Void
        var move: (URL, URL, Bool) throws -> Void
        var reopen: @MainActor (URL) async -> Void
        static var live: Environment {
            Environment(signature: certificate, active: { !runningApps(at: $0).isEmpty }, quit: OverwriteInstaller.quit,
                register: { url in
                    let result = LSRegisterURL(url as CFURL, true)
                    guard result == noErr else { throw failure("系统登记失败（\(result)）。") }
                }, move: atomicMove, reopen: { url in
                    _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                })
        }
    }
    private struct ValidatedApp {
        let info: InstalledAppInfo
        let version: [Int]
        let certificate: Data
        let inode: UInt64
        let revision: Data
    }

    static func inspect(_ url: URL) throws -> InstalledAppInfo {
        try validate(url, signature: certificate).info
    }

    static func validateSource(_ source: URL, signedLike installer: URL) throws {
        let sourceIdentity = try validate(source, signature: certificate).certificate
        let installerIdentity = try signingCertificate(checkedPath(installer), expectedIdentifier: nil)
        guard sourceIdentity == installerIdentity else { throw failure("安装包与安装器签名来源不同，请重新下载完整安装包。") }
    }

    @MainActor static func install(source: URL, destination: URL, progress: @escaping (String) -> Void) async throws -> URL {
        try await install(source: source, destination: destination, progress: progress, environment: .live)
    }

    @MainActor static func install(source: URL, destination: URL, progress: @escaping (String) -> Void, environment: Environment) async throws -> URL {
        let source = try checkedPath(source), target = try checkedPath(destination)
        guard target.pathExtension == "app", !contains(source, target), !contains(target, source) else {
            throw failure("安装源与目标必须是不同且互不包含的应用路径。")
        }
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path), access(parent.path, W_OK | X_OK) == 0 else {
            throw failure("目标目录不可写。请选择原应用所在的可写位置或可写的 Applications 文件夹。")
        }
        let lockURL = try checkedPath(parent.appendingPathComponent(".\(target.lastPathComponent).xclip-install.lock"))
        let lock = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard lock >= 0 else { throw failure("无法取得安装锁，请检查目标目录的写入权限。") }
        defer { _ = flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw failure("另一个安装正在更新此应用，请稍后再试。") }
        progress("正在验证安装包和原应用…")
        let initial = try await Task.detached { () throws -> (ValidatedApp, ValidatedApp?) in
            let incoming = try validate(source, signature: environment.signature)
            let previous = FileManager.default.fileExists(atPath: target.path) ? try validate(target, signature: environment.signature) : nil
            try compatible(incoming, previous)
            return (incoming, previous)
        }.value
        let container = parent.appendingPathComponent(".xclip-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let stage = container.appendingPathComponent("Xclip.app", isDirectory: true)
        var preserveRecovery = false
        var wasRunning = false
        defer {
            if !preserveRecovery { try? FileManager.default.removeItem(at: container) }
        }
        do {
            progress("正在准备新版应用…")
            try await Task.detached {
                try FileManager.default.copyItem(at: source, to: stage)
                let staged = try validate(stage, signature: environment.signature)
                guard staged.certificate == initial.0.certificate, staged.version == initial.0.version, staged.revision == initial.0.revision else { throw failure("暂存应用与安装源不一致。") }
            }.value
            try Task.checkCancellation()
            wasRunning = environment.active(target)
            if wasRunning {
                progress("正在正常退出旧版 Xclip，请完成应用中的保存提示…")
                try await environment.quit(target)
            }
            try Task.checkCancellation()
            progress("正在原位置更新 Xclip…")
            // Revalidation, the final process check, and atomic replacement form one worker step.
            try await Task.detached {
                _ = try checkedPath(source); _ = try checkedPath(target); _ = try checkedPath(stage)
                let incoming = try validate(source, signature: environment.signature)
                let staged = try validate(stage, signature: environment.signature)
                guard incoming.inode == initial.0.inode, incoming.revision == initial.0.revision,
                      incoming.certificate == initial.0.certificate, incoming.version == initial.0.version,
                      staged.certificate == incoming.certificate, staged.version == incoming.version,
                      staged.revision == incoming.revision else { throw failure("安装源在准备期间发生了变化。") }
                let current = FileManager.default.fileExists(atPath: target.path) ? try validate(target, signature: environment.signature) : nil
                guard current?.inode == initial.1?.inode, current?.revision == initial.1?.revision else { throw failure("目标应用在准备期间发生了变化，已保留现有应用。") }
                try compatible(staged, current)
                guard !environment.active(target) else { throw failure("旧版 Xclip 仍在运行或重新启动，已停止替换。") }
                try environment.move(stage, target, current != nil)
            }.value
            do {
                try await Task.detached {
                    let installed = try validate(target, signature: environment.signature)
                    guard installed.certificate == initial.0.certificate, installed.version == initial.0.version, installed.revision == initial.0.revision else { throw failure("安装后应用与已验证的新版不一致。") }
                    try environment.register(target)
                }.value
            } catch {
                do {
                    guard !environment.active(target) else { throw failure("新版正在运行，无法安全回滚。") }
                    try await Task.detached {
                        try environment.move(target, stage, initial.1 != nil)
                        if initial.1 != nil {
                            let old = try validate(target, signature: environment.signature)
                            guard old.inode == initial.1?.inode, old.revision == initial.1?.revision else { throw failure("回滚后的应用身份不一致。") }
                        }
                    }.value
                    if initial.1 != nil {
                        do { try await Task.detached { try environment.register(target) }.value }
                        catch { progress("旧应用已恢复，系统登记仍需检查：\(error.localizedDescription)") }
                    }
                } catch let rollbackError {
                    preserveRecovery = true
                    throw failure("更新校验失败，自动回滚未完成。保留目标 \(target.path) 和恢复目录 \(container.path)。原因：\(rollbackError.localizedDescription)")
                }
                throw failure("更新校验失败，已恢复安装前状态：\(error.localizedDescription)")
            }
            if initial.1 != nil {
                let backup = parent.appendingPathComponent(".xclip-backup-\(UUID().uuidString)", isDirectory: true)
                do {
                    try environment.move(container, backup, false)
                    progress("旧版本已保留在：\(backup.path)")
                } catch {
                    preserveRecovery = true
                    progress("新版已安装；旧版本保留在：\(container.path)")
                }
            }
            progress("更新完成，历史与设置已保留。")
            return target
        } catch {
            // Reopen only a positively identified original installation, never an uncertain rollback.
            if wasRunning, !preserveRecovery, !environment.active(target), initial.1 != nil {
                let safe = try? await Task.detached {
                    let old = try validate(target, signature: environment.signature)
                    return old.inode == initial.1?.inode && old.revision == initial.1?.revision
                }.value
                if safe == true { await environment.reopen(target) }
            }
            throw error
        }
    }

    private static func failure(_ message: String) -> OverwriteInstallError { .message(message) }
    private static func contains(_ child: URL, _ parent: URL) -> Bool {
        child.path == parent.path || child.path.hasPrefix(parent.path + "/")
    }
    static func checkedPath(_ value: URL) throws -> URL {
        guard value.isFileURL, !value.pathComponents.contains("..") else { throw failure("仅支持明确的本地应用路径。") }
        // Foundation's standardizedFileURL rewrites existing /private/tmp to the
        // symlink /tmp. Normalize lexically so the checked path remains the exact path.
        let url = URL(fileURLWithPath: "/" + value.pathComponents.dropFirst().filter { $0 != "." }.joined(separator: "/"), isDirectory: value.hasDirectoryPath)
        var current = url
        while true {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: current.path), attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw failure("路径包含符号链接，已保留原文件：\(current.path)")
            }
            if current.path == "/" { break }
            current.deleteLastPathComponent()
        }
        return url
    }
    private static func version(_ value: Any?) throws -> [Int] {
        guard let text = value as? String, text.range(of: "^[0-9]{1,9}(\\.[0-9]{1,9}){0,3}$", options: .regularExpression) != nil else { throw failure("应用版本信息无效。") }
        let values = text.split(separator: ".").compactMap { Int($0) }
        return values + Array(repeating: 0, count: 4 - values.count)
    }
    private static func compatible(_ incoming: ValidatedApp, _ previous: ValidatedApp?) throws {
        guard let previous else { return }
        guard !incoming.version.lexicographicallyPrecedes(previous.version) else { throw failure("已安装版本更新，拒绝降级。") }
        guard incoming.certificate == previous.certificate else { throw failure("新版与旧版签名证书不同，已保留旧版。请使用相同签名来源的安装包。") }
    }
    private static func validate(_ value: URL, signature: (URL) throws -> Data) throws -> ValidatedApp {
        let url = try checkedPath(value), manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard url.pathExtension == "app", attributes[.type] as? FileAttributeType == .typeDirectory else { throw failure("不是完整的应用目录：\(url.path)") }
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
        guard let info, info["CFBundleIdentifier"] as? String == bundleIdentifier,
              info["CFBundleExecutable"] as? String == "Xclip", info["CClipTestDataDirectory"] == nil,
              access(url.appendingPathComponent("Contents/MacOS/Xclip").path, X_OK) == 0 else { throw failure("此目录不是正式 Xclip，或包含测试数据配置，已保留原文件。") }
        let semanticVersion = try version(info["CFBundleShortVersionString"])
        let buildVersion = try version(info["CFBundleVersion"])
        let seal = try PropertyListSerialization.propertyList(from: Data(contentsOf: url.appendingPathComponent("Contents/_CodeSignature/CodeResources")), format: nil) as? [String: Any]
        guard let entries = seal?["files2"] as? [String: Any] else { throw failure("应用缺少完整的签名资源清单。") }
        var allowed: Set<String> = ["Contents/Info.plist", "Contents/MacOS/Xclip", "Contents/PkgInfo", "Contents/_CodeSignature/CodeResources"]
        for name in entries.keys {
            guard !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else { throw failure("签名资源路径无效。") }
            allowed.insert("Contents/" + name)
        }
        var enumerationError: Error?
        guard let contents = manager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey], options: [], errorHandler: { _, error in enumerationError = error; return false }) else { throw failure("无法读取应用内容。") }
        for case let child as URL in contents {
            let values = try child.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            let relative = String(child.path.dropFirst(url.path.count + 1))
            guard values.isSymbolicLink != true,
                  (values.isRegularFile == true && allowed.contains(relative)) ||
                  (values.isDirectory == true && allowed.contains(where: { $0.hasPrefix(relative + "/") })) else { throw failure("应用包含未确认的文件或目录，已保留：\(child.path)") }
        }
        if let enumerationError { throw enumerationError }
        let leaf = try signature(url)
        guard !leaf.isEmpty else { throw failure("应用使用临时签名，无法确认稳定更新身份；请使用相同证书签名的正式版本。") }
        // The executable seals CodeResources and Info.plist; keep an explicit content
        // fingerprint as well as the inode to detect a same-version in-place change.
        var fingerprint = SHA256()
        for path in ["Contents/MacOS/Xclip", "Contents/Info.plist", "Contents/_CodeSignature/CodeResources"] {
            fingerprint.update(data: try Data(contentsOf: url.appendingPathComponent(path), options: .mappedIfSafe))
        }
        return ValidatedApp(info: InstalledAppInfo(url: url, version: info["CFBundleShortVersionString"] as! String),
            version: semanticVersion + buildVersion, certificate: leaf, inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            revision: Data(fingerprint.finalize()))
    }
    private static func certificate(_ url: URL) throws -> Data {
        try signingCertificate(url, expectedIdentifier: bundleIdentifier)
    }
    private static func signingCertificate(_ url: URL, expectedIdentifier: String?) throws -> Data {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { throw failure("无法读取应用签名。") }
        var detail: Unmanaged<CFError>?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidityWithErrors(code, flags, nil, &detail) == errSecSuccess else {
            let message = detail?.takeRetainedValue().localizedDescription ?? "未知签名错误"
            throw failure("应用签名校验失败：\(message)")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any], let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              expectedIdentifier == nil || identifier == expectedIdentifier,
              let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first else {
            throw failure("应用缺少稳定签名证书或签名标识不正确，已保留原应用。")
        }
        let data = SecCertificateCopyData(leaf) as Data
        let hash = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let escapedID = identifier.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("identifier \"\(escapedID)\" and certificate leaf = H\"\(hash)\"" as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { throw failure("应用各架构的签名身份不一致。") }
        return data
    }
    private static func runningApps(at url: URL) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).filter {
            $0.bundleURL?.path == url.path && $0.executableURL?.path == url.appendingPathComponent("Contents/MacOS/Xclip").path && !$0.isTerminated
        }
    }
    @MainActor private static func quit(_ url: URL) async throws {
        for app in runningApps(at: url) {
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier, app.terminate() else { throw failure("Xclip 尚未同意退出。请完成保存或取消操作后重试，原应用已保留。") }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while !runningApps(at: url).isEmpty {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw failure("等待 Xclip 正常退出已超时，原应用未替换。") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
    private static func atomicMove(_ source: URL, _ target: URL, _ exchange: Bool) throws {
        guard renamex_np(source.path, target.path, exchange ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)) == 0 else {
            throw failure("无法原子替换应用：\(String(cString: strerror(errno)))")
        }
    }
}
