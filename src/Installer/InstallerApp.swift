import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class InstallerModel: ObservableObject {
    static let shared = InstallerModel()
    @Published var source = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Xclip.app")
    @Published var version = ""
    @Published var destinations: [URL] = []
    @Published var destination = URL(fileURLWithPath: "/Applications/Xclip.app")
    @Published var status = ""
    @Published var error: String?
    @Published var isInstalling = false
    @Published var installed = false
    @Published var sourceReady = false

    init() { refresh() }

    var hasExistingApp: Bool { FileManager.default.fileExists(atPath: destination.path) }

    func refresh() {
        do {
            try OverwriteInstaller.validateSource(source, signedLike: Bundle.main.bundleURL)
            version = try OverwriteInstaller.inspect(source).version
            sourceReady = true
        } catch {
            sourceReady = false
            self.error = "未能自动读取新版应用，请点击“选择新版应用”并选择安装包中的 Xclip.app。\n\(error.localizedDescription)"
        }
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == "local.cclip.app" }.compactMap(\.bundleURL)
        let standard = [URL(fileURLWithPath: "/Applications/Xclip.app"),
                        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Xclip.app"),
                        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/Xclip.app")]
        let registered = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: "local.cclip.app")
        var seen = Set<String>()
        destinations = (running + standard + registered).filter { url in
            let path = url.standardizedFileURL.path
            return url.standardizedFileURL != source.standardizedFileURL
                && !path.hasPrefix("/Volumes/") && !path.contains("/.build/")
                && seen.insert(path).inserted && (try? OverwriteInstaller.inspect(url)) != nil
        }
        if let first = destinations.first { destination = first }
        else { destinations = [destination] }
    }

    func chooseSource() {
        let panel = NSOpenPanel()
        panel.title = "选择安装包中的新版 Xclip.app"
        panel.prompt = "使用此新版应用"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        do {
            try OverwriteInstaller.validateSource(selected, signedLike: Bundle.main.bundleURL)
            let info = try OverwriteInstaller.inspect(selected)
            source = selected
            version = info.version
            sourceReady = true
            error = nil
            installed = false
            status = ""
        } catch { self.error = error.localizedDescription }
    }

    func chooseExisting() {
        let panel = NSOpenPanel()
        panel.title = "选择要覆盖更新的 Xclip.app"
        panel.prompt = "选择此应用"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        do {
            _ = try OverwriteInstaller.inspect(selected)
            select(selected)
        } catch { self.error = error.localizedDescription }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择 Xclip 安装文件夹"
        panel.prompt = "安装到此文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        select(selected.appendingPathComponent("Xclip.app"))
    }

    private func select(_ url: URL) {
        if !destinations.contains(url) { destinations.append(url) }
        destination = url
        error = nil
        installed = false
        status = ""
    }

    func install() {
        guard !isInstalling, sourceReady else { return }
        let target = destination
        isInstalling = true
        error = nil
        status = "正在检查安装包…"
        Task {
            defer { isInstalling = false }
            do {
                try OverwriteInstaller.validateSource(source, signedLike: Bundle.main.bundleURL)
                let result = try await OverwriteInstaller.install(source: source, destination: target) { [weak self] message in
                    self?.status = message
                }
                installed = true
                status = "覆盖安装完成，正在打开 Xclip…"
                do {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    configuration.createsNewApplicationInstance = true
                    let app = try await NSWorkspace.shared.openApplication(at: result, configuration: configuration)
                    guard app.bundleURL?.standardizedFileURL == result.standardizedFileURL else {
                        throw NSError(domain: "XclipInstaller", code: 1, userInfo: [NSLocalizedDescriptionKey: "系统没有打开指定位置的 Xclip。"])
                    }
                    status = "安装完成，已打开新版 Xclip。"
                } catch {
                    status = "覆盖安装已完成。请从下方位置手动打开 Xclip。"
                    self.error = error.localizedDescription
                }
            } catch {
                self.error = error.localizedDescription
                status = "安装未完成"
            }
        }
    }
}

private struct InstallerView: View {
    @ObservedObject var model: InstallerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.app.fill").font(.system(size: 42)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 5) {
                    Text("安装 Xclip").font(.title.bold())
                    Text(model.version.isEmpty ? "安装与更新" : "新版 \(model.version)").foregroundStyle(.secondary)
                }
            }
            Text("直接更新已有 Xclip，保留剪贴板历史和设置。")
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("新版应用").font(.headline)
                    Spacer()
                    Button("选择新版应用…", action: model.chooseSource).disabled(model.isInstalling || model.installed)
                        .accessibilityIdentifier("installer.chooseSource")
                }
                Text(model.source.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("安装位置").font(.headline)
                Picker("安装位置", selection: $model.destination) {
                    ForEach(model.destinations, id: \.self) { url in
                        Text(url.path).tag(url)
                    }
                }.labelsHidden().disabled(model.isInstalling || model.installed)
                Text(model.destination.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("选择已有应用…", action: model.chooseExisting)
                    Button("选择安装文件夹…", action: model.chooseFolder)
                }.disabled(model.isInstalling || model.installed)
            }
            Text("开始后会请求所选位置的旧版正常退出，原位置覆盖安装并重新打开。若旧版未退出，安装会停止；其他位置的副本保持原样。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.isInstalling {
                HStack { ProgressView().controlSize(.small); Text(model.status) }
            } else if !model.status.isEmpty { Text(model.status).foregroundStyle(model.installed ? Color.primary : .secondary) }
            if let error = model.error {
                ScrollView { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 95)
            }
            HStack {
                Spacer()
                Button(model.installed ? "完成" : "取消") { NSApp.terminate(nil) }.disabled(model.isInstalling)
                if !model.installed {
                    Button(model.hasExistingApp ? "覆盖安装并重启" : "安装并打开", action: model.install)
                        .buttonStyle(.borderedProminent).disabled(model.isInstalling || !model.sourceReady)
                        .accessibilityIdentifier("installer.install")
                }
            }
        }.padding(28).frame(width: 580).fixedSize(horizontal: true, vertical: true)
    }
}

private final class InstallerDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        InstallerModel.shared.isInstalling ? .terminateCancel : .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct XclipInstallerApp: App {
    @NSApplicationDelegateAdaptor(InstallerDelegate.self) private var delegate
    var body: some Scene {
        Window("安装 Xclip", id: "installer") { InstallerView(model: .shared) }
            .windowResizability(.contentSize)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
