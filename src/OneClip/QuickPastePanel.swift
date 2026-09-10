import AppKit
import SwiftUI
import QuartzCore

/// Keeps the native drag source alive while the tray gets out of the drop target's way.
final class QuickPastePanelController: NSObject, NSWindowDelegate {
    private(set) var panel: NSPanel?
    private(set) var isDragging = false
    private(set) var isPresented = false
    private var generation = 0
    private var restingFrame = NSRect.zero
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private(set) var editorWindow: NSWindow?
    private(set) var isContextMenuOpen = false
    private var editorClosed: (() -> Void)?
    private var editingItem: ClipboardItem?
    private var languageObserver: NSObjectProtocol?

    override init() {
        super.init()
        languageObserver = NotificationCenter.default.addObserver(forName: AppLanguage.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.refreshWindowTitles()
        }
    }

    private func refreshWindowTitles() {
        panel?.title = L("快速粘贴", "Quick paste")
        if let editingItem { editorWindow?.title = ClipboardEditing.title(for: editingItem) }
    }

    static func frame(in screen: NSRect) -> NSRect {
        let width = min(1440, max(0, screen.width - 32))
        let height = min(330, max(0, screen.height - 24))
        return NSRect(x: screen.midX - width / 2, y: screen.minY + min(12, screen.height / 2), width: width, height: height)
    }

    func toggle(onOpen: @escaping () -> Void) {
        guard !PrivacyLock.shared.locked, !isDragging else { return }
        if let editorWindow { editorWindow.makeKeyAndOrderFront(nil); return }
        if isPresented, panel?.isVisible == true { dismiss(); return }
        let window: NSPanel
        if let panel { window = panel }
        else {
            window = QuickPastePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = L("快速粘贴", "Quick paste")
            window.identifier = .init("quick-paste")
            window.isReleasedWhenClosed = false
            window.isOpaque = false; window.backgroundColor = .clear
            window.hasShadow = true; window.level = .floating
            window.hidesOnDeactivate = false; window.isMovableByWindowBackground = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.animationBehavior = .none
            panel = window
        }
        window.contentView = QuickPasteSurface(rootView: QuickPasteView(
            onOpen: { [weak self] in self?.dismissImmediately(); onOpen() },
            onClose: { [weak self] in self?.dismiss() },
            onDragBegan: { [weak self] in self?.beginDrag() },
            onDragEnded: { [weak self] success in self?.endDrag(success) },
            onEdit: { [weak self] item, closed in self?.showEditor(item, onClose: closed) },
            onContextMenuTrackingChanged: { [weak self] active in self?.isContextMenuOpen = active }
        ))
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        restingFrame = Self.frame(in: screen.visibleFrame)
        isPresented = true
        installMonitors()
        reveal()
    }

    func beginDrag() {
        guard isPresented, !isDragging, editorWindow == nil, !PrivacyLock.shared.locked else { return }
        isDragging = true
        panel?.ignoresMouseEvents = true
        conceal(forDrag: true)
    }

    func endDrag(_ success: Bool) {
        guard isDragging else { return }
        isDragging = false
        guard isPresented, !PrivacyLock.shared.locked else { dismissImmediately(); return }
        if success { dismissImmediately() }
        else { panel?.ignoresMouseEvents = false; reveal() }
    }

    func dismiss() {
        guard !isDragging, !isContextMenuOpen, editorWindow == nil else { return }
        isPresented = false
        removeMonitors()
        conceal(forDrag: false)
    }

    func dismissImmediately() {
        generation += 1
        isPresented = false
        isContextMenuOpen = false
        editorWindow?.close()
        // Retain the window/hosting view until AppKit has delivered the drag completion.
        panel?.orderOut(nil)
        panel?.alphaValue = 1
        panel?.ignoresMouseEvents = false
        removeMonitors()
    }

    func showEditor(_ item: ClipboardItem, onClose: @escaping () -> Void) {
        guard !PrivacyLock.shared.locked, isPresented, let panel else { onClose(); return }
        if let editorWindow { editorWindow.makeKeyAndOrderFront(nil); onClose(); return }
        let editor = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 570),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        editor.isReleasedWhenClosed = false
        editor.title = ClipboardEditing.title(for: item)
        editor.identifier = .init("quick-paste-editor")
        editor.minSize = NSSize(width: 660, height: 530)
        editor.contentView = NSHostingView(rootView: ClipEditor(item: item, onClose: { [weak self] in self?.editorWindow?.close() }))
        editor.delegate = self
        editorClosed = onClose
        editingItem = item
        editorWindow = editor
        if let visible = panel.screen?.visibleFrame {
            editor.setFrameOrigin(NSPoint(x: visible.midX - editor.frame.width / 2, y: visible.midY - editor.frame.height / 2))
        } else { editor.center() }
        panel.addChildWindow(editor, ordered: .above)
        editor.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === editorWindow else { return }
        panel?.removeChildWindow(closing)
        editorWindow = nil
        editingItem = nil
        let closed = editorClosed
        editorClosed = nil
        closed?()
        if isPresented, !PrivacyLock.shared.locked { panel?.makeKeyAndOrderFront(nil) }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private func reveal() {
        guard let panel else { return }
        generation += 1
        let token = generation
        panel.setFrame(restingFrame.offsetBy(dx: 0, dy: reduceMotion ? 0 : -20), display: false)
        panel.alphaValue = 0
        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.1 : 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(restingFrame, display: true)
        } completionHandler: { [weak self] in
            guard let self, self.generation == token, self.isPresented, !self.isDragging else { return }
            panel.alphaValue = 1
        }
    }

    private func conceal(forDrag: Bool) {
        guard let panel else { return }
        generation += 1
        let token = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.08 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(restingFrame.offsetBy(dx: 0, dy: reduceMotion ? 0 : -28), display: true)
        } completionHandler: { [weak self] in
            guard let self, self.generation == token else { return }
            // Ordering out doesn't release the content or interrupt the system drag session.
            panel.orderOut(nil)
            if !forDrag { panel.alphaValue = 1 }
        }
    }

    private func installMonitors() {
        removeMonitors()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.isDragging, !self.isContextMenuOpen, self.editorWindow == nil else { return }
            self.dismiss()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, !self.isDragging, !self.isContextMenuOpen, self.editorWindow == nil,
               event.window !== self.panel { self.dismiss() }
            return event
        }
    }
    private func removeMonitors() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }; outsideMonitor = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
    }
    deinit {
        removeMonitors()
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
    }
}

private final class QuickPastePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
