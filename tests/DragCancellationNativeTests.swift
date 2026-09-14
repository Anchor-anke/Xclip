import AppKit

/// Exercises the real NSDraggingSession with synthetic content in an off-screen
/// window. Events are posted only to this test process, never to other apps.
/// This is not a substitute for a physical held-left/right-click acceptance test.
/// --observed-mouse verifies the observer callback bridge, not system observation.
final class NativeDragTest: NSObject, NSApplicationDelegate, NSDraggingSource {
    private var window: NSWindow!
    private var source: NSView!
    private var token: UUID?
    private var finished = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 240, height: 120),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        source = NSView(frame: window.contentView!.bounds)
        window.contentView = source
        window.orderBack(nil)
        DispatchQueue.main.async { self.start() }
        let timeout = Timer(timeInterval: 4, repeats: false) { _ in
            fputs("FAIL: native drag did not finish\n", stderr); exit(1)
        }
        RunLoop.main.add(timeout, forMode: .common)
    }

    private func start() {
        let item = NSDraggingItem(pasteboardWriter: "Xclip isolated cancellation test" as NSString)
        item.setDraggingFrame(NSRect(x: 10, y: 10, width: 50, height: 30),
                              contents: NSImage(size: NSSize(width: 50, height: 30)))
        let event = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 20, y: 20),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1,
            clickCount: 1, pressure: 1)!
        source.beginDraggingSession(with: [item], event: event, source: self)
            .animatesToStartingPositionsOnCancelOrFail = false
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        DragCancellationController.shared.isCancelled(token) ? [] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        token = DragCancellationController.shared.begin()
        session.animatesToStartingPositionsOnCancelOrFail = false
        if ProcessInfo.processInfo.arguments.contains("--hidden-source") { window.orderOut(nil) }
        // No left-up is posted: cancellation must end the session on its own.
        let right = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2,
            clickCount: 1, pressure: 1)!
        if ProcessInfo.processInfo.arguments.contains("--observed-mouse") {
            let observationToken = token!
            let timer = Timer(timeInterval: 0.02, repeats: false) { _ in
                precondition(DragCancellationController.shared.consumeObservedMouseEvent(right, token: observationToken),
                             "Current observed right down must be consumed")
            }
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .eventTracking)
        } else {
            NSApp.postEvent(right, atStart: true)
        }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        precondition(!finished, "Only one completion is allowed")
        finished = true
        let cancellation = DragCancellationController.shared
        precondition(cancellation.isCancelled(token), "Right down must reach the production controller")
        precondition(operation.isEmpty, "A cancelled session cannot report a copy operation")
        precondition(NSApp.currentEvent?.type == .keyDown && NSApp.currentEvent?.keyCode == 53,
                     "AppKit must end the drag while processing the queued Escape")
        precondition(cancellation.end(token), "Native end must preserve cancellation reason")
        precondition(!cancellation.canBeginDrag, "Left has not been released, so the gesture stays blocked")
        print("PASS: real NSDraggingSession ended with empty operation on Escape before any left-up; hidden=\(ProcessInfo.processInfo.arguments.contains("--hidden-source")); observedCallback=\(ProcessInfo.processInfo.arguments.contains("--observed-mouse")) (no hardware routing tested)")
        fflush(stdout)
        exit(0)
    }
}

@main enum NativeDragTestMain {
    static func main() {
        let app = XclipApplication.shared
        let delegate = NativeDragTest()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
