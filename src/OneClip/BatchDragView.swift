import AppKit
import SwiftUI

/// Native multi-item drag session, so every file reaches Finder or the destination app.
struct BatchDragView: NSViewRepresentable {
    @ObservedObject private var appLanguage = AppLanguage.shared
    var items: [ClipboardItem]
    var title: String
    func makeNSView(context: Context) -> BatchDragControl { BatchDragControl() }
    func updateNSView(_ view: BatchDragControl, context: Context) { view.items = items; view.label = title; view.needsDisplay = true; view.setAccessibilityLabel(title) }
}
final class BatchDragControl: NSView, NSDraggingSource {
    var items: [ClipboardItem] = []
    var label = L("拖出文件", "Drag files")
    private var started = false
    override var intrinsicContentSize: NSSize { NSSize(width: 120, height: 26) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlColor.setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).fill()
        let text = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: items.isEmpty ? NSColor.disabledControlTextColor : NSColor.labelColor])
        text.draw(at: NSPoint(x: max(5, (bounds.width - text.size().width) / 2), y: (bounds.height - text.size().height) / 2))
    }
    override func mouseDown(with event: NSEvent) { started = false }
    override func mouseDragged(with event: NSEvent) {
        guard !started, !PrivacyLock.shared.locked else { return }
        var dragging: [NSDraggingItem] = []
        for item in items {
            let paths = item.fileURLs ?? item.filePath.map { [$0] } ?? []
            if !paths.isEmpty {
                for path in paths {
                    let url = URL(fileURLWithPath: path)
                    guard FileManager.default.fileExists(atPath: url.path) else { continue }
                    let drag = NSDraggingItem(pasteboardWriter: url as NSURL)
                    drag.setDraggingFrame(NSRect(x: 0, y: 0, width: 36, height: 36), contents: NSWorkspace.shared.icon(forFile: path)); dragging.append(drag)
                }
            } else {
                let drag = NSDraggingItem(pasteboardWriter: item.content as NSString)
                drag.setDraggingFrame(NSRect(x: 0, y: 0, width: 36, height: 36), contents: NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)); dragging.append(drag)
            }
        }
        guard !dragging.isEmpty else { return }
        started = true; beginDraggingSession(with: dragging, event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
