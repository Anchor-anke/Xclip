import AppKit
import SwiftUI
import Combine
import Carbon

class PasteCoordinator: ObservableObject {
    static let shared = PasteCoordinator()
    var targetApplication: NSRunningApplication?
    private var observer: NSObjectProtocol?
    private var generation: UInt64 = 0
    private init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] event in
            if let app = event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { self?.targetApplication = app }
        }
        captureTarget()
    }
    func captureTarget() {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { targetApplication = app }
    }
    func cancelPendingPaste() { generation &+= 1 }
    func paste(_ item: ClipboardItem, plainText: Bool = false, completion: (() -> Void)? = nil) {
        guard !PrivacyLock.shared.locked else { return }
        guard AXIsProcessTrusted() else {
            WorkflowState.shared.status = L("自动粘贴需要辅助功能权限；你也可以使用复制按钮。", "Automatic paste needs Accessibility permission; Copy remains available.")
            return
        }
        guard let target = targetApplication, !target.isTerminated else { WorkflowState.shared.status = L("先切换到要粘贴的应用，再用快捷键打开面板。", "Focus the destination app, then open this panel with its shortcut."); return }
        do { try ClipboardManager.shared.writeToClipboard(item, plainText: plainText) }
        catch { WorkflowState.shared.status = error.localizedDescription; return }
        for window in NSApp.windows where window.level < .mainMenu && !MenuBarController.shared.owns(window) { window.orderOut(nil) }
        target.activate(options: [])
        generation &+= 1
        let pendingGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard !PrivacyLock.shared.locked, self.generation == pendingGeneration, NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { WorkflowState.shared.status = L("目标应用没有获得焦点，内容已复制。", "The destination did not gain focus. Content was copied."); return }
            Self.sendKey(9, flags: .maskCommand)
            WorkflowState.shared.pastedIDs.insert(item.id)
            if WorkflowState.shared.document.moveAfterPaste {
                var value = ClipboardItem(id: item.id, content: item.content, type: item.type, timestamp: Date(), data: item.data, filePath: item.filePath, isFavorite: item.isFavorite)
                value.isPinned = item.isPinned; value.tags = item.tags; value.representations = item.representations; value.fileURLs = item.fileURLs; value.sourceApp = item.sourceApp; value.sourceAppName = item.sourceAppName
                ClipboardManager.shared.update(value)
            }
            if WorkflowState.shared.document.returnAfterPaste {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard !PrivacyLock.shared.locked, self.generation == pendingGeneration, NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { return }
                    Self.sendKey(36, flags: [])
                }
            }
            completion?()
        }
    }
    static func sendKey(_ key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags; event?.setIntegerValueField(.eventSourceUserData, value: 0x43434C49)
            event?.post(tap: .cghidEventTap)
        }
    }
}

/// One Carbon handler dispatches all app and template shortcuts and reports registration conflicts.
class GlobalShortcuts: ObservableObject {
    static let shared = GlobalShortcuts()
    static let optionalActions = ["captureOCR", "captureLong", "captureRecord", "pinClipboard", "restorePin", "togglePins", "resetPinPassthrough"]
    static var allActions: [String] { (Array(defaults.keys) + optionalActions).sorted() }
    @Published var errors: [String] = []
    private var registrationFailures: [(name: String, label: String, result: OSStatus, isAppAction: Bool)] = []
    private var languageObserver: NSObjectProtocol?
    private var references: [EventHotKeyRef] = []
    private var callbacks: [UInt32: () -> Void] = [:]
    private var actions: [String: () -> Void] = [:]
    private var recordingShortcut = false
    private var registrationActivated = false
    private var handler: EventHandlerRef?
    static let defaults: [String: ShortcutSpec] = [
        "history": .init(keyCode: 9, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, label: "⌘⇧V"),
        "stack": .init(keyCode: 8, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, label: "⌘⇧C"),
        "replies": .init(keyCode: 15, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, label: "⌘⇧R"),
        "shelf": .init(keyCode: 2, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, label: "⌘⇧D"),
        "quick": .init(keyCode: 41, modifiers: NSEvent.ModifierFlags.command.rawValue, label: "⌘;"),
        "capture": .init(keyCode: 0, modifiers: NSEvent.ModifierFlags.control.rawValue, label: "⌃A"),
        "split": .init(keyCode: 1, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, label: "⌘⇧S")
    ]

    private init() {
        languageObserver = NotificationCenter.default.addObserver(forName: AppLanguage.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.refreshErrorDescriptions()
        }
    }

    static func title(for action: String) -> String {
        switch action {
        case "history": return L("剪贴板历史", "Clipboard history")
        case "stack": return L("栈粘贴板", "Paste stack")
        case "replies": return L("快捷回复", "Quick replies")
        case "shelf": return L("拖拽容器", "Drop shelf")
        case "quick": return L("快速粘贴", "Quick paste")
        case "capture": return L("截屏 / 结束录屏", "Screenshot / stop recording")
        case "captureOCR": return L("截图识别文字", "Capture and recognize text")
        case "captureLong": return L("长截图", "Scrolling capture")
        case "captureRecord": return L("录屏 / 动图", "Record / GIF")
        case "pinClipboard": return L("剪贴板贴图", "Pin clipboard")
        case "restorePin": return L("恢复上次贴图", "Restore last pin")
        case "togglePins": return L("隐藏 / 显示全部贴图", "Hide / show all pins")
        case "resetPinPassthrough": return L("恢复贴图鼠标交互", "Restore pin mouse interaction")
        case "split": return L("分词入栈", "Split text into stack")
        default: return action
        }
    }

