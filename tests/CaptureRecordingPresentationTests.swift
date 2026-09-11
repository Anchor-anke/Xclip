import AppKit

/// Opt-in native presentation test; briefly shows preparation windows, never SCStream, an encoder, or a microphone.
@main
struct CaptureRecordingPresentationTests {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let main = NSWindow(contentRect: CGRect(x: 20, y: 20, width: 160, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false; main.title = "Synthetic main window"
        main.makeKeyAndOrderFront(nil)
        let controller = CaptureRecordingController()
        let screen = CGDisplayBounds(CGMainDisplayID())
        let region = CGRect(x: screen.minX + 80, y: screen.minY + 80, width: 240, height: 160)
        app.hide(nil)
        controller.start(region: region)
        guard let panel = app.windows.first(where: { $0.identifier?.rawValue == "capture-recording-controls" && $0.isVisible }) else {
            fatalError("Recording preparation must show its own identifiable window after screenshot restoration")
        }
        precondition(controller.phase == .ready && controller.isActive, "Presentation must remain ready without beginning screen capture")
        precondition(!app.isHidden, "Recording preparation unhides an application restored to its hidden state")
        precondition(!main.isVisible, "Revealing recording controls after Cmd+H must leave the main window hidden")
        precondition(panel.isKeyWindow, "The preparation panel becomes key instead of leaving Settings as the selected window")
        precondition(!panel.title.isEmpty && !panel.isExcludedFromWindowsMenu, "The native recording panel is discoverable by title and Window menu")
        main.makeKeyAndOrderFront(nil)
        controller.start(region: region)
        precondition(panel.isKeyWindow && controller.phase == .ready, "A repeated request restores the same preparation panel without recording")
        controller.cancel(); await controller.waitUntilFinished()
        precondition(!controller.isActive && !panel.isVisible, "Cancelling preparation closes its window and drains without a recording")
        main.close()
        print("CaptureRecordingPresentationTests: 7 checks passed; preparation UI only, no desktop or microphone capture.")
    }
}
