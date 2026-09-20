import AppKit
import SwiftUI

/// Native multi-item drag session, so every file reaches Finder or the destination app.
struct BatchDragView: NSViewRepresentable {
    @ObservedObject private var appLanguage = AppLanguage.shared
    var items: [ClipboardItem]
    var title: String
    func makeNSView(context: Context) -> BatchDragControl { BatchDragControl() }
    func updateNSView(_ view: BatchDragControl, context: Context) {
        view.items = items; view.label = title; view.needsDisplay = true; view.setAccessibilityLabel(title)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityEnabled(!items.isEmpty)
        view.toolTip = view.interactionHelp
        view.setAccessibilityHelp(view.toolTip)
    }
}
final class BatchDragControl: NSView {
    var items: [ClipboardItem] = []
    var label = L("拖出文件", "Drag files")
    private var started = false
    private var activeSource: NativeClipboardDraggingSource?
    private var mouseDownLocation: NSPoint?
    var interactionHelp: String {
        items.isEmpty
            ? L("请先选择要拖出的内容。", "Select the content to drag first.")
            : L("按住此处拖动到目标应用，松开即可放入；拖拽中按右键取消。", "Press and hold here, drag to the destination app, then release to drop. Right-click during a drag to cancel.")
    }
    override var intrinsicContentSize: NSSize { NSSize(width: 120, height: 26) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlColor.setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).fill()
        let text = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: items.isEmpty ? NSColor.disabledControlTextColor : NSColor.labelColor])
        text.draw(at: NSPoint(x: max(5, (bounds.width - text.size().width) / 2), y: (bounds.height - text.size().height) / 2))
    }
    override func mouseDown(with event: NSEvent) {
        guard !items.isEmpty, !PrivacyLock.shared.locked,
              activeSource == nil, DragCancellationController.shared.canBeginDrag else { return }
        started = false
        mouseDownLocation = event.locationInWindow
    }
    override func mouseDragged(with event: NSEvent) {
        guard !started, !items.isEmpty, !PrivacyLock.shared.locked, DragCancellationController.shared.canBeginDrag,
              let origin = mouseDownLocation,
              hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 5 else { return }
        started = true
        do {
            let source = try NativeClipboardDraggingSource(items: items) { [weak self] in
                self?.activeSource = nil
                self?.mouseDownLocation = nil
            }
            activeSource = source
            source.begin(from: self, event: event)
        } catch { NativeClipboardDraggingSource.report(error) }
    }
    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil }
        guard mouseDownLocation != nil, !started, activeSource == nil,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        _ = showInteractionHelp()
    }
    override func accessibilityPerformPress() -> Bool { showInteractionHelp() }
    private func showInteractionHelp() -> Bool {
        guard !items.isEmpty, !PrivacyLock.shared.locked,
              activeSource == nil, DragCancellationController.shared.canBeginDrag else { return false }
        ClipboardManager.shared.lastError = nil
        WorkflowState.shared.status = interactionHelp
        return true
    }
}
