import AppKit
import SwiftUI

/// Keeps SwiftUI's scrolling and keyboard positioning, adding vertical-wheel
/// input only within the card strip's native viewport.
struct QuickPasteWheelScroll: NSViewRepresentable {
    var isEnabled = true

    func makeNSView(context: Context) -> QuickPasteWheelScrollView {
        let view = QuickPasteWheelScrollView()
        view.isEnabled = isEnabled
        return view
    }

    func updateNSView(_ view: QuickPasteWheelScrollView, context: Context) {
        view.isEnabled = isEnabled
    }

    static func dismantleNSView(_ view: QuickPasteWheelScrollView, coordinator: ()) {
        view.stopMonitoring()
    }
}

final class QuickPasteWheelScrollView: NSView {
    var isEnabled = true
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func handle(_ event: NSEvent) -> Bool {
        guard isEnabled, !PrivacyLock.shared.locked,
              let window, event.window === window, window.isVisible,
              !isHiddenOrHasHiddenAncestor, let scrollView = enclosingScrollView,
              scrollView.contentView.visibleRect.contains(scrollView.contentView.convert(event.locationInWindow, from: nil)),
              let movement = Self.horizontalMovement(for: event, lineScroll: scrollView.horizontalLineScroll) else { return false }
        let clip = scrollView.contentView
        var target = clip.bounds
        target.origin.x += movement
        // Use the existing clip view so SwiftUI observes its bounds change and
        // keeps lazy cards and keyboard scrollTo positioning in sync.
        clip.scroll(to: clip.constrainBoundsRect(target).origin)
        scrollView.reflectScrolledClipView(clip)
        return true
    }

    static func horizontalMovement(for event: NSEvent, lineScroll: CGFloat) -> CGFloat? {
        guard event.type == .scrollWheel,
              event.scrollingDeltaX == 0, event.scrollingDeltaY != 0,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return nil }
        // NSEvent already applies the system's natural-scroll preference.
        // Precise input (including momentum) is in points; mouse wheels use lines.
        return -event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : lineScroll)
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
