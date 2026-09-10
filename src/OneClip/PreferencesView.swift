import SwiftUI
import AppKit
import ServiceManagement
import Carbon

struct PreferencesView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var state = WorkflowState.shared
    @ObservedObject private var lock = PrivacyLock.shared
    @ObservedObject private var shortcuts = GlobalShortcuts.shared
    @State private var password = ""
    @State private var categoryName = ""
    @State private var categoryPattern = ""
    @State private var categoryParent: UUID?
    @State private var storageInfo = ClipboardManager.shared.getStorageInfo()
    @State private var tab = "general"
    var body: some View {
        VStack {
            Picker(L("设置分组", "Settings group"), selection: $tab) {
                Text(L("通用", "General")).tag("general"); Text(L("隐私", "Privacy")).tag("privacy")
                Text(L("数据", "Data")).tag("data"); Text(L("分类", "Categories")).tag("categories"); Text(L("快捷键", "Shortcuts")).tag("shortcuts")
            }.pickerStyle(.segmented).padding()
            Form {
                switch tab {
                case "privacy": privacy
                case "data": data
                case "categories": categories
                case "shortcuts": shortcutSettings
                default: general
                }
            }.formStyle(.grouped)
        }.navigationTitle(L("设置", "Settings"))
            .environment(\.locale, appLanguage.locale)
    }
    private var general: some View {
        Group {
            Section(L("界面语言", "Interface language")) {
                Picker(L("语言", "Language"), selection: Binding(get: { appLanguage.code }, set: { code in
                    perform { try state.setLanguage(code) }
                })) {
                    Text("简体中文").tag("zh")
                    Text("English").tag("en")
                }
                .accessibilityIdentifier("settings.language")
                Text(L("切换后立即生效，并记住你的选择。", "Changes apply immediately and are remembered."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("外观与启动", "Appearance & launch")) {
                Picker(L("主题", "Theme"), selection: $settings.themeMode) { Text(L("跟随系统", "System")).tag("system"); Text(L("浅色", "Light")).tag("light"); Text(L("深色", "Dark")).tag("dark") }
                Toggle(L("在 Dock 显示", "Show in Dock"), isOn: $settings.showInDock).onChange(of: settings.showInDock) { _, value in
                    NSApp.setActivationPolicy(value ? .regular : .accessory)
                    DispatchQueue.main.async { MenuBarController.shared.restore() }
                }
                Toggle(L("显示菜单栏图标", "Show menu bar icon"), isOn: $settings.showInMenuBar)
                Toggle(L("登录时启动", "Launch at login"), isOn: $settings.autoStartOnLogin).onChange(of: settings.autoStartOnLogin) { _, value in
                    perform { if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                }
                Toggle(L("窗口置顶", "Keep window on top"), isOn: $settings.keepWindowOnTop).onChange(of: settings.keepWindowOnTop) { _, value in NSApp.windows.first(where: { $0.identifier?.rawValue == "main" })?.level = value ? .floating : .normal }
            }
            Section(L("桌面交互", "Desktop interaction")) {
                Toggle(L("右侧屏幕边缘唤起快速面板", "Reveal quick panel at right screen edge"), isOn: $state.document.edgeReveal)
                Toggle(L("拖到屏幕顶部唤起拖放架", "Reveal drop shelf by dragging to screen top"), isOn: $state.document.topShelf)
                Toggle(L("划词快捷菜单", "Selection action menu"), isOn: $state.document.selectionMenu)
                Toggle(L("访达 ⌘X / ⌘V 移动文件", "Finder ⌘X / ⌘V file move"), isOn: $state.document.finderCut)
                Text(L("划词、自动粘贴与访达增强需要辅助功能权限。", "Selection actions, automatic paste and Finder enhancement require Accessibility.")).font(.caption).foregroundStyle(.secondary)
                Button(L("打开辅助功能设置", "Open Accessibility settings")) { openAccessibility() }
                Button(L("授权后重新连接", "Reconnect after granting access")) { DesktopEvents.shared.configure() }
            }
            Section(L("粘贴行为", "Paste behavior")) {
                Toggle(L("粘贴后移到顶部", "Move pasted item to top"), isOn: $state.document.moveAfterPaste)
                Toggle(L("粘贴后自动回车", "Press Return after paste"), isOn: $state.document.returnAfterPaste)
            }
            Section(L("关于", "About")) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().scaledToFit().frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                    Text("Xclip").font(.headline)
                }
            }
        }
    }
    private var privacy: some View {
        Group {
            Section(L("历史锁", "History lock")) {
                Text(L("使用密码或系统验证保护界面；这不会加密数据库文件。", "Protect the interface with a password or system authentication. Database files are not encrypted.")).font(.callout)
                SecureField(L("设置密码（至少 8 位）", "Set password (8+ characters)"), text: $password)
                HStack {
                    Button(L("保存密码", "Save password")) { perform { try lock.setPassword(password); password = ""; state.status = L("密码已保存在钥匙串。", "Password verifier saved in Keychain.") } }.disabled(password.count < 8)
                    Button(L("立即锁定", "Lock now")) { lock.lock() }.disabled(!lock.enabled)
                    Button(L("移除密码", "Remove password")) { lock.removePassword() }.disabled(!lock.enabled)
                }
            }
            Section(L("捕获排除", "Capture exclusions")) {
                TextField(L("应用标识，每行一个", "Application bundle IDs, one per line"), text: $state.document.excludedApps, axis: .vertical).lineLimit(3...6)
                TextField(L("排除内容的正则，每行一个", "Exclude content patterns, one regex per line"), text: $state.document.excludedPatterns, axis: .vertical).lineLimit(3...6)
                Text(L("标记为敏感或临时的剪贴板内容始终跳过，内容不会写入诊断日志。", "Concealed and transient clipboard items are always skipped. Content is not written to diagnostic logs.")).font(.caption).foregroundStyle(.secondary)
                Button(L("应用过滤规则", "Apply filters")) { perform { for pattern in state.document.excludedPatterns.components(separatedBy: .newlines) where !pattern.isEmpty { _ = try NSRegularExpression(pattern: pattern) }; applyCapturePreferences(); state.status = L("过滤规则已更新。", "Capture filters updated.") } }
            }
        }
    }
    private var data: some View {
        Group {
            Section(L("历史保存", "History storage")) {
                Toggle(L("持久保存历史", "Persist history"), isOn: $settings.enableHistoryPersistence)
                Picker(L("历史数量", "History limit"), selection: $settings.maxItems) { Text(L("不限制", "Unlimited")).tag(0); Text("500").tag(500); Text("2000").tag(2000); Text("10000").tag(10000) }
                Picker(L("自动清理", "Retention"), selection: $settings.autoCleanupDays) { Text(L("从不", "Never")).tag(0); Text(L("7 天", "7 days")).tag(7); Text(L("30 天", "30 days")).tag(30); Text(L("90 天", "90 days")).tag(90) }
                Toggle(L("自动识别新图片文字，供历史搜索", "Recognize new images for history search"), isOn: Binding(get: { state.document.autoRecognizeImages ?? false }, set: { state.document.autoRecognizeImages = $0 }))
                Text(L("收藏和置顶不会自动清理。", "Favorites and pinned items are protected from automatic cleanup.")).font(.caption)
                Text("\(storageInfo.itemCount) " + L("条 · ", "items · ") + storageInfo.totalSize.formatted(.byteCount(style: .file).locale(appLanguage.locale)))
                Text(storageInfo.cachePath).font(.caption).textSelection(.enabled)
                HStack { Button(L("更改历史存储位置…", "Change history location…")) { WorkspaceBackup.shared.relocate(); refreshStorage() }; Button(L("执行过期清理", "Clean expired items")) { ClipboardManager.shared.performManualCleanup(); refreshStorage() } }
            }
            Section(L("备份与恢复", "Backup & restore")) {
                Toggle(L("每天自动备份到本地（保留 7 份）", "Daily local backups (keep 7)"), isOn: $state.document.automaticBackup)
                HStack {
                    Button(L("导出完整备份…", "Export full backup…")) { let panel = NSSavePanel(); panel.nameFieldStringValue = "Xclip-" + Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)) + ".oneclipbackup"; if panel.runModal() == .OK, let url = panel.url { perform { try WorkspaceBackup.shared.export(to: url); state.status = L("完整备份已保存。", "Full backup saved.") } } }
                    Button(L("合并导入备份…", "Merge backup…")) { let panel = NSOpenPanel(); if panel.runModal() == .OK, let url = panel.url { perform { try WorkspaceBackup.shared.restore(from: url); refreshStorage(); state.status = L("备份已合并。网络功能和导入的快捷键保持关闭。", "Backup merged. Network features and imported shortcuts remain disabled.") } } }
                }
                Button(L("导入旧版数据目录…", "Import legacy data folder…")) { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK, let url = panel.url { perform { try ClipboardManager.shared.store.migrateLegacyDirectory(from: url); ClipboardManager.shared.reload(); refreshStorage() } } }
                Text(L("备份包含历史、附件、收藏、栈、模板、分类和设置；不包含密码或 API 密钥。", "Backups include history, attachments, favorites, stack, templates, categories and settings, excluding passwords and API keys.")).font(.caption)
            }
        }
    }
    private var categories: some View {
        Group {
            Section(L("自定义分类", "Custom categories")) {
                ForEach(state.document.categories) { category in
                    HStack {
                        VStack(alignment: .leading) { Text(category.name); Text(category.pattern.isEmpty ? L("手动分类", "Manual category") : category.pattern).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if let parent = category.parentID, let name = state.document.categories.first(where: { $0.id == parent })?.name { Text(name).font(.caption) }
                        Button { if let i = state.document.categories.firstIndex(where: { $0.id == category.id }), i > 0 { state.document.categories.swapAt(i, i - 1) } } label: { Image(systemName: "arrow.up") }.help(L("上移", "Move up"))
                        Button(role: .destructive) { state.document.categories.removeAll { $0.id == category.id }; for index in state.document.categories.indices where state.document.categories[index].parentID == category.id { state.document.categories[index].parentID = nil } } label: { Image(systemName: "trash") }
                    }
                }
                TextField(L("分类名称", "Category name"), text: $categoryName)
                TextField(L("自动匹配正则（可选）", "Automatic regex (optional)"), text: $categoryPattern)
                Picker(L("上级分类", "Parent category"), selection: $categoryParent) { Text(L("无", "None")).tag(nil as UUID?); ForEach(state.document.categories) { Text($0.name).tag(Optional($0.id)) } }
                Button(L("添加分类", "Add category")) { perform { if !categoryPattern.isEmpty { _ = try NSRegularExpression(pattern: categoryPattern) }; guard !state.document.categories.contains(where: { $0.name == categoryName }) else { throw ClipboardError.dataCorrupted }; state.document.categories.append(.init(name: categoryName, parentID: categoryParent, pattern: categoryPattern)); categoryName = ""; categoryPattern = "" } }.disabled(categoryName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(L("将规则应用到已有历史", "Apply rules to history")) { for item in ClipboardManager.shared.clipboardItems { ClipboardManager.shared.update(state.applyRules(item)) } }
            }
        }
    }
    private var shortcutSettings: some View {
        Group {
            Section(L("全局快捷键", "Global shortcuts")) {
                ForEach(GlobalShortcuts.defaults.keys.sorted(), id: \.self) { name in
                    HStack {
                        Text(shortcutTitle(name)); Spacer()
                        Text((state.document.shortcuts[name] ?? GlobalShortcuts.defaults[name])?.label ?? "").font(.system(.body, design: .monospaced))
                        Button(L("修改…", "Change…")) { ShortcutRecorder.shared.record { spec in state.document.shortcuts[name] = spec; NotificationCenter.default.post(name: .init("CClipShortcutsChanged"), object: nil) } }
                        Button(L("恢复", "Reset")) { state.document.shortcuts.removeValue(forKey: name); NotificationCenter.default.post(name: .init("CClipShortcutsChanged"), object: nil) }
                    }
                }
                ForEach(shortcuts.errors, id: \.self) { Text($0).foregroundStyle(.red) }
            }
        }
    }
    private func refreshStorage() { storageInfo = ClipboardManager.shared.getStorageInfo() }
}
func shortcutTitle(_ name: String) -> String {
    switch name {
    case "history": return L("主窗口", "History")
    case "stack": return L("栈粘贴板", "Stack")
    case "replies": return L("快捷回复", "Replies")
    case "shelf": return L("拖拽容器", "Shelf")
    case "quick": return L("快速面板", "Quick panel")
    case "capture": return L("截图", "Capture")
    case "split": return L("按行入栈", "Split to stack")
    default: return name
    }
}
func openAccessibility() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
func applyCapturePreferences() {
    ClipboardManager.shared.excludedApplications = Set(WorkflowState.shared.document.excludedApps.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    ClipboardManager.shared.sensitivePatterns = WorkflowState.shared.document.excludedPatterns.components(separatedBy: .newlines).filter { !$0.isEmpty }
}

class ShortcutRecorder {
    static let shared = ShortcutRecorder()
    private var monitor: Any?
    private var panel: NSPanel?
    private var languageObserver: NSObjectProtocol?
    private init() {
        languageObserver = NotificationCenter.default.addObserver(forName: AppLanguage.didChange, object: AppLanguage.shared, queue: .main) { [weak self] _ in
            self?.panel?.title = L("按下新快捷键，Esc 取消", "Press new shortcut. Esc to cancel.")
        }
    }
    func record(_ completion: @escaping (ShortcutSpec) -> Void) {
        cancel()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 110), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = L("按下新快捷键，Esc 取消", "Press new shortcut. Esc to cancel.")
        panel.contentView = NSHostingView(rootView: ShortcutRecorderPrompt())
        panel.center(); panel.makeKeyAndOrderFront(nil); self.panel = panel
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.cancel(); return nil }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.intersection([.command, .option, .control]).isEmpty else { NSSound.beep(); return nil }
            let label = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + (event.charactersIgnoringModifiers?.uppercased() ?? "[\(event.keyCode)]")
            completion(.init(keyCode: event.keyCode, modifiers: flags.rawValue, label: label)); self.cancel(); return nil
        }
    }
    private func cancel() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; panel?.close(); panel = nil }
}

