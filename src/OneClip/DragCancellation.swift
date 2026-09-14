import AppKit
import OSLog

enum DragCompletion {
    case accepted, cancelled, notAccepted
}

/// State belongs to a drag gesture, not a view: the quick panel can disappear
/// while AppKit continues tracking the drag over another application.
struct DragCancellationState {
    struct Session {
        let id: UUID
        let native: Bool
        var cancelled = false
    }
    enum Input { case leftDown, leftUp, leftDragged, rightDown, rightUp, rightDragged, escape }
    private(set) var session: Session?
    private(set) var blockedUntilLeftUp = false
    private(set) var suppressRightUp = false
    private(set) var pendingEscape: UUID?

    var canBegin: Bool { !blockedUntilLeftUp && !suppressRightUp }
    var needsEvents: Bool { session != nil || blockedUntilLeftUp || suppressRightUp }

    mutating func begin(native: Bool) -> UUID {
        // SwiftUI can request more than one provider for the same drag.
        if let session { return session.id }
        let id = UUID()
        guard canBegin else { return id }
        session = Session(id: id, native: native)
        return id
    }

    func isCancelled(_ id: UUID?) -> Bool {
        guard let id else { return false }
        return session?.id == id && session?.cancelled == true
    }

    @discardableResult mutating func end(_ id: UUID?) -> Bool {
        guard let id, session?.id == id else { return false }
        let cancelled = session?.cancelled == true
        session = nil
        pendingEscape = nil
        // Keep the physical gesture guard and paired right-up after native end.
        return cancelled
    }

    /// A fresh local left-down can recover a release missed after observation
    /// expired. Keep the left guard for consume(.leftDown), and never remove a
    /// still-held right button's paired release or alter an active session.
    @discardableResult mutating func recoverExpiredObservation(rightButtonPressed: Bool) -> Bool {
        guard session == nil, !rightButtonPressed else { return false }
        suppressRightUp = false
        return true
    }

    /// Returns true only when this event belongs to the cancelled gesture.
    mutating func consume(_ input: Input) -> Bool {
        switch input {
        case .rightDown:
            guard session != nil || blockedUntilLeftUp else { return false }
            suppressRightUp = true
            blockedUntilLeftUp = true
            if session?.cancelled == false {
                session?.cancelled = true
                pendingEscape = session?.id
            }
            return true
        case .rightUp:
            let suppress = suppressRightUp
            suppressRightUp = false
            return suppress
        case .rightDragged:
            return suppressRightUp
        case .leftDragged:
            return blockedUntilLeftUp
        case .leftUp:
            let suppress = blockedUntilLeftUp
            blockedUntilLeftUp = false
            if session?.native == false { _ = end(session?.id) }
            return suppress
        case .leftDown:
            // A fresh down also recovers if the previous up was consumed by
            // another AppKit tracking loop. It is never a continuation drag.
            blockedUntilLeftUp = false
            if session?.native == false { _ = end(session?.id) }
            return false
        case .escape:
            // SwiftUI's provider callback has no end notification on older
            // systems. A physical Escape must retire that fallback session,
            // while the native drag loop still receives the actual key event.
            if session?.native == false {
                _ = end(session?.id)
                blockedUntilLeftUp = true
            }
            return false
        }
    }

    mutating func takeEscape() -> Bool {
        defer { pendingEscape = nil }
        return pendingEscape != nil && pendingEscape == session?.id
    }
}

/// Main-thread only, like NSApplication's event queue and NSDraggingSource.
final class DragCancellationController {
    #if DRAG_CANCELLATION_TESTS
    static let shared = DragCancellationController()
    #else
    static let shared = DragCancellationController(observesSystemEvents: true)
    #endif
    private var state = DragCancellationState()
    private let logger = os.Logger(subsystem: "local.cclip.app", category: "DragCancellation")
    private let observesSystemEvents: Bool
    private let systemObserver = DragSystemEventObserver()
    private var observationToken: UUID?
    private var observationExpired = false
    private var releaseTimeout: Timer?

