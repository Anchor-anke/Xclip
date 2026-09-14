import AppKit
import Foundation

@main
struct DragCancellationTests {
    enum Failure: Error { case assertion(String) }
    static var assertions = 0

    static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure.assertion(message) }
        assertions += 1
    }

    static func mouse(_ type: NSEvent.EventType, number: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, eventNumber: number, clickCount: 1, pressure: 0)!
    }

    static func testIdleAndNormalDrag() throws {
        var state = DragCancellationState()
        try expect(state.canBegin && !state.needsEvents, "idle permits dragging without monitoring")
        for input: DragCancellationState.Input in [.leftDown, .leftDragged, .leftUp, .rightDown, .rightDragged, .rightUp, .escape] {
            try expect(!state.consume(input), "idle leaves ordinary mouse events untouched")
        }
        try expect(!state.takeEscape(), "idle cannot synthesize a cancellation")
        let token = state.begin(native: true)
        try expect(state.needsEvents && state.canBegin, "native begin enables monitoring")
        try expect(state.begin(native: true) == token, "duplicate native begin retains the gesture token")
        try expect(!state.consume(.leftDragged), "normal left drag is not consumed")
        try expect(!state.consume(.leftUp), "normal left release reaches the drop target")
        try expect(state.session?.id == token, "native session waits for its completion callback")
        try expect(!state.end(token), "normal native completion is not reported as cancelled")
        try expect(!state.needsEvents && state.canBegin, "normal native end removes monitoring")
    }

    static func testCancellationAndDuplicateRightClicks() throws {
        var state = DragCancellationState()
        let token = state.begin(native: true)
        try expect(state.consume(.rightDown), "right down cancels the active gesture")
        try expect(state.isCancelled(token) && !state.canBegin, "cancelled gesture cannot restart")
        try expect(state.takeEscape(), "first cancellation requests one Escape")
        try expect(!state.takeEscape(), "Escape request is consumed exactly once")
        try expect(state.consume(.rightDown), "duplicate right down remains suppressed")
        try expect(!state.takeEscape(), "duplicate right down does not request another Escape")
        try expect(state.consume(.rightDragged), "right drag in the cancelled gesture is suppressed")
        try expect(state.consume(.leftDragged), "continued physical left drag is suppressed")
        try expect(state.end(token), "native end reports explicit cancellation")
        try expect(state.consume(.leftDragged), "left continuation stays suppressed after native end")
        try expect(state.consume(.rightDown), "extra right down before left release stays suppressed")
        try expect(!state.takeEscape(), "ended session cannot emit a stale Escape")
        try expect(state.consume(.rightUp), "paired right release is consumed")
        try expect(state.consume(.leftUp), "cancelled gesture's left release is consumed")
        try expect(state.canBegin && !state.needsEvents, "both releases completely end the guard")
        try expect(!state.consume(.leftDragged), "later unrelated left drag is unaffected")
        try expect(!state.consume(.rightUp), "later unrelated right release is unaffected")
    }

    static func testReleaseOrders() throws {
        for native in [true, false] {
            for rightFirst in [true, false] {
                var state = DragCancellationState()
                let token = state.begin(native: native)
                _ = state.consume(.rightDown)
                _ = state.takeEscape()
                if native { try expect(state.end(token), "native cancellation can finish before physical releases") }
                let first: DragCancellationState.Input = rightFirst ? .rightUp : .leftUp
                let second: DragCancellationState.Input = rightFirst ? .leftUp : .rightUp
                try expect(state.consume(first), "first release is consumed in either button order")
                try expect(!state.canBegin && state.needsEvents, "remaining held button keeps its guard")
                if rightFirst {
                    try expect(state.consume(.leftDragged), "left continuation stays blocked after right release")
                } else {
                    try expect(state.consume(.rightDragged), "right continuation stays blocked after left release")
                }
                try expect(state.consume(second), "second release is consumed in either button order")
                try expect(state.canBegin && !state.needsEvents, "either release order restores idle")
            }
        }
    }

    static func testFreshLeftDownAndSwiftUI() throws {
        var state = DragCancellationState()
        let token = state.begin(native: false)
        try expect(state.begin(native: false) == token, "multiple SwiftUI provider requests reuse one gesture")
        _ = state.consume(.rightDown)
        _ = state.takeEscape()
        _ = state.consume(.rightUp)
        try expect(!state.consume(.leftDown), "fresh left down is never swallowed")
        try expect(state.session == nil && state.canBegin && !state.needsEvents,
                   "fresh down recovers an old SwiftUI gesture whose left up was missed")
        let next = state.begin(native: false)
        try expect(next != token && !state.isCancelled(next), "fresh SwiftUI gesture has independent cancellation state")
        try expect(!state.consume(.leftUp), "normal SwiftUI release remains available to the drop target")
        try expect(state.session == nil && !state.needsEvents, "SwiftUI release completes its fallback lifecycle")

        let third = state.begin(native: true)
        _ = state.consume(.rightDown)
        _ = state.end(third)
        try expect(!state.consume(.leftDown), "fresh down is forwarded while a paired right release is pending")
        try expect(!state.blockedUntilLeftUp && state.suppressRightUp && !state.canBegin,
                   "fresh down preserves a still-held right button's paired release")
        try expect(state.consume(.rightUp), "pending right release does not leak after fresh down")
        try expect(state.canBegin && !state.needsEvents, "release of the remaining right button restores idle")
    }

    static func testTokensAndPendingEscape() throws {
        var state = DragCancellationState()
        let old = state.begin(native: true)
        try expect(!state.end(nil) && !state.end(UUID()), "missing and foreign tokens cannot end a session")
        try expect(state.session?.id == old, "foreign end preserves the live token")
        _ = state.consume(.rightDown)
        try expect(state.end(old), "cancelled token ends once")
        try expect(!state.takeEscape(), "ending a token discards its pending Escape")
        try expect(!state.end(old), "duplicate completion is harmless")
        let refused = state.begin(native: false)
        try expect(state.session == nil && !state.isCancelled(refused), "blocked begin cannot create another session")
        _ = state.consume(.rightUp)
        _ = state.consume(.leftUp)
        let current = state.begin(native: true)
        try expect(current != old && current != refused, "new accepted gesture gets a new token")
        try expect(!state.end(old) && state.session?.id == current, "late old completion cannot end a new drag")
        try expect(!state.isCancelled(old) && !state.isCancelled(nil), "stale and absent tokens are not current cancellations")
        _ = state.consume(.rightDown)
        try expect(!state.end(old) && state.pendingEscape == current, "late completion preserves the new Escape request")
        try expect(state.takeEscape(), "new token retains its own cancellation request")
    }

    static func testExpiredObservationRecovery() throws {
        var released = DragCancellationState()
        let ended = released.begin(native: true)
        _ = released.consume(.rightDown)
        _ = released.takeEscape()
        _ = released.end(ended)
        try expect(!released.canBegin && released.suppressRightUp && released.blockedUntilLeftUp,
                   "missed releases leave both gesture guards after native cancellation")
        try expect(released.recoverExpiredObservation(rightButtonPressed: false),
                   "expired observation can recover a right button that is already released")
        try expect(!released.suppressRightUp && released.blockedUntilLeftUp && !released.canBegin,
                   "idle recovery removes only the stale right-release guard")
        try expect(!released.consume(.leftDown) && released.canBegin && !released.needsEvents,
                   "the fresh left-down clears the left guard and restores dragging")
        try expect(!released.takeEscape(), "release recovery does not emit another cancellation Escape")

        var held = DragCancellationState()
        let token = held.begin(native: true)
        _ = held.consume(.rightDown)
        _ = held.takeEscape()
        _ = held.end(token)
        try expect(!held.recoverExpiredObservation(rightButtonPressed: true),
                   "expired observation cannot remove a still-held right button's protection")
        try expect(held.suppressRightUp && held.blockedUntilLeftUp,
                   "a held right button preserves both guards until the fresh gesture is processed")
        try expect(!held.consume(.leftDown) && held.suppressRightUp && !held.canBegin,
                   "fresh left-down while right remains held cannot restart dragging")
        try expect(held.recoverExpiredObservation(rightButtonPressed: false),
                   "a later fresh gesture can recover once that right button is released")
        try expect(!held.consume(.leftDown) && held.canBegin && !held.needsEvents,
                   "later recovery restores idle even if the old right-up was never delivered")

        let current = held.begin(native: true)
        _ = held.consume(.rightDown)
        try expect(!held.recoverExpiredObservation(rightButtonPressed: false),
                   "idle recovery cannot alter an active native session")
        try expect(held.session?.id == current && held.isCancelled(current) && held.suppressRightUp,
                   "active cancellation retains its token and release guards")
        try expect(held.takeEscape(), "idle recovery cannot discard an active session's pending Escape")
    }

    static func testPhysicalEscape() throws {
        var state = DragCancellationState()
        let fallback = state.begin(native: false)
        try expect(!state.consume(.escape), "physical Escape remains available to the native event loop")
        try expect(state.session == nil && state.blockedUntilLeftUp && !state.canBegin,
                   "physical Escape ends the SwiftUI fallback and guards the remaining left gesture")
        try expect(!state.isCancelled(fallback) && !state.takeEscape(), "physical Escape cannot queue a second Escape")
        try expect(state.consume(.leftDragged), "left continuation after physical Escape is suppressed")
        try expect(state.consume(.rightDown), "right down after physical Escape belongs to the cancelled gesture")
        try expect(!state.takeEscape(), "right down after fallback Escape does not revive a stale session")
        try expect(state.consume(.leftUp) && !state.canBegin, "left release keeps the outstanding right release guarded")
        try expect(state.consume(.rightUp) && state.canBegin && !state.needsEvents,
                   "both releases restore normal input after physical Escape")
        try expect(!state.consume(.escape) && !state.needsEvents, "ordinary Escape outside a drag leaves state idle")

        let native = state.begin(native: true)
        try expect(!state.consume(.escape), "native drag receives physical Escape unchanged")
        try expect(state.session?.id == native && !state.blockedUntilLeftUp,
                   "physical Escape leaves native lifecycle to its completion callback")
        try expect(!state.takeEscape() && !state.end(native), "native Escape does not emit a duplicate or invent right-click cancellation")

        let controller = DragCancellationController()
        let token = controller.begin(native: false)
        let regularKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        try expect(!controller.consume(regularKey) && controller.canBeginDrag, "ordinary keys do not end the fallback gesture")
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!
        try expect(!controller.consume(escape) && !controller.canBeginDrag, "controller maps Escape keyDown to fallback cleanup without swallowing it")
        try expect(!controller.end(token) && controller.takeEscape() == nil, "retired fallback token cannot create another Escape")
        try expect(controller.consume(mouse(.leftMouseUp)) && !controller.needsEvents,
                   "fallback Escape without any right click needs only the final left release")
    }

    static func testControllerMapping() throws {
        let controller = DragCancellationController()
        try expect(controller.additionalEventMask.isEmpty, "idle controller does not broaden event masks")
        let token = controller.begin()
        try expect(controller.additionalEventMask == .rightMouseDown, "active normal drag only adds the cancellation trigger")
        try expect(!controller.consume(mouse(.leftMouseDragged)), "controller forwards normal native dragging")
        try expect(controller.consume(mouse(.rightMouseDown)), "controller maps right mouse down to cancellation")
        let expected: NSEvent.EventTypeMask = [.rightMouseDown, .rightMouseUp, .rightMouseDragged, .leftMouseUp, .leftMouseDragged]
        try expect(controller.additionalEventMask == expected, "cancelled controller requests only gesture events it suppresses")
        let escape = controller.takeEscape()
        try expect(escape?.type == .keyDown && escape?.keyCode == 53 && escape?.characters == "\u{1B}",
                   "controller creates Escape without generating any mouse release")
        try expect(escape?.modifierFlags.isEmpty == true && escape?.isARepeat == false,
                   "cancellation Escape has no inherited modifiers or repeat flag")
        try expect(escape.map { !controller.consume($0) } == true, "controller never consumes its own Escape")
        try expect(controller.takeEscape() == nil, "controller emits Escape only once")
        try expect(controller.end(token), "controller returns the explicit cancellation outcome")
        try expect(controller.consume(mouse(.rightMouseUp)) && controller.consume(mouse(.leftMouseUp)),
                   "controller consumes both physical releases after native end")
        try expect(controller.additionalEventMask.isEmpty && !controller.needsEvents && controller.canBeginDrag,
                   "completed controller leaves normal event dispatch unchanged")
    }

    /// Optional isolated queue verification: no windows, run(), global events,
    /// pasteboard writes, or interaction with the user's Xclip process.
    @MainActor static func testApplicationQueue() throws {
        let app = XclipApplication.shared
        app.setActivationPolicy(.prohibited)
        try expect(app is XclipApplication, "isolated queue test uses the production application subclass")
        let controller = DragCancellationController.shared
        try expect(!controller.needsEvents, "isolated queue begins without a drag")
        app.postEvent(mouse(.rightMouseDown, number: 201), atStart: true)
        let normal = app.nextEvent(matching: .rightMouseDown, until: .distantPast, inMode: .default, dequeue: true)
        try expect(normal?.eventNumber == 201 && !controller.needsEvents, "ordinary right click passes through production nextEvent")
        let token = controller.begin()
        app.postEvent(mouse(.rightMouseDown, number: 202), atStart: true)
        let peek = app.nextEvent(matching: .rightMouseDown, until: .distantPast, inMode: .default, dequeue: false)
        try expect(peek?.eventNumber == 202 && !controller.isCancelled(token), "peek does not cancel or dequeue the right click")
        try expect(controller.takeEscape() == nil, "peek cannot queue an Escape")
        let actual = app.nextEvent(matching: [.rightMouseDown, .keyDown], until: .distantPast, inMode: .default, dequeue: true)
        try expect(actual?.type == .keyDown && actual?.keyCode == 53 && controller.isCancelled(token),
                   "real dequeue consumes right click and returns the Escape fetched through super")
        try expect(app.currentEvent?.type == .keyDown && app.currentEvent?.keyCode == 53,
                   "AppKit currentEvent agrees with the returned Escape")
        _ = controller.end(token)
        app.postEvent(mouse(.leftMouseUp, number: 203), atStart: true)
        app.postEvent(mouse(.rightMouseUp, number: 204), atStart: true)
        let releases = app.nextEvent(matching: [.leftMouseUp, .rightMouseUp], until: .distantPast, inMode: .default, dequeue: true)
        try expect(releases == nil && !controller.needsEvents, "cancelled physical releases are consumed without a returned drop event")

        let expiringToken = controller.begin()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: false) { _ in
            // scheduledTimer is registered on this test's main run loop.
            _ = DragCancellationController.shared.end(expiringToken)
            let followingKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
            app.postEvent(followingKey, atStart: true)
            app.postEvent(mouse(.rightMouseDown, number: 301), atStart: true)
        }
        defer { timer.invalidate() }
        let requestedKey = app.nextEvent(matching: .keyDown, until: Date().addingTimeInterval(2), inMode: .default, dequeue: true)
        try expect(requestedKey?.type == .keyDown && requestedKey?.keyCode == 9,
                   "session end during a wait cannot return a right click to a key-only caller")
        try expect(app.currentEvent?.type == .keyDown && app.currentEvent?.keyCode == 9,
                   "mask recovery still fetches the returned key through AppKit")
        let preservedRight = app.nextEvent(matching: .rightMouseDown, until: .distantPast, inMode: .default, dequeue: true)
        try expect(preservedRight?.eventNumber == 301 && !controller.needsEvents,
                   "right click fetched with an expired drag mask remains available for ordinary dispatch")
        try expect(app.nextEvent(matching: .rightMouseDown, until: .distantPast, inMode: .default, dequeue: true) == nil,
                   "mask recovery preserves the right click exactly once")
    }

    /// Calls the observation entry point while AppKit is already waiting. This
    /// verifies callback wiring and wake-up, not hardware or WindowServer routing.
    @MainActor static func testObservedMouseQueue() throws {
        let app = XclipApplication.shared
        let controller = DragCancellationController.shared
        for mode: RunLoop.Mode in [.default, .eventTracking] {
            try expect(!controller.needsEvents, "observed mouse test starts idle")
            let token = controller.begin()
            var callbackFired = false
            var callbackConsumed = false
            let timer = Timer(timeInterval: 0.02, repeats: false) { _ in
                callbackFired = true
                callbackConsumed = DragCancellationController.shared.consumeObservedMouseEvent(mouse(.rightMouseDown, number: 401), token: token)
            }
            RunLoop.main.add(timer, forMode: mode)
            let actual = app.nextEvent(matching: .keyDown, until: Date().addingTimeInterval(2), inMode: mode, dequeue: true)
            timer.invalidate()
            try expect(callbackFired && callbackConsumed, "observed right down reaches the current controller while nextEvent waits")
            try expect(actual?.type == .keyDown && actual?.keyCode == 53,
                       "observed right down immediately wakes a key-only nextEvent with Escape")
            try expect(app.currentEvent?.type == .keyDown && app.currentEvent?.keyCode == 53,
                       "observed cancellation still retrieves Escape through AppKit")
            try expect(controller.isCancelled(token) && !controller.canBeginDrag,
                       "observed cancellation remains guarded without any left-up event")
            try expect(controller.takeEscape() == nil,
                       "observed callback posts and drains its Escape request immediately")
            try expect(app.nextEvent(matching: .keyDown, until: .distantPast, inMode: mode, dequeue: true) == nil,
                       "the next queue fetch cannot produce a second cancellation Escape")
            try expect(controller.consumeObservedMouseEvent(mouse(.rightMouseDown, number: 402), token: token),
                       "duplicate observed right down remains part of the cancelled gesture")
            try expect(app.nextEvent(matching: .keyDown, until: .distantPast, inMode: mode, dequeue: true) == nil,
                       "duplicate observed right down does not post another Escape")
            try expect(controller.end(token), "native completion retains the observed cancellation reason")
            // Cleanup occurs only after all no-left-up assertions; no release is
            // posted to AppKit to trigger the cancellation under test.
            try expect(controller.consume(mouse(.rightMouseUp)) && controller.consume(mouse(.leftMouseUp)),
                       "physical release cleanup restores the observed gesture")
            try expect(!controller.needsEvents && controller.canBeginDrag, "observed gesture returns to idle")
        }

        let old = controller.begin()
        try expect(!controller.end(old), "old observation ends normally")
        let current = controller.begin()
        try expect(current != old, "replacement drag gets a distinct observation token")
        try expect(!controller.consumeObservedMouseEvent(mouse(.rightMouseDown, number: 403), token: old),
                   "late right-down callback for an old observer cannot cancel the replacement drag")
        try expect(!controller.consumeObservedMouseEvent(mouse(.leftMouseUp, number: 404), token: old),
                   "late release callback for an old observer cannot affect the replacement drag")
        try expect(!controller.isCancelled(current) && controller.canBeginDrag && controller.needsEvents,
                   "stale observation callbacks leave the current native drag active")
        try expect(controller.takeEscape() == nil && app.nextEvent(matching: .keyDown, until: .distantPast, inMode: .default, dequeue: true) == nil,
                   "stale observation callbacks neither request nor post Escape")
        try expect(controller.consumeObservedMouseEvent(mouse(.rightMouseDown, number: 405), token: current),
                   "the current observation token still cancels normally")
        let escape = app.nextEvent(matching: .keyDown, until: .distantPast, inMode: .default, dequeue: true)
        try expect(escape?.keyCode == 53 && controller.isCancelled(current), "current token posts the replacement drag's Escape")
        try expect(!controller.consumeObservedMouseEvent(mouse(.rightMouseUp, number: 406), token: old),
                   "old observer release cannot clear the replacement gesture's paired right-up")
        try expect(controller.end(current) && controller.consume(mouse(.leftMouseUp)) && !controller.canBeginDrag,
                   "replacement cancellation remains blocked for its own outstanding right release")
        try expect(controller.consume(mouse(.rightMouseUp)) && !controller.needsEvents,
                   "replacement gesture's own right release finishes cleanup")
    }

    @MainActor static func main() throws {
        try testIdleAndNormalDrag()
        try testCancellationAndDuplicateRightClicks()
        try testReleaseOrders()
        try testFreshLeftDownAndSwiftUI()
        try testTokensAndPendingEscape()
        try testExpiredObservationRecovery()
        try testPhysicalEscape()
        try testControllerMapping()
        if CommandLine.arguments.contains("--queue") {
            try testApplicationQueue()
            try testObservedMouseQueue()
        }
        print("Drag cancellation: \(assertions) assertions passed.\(CommandLine.arguments.contains("--queue") ? " Isolated application queue verified." : " Use --queue for optional AppKit queue verification.")")
    }
}