private struct ShortcutRecorderPrompt: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    var body: some View {
        Text(L("请使用 Command、Option 或 Control 组合键。", "Include Command, Option or Control.")).padding(20)
    }
}

class WorkspaceBackup {
    static let shared = WorkspaceBackup()
    private let clipboard: ClipboardManager
    private let workflow: WorkflowState
    private let settings: SettingsManager
    private let scripts: ScriptService
    private let ai: AIService
    private let defaults: UserDefaults

    init(clipboard: ClipboardManager = .shared, workflow: WorkflowState = .shared,
         settings: SettingsManager = .shared, scripts: ScriptService = .shared, ai: AIService = .shared, defaults: UserDefaults = .standard) {
        self.clipboard = clipboard; self.workflow = workflow; self.settings = settings; self.scripts = scripts; self.ai = ai; self.defaults = defaults
    }
    private var additional: [ClipboardItem] {
        let doc = workflow.document
        return doc.stack + doc.shelf + doc.replies.map(\.item)
    }
    private func remap(_ document: WorkflowDocument, to items: [ClipboardItem]) throws -> WorkflowDocument {
        let previous = document.stack + document.shelf + document.replies.map(\.item)
        guard previous.count == items.count, zip(previous, items).allSatisfy({ $0.id == $1.id }) else { throw ClipboardError.dataCorrupted }
        var doc = document
        var index = 0
        for i in doc.stack.indices { doc.stack[i] = items[index]; index += 1 }
        for i in doc.shelf.indices { doc.shelf[i] = items[index]; index += 1 }
        for i in doc.replies.indices { doc.replies[i].item = items[index]; index += 1 }
        return doc
    }
    func export(to url: URL, persistentHistoryOnly: Bool = false) throws {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
        let history = settings.enableHistoryPersistence || persistentHistoryOnly ? clipboard.store.getStorageInfo().cachePath : StoragePaths.historyDirectory.path
        let forbidden = ["history.sqlite3", "history.sqlite3-wal", "history.sqlite3-shm", "workflow.json", "settings.json"]
        guard !forbidden.contains(url.lastPathComponent),
              !canonical.hasPrefix(URL(fileURLWithPath: history).resolvingSymlinksInPath().path + "/attachments/") else { throw ClipboardError.storageFailure }
        let historyItems = settings.enableHistoryPersistence || persistentHistoryOnly ? try clipboard.store.readItems() : clipboard.clipboardItems
        var archive = try HistoryArchive.make(items: historyItems, additionalItems: additional)
        let portableDocument = try remap(workflow.document, to: archive.additionalItems ?? [])
        archive.extraFiles = [
            "workflow.json": try JSONEncoder().encode(portableDocument),
            "settings.json": try JSONEncoder().encode(snapshotSettings()),
            "scripts.json": try JSONEncoder().encode(scripts.scripts),
            "ai-configuration.json": try JSONEncoder().encode(ai.configuration)
        ]
        try archive.validate()
        try JSONEncoder().encode(archive).write(to: url, options: .atomic)
    }