    init(observesSystemEvents: Bool = false) {
        self.observesSystemEvents = observesSystemEvents
    }
    var canBeginDrag: Bool { state.canBegin }
    var needsEvents: Bool { state.needsEvents }
    var additionalEventMask: NSEvent.EventTypeMask {
        var mask: NSEvent.EventTypeMask = []
        if state.session != nil || state.blockedUntilLeftUp { mask.insert(.rightMouseDown) }
        if state.suppressRightUp { mask.formUnion([.rightMouseUp, .rightMouseDragged]) }
        if state.blockedUntilLeftUp { mask.formUnion([.leftMouseUp, .leftMouseDragged]) }
        return mask
    }
    func begin(native: Bool = true) -> UUID {
        let token = state.begin(native: native)
        if state.session?.id == token, observationToken == nil {
            observationToken = token
            observationExpired = false
            if observesSystemEvents {
                logger.notice("Drag began; native source: \(native)")
                systemObserver.start { [weak self] event in
                    self?.consumeObservedMouseEvent(event, token: token) ?? false
                }
            }
        }
        return token
    }
    func isCancelled(_ token: UUID?) -> Bool { state.isCancelled(token) }
    @discardableResult func end(_ token: UUID?) -> Bool {
        let wasCurrent = token != nil && state.session?.id == token
        let cancelled = state.end(token)
        if wasCurrent, observesSystemEvents { logger.notice("Drag ended; right-click cancelled: \(cancelled)") }
        updateObservationLifetime()
        return cancelled
    }

    func consume(_ event: NSEvent) -> Bool {
        let input: DragCancellationState.Input
        switch event.type {
        case .leftMouseDown:
            if observationExpired,
               state.recoverExpiredObservation(rightButtonPressed: NSEvent.pressedMouseButtons & 2 != 0) {
                observationExpired = false
            }
            input = .leftDown
        case .leftMouseUp: input = .leftUp
        case .leftMouseDragged: input = .leftDragged
        case .rightMouseDown: input = .rightDown
        case .rightMouseUp: input = .rightUp
        case .rightMouseDragged: input = .rightDragged
        case .keyDown where event.keyCode == 53: input = .escape
        default: return false
        }
        let wasCancelled = state.session?.cancelled == true
        let consumed = state.consume(input)
        if !wasCancelled, state.session?.cancelled == true, observesSystemEvents {
            logger.notice("Right mouse received; requesting drag cancellation")
        }
        updateObservationLifetime()
        return consumed
    }

    /// System mouse observation also sees clicks consumed by native tracking or
    /// routed outside the hidden source panel. Post immediately: nextEvent may
    /// already be blocked inside super waiting for an event in our own queue.
    @discardableResult func consumeObservedMouseEvent(_ event: NSEvent, token: UUID) -> Bool {
        guard observationToken == token else { return false }
        switch event.type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged, .leftMouseUp: break
        default: return false
        }
        let consumed = consume(event)
        if let escape = takeEscape() { NSApp.postEvent(escape, atStart: true) }
        return consumed
    }

    private func updateObservationLifetime() {
        if !state.needsEvents {
            systemObserver.stop()
            observationToken = nil
            observationExpired = false
            releaseTimeout?.invalidate()
            releaseTimeout = nil
        } else if observesSystemEvents, !observationExpired, state.session == nil, releaseTimeout == nil {
            // Normally both releases arrive immediately. A lost release (e.g.
            // sleep/lock) must not leave an application-wide mouse tap running.
            let token = observationToken
            let timer = Timer(timeInterval: 10, repeats: false) { [weak self] _ in
                guard let self, self.observationToken == token, self.state.session == nil else { return }
                self.systemObserver.stop()
                self.observationToken = nil
                self.observationExpired = true
                self.releaseTimeout = nil
            }
            releaseTimeout = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func takeEscape() -> NSEvent? {
        guard state.takeEscape() else { return nil }
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: 53)
    }
}

/// Native drag tracking bypasses sendEvent/local monitors. Observe the app's
/// own queue as well as the drag-scoped system mouse observer.
@objc(XclipApplication)
final class XclipApplication: NSApplication {
    override func nextEvent(matching mask: NSEvent.EventTypeMask, until expiration: Date?,
                            inMode mode: RunLoop.Mode, dequeue flag: Bool) -> NSEvent? {
        guard flag, Thread.isMainThread else {
            return super.nextEvent(matching: mask, until: expiration, inMode: mode, dequeue: flag)
        }
        let cancellation = DragCancellationController.shared
        while true {
            // Fetch the posted event through super, so AppKit's currentEvent
            // stays consistent. Never return a fabricated event to its caller.
            if mask.contains(.keyDown), let escape = cancellation.takeEscape() {
                postEvent(escape, atStart: true)
            }
            let trackingMask = mask.union(cancellation.additionalEventMask)
            guard let event = super.nextEvent(matching: trackingMask, until: expiration,
                                              inMode: mode, dequeue: true) else { return nil }
            if cancellation.consume(event) { continue }
            // A timer or nested callback may end the session while super waits.
            // An event fetched using the old expanded mask then belongs to normal
            // dispatch: preserve it, but do not return a type this caller excluded.
            let eventMask = NSEvent.EventTypeMask(rawValue: 1 << event.type.rawValue)
            if !mask.contains(eventMask) {
                postEvent(event, atStart: true)
                continue
            }
            return event
        }
    }
}
