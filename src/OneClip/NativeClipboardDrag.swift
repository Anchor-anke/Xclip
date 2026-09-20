import AppKit
import SwiftUI

extension View {
    /// The background observes a drag without taking clicks away from SwiftUI.
    func nativeClipboardDrag(_ item: ClipboardItem) -> some View {
        background(NativeClipboardDrag(items: [item]))
    }

    /// Reserve embedded SwiftUI controls and selectable text for their own gestures.
    func nativeClipboardDragExcluded() -> some View {
        background(NativeClipboardDrag(items: [], excludesDragging: true))
    }
}

private struct NativeClipboardDrag: NSViewRepresentable {
    var items: [ClipboardItem]
    var excludesDragging = false

    func makeNSView(context: Context) -> NativeClipboardDragView { NativeClipboardDragView() }
    func updateNSView(_ view: NativeClipboardDragView, context: Context) {
        view.items = items
        view.excludesDragging = excludesDragging
    }
    static func dismantleNSView(_ view: NativeClipboardDragView, coordinator: ()) {
        NativeClipboardDragMonitor.shared.remove(view)
    }
}

final class NativeClipboardDragView: NSView {
    var items: [ClipboardItem] = []
    var excludesDragging = false
    private var activeSource: NativeClipboardDraggingSource?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { NativeClipboardDragMonitor.shared.remove(self) }
        else { NativeClipboardDragMonitor.shared.add(self) }
    }

    func contains(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.isVisible,
              !isHiddenOrHasHiddenAncestor, alphaValue > 0 else { return false }
        // On newer macOS versions a non-clipping NSView can report a visibleRect
        // larger than its bounds. The row's own rectangle remains authoritative.
        let point = convert(event.locationInWindow, from: nil)
        return bounds.contains(point) && visibleRect.contains(point)
    }

    func startDragging(_ items: [ClipboardItem], event: NSEvent) throws {
        guard activeSource == nil else { return }
        let source = try NativeClipboardDraggingSource(items: items) { [weak self] in self?.activeSource = nil }
        activeSource = source
        source.begin(from: self, event: event)
    }
}

/// One monitor serves all visible rows; backgrounds never become mouse targets.
final class NativeClipboardDragMonitor {
    static let shared = NativeClipboardDragMonitor()
    private let views = NSHashTable<NativeClipboardDragView>.weakObjects()
    private var monitor: Any?
    private weak var armedView: NativeClipboardDragView?
    private var armedItems: [ClipboardItem] = []
    private var origin: NSPoint?

    // A seam for isolated event tests; production always starts a native session.
    var beginDrag: (NativeClipboardDragView, [ClipboardItem], NSEvent) throws -> Void = {
        try $0.startDragging($1, event: $2)
    }
    var reportError: (Error) -> Void = NativeClipboardDraggingSource.report

    func add(_ view: NativeClipboardDragView) {
        views.add(view)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .keyDown]) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
    }

    func remove(_ view: NativeClipboardDragView) {
        views.remove(view)
        if armedView === view { reset() }
        guard views.allObjects.isEmpty, let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    private func reset() {
        armedView = nil
        armedItems = []
        origin = nil
    }

    /// Only the drag event that starts our native session is consumed.
    /// Down/up, double-click, selection modifiers and context clicks stay with SwiftUI.
    func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            reset()
            guard !PrivacyLock.shared.locked, DragCancellationController.shared.canBeginDrag,
                  event.clickCount == 1,
                  event.modifierFlags.intersection([.command, .control, .shift]).isEmpty else { return false }
            let hits = views.allObjects.filter { $0.contains(event) }
            guard !hits.contains(where: \.excludesDragging), !Self.isInteractiveHit(event),
                  let view = hits.filter({ !$0.items.isEmpty }).min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) else { return false }
            armedView = view
            armedItems = view.items
            origin = event.locationInWindow
            return false
        case .leftMouseDragged:
            guard let view = armedView, let origin else { return false }
            guard !PrivacyLock.shared.locked, DragCancellationController.shared.canBeginDrag,
                  event.window === view.window, view.window?.isVisible == true,
                  !view.isHiddenOrHasHiddenAncestor, view.items.map(\.id) == armedItems.map(\.id) else { reset(); return false }
            guard hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 5 else { return false }
            let items = armedItems
            reset() // A failed preparation must not retry repeatedly while the mouse stays down.
            do { try beginDrag(view, items, event) }
            catch { reportError(error) }
            return true
        case .leftMouseUp, .rightMouseDown, .keyDown:
            reset()
            return false
        default:
            return false
        }
    }

    static func isInteractiveHit(_ event: NSEvent) -> Bool {
        guard let content = event.window?.contentView else { return false }
        var hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
        while let current = hit {
            if let text = current as? NSTextField {
                if text.isEditable || text.isSelectable { return true }
            } else if let text = current as? NSTextView {
                if text.isEditable || text.isSelectable { return true }
            } else if current is NSControl, !(current is NSImageView), !(current is NSTableView) { return true }
            hit = current.superview
        }
        return false
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

/// The sender retains this delegate; it retains the view and attachment snapshots
/// until AppKit ends the drag, including cancellation or a disappearing SwiftUI row.
final class NativeClipboardDraggingSource: NSObject, NSDraggingSource {
    private let items: [ClipboardItem]
    private let writers: [NSPasteboardWriting]
    private let onEnd: () -> Void
    private var sourceView: NSView?
    private var cancellationToken: UUID?
    private var ended = false

    init(items: [ClipboardItem], manager: ClipboardManager = .shared, onEnd: @escaping () -> Void) throws {
        self.items = items
        self.writers = try QuickPasteDragPayload.writers(for: items, manager: manager)
        self.onEnd = onEnd
        super.init()
    }

    func begin(from view: NSView, event: NSEvent) {
        sourceView = view
        let point = view.convert(event.locationInWindow, from: nil)
        let frame = NSRect(x: point.x - 20, y: point.y - 20, width: 40, height: 40)
        let draggingItems = writers.map { writer in
            let item = NSDraggingItem(pasteboardWriter: writer)
            let icon: NSImage?
            if let url = writer as? NSURL { icon = NSWorkspace.shared.icon(forFile: url.path ?? "") }
            else { icon = NSImage(systemSymbolName: items.first?.type.icon ?? "doc", accessibilityDescription: nil) }
            item.setDraggingFrame(frame, contents: icon)
            return item
        }
        let session = view.beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
        session.draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        PrivacyLock.shared.locked || DragCancellationController.shared.isCancelled(cancellationToken) ? [] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        cancellationToken = DragCancellationController.shared.begin()
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard !ended else { return }
        ended = true
        let cancelled = DragCancellationController.shared.end(cancellationToken)
        cancellationToken = nil
        if operation == [], !cancelled, !PrivacyLock.shared.locked {
            WorkflowState.shared.status = L("目标应用未接收拖出的内容，可重试或使用复制、粘贴。", "The destination did not accept the drop. Try again, or use Copy and Paste.")
        }
        onEnd()
        sourceView = nil
    }

    static func report(_ error: Error) {
        let message = L("无法拖出内容：", "Unable to drag this item: ") + error.localizedDescription
        ClipboardManager.shared.lastError = message
        WorkflowState.shared.status = message
        NSSound.beep()
    }
}