    func restore(from url: URL) throws {
        let archive = try JSONDecoder().decode(HistoryArchive.self, from: Data(contentsOf: url))
        try archive.validate()
        let importedDocument = try archive.extraFiles?["workflow.json"].map { try JSONDecoder().decode(WorkflowDocument.self, from: $0) }
        let importedSettings = try archive.extraFiles?["settings.json"].map { try JSONDecoder().decode(AppSettings.self, from: $0) }
        let importedScripts = try archive.extraFiles?["scripts.json"].map { try JSONDecoder().decode([ClipboardScript].self, from: $0) }
        let importedAI = try (archive.extraFiles?["ai-configuration.json"] ?? archive.extraFiles?["ai-settings.json"]).map { try JSONDecoder().decode(AIConfiguration.self, from: $0) }
        if let doc = importedDocument {
            _ = try remap(doc, to: archive.additionalItems ?? [])
            guard ["zh", "en"].contains(doc.language), ["list", "grid", "horizontal"].contains(doc.layout) else { throw ClipboardError.dataCorrupted }
            for pattern in doc.excludedPatterns.components(separatedBy: .newlines) + doc.categories.map(\.pattern) where !pattern.isEmpty { _ = try NSRegularExpression(pattern: pattern) }
        }
        if let configuration = importedAI {
            _ = try configuration.requestURL()
            guard configuration.temperature.isFinite, (0...2).contains(configuration.temperature) else { throw ClipboardError.dataCorrupted }
        }
        if let app = importedSettings {
            guard app.maxItems >= 0, (0...36_500).contains(app.autoCleanupDays), app.monitoringInterval.isFinite,
                  (0.2...60).contains(app.monitoringInterval), app.compressionQuality.isFinite,
                  (0...1).contains(app.compressionQuality), app.maxImageSize.isFinite,
                  (1...100_000).contains(app.maxImageSize) else { throw ClipboardError.dataCorrupted }
        }
        if let importedScripts {
            guard importedScripts.allSatisfy({ $0.code.utf8.count <= 65_536 && ["manual", "copy", "paste"].contains($0.trigger) }) else { throw ClipboardError.dataCorrupted }
        }
        // All structured settings have been decoded and checked before any history mutation.
        let previousHistory = settings.enableHistoryPersistence ? try clipboard.store.readItems() : clipboard.clipboardItems
        let previousDocument = workflow.document
        let file = StoragePaths.dataDirectory.appendingPathComponent("workflow.json")
        let previousFile = try? Data(contentsOf: file)
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("cclip-workspace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stage) }
        var didImport = false
        do {
            let result: BackupImportResult
            let historyToDisplay: [ClipboardItem]
            if settings.enableHistoryPersistence {
                result = try clipboard.store.importWorkspaceBackup(from: url)
                historyToDisplay = result.items
            } else {
                let materialized = try archive.unpackWorkspace(to: stage)
                var auxiliaryOnly = archive
                auxiliaryOnly.items = []
                let auxiliaryURL = stage.appendingPathComponent("auxiliary.backup")
                try JSONEncoder().encode(auxiliaryOnly).write(to: auxiliaryURL)
                result = try clipboard.store.importWorkspaceBackup(from: auxiliaryURL)
                historyToDisplay = materialized.items
            }
            didImport = true
            var merged = previousDocument
            if let document = importedDocument {
                var incoming = try remap(document, to: result.additionalItems)
                incoming.replies = incoming.replies.map { var reply = $0; reply.hotkey = nil; return reply }
                let stackIDs = Set(merged.stack.map(\.id)), shelfIDs = Set(merged.shelf.map(\.id))
                merged.stack += incoming.stack.filter { !stackIDs.contains($0.id) }
                merged.shelf += incoming.shelf.filter { !shelfIDs.contains($0.id) }
                for reply in incoming.replies where !merged.replies.contains(where: { $0.id == reply.id }) { merged.replies.append(reply) }
                var categoryIDs: [UUID: UUID] = [:]
                for category in incoming.categories { categoryIDs[category.id] = merged.categories.first(where: { $0.name == category.name })?.id ?? category.id }
                for var category in incoming.categories where !merged.categories.contains(where: { $0.name == category.name }) {
                    category.parentID = category.parentID.flatMap { categoryIDs[$0] }
                    merged.categories.append(category)
                }
                merged.language = incoming.language; merged.layout = incoming.layout
                merged.excludedApps = mergedLines(merged.excludedApps, incoming.excludedApps)
                merged.excludedPatterns = mergedLines(merged.excludedPatterns, incoming.excludedPatterns)
                merged.searchHistory = Array((incoming.searchHistory + merged.searchHistory).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(20))
                merged.moveAfterPaste = incoming.moveAfterPaste; merged.returnAfterPaste = incoming.returnAfterPaste
                // Shortcut bindings and permission-dependent background features keep local authorization.
            }
            try FileManager.default.createDirectory(at: StoragePaths.dataDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(merged).write(to: file, options: .atomic)
            try clipboard.adoptImportedHistory(historyToDisplay)
            try workflow.reloadFromDisk()
            if let importedSettings { applySettings(importedSettings) }
            if let importedAI { ai.configuration = importedAI }
            if let importedScripts {
                var mergedScripts = scripts.scripts
                for var script in importedScripts where !mergedScripts.contains(where: { $0.id == script.id }) {
                    script.enabled = false
                    mergedScripts.append(script)
                }
                scripts.scripts = mergedScripts
            }
            clipboard.excludedApplications = Set(merged.excludedApps.components(separatedBy: .newlines).filter { !$0.isEmpty })
            clipboard.sensitivePatterns = merged.excludedPatterns.components(separatedBy: .newlines).filter { !$0.isEmpty }
        } catch {
            if didImport, settings.enableHistoryPersistence {
                try? clipboard.store.setItemLimit(0)
                _ = try? clipboard.store.replaceItems(previousHistory)
            }
            clipboard.clipboardItems = previousHistory; clipboard.changed()
            if let previousFile { try? previousFile.write(to: file, options: .atomic) }
            else { try? FileManager.default.removeItem(at: file) }
            throw error
        }
    }

    func relocate() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        perform { try relocate(to: directory.appendingPathComponent("CClip-History", isDirectory: true)) }
    }
    /// A testable migration action. The source is retained; the selected target must be empty.
    func relocate(to target: URL) throws {
        guard !FileManager.default.fileExists(atPath: target.path) else { throw AutomationError.invalid(L("目标目录已存在，请选择新的历史目录。", "The destination already exists. Choose a new history folder.")) }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("cclip-relocate-\(UUID().uuidString).backup")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try export(to: temporary, persistentHistoryOnly: true)
        let destination = ClipboardStore(storageDirectory: target, requiresEmptyStore: true, getCleanupDays: { [weak self] in
            guard let self, self.settings.enableHistoryPersistence else { return 0 }
            return self.settings.autoCleanupDays
        })
        if let error = destination.lastError { throw AutomationError.invalid(error) }
        let result = try destination.importWorkspaceBackup(from: temporary, merge: false)
        let updated = try remap(workflow.document, to: result.additionalItems)
        // Commit the workflow paths before switching the selected database; failures leave the source selected.
        try JSONEncoder().encode(updated).write(to: StoragePaths.dataDirectory.appendingPathComponent("workflow.json"), options: .atomic)
        defaults.set(target.path, forKey: "local.cclip.historyDirectory")
        clipboard.store = destination; try workflow.reloadFromDisk()
        if settings.enableHistoryPersistence { try clipboard.adoptImportedHistory(result.items, merge: false) }
        workflow.status = L("历史已迁移；原目录保留作为备份。", "History migrated. The original directory is retained as a backup.")
    }
    func automaticBackupIfDue() {
        guard workflow.document.automaticBackup, settings.enableHistoryPersistence, !PrivacyLock.shared.locked else { return }
        let directory = StoragePaths.dataDirectory.appendingPathComponent("Backups", isDirectory: true)
        let date = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let target = directory.appendingPathComponent(date + ".oneclipbackup")
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        perform {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try export(to: target)
            let old = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "oneclipbackup" }.sorted { $0.lastPathComponent > $1.lastPathComponent }.dropFirst(7)
            for file in old { try FileManager.default.removeItem(at: file) }
        }
    }
    private func mergedLines(_ a: String, _ b: String) -> String {
        Array(Set((a + "\n" + b).components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted().joined(separator: "\n")
    }
    private func snapshotSettings() -> AppSettings {
        var value = AppSettings()
        value.showInDock = settings.showInDock; value.maxItems = settings.maxItems
        value.enableHistoryPersistence = settings.enableHistoryPersistence; value.autoStartOnLogin = settings.autoStartOnLogin
        value.isFirstLaunch = settings.isFirstLaunch; value.hasShownWelcome = settings.hasShownWelcome; value.hasShownPermissionPrompt = settings.hasShownPermissionPrompt
        value.previewSize = settings.previewSize; value.showLineNumbers = settings.showLineNumbers; value.enableAnimations = settings.enableAnimations
        value.showInMenuBar = settings.showInMenuBar; value.enableNotifications = settings.enableNotifications
        value.maxImageSize = settings.maxImageSize; value.compressionQuality = settings.compressionQuality
        value.monitoringInterval = settings.monitoringInterval; value.autoCleanupDays = settings.autoCleanupDays
        value.themeMode = settings.themeMode; value.keepWindowOnTop = settings.keepWindowOnTop
        return value
    }
    private func applySettings(_ value: AppSettings) {
        settings.showInDock = value.showInDock; settings.maxItems = value.maxItems
        settings.previewSize = value.previewSize; settings.showLineNumbers = value.showLineNumbers
        settings.enableAnimations = value.enableAnimations; settings.showInMenuBar = value.showInMenuBar
        settings.maxImageSize = value.maxImageSize; settings.compressionQuality = value.compressionQuality
        settings.monitoringInterval = value.monitoringInterval; settings.autoCleanupDays = value.autoCleanupDays
        settings.themeMode = value.themeMode; settings.keepWindowOnTop = value.keepWindowOnTop
        // Persistence, launch-at-login, notifications and permission onboarding stay local.
    }
}
