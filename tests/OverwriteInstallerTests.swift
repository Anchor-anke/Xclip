import AppKit
import Darwin
import Foundation

@main
struct OverwriteInstallerTests {
    @MainActor final class Fixture {
        let root: URL
        let source: URL
        let target: URL
        var active = false
        var quitCalls = 0
        var reopened = 0
        var moves = 0
        var registered: [String] = []
        var messages: [String] = []
        init(existing: Bool = true) throws {
            root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("xclip-overwrite-test-\(UUID().uuidString)")
            source = root.appendingPathComponent("incoming/Xclip.app")
            target = root.appendingPathComponent("Applications/Xclip.app")
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.bundle(source, payload: "new", build: "2")
            if existing { try Self.bundle(target, payload: "old", build: "1") }
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        static func bundle(_ url: URL, payload: String, build: String) throws {
            let executable = url.appendingPathComponent("Contents/MacOS/Xclip")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(payload.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            try metadata(url, values: ["CFBundleIdentifier": "local.cclip.app", "CFBundleExecutable": "Xclip", "CFBundleShortVersionString": "0.4.0", "CFBundleVersion": build])
            let resources = url.appendingPathComponent("Contents/_CodeSignature/CodeResources")
            try FileManager.default.createDirectory(at: resources.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["files2": [String: String]()], format: .xml, options: 0).write(to: resources)
        }
        static func metadata(_ url: URL, values: [String: Any]) throws {
            let file = url.appendingPathComponent("Contents/Info.plist")
            var metadata = (try? Data(contentsOf: file)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
            metadata.merge(values) { _, new in new }
            try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0).write(to: file)
        }
        func payload(_ app: URL? = nil) throws -> String {
            try String(contentsOf: (app ?? target).appendingPathComponent("Contents/MacOS/Xclip"), encoding: .utf8)
        }
        func directories(_ prefix: String) throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: target.deletingLastPathComponent(), includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(prefix) }
        }
        var environment: OverwriteInstaller.Environment {
            .init(signature: { _ in Data([1, 2, 3]) }, active: { [self] _ in active }, quit: { [self] _ in quitCalls += 1; active = false },
                register: { [self] app in registered.append(try payload(app)) }, move: { [self] from, to, swap in
                    moves += 1
                    guard renamex_np(from.path, to.path, swap ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)) == 0 else { throw OverwriteInstallError.message("test rename failed") }
                }, reopen: { [self] _ in reopened += 1 })
        }
        func install(_ environment: OverwriteInstaller.Environment? = nil) async throws -> URL {
            try await OverwriteInstaller.install(source: source, destination: target, progress: { self.messages.append($0) }, environment: environment ?? self.environment)
        }
    }
    static var count = 0
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw OverwriteInstallError.message("FAIL: " + message) }
        count += 1; print("PASS: " + message)
    }
    @MainActor static func rejected(_ operation: () async throws -> URL, containing text: String) async throws {
        do { _ = try await operation(); throw OverwriteInstallError.message("unexpected success") }
        catch { try require(error.localizedDescription.contains(text), "Rejects \(text)") }
    }
    @MainActor static func main() async throws {
        do {
            let fixture = try Fixture(); fixture.active = true
            let data = fixture.root.appendingPathComponent("Application Support/CClip/workflow.json")
            try FileManager.default.createDirectory(at: data.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("user shortcuts and history".utf8).write(to: data)
            let installed = try await fixture.install()
            try require(installed == fixture.target, "Returns the exact destination")
            try require(try fixture.payload() == "new" && fixture.payload(fixture.source) == "new", "Atomic replacement preserves the source")
            try require(fixture.quitCalls == 1 && fixture.registered == ["new"] && fixture.reopened == 0, "Quits only through the injected normal-exit interface and does not launch the new app")
            let backups = try fixture.directories(".xclip-backup-")
            try require(backups.count == 1 && fixture.payload(backups[0].appendingPathComponent("Xclip.app")) == "old", "Retains the old signed app as an explicit backup")
            try require(try String(contentsOf: data, encoding: .utf8) == "user shortcuts and history", "Application Support data remains unchanged")
            try require(try fixture.directories(".xclip-install-").isEmpty, "Successful update leaves no temporary staging directory")
        }
        do {
            let fixture = try Fixture(existing: false)
            _ = try await fixture.install()
            try require(try fixture.payload() == "new" && fixture.quitCalls == 0, "First install works without an existing app or quit request")
        }
        for failure in ["拒绝退出", "正常退出已超时"] {
            let fixture = try Fixture(); fixture.active = true
            var environment = fixture.environment
            environment.quit = { _ in throw OverwriteInstallError.message(failure) }
            try await rejected({ try await fixture.install(environment) }, containing: failure)
            try require(try fixture.payload() == "old" && fixture.moves == 0, "Exit refusal or timeout cannot replace the installed application")
        }
        do {
            let fixture = try Fixture(); fixture.active = true
            var environment = fixture.environment
            environment.signature = { app in
                if app == fixture.target, try fixture.payload() == "new" { throw OverwriteInstallError.message("bad installed signature") }
                return Data([1, 2, 3])
            }
            try await rejected({ try await fixture.install(environment) }, containing: "已恢复安装前状态")
            try require(try fixture.payload() == "old" && fixture.reopened == 1 && fixture.registered == ["old"], "Post-install signature failure restores and reopens the verified original path")
        }
        do {
            let fixture = try Fixture(); fixture.active = true
            var environment = fixture.environment
            environment.register = { app in
                fixture.registered.append(try fixture.payload(app))
                if try fixture.payload(app) == "new" { throw OverwriteInstallError.message("registration failure") }
            }
            try await rejected({ try await fixture.install(environment) }, containing: "已恢复安装前状态")
            try require(try fixture.payload() == "old" && fixture.registered == ["new", "old"] && fixture.reopened == 1, "Registration failure rolls back before reopening the old app")
        }
        do {
            let fixture = try Fixture(existing: false)
            var environment = fixture.environment
            environment.register = { _ in throw OverwriteInstallError.message("registration failure") }
            try await rejected({ try await fixture.install(environment) }, containing: "已恢复安装前状态")
            try require(!FileManager.default.fileExists(atPath: fixture.target.path), "Failed first install returns the target to absent")
        }
        do {
            let fixture = try Fixture(); fixture.active = true
            var environment = fixture.environment
            let move = environment.move
            environment.register = { _ in throw OverwriteInstallError.message("registration failure") }
            environment.move = { from, to, swap in
                if from == fixture.target { throw OverwriteInstallError.message("rollback failure") }
                try move(from, to, swap)
            }
            try await rejected({ try await fixture.install(environment) }, containing: "自动回滚未完成")
            let recovery = try fixture.directories(".xclip-install-")
            try require(recovery.count == 1 && fixture.payload(recovery[0].appendingPathComponent("Xclip.app")) == "old", "Failed rollback retains the original in a recovery directory")
            try require(fixture.reopened == 0, "Uncertain recovery never reopens a possibly replaced target")
        }
        do {
            let fixture = try Fixture(); fixture.active = true
            var environment = fixture.environment
            environment.signature = { app in
                if app == fixture.target && fixture.quitCalls == 1 { fixture.active = true }
                return Data([1, 2, 3])
            }
            try await rejected({ try await fixture.install(environment) }, containing: "仍在运行或重新启动")
            try require(fixture.moves == 0 && fixture.payload() == "old", "Final process recheck catches an app restarted during validation")
        }
        for changed in ["source", "target"] {
            let fixture = try Fixture(); fixture.active = true
            var environment = fixture.environment
            environment.quit = { _ in
                fixture.active = false
                let app = changed == "source" ? fixture.source : fixture.target
                try Data("changed in place".utf8).write(to: app.appendingPathComponent("Contents/MacOS/Xclip"))
            }
            try await rejected({ try await fixture.install(environment) }, containing: "准备期间发生了变化")
            try require(fixture.moves == 0, "Same-version \(changed) changes are rejected before replacement")
            try require(fixture.reopened == (changed == "source" ? 1 : 0), "Only the verified unchanged original can reopen after a changed \(changed)")
        }
        for kind in ["other-app", "test-data", "unknown-file", "downgrade", "certificate", "adhoc", "symlink", "nested"] {
            let fixture = try Fixture()
            var environment = fixture.environment
            var expected = ""
            switch kind {
            case "other-app": try Fixture.metadata(fixture.target, values: ["CFBundleIdentifier": "other.app"]); expected = "不是正式 Xclip"
            case "test-data": try Fixture.metadata(fixture.target, values: ["CClipTestDataDirectory": fixture.root.path]); expected = "测试数据"
            case "unknown-file": try Data("keep me".utf8).write(to: fixture.target.appendingPathComponent("private.txt")); expected = "未确认的文件"
            case "downgrade": try Fixture.metadata(fixture.target, values: ["CFBundleVersion": "3"]); expected = "拒绝降级"
            case "certificate": environment.signature = { $0 == fixture.target ? Data([9]) : Data([1, 2, 3]) }; expected = "签名证书不同"
            case "adhoc": environment.signature = { _ in Data() }; expected = "临时签名"
            case "symlink":
                let alias = fixture.target.deletingLastPathComponent().appendingPathComponent("Alias.app")
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.target)
                try await rejected({ try await OverwriteInstaller.install(source: fixture.source, destination: alias, progress: { _ in }, environment: environment) }, containing: "符号链接")
                continue
            default:
                let nested = fixture.target.appendingPathComponent("Nested.app")
                try await rejected({ try await OverwriteInstaller.install(source: nested, destination: fixture.target, progress: { _ in }, environment: environment) }, containing: "互不包含")
                continue
            }
            try await rejected({ try await fixture.install(environment) }, containing: expected)
            try require(fixture.moves == 0 && fixture.quitCalls == 0 && fixture.payload() == "old", "Unsafe \(kind) leaves the original untouched")
        }
        do {
            let fixture = try Fixture()
            let path = fixture.target.deletingLastPathComponent().appendingPathComponent(".Xclip.app.xclip-install.lock")
            let descriptor = open(path.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            defer { _ = flock(descriptor, LOCK_UN); close(descriptor) }
            try require(descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0, "Fixture holds the exact-target installation lock")
            try await rejected({ try await fixture.install() }, containing: "另一个安装")
            try require(fixture.moves == 0, "Concurrent installation cannot start replacement")
        }
        print("All \(count) overwrite installer checks passed using isolated fixtures; no real applications were terminated or installed.")
    }
}
