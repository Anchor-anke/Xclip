import AppKit

/// A short, isolated AppKit regression probe. It only inspects windows owned by
/// this process and does not initialize the application, clipboard, or monitors.
/// Compile with MenuBarController.swift and StoragePaths.swift; run with a fresh
/// CCLIP_DATA_DIR or a CClipTestDataDirectory entry in the test bundle's plist.
/// The transient test window and status item close automatically.
@main
struct MenuBarTests {
    static func main() {
        let environmentDirectory = ProcessInfo.processInfo.environment["CCLIP_DATA_DIR"]
        let bundleDirectory = Bundle.main.object(forInfoDictionaryKey: "CClipTestDataDirectory") as? String
        guard environmentDirectory?.isEmpty == false || bundleDirectory?.isEmpty == false else {
            fputs("MenuBarTests requires an isolated CCLIP_DATA_DIR or CClipTestDataDirectory.\n", stderr)
            exit(2)
        }
        // A stalled test must not leave a test app or status item running.
        DispatchQueue.global().asyncAfter(deadline: .now() + 40) {
            fputs("MenuBarTests timed out after 40 seconds.\n", stderr)
            exit(124)
        }
        let application = NSApplication.shared
        let delegate = MenuBarProbe()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}

private final class MenuBarProbe: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var label: NSTextField!
    private var legacyItem: NSStatusItem?
    private let controller = MenuBarController.shared
    private var stableItem: NSStatusItem?
    private var samples: [[String: Any]] = []
    private var failures: [String] = []
    private var checks = 0
    private var baselineStatusWindowCount = 0
    private var steps: [(String, () -> Void)] = []
    private var stepIndex = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 420, height: 110),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Xclip Menu Bar Probe"
        window.isReleasedWhenClosed = false
        label = NSTextField(wrappingLabelWithString: "Isolated AppKit status-item test.\nThis window closes automatically.")
        label.frame = NSRect(x: 18, y: 20, width: 384, height: 72)
        window.contentView?.addSubview(label)
        window.orderFront(nil)
        createLegacyItem()
        steps = [
            ("legacy.initial.regular", {}),
            ("legacy.policy.accessory", { NSApp.setActivationPolicy(.accessory) }),
            ("legacy.policy.regular", { NSApp.setActivationPolicy(.regular) }),
            ("legacy.hide.allExceptStatusBar", {
                for candidate in NSApp.windows where candidate.level != .statusBar { candidate.orderOut(nil) }
            }),
            ("legacy.setItemVisible", { self.legacyItem?.isVisible = true }),
            ("legacy.removeAndRecreate", {
                if let item = self.legacyItem { NSStatusBar.system.removeStatusItem(item) }
                self.legacyItem = nil
                self.createLegacyItem()
            }),
            ("controller.enable", {
                if let item = self.legacyItem { NSStatusBar.system.removeStatusItem(item) }
                self.legacyItem = nil
                self.window.orderFront(nil)
                self.check(self.controller.statusItem == nil, "Controller starts without an item")
                self.controller.setEnabled(true)
                self.stableItem = self.controller.statusItem
                self.check(self.stableItem != nil, "Enable creates an item")
            }),
            ("controller.restoreRepeated", {
                for _ in 0..<5 { self.controller.restore() }
                self.check(self.controller.statusItem === self.stableItem, "Repeated restore retains exactly the same item")
                self.check(self.controller.statusItem?.button?.image != nil, "Controller has an image")
                self.check(self.controller.statusItem?.isVisible == true, "Controller requests item visibility")
            }),
            ("controller.policy.accessory", {
                NSApp.setActivationPolicy(.accessory)
                self.controller.restore()
            }),
            ("controller.policy.regular", {
                NSApp.setActivationPolicy(.regular)
                self.controller.restore()
            }),
            ("controller.hide.statusWindow", { self.controller.statusItem?.button?.window?.orderOut(nil) }),
            ("controller.restore.afterWindowHidden", { self.controller.restore() }),
            ("controller.disable", {
                self.controller.setEnabled(false)
                self.check(self.controller.statusItem == nil, "Disable releases owned item")
                self.check(!self.controller.enabled, "Disable clears enabled state")
            }),
            ("controller.restoreWhileDisabled", {
                self.controller.restore()
                self.check(self.controller.statusItem == nil, "Restore does not recreate a disabled item")
            }),
            ("controller.reenable", {
                self.controller.setEnabled(true)
                self.check(self.controller.statusItem != nil, "Re-enable creates an item")
                self.check(self.controller.statusItem !== self.stableItem, "Re-enable uses a fresh item")
                self.stableItem = self.controller.statusItem
            }),
            ("controller.hide.productionFilter", {
                for candidate in NSApp.windows where candidate.level < .mainMenu && !self.controller.owns(candidate) {
                    candidate.orderOut(nil)
                }
                self.check(self.controller.statusItem === self.stableItem, "Window dismissal preserves owned item")
            }),
            ("controller.disable.final", { self.controller.setEnabled(false) })
        ]
        runNextStep()
    }

    private func createLegacyItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Xclip isolated probe")
        item.button?.toolTip = "Xclip isolated menu bar test"
        legacyItem = item
    }

    private func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { failures.append(message) }
    }

    private func runNextStep() {
        guard stepIndex < steps.count else { finish(); return }
        let (name, action) = steps[stepIndex]
        stepIndex += 1
        label.stringValue = "Isolated AppKit status-item test\n\(name)\nThis window closes automatically."
        action()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            self.record(name)
            self.runNextStep()
        }
    }

    private func describe(_ window: NSWindow) -> [String: Any] {
        ["class": String(describing: type(of: window)), "windowNumber": window.windowNumber,
         "level": window.level.rawValue, "visible": window.isVisible, "miniaturized": window.isMiniaturized,
         "frame": NSStringFromRect(window.frame), "alpha": window.alphaValue,
         "occlusionVisible": window.occlusionState.contains(.visible),
         "intersectsScreen": NSScreen.screens.contains { $0.frame.intersects(window.frame) }]
    }

    private func record(_ stage: String) {
        let item = legacyItem ?? controller.statusItem
        let visibleStatusWindows = NSApp.windows.filter { $0.level == .statusBar && $0.isVisible }
        if stage == "legacy.initial.regular" { baselineStatusWindowCount = visibleStatusWindows.count }
        if ["controller.enable", "controller.restoreRepeated", "controller.policy.accessory", "controller.policy.regular",
            "controller.restore.afterWindowHidden", "controller.reenable", "controller.hide.productionFilter"].contains(stage) {
            check(item?.button?.window?.isVisible == true, "\(stage): own status window is visible")
            check(item?.button?.window.map { candidate in NSScreen.screens.contains { $0.frame.intersects(candidate.frame) } } == true,
                  "\(stage): own status window intersects a screen")
            check(visibleStatusWindows.count <= baselineStatusWindowCount, "\(stage): no extra visible status windows")
        }
        if stage == "controller.hide.statusWindow" {
            check(item?.button?.window?.isVisible == false, "The probe actually hides its status window")
        }
        if stage == "controller.restore.afterWindowHidden" { stableItem = controller.statusItem }
        if ["controller.disable", "controller.restoreWhileDisabled", "controller.disable.final"].contains(stage) {
            check(visibleStatusWindows.isEmpty, "\(stage): no status windows remain visible")
        }
        var sample: [String: Any] = [
            "stage": stage, "activationPolicy": NSApp.activationPolicy().rawValue,
            "applicationHidden": NSApp.isHidden, "statusBarLevelConstant": NSWindow.Level.statusBar.rawValue,
            "mainMenuLevelConstant": NSWindow.Level.mainMenu.rawValue,
            "itemExists": item != nil, "itemVisible": item?.isVisible ?? false,
            "statusBarThickness": NSStatusBar.system.thickness,
            "ownWindows": NSApp.windows.map(describe),
            "screenFrames": NSScreen.screens.map { NSStringFromRect($0.frame) }
        ]
        if let button = item?.button {
            sample["buttonFrame"] = NSStringFromRect(button.frame)
            sample["imageExists"] = button.image != nil
            sample["imageTemplate"] = button.image?.isTemplate ?? false
            sample["imageSize"] = NSStringFromSize(button.image?.size ?? .zero)
            if let itemWindow = button.window { sample["statusWindow"] = describe(itemWindow) }
        }
        samples.append(sample)
        if let data = try? JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
        fflush(stdout)
    }

    private func finish() {
        controller.setEnabled(false)
        if let item = legacyItem { NSStatusBar.system.removeStatusItem(item) }
        legacyItem = nil
        stableItem = nil
        window.close()
        let report: [String: Any] = ["checks": checks, "failures": failures, "samples": samples,
                                    "bundleIdentifier": Bundle.main.bundleIdentifier ?? "nil",
                                    "bundlePath": Bundle.main.bundlePath,
                                    "executablePath": Bundle.main.executablePath ?? "nil",
                                    "runningApplicationBundleID": NSRunningApplication.current.bundleIdentifier ?? "nil",
                                    "runningApplicationBundleURL": NSRunningApplication.current.bundleURL?.path ?? "nil",
                                    "runningApplicationExecutableURL": NSRunningApplication.current.executableURL?.path ?? "nil",
                                    "dataDirectory": StoragePaths.dataDirectory.path,
                                    "note": "Own-process geometry only; does not prove actual on-screen visibility."]
        do {
            let folder = StoragePaths.dataDirectory
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: folder.appendingPathComponent("menu-bar-regression.json"), options: .atomic)
        } catch { failures.append("Write report: \(error.localizedDescription)") }
        print("MenuBarTests: \(checks) lifecycle checks, \(failures.count) failures; \(samples.count) geometry samples")
        failures.forEach { print("FAIL: \($0)") }
        fflush(stdout)
        exit(failures.isEmpty ? 0 : 1)
    }
}