    private func refreshErrorDescriptions() {
        errors = registrationFailures.map { failure in
            let name = failure.isAppAction ? Self.title(for: failure.name) : failure.name
            return "\(name) · \(failure.label): \(L("快捷键冲突或无法注册", "Shortcut conflict or registration failure")) (\(failure.result))"
        }
    }

    static func effectiveShortcut(for action: String, in document: WorkflowDocument) -> ShortcutSpec? {
        guard !document.disabledShortcuts.contains(action) else { return nil }
        return document.shortcuts[action] ?? defaults[action]
    }

    static func conflictDescription(for spec: ShortcutSpec, excluding action: String, in document: WorkflowDocument) -> String? {
        let supported: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        func matches(_ other: ShortcutSpec) -> Bool {
            spec.keyCode == other.keyCode && spec.flags.intersection(supported) == other.flags.intersection(supported)
        }
        for name in Set(allActions + Array(document.shortcuts.keys)).sorted() where name != action {
            if let other = effectiveShortcut(for: name, in: document), matches(other) {
                return L("此快捷键已用于“\(title(for: name))”，请使用其他组合。", "This shortcut is used by “\(title(for: name))”. Choose another combination.")
            }
        }
        for reply in document.replies {
            if let other = reply.hotkey, matches(other) {
                return L("此快捷键已用于快捷回复“\(reply.title)”，请使用其他组合。", "This shortcut is used by the quick reply “\(reply.title)”. Choose another combination.")
            }
        }
        return nil
    }

    // Carbon consumes registered shortcuts before the recorder's local event monitor.
    // Release them while recording so the current shortcut can be recorded safely.
    func pauseForShortcutRecording() {
        recordingShortcut = true
        references.forEach { UnregisterEventHotKey($0) }; references.removeAll(); callbacks.removeAll()
    }

    func resumeAfterShortcutRecording() {
        guard recordingShortcut else { return }
        recordingShortcut = false
        // Preview/test processes that never registered must stay inactive, including replies.
        guard registrationActivated else { return }
        register(actions: actions)
    }

    func register(actions: [String: () -> Void]) {
        registrationActivated = true
        self.actions = actions
        references.forEach { UnregisterEventHotKey($0) }; references.removeAll(); callbacks.removeAll(); errors.removeAll()
        registrationFailures.removeAll()
        guard !recordingShortcut else { return }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                GlobalShortcuts.shared.callbacks[id.id]?()
                return noErr
            }, 1, &type, nil, &handler)
        }
        var index: UInt32 = 1
        func add(_ spec: ShortcutSpec, name: String, isAppAction: Bool = false, action: @escaping () -> Void) {
            let flags = spec.flags
            var modifiers: UInt32 = 0
            if flags.contains(.command) { modifiers |= UInt32(cmdKey) }; if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            if flags.contains(.option) { modifiers |= UInt32(optionKey) }; if flags.contains(.control) { modifiers |= UInt32(controlKey) }
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(spec.keyCode), modifiers, EventHotKeyID(signature: 0x43434C50, id: index), GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref { references.append(ref); callbacks[index] = action }
            else { registrationFailures.append((name, spec.label, result, isAppAction)) }
            index += 1
        }
        for name in actions.keys.sorted() {
            if let spec = Self.effectiveShortcut(for: name, in: WorkflowState.shared.document), let action = actions[name] { add(spec, name: name, isAppAction: true, action: action) }
        }
        for reply in WorkflowState.shared.document.replies {
            let replyID = reply.id
            if let spec = reply.hotkey { add(spec, name: reply.title) {
                guard let current = WorkflowState.shared.document.replies.first(where: { $0.id == replyID }), current.hotkey == spec else { return }
                PasteCoordinator.shared.captureTarget(); PasteCoordinator.shared.paste(current.item)
            } }
        }
        refreshErrorDescriptions()
    }

    deinit { if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) } }
}

class DesktopEvents {
    static let shared = DesktopEvents()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var monitor: Any?
    private var edgeTimer: Timer?
    private var lastEdge = Date.distantPast
    private var cutChangeCount: Int?
    private var cutPending = false
    private var cutGeneration: UInt64 = 0
    var show: ((String) -> Void)?
    var selectionPanel: NSPanel?
    var selectedText = ""

    func cancelPendingCut() {
        cutGeneration &+= 1; cutPending = false; cutChangeCount = nil
    }

    private func canUseFinder(_ pid: pid_t, generation: UInt64) -> Bool {
        guard !PrivacyLock.shared.locked, WorkflowState.shared.document.finderCut,
              cutGeneration == generation, let app = NSWorkspace.shared.frontmostApplication else { return false }
        return app.processIdentifier == pid && app.bundleIdentifier == "com.apple.finder"
    }

