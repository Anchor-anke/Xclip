import AppKit

/// A separate, windowless AppKit process. The synthetic suite remains NSApplication-free.
/// Tests nested event-tracking run-loop delivery; it never displays or clicks a menu.
@main
@MainActor
enum NativeLanguageEventTests {
    private static var checks = 0

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        // Running inside an existing main-queue callback reproduces menu tracking's
        // nested loop: another main-queue callback cannot complete until it returns.
        DispatchQueue.main.async {
            do {
                try runSuite(app)
                print("NativeLanguageEventTests: \(checks) checks passed; eventTracking mode only; no windows, menu display, actions or clipboard access.")
                fflush(stdout)
                exit(0)
            } catch {
                fputs("NativeLanguageEventTests FAIL: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    private static func runSuite(_ app: NSApplication) throws {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: AppLanguage.preferenceKey)
        let originalCode = AppLanguage.shared.code
        let previousMenu = app.mainMenu
        defer {
            app.mainMenu = previousMenu
            AppLanguage.shared.select(originalCode)
            if let original { defaults.set(original, forKey: AppLanguage.preferenceKey) }
            else { defaults.removeObject(forKey: AppLanguage.preferenceKey) }
        }
        let menu = NSMenu(title: "Synthetic tracking main menu")
        menu.autoenablesItems = false
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        edit.representedObject = NSObject()
        let editMenu = NSMenu(title: "Edit")
        editMenu.autoenablesItems = false
        edit.submenu = editMenu
        menu.addItem(edit)
        let copy = NSMenuItem(title: "Copy", action: NSSelectorFromString("copy:"), keyEquivalent: "c")
        editMenu.addItem(copy)
        app.mainMenu = menu

        var ordinaryDispatchCompleted = false
        DispatchQueue.main.async { ordinaryDispatchCompleted = true }
        AppLanguage.shared.select("zh")
        let controller = NativeLanguageController()
        controller.start()
        controller.start()
        try pumpTracking(until: { copy.title == "复制" && edit.title == "编辑" }, message: "Initial refresh completes while the eventTracking loop is active")
        try expect(!ordinaryDispatchCompleted, "The ordinary main-queue callback has not run during nested event tracking")

        // The tracking event itself localizes synchronously; later AppKit rebuilds
        // must also be repaired before returning to the ordinary application loop.
        copy.title = "Copy"
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: editMenu)
        try expect(copy.title == "复制", "The beginning-of-tracking event translates its current menu immediately")
        copy.title = "Copy"
        NotificationCenter.default.post(name: NSMenu.didChangeItemNotification, object: editMenu)
        try pumpTracking(until: { copy.title == "复制" }, message: "An AppKit-style title rewrite after tracking begins is repaired before tracking ends")

        let closeAll = NSMenuItem(title: "Close All", action: NSSelectorFromString("closeAll:"), keyEquivalent: "")
        editMenu.addItem(closeAll)
        NotificationCenter.default.post(name: NSMenu.didAddItemNotification, object: editMenu)
        try pumpTracking(until: { closeAll.title == "全部关闭" }, message: "A menu item added during tracking is translated in eventTracking mode")

        AppLanguage.shared.select("en")
        try pumpTracking(until: { copy.title == "Copy" && closeAll.title == "Close All" && edit.title == "Edit" }, message: "A language change refreshes existing tracked menu items before tracking ends")
        copy.title = "复制"
        NotificationCenter.default.post(name: NSMenu.didChangeItemNotification, object: editMenu)
        try pumpTracking(until: { copy.title == "Copy" }, message: "Repeated tracking-time rewrites also recover when English is selected")
        let attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.red, .kern: 0.75]
        copy.attributedTitle = NSAttributedString(string: "拷贝", attributes: attributes)
        copy.title = "Copy"
        NotificationCenter.default.post(name: NSMenu.didChangeItemNotification, object: editMenu)
        try pumpTracking(until: { copy.title == "Copy" && copy.attributedTitle?.string == "Copy" }, message: "An attributed-title rewrite is repaired during tracking even when the plain title is correct")
        try expect(copy.attributedTitle.map { ($0.attributes(at: 0, effectiveRange: nil) as NSDictionary).isEqual(to: attributes) } == true,
                   "Tracking-time attributed-title refresh preserves its style")
        // AppKit can track a temporary menu that is not reachable from mainMenu.
        let detached = NSMenu(title: "Synthetic tracked copy")
        detached.autoenablesItems = false
        let detachedCopy = NSMenuItem(title: "复制", action: NSSelectorFromString("copy:"), keyEquivalent: "c")
        detached.addItem(detachedCopy)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: detached)
        try expect(detachedCopy.title == "Copy", "A detached tracked menu is localized when tracking begins")
        detachedCopy.title = "复制"
        NotificationCenter.default.post(name: NSMenu.didChangeItemNotification, object: detached)
        try pumpTracking(until: { detachedCopy.title == "Copy" }, message: "A title rewritten in a detached tracked copy refreshes before tracking ends")
        try expect(!menu.items.contains(where: { $0.submenu === detached }), "The tracked copy regression remains independent of the main menu tree")
        try expect(!ordinaryDispatchCompleted, "All translated assertions complete before the queued callback and before leaving tracking")
        try expect(app.windows.isEmpty && app.keyWindow == nil, "The event regression process never creates a window")
        try expect(copy.action.map(NSStringFromSelector) == "copy:" && closeAll.action.map(NSStringFromSelector) == "closeAll:" && copy.keyEquivalent == "c", "Tracking-time refresh preserves actions and shortcuts")
    }

    private static func pumpTracking(until condition: () -> Bool, message: String) throws {
        var witnessedTrackingMode = false
        RunLoop.main.perform(inModes: [.eventTracking]) {
            witnessedTrackingMode = RunLoop.current.currentMode == .eventTracking
        }
        let deadline = Date().addingTimeInterval(1)
        repeat {
            // Never run default mode here: a post-close refresh must fail this test.
            RunLoop.main.run(mode: .eventTracking, before: min(deadline, Date().addingTimeInterval(0.02)))
        } while (!condition() || !witnessedTrackingMode) && Date() < deadline
        try expect(witnessedTrackingMode, "The assertion was exercised inside eventTracking mode")
        try expect(condition(), message)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw NSError(domain: "NativeLanguageEventTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        checks += 1
        print("PASS Event \(checks): \(message)")
        fflush(stdout)
    }
}
