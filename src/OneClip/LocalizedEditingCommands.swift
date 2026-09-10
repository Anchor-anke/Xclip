import AppKit
import SwiftUI

/// The titles originate in SwiftUI, so AppKit cannot restore system-language defaults.
struct LocalizedEditingCommands: Commands {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject private var state = EditingCommandState.shared

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            command(.undo).keyboardShortcut("z", modifiers: .command)
            command(.redo).keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .pasteboard) {
            command(.cut).keyboardShortcut("x", modifiers: .command)
            command(.copy).keyboardShortcut("c", modifiers: .command)
            command(.paste).keyboardShortcut("v", modifiers: .command)
            command(.pasteAsPlainText).keyboardShortcut("v", modifiers: [.command, .option, .shift])
        }
        CommandGroup(replacing: .textEditing) {
            command(.delete).keyboardShortcut(.delete, modifiers: [])
            command(.selectAll).keyboardShortcut("a", modifiers: .command)
        }
    }

    private func command(_ action: EditingCommandAction) -> some View {
        Button(appLanguage.text(action.chinese, action.english)) { state.perform(action) }
            .disabled(!state.isEnabled(action))
    }
}

enum EditingCommandAction: String, CaseIterable {
    case undo, redo, cut, copy, paste, pasteAsPlainText, delete, selectAll
    var selector: Selector { NSSelectorFromString(rawValue + ":") }
    var chinese: String {
        switch self {
        case .undo: return "撤销"
        case .redo: return "重做"
        case .cut: return "剪切"
        case .copy: return "复制"
        case .paste: return "粘贴"
        case .pasteAsPlainText: return "粘贴并匹配样式"
        case .delete: return "删除"
        case .selectAll: return "全选"
        }
    }
    var english: String {
        switch self {
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .cut: return "Cut"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .pasteAsPlainText: return "Paste and Match Style"
        case .delete: return "Delete"
        case .selectAll: return "Select All"
        }
    }
    var menuItem: NSMenuItem {
        NSMenuItem(title: AppLanguage.text(chinese, english), action: selector, keyEquivalent: "")
    }
}

/// Mirrors AppKit menu validation, including the more specific NSMenuItemValidation
/// hook before generic UI validation. Responder lookup remains live at dispatch time.
@MainActor
final class EditingCommandState: ObservableObject {
    static let shared = EditingCommandState()
    @Published private(set) var enabled: Set<EditingCommandAction> = []
    private let resolveTarget: @MainActor (Selector, NSMenuItem) -> AnyObject?
    private let sendAction: @MainActor (Selector, NSMenuItem) -> Bool
    private var observers: [NSObjectProtocol] = []
    private var refreshing = false

    init(observesApplication: Bool = true,
         resolveTarget: @escaping @MainActor (Selector, NSMenuItem) -> AnyObject? = { selector, sender in NSApp?.target(forAction: selector, to: nil, from: sender) as AnyObject? },
         sendAction: @escaping @MainActor (Selector, NSMenuItem) -> Bool = { selector, sender in NSApp?.sendAction(selector, to: nil, from: sender) ?? false }) {
        self.resolveTarget = resolveTarget
        self.sendAction = sendAction
        if observesApplication {
            let notifications: [Notification.Name] = [
                NSMenu.didBeginTrackingNotification, NSApplication.didUpdateNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                NSText.didChangeNotification, NSTextView.didChangeSelectionNotification,
                Notification.Name.NSUndoManagerDidUndoChange, Notification.Name.NSUndoManagerDidRedoChange,
                Notification.Name.NSUndoManagerDidCloseUndoGroup
            ]
            for name in notifications {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
            }
        }
        refresh()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func isEnabled(_ action: EditingCommandAction) -> Bool { enabled.contains(action) }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let updated = Set(EditingCommandAction.allCases.filter { validate($0, sender: $0.menuItem) })
        if updated != enabled { enabled = updated }
    }

    @discardableResult
    func perform(_ action: EditingCommandAction) -> Bool {
        let sender = action.menuItem
        guard validate(action, sender: sender) else { refresh(); return false }
        let delivered = sendAction(action.selector, sender)
        refresh()
        return delivered
    }

    private func validate(_ action: EditingCommandAction, sender: NSMenuItem) -> Bool {
        guard let target = resolveTarget(action.selector, sender) as? NSObjectProtocol,
              target.responds(to: action.selector) else { return false }
        if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(sender) }
        if let validator = target as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(sender) }
        return true
    }
}
