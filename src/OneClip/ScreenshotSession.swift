import Foundation

/// Coordinates one user-initiated capture. Dependencies keep lifecycle checks independent of the desktop.
@MainActor
final class ScreenshotSession<Output> {
    struct Actions {
        var isAllowed: () -> Bool
        var prepare: () throws -> Void
        var conceal: () -> Void
        var capture: () async throws -> Output
        var cancelCapture: () -> Void
        var restore: () -> Void
        var complete: (Output) -> Void
        var isCancellation: (Error) -> Bool
        var reportFailure: (Error) -> Void
    }

    private let actions: Actions
    private var task: Task<Void, Never>?
    var isActive: Bool { task != nil }

    init(actions: Actions) { self.actions = actions }

    func start() {
        guard task == nil, actions.isAllowed() else { return }
        task = Task { @MainActor in
            var concealed = false
            var outcome: Result<Output, Error>
            do {
                try Task.checkCancellation()
                guard actions.isAllowed() else { throw CancellationError() }
                // A system permission dialog must appear before the application is hidden.
                try actions.prepare()
                try Task.checkCancellation()
                guard actions.isAllowed() else { throw CancellationError() }
                actions.conceal()
                concealed = true
                let output = try await actions.capture()
                try Task.checkCancellation()
                guard actions.isAllowed() else { throw CancellationError() }
                outcome = .success(output)
            } catch { outcome = .failure(error) }

            if concealed { actions.restore() }
            // Keep the session busy until the underlying capture has fully drained.
            // This prevents a cancelled process from interfering with a subsequent capture.
            defer { task = nil }
            switch outcome {
            case .success(let output):
                if !Task.isCancelled, actions.isAllowed() { actions.complete(output) }
            case .failure(let error):
                if !Task.isCancelled, !(error is CancellationError), !actions.isCancellation(error), actions.isAllowed() {
                    actions.reportFailure(error)
                }
            }
        }
    }

    func cancel() {
        guard let task else { return }
        task.cancel()
        actions.cancelCapture()
    }

    func waitUntilFinished() async { await task?.value }
}
