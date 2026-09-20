import AppKit

/// These windows are never displayed and these events are never posted.
private final class NativeDragTestWindow: NSWindow {
    var testVisible = true
    override var isVisible: Bool { testVisible }
}

private final class NativeDragTestTableDataSource: NSObject, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { 3 }
}

private final class NativeDragTestEvent: NSEvent {
    private let source: NSEvent
    private weak var testWindow: NSWindow?

    init(source: NSEvent, window: NSWindow) {
        self.source = source
        testWindow = window
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("Test events are not archived") }
    override var type: NSEvent.EventType { source.type }
    override var window: NSWindow? { testWindow }
    override var locationInWindow: NSPoint { source.locationInWindow }
    override var modifierFlags: NSEvent.ModifierFlags { source.modifierFlags }
    override var clickCount: Int { source.clickCount }
}

enum NativeClipboardDragTests {
    private static var checks = 0
    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw NSError(domain: "NativeClipboardDragTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1
        print("PASS native drag \(checks): \(message)")
    }

    @MainActor static func run() throws {
        checks = 0
        let window = NativeDragTestWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 350),
                                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 350))
        window.contentView = root
        let monitor = NativeClipboardDragMonitor()
        let item = ClipboardItem(id: UUID(), content: "Synthetic attachment", type: .file, timestamp: Date(), fileURLs: ["/synthetic/one", "/synthetic/two"])
        let anchor = NativeClipboardDragView(frame: NSRect(x: 20, y: 20, width: 300, height: 180))
        anchor.items = [item]
        root.addSubview(anchor)
        monitor.add(anchor)
        defer {
            monitor.remove(anchor)
            window.contentView = nil
            window.close()
        }
        var starts = 0, failures = 0, delivered: [ClipboardItem] = []
        monitor.beginDrag = { _, items, _ in starts += 1; delivered = items }
        monitor.reportError = { _ in failures += 1 }

        func event(_ type: NSEvent.EventType, x: CGFloat = 50, y: CGFloat = 50,
                   flags: NSEvent.ModifierFlags = [], clicks: Int = 1, target: NSWindow? = nil) throws -> NSEvent {
            guard let source = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: flags,
                                                  timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 0) else {
                throw ClipboardError.dataCorrupted
            }
            return NativeDragTestEvent(source: source, window: target ?? window)
        }
        func drag(x: CGFloat = 50, y: CGFloat = 50, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) throws {
            _ = monitor.handle(try event(.leftMouseDown, x: x, y: y, flags: flags, clicks: clicks))
            _ = monitor.handle(try event(.leftMouseDragged, x: x + 12, y: y, flags: flags, clicks: clicks))
        }

        try expect(anchor.hitTest(NSPoint(x: 10, y: 10)) == nil, "The background never intercepts native or SwiftUI hit testing")
        try expect(!monitor.handle(try event(.leftMouseDown)), "Mouse down remains available for List selection")
        try expect(!monitor.handle(try event(.leftMouseDragged, x: 53)), "Small pointer movement does not start a drag")
        try expect(!monitor.handle(try event(.leftMouseUp, x: 53)) && starts == 0, "An ordinary click remains intact")
        try drag()
        try expect(starts == 1 && delivered.first?.fileURLs?.count == 2, "A row delivers its complete multi-file record to the shared payload")
        try expect(!monitor.handle(try event(.leftMouseDragged, x: 90)) && starts == 1, "One gesture starts at most one native session")
        try expect(!monitor.handle(try event(.leftMouseUp)), "Mouse up remains available for existing gestures")

        try drag(clicks: 2)
        for flags: NSEvent.ModifierFlags in [.command, .control, .shift] { try drag(flags: flags) }
        try expect(starts == 1, "Double-click paste and modified selection/context clicks cannot start file drags")
        _ = monitor.handle(try event(.leftMouseDown))
        try expect(!monitor.handle(try event(.rightMouseDown)), "The right-click event remains available to the existing context menu")
        _ = monitor.handle(try event(.leftMouseDragged, x: 80))
        try expect(starts == 1, "A context click cancels a pending row drag")

        let exclusion = NativeClipboardDragView(frame: NSRect(x: 120, y: 30, width: 80, height: 70))
        exclusion.excludesDragging = true
        root.addSubview(exclusion)
        monitor.add(exclusion)
        try drag(x: 140)
        try expect(starts == 1, "Embedded SwiftUI button and selectable-text exclusion regions keep their gestures")
        try drag(x: 50)
        try expect(starts == 2, "The same row remains draggable outside an embedded control's exclusion bounds")
        monitor.remove(exclusion)
        exclusion.removeFromSuperview()

        let button = NSButton(title: "Synthetic Copy", target: nil, action: nil)
        button.frame = NSRect(x: 40, y: 40, width: 130, height: 40)
        root.addSubview(button)
        try drag()
        try expect(starts == 2, "Dragging inside a native button cannot trigger a row drag")
        button.removeFromSuperview()
        let text = NSTextField(string: "Synthetic editable text")
        text.frame = NSRect(x: 40, y: 40, width: 180, height: 40)
        root.addSubview(text)
        try drag()
        try expect(starts == 2, "An editable field keeps its caret and text-selection gestures")
        text.removeFromSuperview()

        // NSTableView inherits NSControl: treating every control ancestor as an
        // embedded button would accidentally disable every SwiftUI List row.
        let table = NSTableView(frame: root.bounds)
        let tableData = NativeDragTestTableDataSource()
        table.rowHeight = 110
        let column = NSTableColumn(identifier: .init("synthetic-row"))
        column.width = 500
        table.addTableColumn(column)
        table.dataSource = tableData
        table.reloadData()
        root.addSubview(table)
        anchor.removeFromSuperview()
        table.addSubview(anchor)
        monitor.add(anchor)
        let label = NSTextField(labelWithString: "Synthetic row title")
        label.frame = NSRect(x: 40, y: 40, width: 180, height: 40)
        table.addSubview(label)
        // Empty tables shrink themselves to their content. Give this fixture
        // actual rows/columns and a viewport before testing the row hit region.
        table.frame = root.bounds
        let tablePoint = table.convert(NSPoint(x: 50, y: 50), to: nil)
        try drag(x: tablePoint.x, y: tablePoint.y)
        try expect(starts == 3, "A static label inside an NSTableView row remains draggable")
        label.removeFromSuperview()
        anchor.removeFromSuperview()
        root.addSubview(anchor)
        monitor.add(anchor)
        table.removeFromSuperview()

        try drag(x: 350)
        anchor.isHidden = true
        try drag()
        anchor.isHidden = false
        window.testVisible = false
        try drag()
        window.testVisible = true
        try expect(starts == 3, "Off-row, hidden-row and hidden-window gestures are ignored")
        _ = monitor.handle(try event(.leftMouseDown))
        anchor.items = [ClipboardItem(id: UUID(), content: "Reused row", type: .text, timestamp: Date())]
        _ = monitor.handle(try event(.leftMouseDragged, x: 80))
        try expect(starts == 3, "A SwiftUI row reused during a gesture cannot drag another record")
        anchor.items = [item]

        let other = NativeDragTestWindow(contentRect: root.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        _ = monitor.handle(try event(.leftMouseDown))
        _ = monitor.handle(try event(.leftMouseDragged, x: 80, target: other))
        try expect(starts == 3, "A gesture cannot cross into another Xclip window")
        other.close()

        monitor.beginDrag = { _, _, _ in throw ClipboardError.dataCorrupted }
        try drag()
        _ = monitor.handle(try event(.leftMouseDragged, x: 95))
        try expect(failures == 1, "A failed preparation reports once without retrying or starting a partial drag")
        print("NativeClipboardDragTests: \(checks) checks passed; undisplayed windows, no posted events or desktop clipboard access.")
    }
}
