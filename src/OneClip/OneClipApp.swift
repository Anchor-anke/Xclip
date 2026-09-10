import SwiftUI
import AppKit
import Combine

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let menuBar = MenuBarController.shared
    private var mainWindow: NSWindow?
    private let quickPanel = QuickPastePanelController()
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var backupTimer: Timer?
    private var autoOCRTask: Task<Void, Never>?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            do { try AppSmokeTests.run(); exit(0) } catch { fputs("Smoke test failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if ProcessInfo.processInfo.arguments.contains("--render-snapshots") {
            do { try AppRenderTests.run(); exit(0) } catch { fputs("Render tests failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        _ = WorkflowState.shared
        NativeLanguageController.shared.start()
        let isUITest = ProcessInfo.processInfo.arguments.contains("--ui-test") || Bundle.main.object(forInfoDictionaryKey: "CClipTestDataDirectory") != nil
        let clipboard = ClipboardManager.shared
        clipboard.captureAllowed = { !PrivacyLock.shared.locked }
        clipboard.textTransform = { text, trigger in try ScriptService.shared.transform(text, trigger: trigger) }
        clipboard.onCapture = { [weak self] item in
            let classified = WorkflowState.shared.applyRules(item)
            if classified.tags != item.tags { clipboard.update(classified) }
            if WorkflowState.shared.stackCollecting { WorkflowState.shared.addToStack(classified) }
            LANSyncService.shared.sendCaptured(classified)
            self?.recognizeForSearch(classified)
        }
        observers.append(NotificationCenter.default.addObserver(forName: .init("CClipOCRText"), object: nil, queue: .main) { event in if let text = event.object as? String, !PrivacyLock.shared.locked { Xclip.perform { _ = try ClipboardManager.shared.addText(text) } } })
        observers.append(NotificationCenter.default.addObserver(forName: .init("CClipTranslateText"), object: nil, queue: .main) { [weak self] _ in self?.show("automation") })
        observers.append(NotificationCenter.default.addObserver(forName: .init("CClipAIInput"), object: nil, queue: .main) { [weak self] _ in self?.show("automation") })
        applyCapturePreferences()
        _ = PasteCoordinator.shared
        _ = AIService.shared
        if !isUITest { clipboard.startMonitoring() }
        DesktopEvents.shared.show = { [weak self] section in self?.show(section) }
        if !isUITest { DesktopEvents.shared.configure() }
        menuBar.onLeftClick = { [weak self] in self?.show("quick") }
        menuBar.menu = { [weak self] in self?.makeMenu() ?? NSMenu() }
        observers.append(NotificationCenter.default.addObserver(forName: .init("CClipShortcutsChanged"), object: nil, queue: .main) { [weak self] _ in self?.registerShortcuts() })
        observers.append(NotificationCenter.default.addObserver(forName: .init("CClipLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.autoOCRTask?.cancel(); PasteCoordinator.shared.cancelPendingPaste(); DesktopEvents.shared.cancelPendingCut(); closeClipPreview(); self?.quickPanel.dismissImmediately(); DesktopEvents.shared.hideSelection(); FloatingClips.shared.closeAll(); Task { @MainActor in PinnedImageController.shared.closeAll() }; LANSyncService.shared.stop()
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in if PrivacyLock.shared.enabled { PrivacyLock.shared.lock() } })
        if !isUITest { registerShortcuts() }
        backupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in ClipboardManager.shared.performManualCleanup(); WorkspaceBackup.shared.automaticBackupIfDue() }
        DispatchQueue.main.async {
            self.mainWindow = NSApp.windows.first(where: { $0.title == "Xclip" })
            self.mainWindow?.identifier = NSUserInterfaceItemIdentifier("main")
            NSApp.setActivationPolicy(SettingsManager.shared.showInDock ? .regular : .accessory)
            // Finish the regular/accessory transition before inserting the status item.
            DispatchQueue.main.async {
                SettingsManager.shared.$showInMenuBar.removeDuplicates().receive(on: DispatchQueue.main)
                    .sink { [weak self] in self?.menuBar.setEnabled($0) }.store(in: &self.cancellables)
            }
            if isUITest {
                self.mainWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) { menuBar.restore() }
    func applicationDidChangeScreenParameters(_ notification: Notification) { menuBar.restore() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let editor = quickPanel.editorWindow { editor.makeKeyAndOrderFront(nil); return true }
        show("history"); return true
    }
    func applicationWillTerminate(_ notification: Notification) { ClipboardManager.shared.stopMonitoring(); ClipboardManager.shared.cleanupImageDragFiles(); LANSyncService.shared.stop(); backupTimer?.invalidate() }
    private func recognizeForSearch(_ item: ClipboardItem) {
        guard WorkflowState.shared.document.autoRecognizeImages == true, item.type == .image,
              let data = item.data ?? item.filePath.flatMap({ try? Data(contentsOf: URL(fileURLWithPath: $0)) }) else { return }
        autoOCRTask?.cancel()
        autoOCRTask = Task { @MainActor in
            do {
                let text = try await CaptureService.shared.recognizeText(in: data)
                guard !Task.isCancelled, !PrivacyLock.shared.locked, !text.isEmpty,
                      var current = ClipboardManager.shared.clipboardItems.first(where: { $0.id == item.id }) else { return }
                current.content += "\n" + text
                ClipboardManager.shared.update(current)
            } catch { if !Task.isCancelled { WorkflowState.shared.status = error.localizedDescription } }
        }
    }
    private func registerShortcuts() {
        GlobalShortcuts.shared.register(actions: [
            "history": { [weak self] in self?.show("history") }, "stack": { [weak self] in self?.show("stack") },
            "replies": { [weak self] in self?.show("replies") }, "shelf": { [weak self] in self?.show("shelf") },
            "quick": { [weak self] in self?.show("quick") }, "capture": { [weak self] in self?.show("capture") },
            "split": { if !PrivacyLock.shared.locked, let text = NSPasteboard.general.string(forType: .string) { WorkflowState.shared.splitLines(text) } }
        ])
    }
    func show(_ section: String) {
        PasteCoordinator.shared.captureTarget()
        if section == "quick" && !PrivacyLock.shared.locked { showQuickPanel(); return }
        if mainWindow == nil { mainWindow = NSApp.windows.first(where: { $0.title == "Xclip" }) }
        mainWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .init("CClipSection"), object: section)
    }
    private func makeMenu() -> NSMenu {
        let menu = NSMenu(); menu.delegate = self
        func add(_ title: String, action: Selector, represented: Any? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.representedObject = represented; menu.addItem(item)
        }
        add(L("打开 Xclip", "Open Xclip"), action: #selector(menuShow), represented: "history")
        if !PrivacyLock.shared.locked {
            menu.addItem(.separator())
            for item in ClipboardManager.shared.clipboardItems.prefix(12) {
                add(String(item.displayContent.prefix(64)).replacingOccurrences(of: "\n", with: " "), action: #selector(menuCopy), represented: item)
            }
            menu.addItem(.separator())
            add(L("撤销删除", "Undo deletion"), action: #selector(menuUndo))
            add(L("设置", "Settings"), action: #selector(menuShow), represented: "settings")
            add(L("锁定", "Lock"), action: #selector(menuLock))
        }
        add(L("退出", "Quit"), action: #selector(menuQuit)); return menu
    }
    @objc private func menuShow(_ sender: NSMenuItem) { show(sender.representedObject as? String ?? "history") }
    @objc private func menuCopy(_ sender: NSMenuItem) { if !PrivacyLock.shared.locked, let item = sender.representedObject as? ClipboardItem { ClipboardManager.shared.copyToClipboard(item: item) } }
    @objc private func menuUndo() { if !PrivacyLock.shared.locked { ClipboardManager.shared.undoDelete() } }
    @objc private func menuLock() { PrivacyLock.shared.lock() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
    private func showQuickPanel() {
        quickPanel.toggle { [weak self] in self?.show("history") }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !PrivacyLock.shared.locked else { show("history"); return }
        for url in urls {
            Xclip.perform {
                switch try ClipRoute.parse(url) {
                case .show: show("history")
                case .search(let query): show("history"); NotificationCenter.default.post(name: .init("CClipSearch"), object: query)
                case .capture: show("capture")
                case .add(let text), .stack(let text):
                    show("history")
                    let alert = NSAlert(); alert.messageText = L("接收外部应用传来的内容？", "Receive content from another app?")
                    alert.informativeText = String(text.prefix(600)); alert.addButton(withTitle: L("接收", "Receive")); alert.addButton(withTitle: L("取消", "Cancel"))
                    if alert.runModal() == .alertFirstButtonReturn {
                        if case .stack = try ClipRoute.parse(url) { WorkflowState.shared.splitLines(text); show("stack") }
                        else { _ = try ClipboardManager.shared.addText(text) }
                    }
                }
            }
        }
    }
}

class FloatingClips {
    static let shared = FloatingClips()
    private var panels: [NSPanel] = []
    private var languageObserver: NSObjectProtocol?
    private init() {
        languageObserver = NotificationCenter.default.addObserver(forName: AppLanguage.didChange, object: AppLanguage.shared, queue: .main) { [weak self] _ in
            self?.panels.forEach { $0.title = L("桌面贴图 / 便签", "Floating clip") }
        }
    }
    func show(_ item: ClipboardItem) {
        guard !PrivacyLock.shared.locked else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 310), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = L("桌面贴图 / 便签", "Floating clip"); panel.level = .floating; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: FloatingClipView(item: item, panel: panel))
        panel.center(); panel.makeKeyAndOrderFront(nil); panels.append(panel)
    }
    func closeAll() { panels.forEach { $0.close() }; panels.removeAll() }
}
private struct FloatingClipView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    let item: ClipboardItem
    let panel: NSPanel
    @State private var opacity = 1.0
    var body: some View { VStack { ClipPreview(item: item); HStack { Slider(value: $opacity, in: 0.25...1).accessibilityLabel(L("透明度", "Opacity")).onChange(of: opacity) { _, value in panel.alphaValue = value }; Button(L("复制", "Copy")) { ClipboardManager.shared.copyToClipboard(item: item) }; Button(L("关闭", "Close")) { panel.close() }.keyboardShortcut(.cancelAction) } }.padding(12) }
}

@main
struct OneClipApp: App {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Window("Xclip", id: "main") { ContentView().environment(\.locale, appLanguage.locale) }
            .defaultSize(width: 1040, height: 740)
            .commands {
                LocalizedEditingCommands()
                CommandGroup(replacing: .newItem) {
                    Button(L("打开资料库", "Open library")) { appDelegate.show("history") }.keyboardShortcut("n")
                    Button(L("快速粘贴", "Quick paste")) { appDelegate.show("quick") }
                }
                CommandGroup(replacing: .appSettings) { Button(L("设置…", "Settings…")) { appDelegate.show("settings") }.keyboardShortcut(",") }
            }
    }
}