    func configure() {
        if tap == nil && AXIsProcessTrusted() {
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: 1 << CGEventType.keyDown.rawValue, callback: { _, type, event, _ in
                let service = DesktopEvents.shared
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = service.tap { CGEvent.tapEnable(tap: tap, enable: true) }; return Unmanaged.passUnretained(event)
                }
                guard event.getIntegerValueField(.eventSourceUserData) != 0x43434C49, !PrivacyLock.shared.locked else { return Unmanaged.passUnretained(event) }
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags.intersection([.maskCommand, .maskControl, .maskShift, .maskAlternate])
                let state = WorkflowState.shared
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return Unmanaged.passUnretained(event) }
                if flags == .maskCommand && code == 9 && state.stackPasting && !state.document.stack.isEmpty {
                    let item = state.document.stack[0]
                    DispatchQueue.main.async { PasteCoordinator.shared.captureTarget(); PasteCoordinator.shared.paste(item) { if WorkflowState.shared.document.stack.first?.id == item.id { WorkflowState.shared.document.stack.removeFirst() } } }
                    return nil
                }
                if state.document.finderCut && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" && flags == .maskCommand {
                    if code == 7 {
                        guard let finderPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return Unmanaged.passUnretained(event) }
                        service.cancelPendingCut()
                        let generation = service.cutGeneration
                        service.cutPending = true
                        let beforeCopy = NSPasteboard.general.changeCount
                        DispatchQueue.main.async {
                            guard service.canUseFinder(finderPID, generation: generation) else { if service.cutGeneration == generation { service.cancelPendingCut() }; return }
                            PasteCoordinator.sendKey(8, flags: .maskCommand)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                guard service.canUseFinder(finderPID, generation: generation) else { if service.cutGeneration == generation { service.cancelPendingCut() }; return }
                                let board = NSPasteboard.general
                                let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
                                if board.changeCount != beforeCopy && !files.isEmpty { service.cutChangeCount = board.changeCount }
                                service.cutPending = false
                            }
                        }
                        return nil
                    }
                    if code == 9 && !service.cutPending, let change = service.cutChangeCount, change == NSPasteboard.general.changeCount {
                        guard let finderPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return Unmanaged.passUnretained(event) }
                        let generation = service.cutGeneration
                        service.cutChangeCount = nil
                        DispatchQueue.main.async {
                            guard service.canUseFinder(finderPID, generation: generation), NSPasteboard.general.changeCount == change else { return }
                            PasteCoordinator.sendKey(9, flags: [.maskCommand, .maskAlternate])
                        }
                        return nil
                    }
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: nil)
            if let tap { source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0); CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes); CGEvent.tapEnable(tap: tap, enable: true) }
        }
        if monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
                guard WorkflowState.shared.document.selectionMenu else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.inspectSelection() }
            }
        }
        if edgeTimer == nil {
            edgeTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.inspectEdge() }
        }
    }
    private func inspectEdge() {
        guard !PrivacyLock.shared.locked, Date().timeIntervalSince(lastEdge) > 1.5 else { return }
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }
        if WorkflowState.shared.document.topShelf && point.y > screen.frame.maxY - 4 && NSEvent.pressedMouseButtons == 1 {
            lastEdge = Date(); show?("shelf")
        } else if WorkflowState.shared.document.edgeReveal && point.x > screen.frame.maxX - 2 && NSEvent.pressedMouseButtons == 0 {
            lastEdge = Date(); show?("quick")
        }
    }
    private func inspectSelection() {
        guard !PrivacyLock.shared.locked, AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              !ClipboardManager.shared.excludedApplications.contains(app.bundleIdentifier ?? "") else { return }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        var subrole: CFTypeRef?; AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard subrole as? String != kAXSecureTextFieldSubrole else { return }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success, let text = value as? String, !text.isEmpty, text.utf8.count <= 100_000 else { selectionPanel?.orderOut(nil); return }
        selectedText = text; PasteCoordinator.shared.captureTarget()
        let panel = selectionPanel ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 42), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isReleasedWhenClosed = false; panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: SelectionActions(text: text))
        panel.setFrameOrigin(NSPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y - 52)); panel.orderFrontRegardless(); selectionPanel = panel
    }
    func hideSelection() { selectionPanel?.orderOut(nil) }
}
private struct SelectionActions: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    let text: String
    var body: some View {
        HStack {
            Button(L("复制", "Copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); DesktopEvents.shared.hideSelection() }
            Button(L("翻译 / AI", "Translate / AI")) { NotificationCenter.default.post(name: .init("CClipAIInput"), object: text); DesktopEvents.shared.show?("automation"); DesktopEvents.shared.hideSelection() }
            Button(L("入栈", "Stack")) { WorkflowState.shared.splitLines(text); DesktopEvents.shared.hideSelection() }
            Button { DesktopEvents.shared.hideSelection() } label: { Image(systemName: "xmark") }.help(L("关闭", "Close"))
        }.padding(8).background(.regularMaterial)
    }
}
