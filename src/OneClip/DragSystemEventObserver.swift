import AppKit
import ApplicationServices
import OSLog

/// A temporary, main-run-loop observer for one drag and its paired releases.
/// The handler must stay short; only an active tap can suppress an event.
final class DragSystemEventObserver {
    private let logger = os.Logger(subsystem: "local.cclip.app", category: "DragCancellation")
    private static let mouseTypes: [CGEventType] = [
        .rightMouseDown, .rightMouseUp, .rightMouseDragged, .leftMouseUp
    ]
    private static let mouseMask: NSEvent.EventTypeMask = [
        .rightMouseDown, .rightMouseUp, .rightMouseDragged, .leftMouseUp
    ]
    private var handler: ((NSEvent) -> Bool)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var globalMonitor: Any?
    private var generation: UInt64 = 0
    private(set) var isRunning = false

    func start(handler: @escaping (NSEvent) -> Bool) {
        precondition(Thread.isMainThread)
        stop()
        self.handler = handler
        isRunning = true
        // Never request new access. A denied or unavailable tap falls back to
        // mouse-only observation, which cannot suppress another app's event.
        if AXIsProcessTrusted() {
            let mask = Self.mouseTypes.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, info in
                    guard let info else { return Unmanaged.passUnretained(event) }
                    let observer = Unmanaged<DragSystemEventObserver>.fromOpaque(info)
                        .takeUnretainedValue()
                    return observer.receive(type: type, event: event)
                }, userInfo: Unmanaged.passUnretained(self).toOpaque())
            if let tap, let source = CFMachPortCreateRunLoopSource(nil, tap, 0) {
                self.source = source
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                if CGEvent.tapIsEnabled(tap: tap) {
                    logger.notice("Drag mouse observation: event tap")
                    return
                }
            }
        }
        startGlobalFallback()
    }

    func stop() {
        precondition(Thread.isMainThread)
        isRunning = false
        generation &+= 1
        handler = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = nil
        removeTap()
    }

    private func removeTap() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    private func startGlobalFallback() {
        removeTap()
        guard isRunning, globalMonitor == nil else { return }
        let currentGeneration = generation
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.mouseMask) {
            [weak self] event in
            guard let self, self.isRunning, self.generation == currentGeneration,
                  let handler = self.handler else { return }
            // AppKit delivers global monitor callbacks on the main thread.
            precondition(Thread.isMainThread)
            _ = handler(event)
        }
        logger.notice("Drag mouse observation: global mouse monitor")
    }

    private func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let unchanged = Unmanaged.passUnretained(event)
        guard Thread.isMainThread, isRunning else { return unchanged }
        if type == .tapDisabledByTimeout {
            if let tap, CFMachPortIsValid(tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
                if CGEvent.tapIsEnabled(tap: tap) { return unchanged }
            }
            startGlobalFallback()
            return unchanged
        }
        if type == .tapDisabledByUserInput {
            startGlobalFallback()
            return unchanged
        }
        guard Self.mouseTypes.contains(type), let event = NSEvent(cgEvent: event),
              let handler else { return unchanged }
        // Keep the closure alive while it runs: it may synchronously call stop.
        return handler(event) ? nil : unchanged
    }

    deinit { stop() }
}
