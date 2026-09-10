import AppKit
import Combine

@main
@MainActor
enum LocalizedEditingCommandsTests {
    private static var checks = 0
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw NSError(domain: "EditingCommandsTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1
        print("PASS Editing \(checks): \(message)")
    }

    static func main() throws {
        var target: AnyObject?
        var dispatched: [String] = []
        let state = EditingCommandState(observesApplication: false, resolveTarget: { _, _ in target }, sendAction: { selector, sender in
            precondition(sender.action == selector)
            dispatched.append(NSStringFromSelector(selector))
            return true
        })
        try expect(state.enabled.isEmpty, "Actions without a responder are disabled")
        try expect(!state.perform(.copy) && dispatched.isEmpty, "A missing responder never dispatches a command")

        let specific = SpecificValidator()
        target = specific
        specific.allowed = [.copy, .selectAll]
        state.refresh()
        try expect(state.enabled == [.copy, .selectAll], "Menu validation governs each command independently")
        try expect(specific.genericValidations == 0 && specific.menuValidations == EditingCommandAction.allCases.count, "Specific menu validation takes precedence over generic UI validation")
        try expect(state.perform(.copy) && dispatched == ["copy:"], "An enabled command dispatches its standard responder selector")
        specific.allowed.remove(.copy)
        try expect(!state.perform(.copy) && dispatched == ["copy:"] && !state.isEnabled(.copy), "Dispatch revalidates a previously enabled command against current selection state")

        let generic = GenericValidator()
        target = generic
        generic.allowed = false
        state.refresh()
        try expect(!state.isEnabled(.copy), "Generic UI validation can disable a supported action")
        generic.allowed = true
        state.refresh()
        try expect(state.enabled == [.copy] && generic.validations > 0, "Generic UI validation enables only actions actually supported by the responder")
        target = NSObject()
        state.refresh()
        try expect(state.enabled.isEmpty, "An object without the standard action selector cannot enable commands")
        target = PlainResponder()
        state.refresh()
        try expect(state.enabled == [.copy], "A responding object without a validation protocol follows AppKit's enabled default")

        target = specific
        specific.allowed = Set(EditingCommandAction.allCases)
        state.refresh()
        for action in EditingCommandAction.allCases {
            try expect(state.perform(action) && dispatched.last == action.rawValue + ":", "\(action.rawValue) preserves its standard responder-chain action")
        }
        try expect(specific.genericValidations == 0, "Generic validation never overrides the menu-specific result")

        var current: AnyObject? = generic
        let observed = EditingCommandState(resolveTarget: { _, _ in current }, sendAction: { _, _ in false })
        var updates = 0
        let subscription = observed.$enabled.dropFirst().sink { _ in updates += 1 }
        observed.refresh(); observed.refresh()
        try expect(updates == 0, "Unchanged validation avoids redundant observable updates")
        generic.allowed = false
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        try expect(!observed.isEnabled(.copy) && updates == 1, "Opening a menu refreshes enablement from the responder")
        generic.allowed = true
        NotificationCenter.default.post(name: NSApplication.didUpdateNotification, object: nil)
        try expect(observed.isEnabled(.copy) && updates == 2, "Application event updates refresh focus and selection availability")
        try expect(!observed.perform(.copy), "The caller sees a failed responder-chain dispatch")
        current = nil
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: nil)
        try expect(observed.enabled.isEmpty, "Losing the key responder disables editing commands")
        subscription.cancel()
        try expect(NSApp == nil, "The regression suite never creates NSApplication, a window, or accesses a clipboard")
        print("LocalizedEditingCommandsTests: \(checks) checks passed; injected responders only.")
    }
}

private final class SpecificValidator: NSObject, NSMenuItemValidation, NSUserInterfaceValidations {
    var allowed: Set<EditingCommandAction> = []
    var menuValidations = 0
    var genericValidations = 0
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuValidations += 1
        return allowed.contains { $0.selector == menuItem.action }
    }
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool { genericValidations += 1; return false }
    @objc func undo(_ sender: Any?) { }
    @objc func redo(_ sender: Any?) { }
    @objc func cut(_ sender: Any?) { }
    @objc func copy(_ sender: Any?) { }
    @objc func paste(_ sender: Any?) { }
    @objc func pasteAsPlainText(_ sender: Any?) { }
    @objc func delete(_ sender: Any?) { }
    @objc func selectAll(_ sender: Any?) { }
}

private final class GenericValidator: NSObject, NSUserInterfaceValidations {
    var allowed = false
    var validations = 0
    @objc func copy(_ sender: Any?) { }
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool { validations += 1; return allowed }
}

private final class PlainResponder: NSObject {
    @objc func copy(_ sender: Any?) { }
}
