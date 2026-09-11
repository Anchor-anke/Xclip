import Foundation

/// Exercises only injected lifecycle actions. No screen capture, windows, shortcuts, or user data.
@main
@MainActor
struct ScreenshotSessionTests {
    enum Output: Equatable {
        case copy(Data)
        case saved(Data, URL)
    }

    enum Failure: Error, Equatable { case permission, capture, userCancelled }

    @MainActor
    final class Fixture {
        var events: [String] = []
        var allowed = true
        var allowedChecks = 0
        var prepareFailure: Failure?
        var lockDuringPrepare = false
        var lockDuringRestore = false
        var outputs: [Output] = []
        var failures: [Error] = []
        var activeAtRestore: [Bool] = []
        var activeAtComplete: [Bool] = []
        var captureCount = 0
        private var continuation: CheckedContinuation<Output, Error>?
        private var startedWaiter: CheckedContinuation<Void, Never>?
        var session: ScreenshotSession<Output>!

        init() {
            session = ScreenshotSession(actions: .init(
                isAllowed: { [unowned self] in
                    allowedChecks += 1
                    return allowed
                },
                prepare: { [unowned self] in
                    events.append("prepare")
                    if lockDuringPrepare { allowed = false }
                    if let prepareFailure { throw prepareFailure }
                },
                conceal: { [unowned self] in events.append("conceal") },
                capture: { [unowned self] in
                    events.append("capture")
                    captureCount += 1
                    return try await withCheckedThrowingContinuation { continuation in
                        self.continuation = continuation
                        startedWaiter?.resume()
                        startedWaiter = nil
                    }
                },
                cancelCapture: { [unowned self] in events.append("cancel") },
                restore: { [unowned self] in
                    events.append("restore")
                    activeAtRestore.append(session.isActive)
                    if lockDuringRestore { allowed = false }
                },
                complete: { [unowned self] output in
                    events.append("complete")
                    activeAtComplete.append(session.isActive)
                    outputs.append(output)
                },
                isCancellation: { ($0 as? Failure) == .userCancelled },
                reportFailure: { [unowned self] error in
                    events.append("failure")
                    failures.append(error)
                }
            ))
        }

        func waitForCapture() async {
            if continuation != nil { return }
            await withCheckedContinuation { startedWaiter = $0 }
        }

        func resolve(_ result: Result<Output, Error>) {
            precondition(continuation != nil, "A capture must start before resolving it")
            let pending = continuation
            continuation = nil
            pending?.resume(with: result)
        }
    }

