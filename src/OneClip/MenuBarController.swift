import AppKit

/// Own the menu-bar item independently of application windows and activation policy.
final class MenuBarController: NSObject {
    static let shared = MenuBarController()
    private(set) var statusItem: NSStatusItem?
    private(set) var enabled = false
    var onLeftClick: (() -> Void)?
    var menu: (() -> NSMenu)?
    private var diagnosticGeneration = 0

    func setEnabled(_ enabled: Bool) {
        precondition(Thread.isMainThread)
        self.enabled = enabled
        if enabled { restore() }
        else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            recordDiagnostics(reason: "disabled")
        }
    }

    func restore() {
        precondition(Thread.isMainThread)
        guard enabled else { return }
        // Setting isVisible=true again does not repair a status window that AppKit
        // has already ordered out. Reinsert through NSStatusBar, never order its
        // system-managed window forward ourselves.
        if let item = statusItem, let window = item.button?.window,
           !window.isVisible, !NSApp.isHidden {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            // An explicit identity avoids AppKit's generated names changing with creation order.
            item.autosaveName = "CClip.MainMenuBarItem"
            item.behavior = []
            statusItem = item
        }
        guard let item = statusItem, let button = item.button else { return }
        let icon = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Xclip")
        icon?.size = NSSize(width: 18, height: 18)
        icon?.isTemplate = true
        button.image = icon
        button.title = icon == nil ? "Xclip" : ""
        item.length = icon == nil ? NSStatusItem.variableLength : NSStatusItem.squareLength
        button.toolTip = "Xclip"
        button.setAccessibilityLabel("Xclip")
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.isVisible = true
        button.needsDisplay = true
        recordDiagnostics(reason: "restored")
    }

    func owns(_ window: NSWindow) -> Bool { statusItem?.button?.window === window }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp, let item = statusItem, let menu = menu?() {
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        } else { onLeftClick?() }
    }

    /// Only geometry and our own app state; never clipboard content or settings secrets.
    func diagnostics(reason: String) -> [String: Any] {
        let button = statusItem?.button
        let window = button?.window
        let frame = window?.frame ?? .zero
        return [
            "reason": reason, "timestamp": ISO8601DateFormatter().string(from: Date()),
            "pid": ProcessInfo.processInfo.processIdentifier, "bundlePath": Bundle.main.bundlePath,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
            "registeredBundleIdentifier": NSRunningApplication.current.bundleIdentifier ?? "",
            "registeredBundlePath": NSRunningApplication.current.bundleURL?.path ?? "",
            "enabled": enabled, "itemExists": statusItem != nil,
            "itemVisible": statusItem?.isVisible ?? false, "buttonExists": button != nil,
            "imageExists": button?.image != nil, "windowExists": window != nil,
            "windowVisible": window?.isVisible ?? false, "windowLevel": window?.level.rawValue ?? -1,
            "windowOcclusionVisible": window?.occlusionState.contains(.visible) ?? false,
            "frame": NSStringFromRect(frame), "intersectsScreen": NSScreen.screens.contains { $0.frame.intersects(frame) },
            "screens": NSScreen.screens.map { NSStringFromRect($0.frame) },
            "statusWindows": NSApp.windows.filter { $0.level == .statusBar }.map { candidate -> [String: Any] in
                ["frame": NSStringFromRect(candidate.frame), "visible": candidate.isVisible,
                 "occlusionVisible": candidate.occlusionState.contains(.visible),
                 "buttonWindow": candidate === window]
            },
            "activationPolicy": NSApp.activationPolicy().rawValue, "applicationHidden": NSApp.isHidden
        ]
    }

    private func recordDiagnostics(reason: String) {
        diagnosticGeneration += 1
        let generation = diagnosticGeneration
        for delay in [0.3, 1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, generation == self.diagnosticGeneration else { return }
                let url = StoragePaths.dataDirectory.appendingPathComponent("menu-bar-diagnostics.json")
                var snapshot = self.diagnostics(reason: reason)
                snapshot["secondsAfterRequest"] = delay
                if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]) {
                    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
    }
}
