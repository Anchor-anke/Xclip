import AppKit

/// All native entry points share this direct capture flow; there is no intermediate tools page.
@MainActor
final class ScreenshotCoordinator {
    static let shared = ScreenshotCoordinator()
    private var presentation: ScreenshotPresentation?
    private var requestedAction: CaptureWorkflowAction?
    private lazy var session = ScreenshotSession<CaptureAnnotationResult>(actions: .init(
        isAllowed: { !PrivacyLock.shared.locked },
        prepare: { try CaptureService.shared.prepareForCapture() },
        conceal: { [weak self] in
            self?.presentation = ScreenshotPresentation()
            NSApp.hide(nil)
        },
        capture: { [weak self] in
            try await CaptureCountdown.shared.wait(seconds: CapturePreferences.shared.delay) { self?.cancel() }
            try await Task.sleep(nanoseconds: 250_000_000)
            return try await CaptureService.shared.captureAndAnnotate(mode: CapturePreferences.shared.smartSelection ? .window : .region, action: self?.requestedAction)
        },
        cancelCapture: { CaptureService.shared.cancel() },
        restore: { [weak self] in
            self?.presentation?.restore(locked: PrivacyLock.shared.locked)
            self?.presentation = nil
        },
        complete: { CaptureWorkflowCoordinator.shared.handle($0) },
        isCancellation: { if case CaptureToolError.cancelled = $0 { return true }; return false },
        reportFailure: { Self.showFailure($0) }
    ))

    var isCapturing: Bool { session.isActive || CaptureWorkflowCoordinator.shared.isLive }
    func start(action: CaptureWorkflowAction? = nil) {
        guard !PrivacyLock.shared.locked else { return }
        if CaptureWorkflowCoordinator.shared.toggleLive() { return }
        guard !session.isActive else { return }
        requestedAction = action; session.start()
    }
    func cancel() { session.cancel(); CaptureWorkflowCoordinator.shared.cancelAll() }

    private static func showFailure(_ error: Error) {
        WorkflowState.shared.status = error.localizedDescription
        let alert = NSAlert()
        alert.messageText = L("截屏暂不可用", "Screenshot unavailable")
        alert.informativeText = error.localizedDescription
        let permissionIssue: Bool
        switch error {
        case CaptureToolError.permissionDenied, CaptureToolError.permissionRestartRequired: permissionIssue = true
        default: permissionIssue = false
        }
        if permissionIssue {
            alert.informativeText += "\n\n" + L("当前应用：", "Current app: ") + Bundle.main.bundleURL.path
            alert.addButton(withTitle: L("打开屏幕录制设置", "Open Screen Recording settings"))
            alert.addButton(withTitle: L("显示当前应用", "Reveal current app"))
        }
        alert.addButton(withTitle: L("关闭", "Close"))
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if permissionIssue, response == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        } else if permissionIssue, response == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
    }
}

/// Preserve the previous foreground application without reopening Xclip's main window.
@MainActor
private final class ScreenshotPresentation {
    private let wasHidden = NSApp.isHidden
    private let wasActive = NSApp.isActive
    private let previousApplication = NSWorkspace.shared.frontmostApplication
    private weak var previousKeyWindow: NSWindow? = NSApp.keyWindow

    func restore(locked: Bool) {
        let stillActive = NSApp.isActive
        if wasHidden || locked { NSApp.hide(nil) }
        else { NSApp.unhideWithoutActivation() }
        guard stillActive else { return } // Respect a deliberate switch to another application.
        if wasActive, !locked {
            previousKeyWindow?.makeKeyAndOrderFront(nil)
        } else if let previousApplication, previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  !previousApplication.isTerminated {
            previousApplication.activate(options: [])
        }
    }
}