    static var checks = 0
    static let copy = Output.copy(Data([12, 34, 56, 78]))

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
        print("PASS: \(message)")
    }

    static func idleAndLockedTests() async {
        let fixture = Fixture()
        require(fixture.events.isEmpty && fixture.allowedChecks == 0, "Construction has no permission, capture, or visibility side effects")
        require(!fixture.session.isActive, "A new session is idle")
        fixture.session.cancel()
        await fixture.session.waitUntilFinished()
        require(fixture.events.isEmpty, "Cancelling and awaiting an idle session are harmless")
        fixture.allowed = false
        fixture.session.start()
        await fixture.session.waitUntilFinished()
        require(!fixture.session.isActive, "A locked session refuses to start")
        require(fixture.events.isEmpty, "A locked start does not request permission or hide the app")
        require(fixture.outputs.isEmpty && fixture.failures.isEmpty, "A locked start produces no output or failure alert")
    }

    static func successTests() async {
        let fixture = Fixture()
        fixture.session.start()
        require(fixture.session.isActive, "Starting marks the session busy synchronously")
        await fixture.waitForCapture()
        require(fixture.events == ["prepare", "conceal", "capture"], "Permission preparation precedes hiding and capture")
        require(fixture.outputs.isEmpty && fixture.failures.isEmpty, "An unfinished capture publishes no result")
        fixture.session.start()
        fixture.session.start()
        require(fixture.captureCount == 1, "Repeated triggers during capture do not start another capture")
        fixture.resolve(.success(copy))
        await fixture.session.waitUntilFinished()
        require(fixture.events == ["prepare", "conceal", "capture", "restore", "complete"], "Successful capture restores presentation before publishing output")
        require(fixture.outputs == [copy], "Copy output bytes and destination pass through unchanged exactly once")
        require(fixture.failures.isEmpty, "Successful capture does not report failure")
        require(fixture.activeAtRestore == [true] && fixture.activeAtComplete == [true], "The session remains busy through restore and completion callbacks")
        require(!fixture.session.isActive, "Completion releases the busy state")

        let saved = Output.saved(Data([90, 80, 70]), URL(fileURLWithPath: "/synthetic/screenshot.png"))
        fixture.session.start()
        await fixture.waitForCapture()
        fixture.resolve(.success(saved))
        await fixture.session.waitUntilFinished()
        require(fixture.captureCount == 2, "A completed session accepts a subsequent capture")
        require(fixture.outputs == [copy, saved], "Saved output retains its bytes and URL without becoming a copy")
        require(fixture.events.filter { $0 == "restore" }.count == 2, "Each successful capture restores presentation once")
    }

    static func failureTests() async {
        let fixture = Fixture()
        fixture.session.start()
        await fixture.waitForCapture()
        fixture.resolve(.failure(Failure.capture))
        await fixture.session.waitUntilFinished()
        require(fixture.events == ["prepare", "conceal", "capture", "restore", "failure"], "Capture failure restores presentation before reporting the error")
        require(fixture.failures.count == 1 && fixture.failures.first as? Failure == .capture, "The original capture failure is reported exactly once")
        require(fixture.outputs.isEmpty && !fixture.session.isActive, "Capture failure publishes no image and returns to idle")

        let denied = Fixture()
        denied.prepareFailure = .permission
        denied.session.start()
        await denied.session.waitUntilFinished()
        require(denied.events == ["prepare", "failure"], "Permission failure never hides, captures, or restores an unhidden app")
        require(denied.failures.count == 1 && denied.failures.first as? Failure == .permission, "Permission failure is reported unchanged")
        require(denied.outputs.isEmpty && !denied.session.isActive, "Permission failure clears busy state without output")
    }

    static func cancellationTests() async {
        let fixture = Fixture()
        fixture.session.start()
        await fixture.waitForCapture()
        fixture.session.cancel()
        require(fixture.events.last == "cancel", "Cancellation immediately calls the underlying capture cancellation action")
        require(fixture.session.isActive, "Cancellation stays busy while the underlying capture is draining")
        fixture.session.start()
        require(fixture.captureCount == 1, "A new trigger cannot overlap a cancelled capture that is still draining")
        require(!fixture.events.contains("restore"), "Presentation is not restored before the cancelled capture drains")
        fixture.resolve(.success(copy))
        await fixture.session.waitUntilFinished()
        require(fixture.outputs.isEmpty, "A late successful result after cancellation is discarded")
        require(fixture.failures.isEmpty, "Cancellation does not display an error")
        require(fixture.events == ["prepare", "conceal", "capture", "cancel", "restore"], "Cancelled capture restores presentation exactly once after draining")
        require(!fixture.session.isActive, "A drained cancelled capture releases busy state")

        fixture.session.start()
        await fixture.waitForCapture()
        fixture.resolve(.success(copy))
        await fixture.session.waitUntilFinished()
        require(fixture.captureCount == 2 && fixture.outputs == [copy], "A fresh capture succeeds after the cancelled session drains")

        let lateFailure = Fixture()
        lateFailure.session.start()
        await lateFailure.waitForCapture()
        lateFailure.session.cancel()
        lateFailure.resolve(.failure(Failure.capture))
        await lateFailure.session.waitUntilFinished()
        require(lateFailure.failures.isEmpty && lateFailure.outputs.isEmpty, "A late capture error after cancellation is suppressed")
        require(lateFailure.events.last == "restore" && !lateFailure.session.isActive, "A late error still restores presentation and clears busy state")

        for error: Error in [CancellationError(), Failure.userCancelled] {
            let cancelledByCapture = Fixture()
            cancelledByCapture.session.start()
            await cancelledByCapture.waitForCapture()
            cancelledByCapture.resolve(.failure(error))
            await cancelledByCapture.session.waitUntilFinished()
            require(cancelledByCapture.failures.isEmpty && cancelledByCapture.outputs.isEmpty,
                    "Capture cancellation \(type(of: error)) is silent without an external cancel call")
            require(cancelledByCapture.events == ["prepare", "conceal", "capture", "restore"] && !cancelledByCapture.session.isActive,
                    "Capture cancellation \(type(of: error)) restores presentation and returns to idle")
        }
    }

    static func lockingAndSchedulingTests() async {
        let immediateCancel = Fixture()
        immediateCancel.session.start()
        immediateCancel.session.cancel()
        await immediateCancel.session.waitUntilFinished()
        require(immediateCancel.events == ["cancel"], "Cancellation before task scheduling does not open a permission prompt")
        require(!immediateCancel.session.isActive && immediateCancel.failures.isEmpty, "Cancellation before task scheduling returns quietly to idle")

        let immediateLock = Fixture()
        immediateLock.session.start()
        immediateLock.allowed = false
        await immediateLock.session.waitUntilFinished()
        require(immediateLock.events.isEmpty, "Locking before task scheduling prevents permission preparation")
        require(!immediateLock.session.isActive, "Locking before task scheduling clears busy state")

        let permissionLock = Fixture()
        permissionLock.lockDuringPrepare = true
        permissionLock.session.start()
        await permissionLock.session.waitUntilFinished()
        require(permissionLock.events == ["prepare"], "Locking during permission preparation prevents hiding and capture")
        require(permissionLock.outputs.isEmpty && permissionLock.failures.isEmpty && !permissionLock.session.isActive,
                "Locking during permission preparation produces no output or alert")

        let pendingLock = Fixture()
        pendingLock.session.start()
        await pendingLock.waitForCapture()
        pendingLock.allowed = false
        pendingLock.resolve(.success(copy))
        await pendingLock.session.waitUntilFinished()
        require(pendingLock.outputs.isEmpty && pendingLock.failures.isEmpty, "Locking while capture awaits suppresses a later successful image")
        require(pendingLock.events.last == "restore" && !pendingLock.session.isActive, "Locking during capture still drains and restores presentation")

        let failureLock = Fixture()
        failureLock.session.start()
        await failureLock.waitForCapture()
        failureLock.allowed = false
        failureLock.resolve(.failure(Failure.capture))
        await failureLock.session.waitUntilFinished()
        require(failureLock.failures.isEmpty && failureLock.outputs.isEmpty, "Locking during capture suppresses a late failure alert")
        require(failureLock.events.last == "restore" && !failureLock.session.isActive, "A locked late failure releases the session after restoring")

        let restoreLock = Fixture()
        restoreLock.lockDuringRestore = true
        restoreLock.session.start()
        await restoreLock.waitForCapture()
        restoreLock.resolve(.success(copy))
        await restoreLock.session.waitUntilFinished()
        require(restoreLock.outputs.isEmpty && restoreLock.failures.isEmpty, "Locking during presentation restoration prevents result publication")
        require(!restoreLock.session.isActive, "A lock during presentation restoration leaves no stuck session")
    }

    static func main() async {
        await idleAndLockedTests()
        await successTests()
        await failureTests()
        await cancellationTests()
        await lockingAndSchedulingTests()
        print("ScreenshotSessionTests: \(checks) checks passed")
    }
}
