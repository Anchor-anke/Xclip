import AppKit

// Pin rendering tests use an isolated lock dependency; production PrivacyLock
// and its Keychain behavior are exercised separately by PrivacyLockTests.
final class PrivacyLock {
    static let shared = PrivacyLock()
    var locked = false
}

@MainActor
@main
struct PinnedImageTests {
    static var checks = 0
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        precondition((try? condition()) == true, message); checks += 1; print("PASS: \(message)")
    }
    static func fixture(width: Int = 6, height: Int = 4) -> CGImage {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let index = (y * width + x) * 4
            rgba[index] = UInt8(20 + (x * 29) % 220); rgba[index + 1] = UInt8(15 + (y * 47) % 220); rgba[index + 2] = UInt8((x + y) % 220)
        } }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(rgba) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    static func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try CaptureImageCodec.context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    static func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let data = try pixels(image), index = (y * image.width + x) * 4; return Array(data[index..<(index + 4)])
    }
    static func mouse(_ type: NSEvent.EventType, _ point: CGPoint, in view: NSView, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: flags, timestamp: 0,
            windowNumber: view.window!.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
    }
    static func key(_ code: UInt16, _ value: String = "", flags: NSEvent.ModifierFlags = [], in view: NSView) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: view.window!.windowNumber,
            context: nil, characters: value, charactersIgnoringModifiers: value, isARepeat: false, keyCode: code)!
    }
    static func scroll(_ delta: Int32, control: Bool = false) -> NSEvent {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!
        if control { event.flags = .maskControl }; return NSEvent(cgEvent: event)!
    }
    static func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    static func waitForTasks() async { for _ in 0..<20 { await Task.yield() } }

    final class VisibilityWindow: NSWindow {
        var concealed: (() -> Void)?
        override func orderOut(_ sender: Any?) { concealed?(); super.orderOut(sender) }
    }
    static func visibilityPolicy() {
        let main = VisibilityWindow(), pin = VisibilityWindow(), result = VisibilityWindow(), otherWorkflow = VisibilityWindow()
        let windows = [main, pin, result, otherWorkflow]
        windows.forEach { $0.isReleasedWhenClosed = false }
        defer { windows.forEach { $0.concealed = nil; $0.close() } }
        pin.level = .normal; result.level = .floating; otherWorkflow.level = .floating
        var events: [String] = []
        main.concealed = { events.append("main hidden") }; pin.concealed = { events.append("pin hidden") }
        result.concealed = { events.append("result hidden") }; otherWorkflow.concealed = { events.append("other hidden") }
        PinnedImagePresentation.prepare(isApplicationHidden: true, windows: windows, pins: [pin, result], unhide: { events.append("unhide") })
        require(events == ["main hidden", "other hidden", "unhide"], "A hidden app conceals its main and other workflow windows before revealing pins")
        require(!events.contains("pin hidden") && !events.contains("result hidden"), "A normal-level pin and its OCR result remain eligible to appear when unhiding")
        events.removeAll()
        PinnedImagePresentation.prepare(isApplicationHidden: false, windows: windows, pins: [pin], unhide: { events.append("unhide") })
        require(events.isEmpty, "Creating a pin while the app is visible does not hide unrelated windows or reactivate the app")
        PinnedImagePresentation.prepare(isApplicationHidden: true, windows: windows, pins: [], unhide: { events.append("unhide") })
        require(events.isEmpty, "A recovery command with no pins does not unhide the app")
        require(windows.allSatisfy { !$0.isVisible }, "Visibility policy tests keep every synthetic window hidden and never unhide NSApplication")
    }

    static func imageOperations() throws {
        let original = fixture(), originalPixels = try pixels(original), data = try CaptureImageCodec.png(original)
        let model = try PinnedImageModel(content: .init(originalData: data))
        try model.rotate(clockwise: true)
        require(model.image.width == 4 && model.image.height == 6, "A quarter-turn swaps image dimensions")
        for y in 0..<4 { for x in 0..<6 {
            require(try pixel(model.image, x: 3 - y, y: x) == pixel(original, x: x, y: y), "Clockwise rotation preserves source pixel \(x),\(y)")
        } }
        try model.rotate(clockwise: false)
        require(try pixels(model.image) == originalPixels, "Opposite rotations restore exact original pixels")
        try model.flip(horizontal: true)
        require(try pixel(model.image, x: 5, y: 0) == pixel(original, x: 0, y: 0), "Horizontal flip places the leftmost source pixel on the right")
        try model.flip(horizontal: false)
        require(try pixel(model.image, x: 5, y: 3) == pixel(original, x: 0, y: 0), "Vertical flip moves the image around its horizontal centerline")
        model.resetImage()
        require(try pixels(model.image) == originalPixels, "Reset restores the original after combined transforms")
        model.setScale(0.5); model.setOpacity(0.5)
        let current = try CaptureImageCodec.decode(model.currentData())
        require(current.width == 3 && current.height == 2, "Current-image export uses displayed scale")
        let currentAlpha = try pixel(current, x: 0, y: 0)[3]
        require(currentAlpha >= 127 && currentAlpha <= 128, "Current-image export includes the selected opacity")
        require(try pixels(CaptureImageCodec.decode(model.content.originalData)) == originalPixels, "Original-image export remains at source resolution without processing")
        model.toggleOriginalSize()
        require(model.scale == 1 && model.opacity == 1, "Middle-click reset restores original size and full opacity")
        model.toggleOriginalSize()
        require(model.scale == 0.5 && model.opacity == 0.5, "A second middle-click restores the previous zoom and opacity")
        model.setScale(1); model.setOpacity(1); model.setCrop(CGRect(x: 1, y: 1, width: 3, height: 2))
        let cropped = try CaptureImageCodec.decode(model.currentData())
        require(cropped.width == 3 && cropped.height == 2, "Thumbnail export contains only its displayed source region")
        require(try pixel(cropped, x: 0, y: 0) == pixel(original, x: 1, y: 1), "Thumbnail export retains the correct crop origin")
        model.toggleThumbnail(); require(!model.thumbnail && model.visibleRect == model.imageBounds, "Leaving thumbnail mode restores the full image")
        model.toggleThumbnail(); require(model.visibleRect == CGRect(x: 1, y: 1, width: 3, height: 2), "Re-entering thumbnail mode restores the remembered crop")
        model.panCrop(by: CGSize(width: 100, height: -100))
        require(model.visibleRect == CGRect(x: 3, y: 0, width: 3, height: 2), "Thumbnail panning clamps the entire crop inside source pixels")
        model.locked = true; model.setScale(3); model.setOpacity(0.2); model.toggleThumbnail(); try model.rotate(clockwise: true)
        require(model.scale == 1 && model.opacity == 1 && model.thumbnail && model.image.width == 6, "Lock prevents zoom, opacity, thumbnail and rotation changes")
        model.locked = false; model.setScale(.infinity); model.setOpacity(.nan)
        require(model.scale == 1 && model.opacity == 1, "Non-finite zoom and opacity values are ignored")
    }

    static func clipboardContent(_ board: NSPasteboard) throws {
        board.clearContents(); board.setString("#28A4E2", forType: .string)
        let color = try PinnedImageContent.clipboard(board)
        require(color.kind == .color && color.text == "#28A4E2", "A clipboard HEX color becomes a color pin with its original code")
        let colorImage = try CaptureImageCodec.decode(color.originalData)
        let swatch = try pixel(colorImage, x: 320, y: 70)
        require(swatch[0] == 40 && swatch[1] == 164 && swatch[2] == 226, "Color pins render the actual source RGB swatch")
        board.clearContents(); board.setString("中文参考\nsecond line", forType: .string); board.setString("<b>中文参考</b>", forType: .html)
        let text = try PinnedImageContent.clipboard(board)
        require(text.kind == .text && text.text == "中文参考\nsecond line" && text.html == "<b>中文参考</b>", "Text pins preserve plain text and HTML while rendering locally")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("pin-fixture-\(UUID().uuidString).txt")
        try "fixture".write(to: temporary, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temporary) }
        board.clearContents(); board.writeObjects([temporary as NSURL])
        let file = try PinnedImageContent.clipboard(board)
        require(file.kind == .files && file.files == [temporary] && file.text == temporary.path, "File pins preserve exact local URLs and paths")
        board.clearContents()
        require((try? PinnedImageContent.clipboard(board)) == nil, "An empty clipboard reports unsupported content rather than creating a blank pin")
        require(PinnedImageRendering.parseColor("#XYZ") == nil && PinnedImageRendering.parseColor("not a color") == nil, "Ordinary text is not misclassified as a color")
    }

    static func windowInteractions(_ board: NSPasteboard, output: URL) throws {
        let controller = PinnedImageController(presentsWindows: false, pasteboard: board)
        defer { controller.closeAll() }
        let data = try CaptureImageCodec.png(fixture(width: 600, height: 400))
        let id = controller.show(data, at: CGRect(x: -5000, y: -5000, width: 300, height: 200))!
        let session = controller.sessions[id]!, canvas = session.canvas, window = session.window
        require(window.styleMask == .borderless && canvas.frame.size == window.contentView!.bounds.size, "Pinned images fill a borderless window without a white workbench frame")
        require(abs(window.frame.width / window.frame.height - 1.5) < 0.0001, "Initial pin sizing preserves source aspect ratio")
        let frame = window.frame
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 80, y: 60), in: canvas))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 100, y: 70), in: canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 100, y: 70), in: canvas))
        require(window.frame.minX == frame.minX + 20 && window.frame.minY == frame.minY - 10 && window.frame.size == frame.size, "Dragging moves a pin without changing image dimensions")
        canvas.scrollWheel(with: scroll(1))
        require(session.model.scale > 0.5 && abs(window.frame.width / window.frame.height - 1.5) < 0.0001, "Mouse wheel zoom keeps image proportions")
        let zoom = session.model.scale
        canvas.scrollWheel(with: scroll(-1, control: true))
        require(session.model.scale == zoom && session.model.opacity < 1 && window.alphaValue == session.model.opacity, "Control-wheel changes actual window opacity without changing zoom")
        canvas.keyDown(with: key(37, "l", in: canvas)); let lockedFrame = window.frame, opacity = session.model.opacity
        canvas.scrollWheel(with: scroll(1)); canvas.scrollWheel(with: scroll(-1, control: true))
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 30, y: 30), in: canvas)); canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 80, y: 60), in: canvas))
        require(session.model.locked && window.frame == lockedFrame && session.model.opacity == opacity, "L locks real mouse movement, zoom and opacity interactions")
        canvas.keyDown(with: key(37, "l", in: canvas)); canvas.keyDown(with: key(17, "t", in: canvas))
        require(!session.model.locked && window.level == .normal, "L unlocks and T switches off always-on-top")
        canvas.perform(.passthrough)
        require(window.ignoresMouseEvents, "Mouse passthrough changes the native window event behavior")
        controller.toggleAll(); controller.resetClickThrough()
        require(!window.ignoresMouseEvents && !controller.isHidden, "Global passthrough recovery restores interaction and unhides pins")
        let fullSize = window.frame.size
        canvas.perform(.thumbnail)
        require(session.model.thumbnail && window.frame.width < fullSize.width && window.frame.height < fullSize.height, "Thumbnail mode displays a smaller source crop")
        canvas.perform(.thumbnail)
        canvas.rightMouseDown(with: mouse(.rightMouseDown, CGPoint(x: 20, y: 20), in: canvas))
        canvas.rightMouseDragged(with: mouse(.rightMouseDragged, CGPoint(x: 100, y: 90), in: canvas))
        canvas.rightMouseUp(with: mouse(.rightMouseUp, CGPoint(x: 100, y: 90), in: canvas))
        require(session.model.thumbnail && session.model.visibleRect.width < session.model.imageBounds.width, "Right-button dragging creates an actual thumbnail crop")
        controller.copy(id)
        let current = try CaptureImageCodec.decode(board.data(forType: .png)!)
        require(current.width == Int(session.model.displaySize.width.rounded()), "Copy-current writes the displayed crop size to the isolated pasteboard")
        controller.copy(id, original: true)
        let original = try CaptureImageCodec.decode(board.data(forType: .png)!)
        require(original.width == 600 && original.height == 400, "Copy-original writes the full source to the isolated pasteboard")
        let menu = canvas.contextMenu()
        require(menu.items.contains(where: { $0.tag == PinnedImageCanvas.Action.resetPassthrough.rawValue }) && menu.items.contains(where: { $0.tag == PinnedImageCanvas.Action.restoreLast.rawValue }), "The pin menu provides recovery actions for closed and click-through windows")
        canvas.keyDown(with: key(53, in: canvas))
        require(controller.activeCount == 0 && controller.historyCount == 1, "Escape closes a pin into recoverable history")
        require(controller.restoreLast(), "Restore-last reopens the most recently closed pin")
        let restored = controller.sessions[id]!
        require(restored.model.thumbnail && restored.model.opacity == opacity, "Restored pins keep image processing and display state")
        restored.canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 30, y: 30), in: restored.canvas, clicks: 2))
        require(controller.activeCount == 0 && controller.historyCount == 1, "Double-click closes a pin without destroying recovery history")
        _ = controller.restoreLast()
        let currentSession = controller.sessions[id]!
        _ = currentSession.canvas.performKeyEquivalent(with: key(13, "w", flags: .command, in: currentSession.canvas))
        require(controller.activeCount == 0 && controller.historyCount == 1, "Command-W uses the same recoverable close operation")
        _ = controller.restoreLast()
        controller.sessions[id]!.model.locked = false
        controller.change(id) { $0.resetImage(); $0.setScale(0.75); $0.setOpacity(1) }
        let snapshot = controller.sessions[id]!.canvas
        snapshot.layoutSubtreeIfNeeded()
        let bitmap = snapshot.bitmapImageRepForCachingDisplay(in: snapshot.bounds)!
        snapshot.cacheDisplay(in: snapshot.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output, options: .atomic)
        require(controller.sessions.values.allSatisfy({ !$0.window.isVisible }), "All pin interaction windows remain hidden throughout testing")
        controller.closeAll()
        require(controller.activeCount == 0 && controller.historyCount == 0 && !controller.restoreLast(), "Privacy closeAll destroys both active and recoverable pins")
    }

    static func asynchronousLifetime(_ board: NSPasteboard) async throws {
        let data = try CaptureImageCodec.png(fixture(width: 100, height: 60))
        let annotated = try CaptureImageCodec.png(fixture(width: 80, height: 40))
        board.clearContents(); board.setString("unchanged clipboard", forType: .string)
        let controller = PinnedImageController(presentsWindows: false, pasteboard: board,
            recognize: { _ in "识别结果" }, annotate: { _, _ in .init(data: annotated, destination: .copy) })
        let id = controller.show(data)!
        controller.annotateImage(id); await waitForTasks()
        require(controller.sessions[id]!.model.image.width == 80 && controller.activeCount == 1, "Space annotation updates the existing pin instead of opening another pin")
        require(board.string(forType: .string) == "unchanged clipboard", "Completing pin annotation does not copy or append to clipboard history")
        controller.recognizeText(id); await waitForTasks()
        let resultWindow = controller.sessions[id]!.resultWindows.first!
        let text = descendants(resultWindow.contentView!).compactMap { $0 as? NSTextView }.first!
        require(text.string == "识别结果" && text.isEditable && !resultWindow.isVisible, "OCR presents a real editable text result in a hidden test window")
        controller.closeAll()
        require(resultWindow.contentView == nil && controller.historyCount == 0, "Privacy destruction clears recognized text windows and pin history")

        var continuation: CheckedContinuation<String, Error>?
        let delayed = PinnedImageController(presentsWindows: false, pasteboard: board, recognize: { _ in
            try await withCheckedThrowingContinuation { continuation = $0 }
        })
        let delayedID = delayed.show(data)!
        delayed.recognizeText(delayedID); await waitForTasks()
        require(continuation != nil, "Delayed OCR reaches the asynchronous recognition operation")
        delayed.closeAll(); continuation?.resume(returning: "late private result"); await waitForTasks()
        require(delayed.activeCount == 0 && delayed.historyCount == 0, "A late OCR completion cannot recreate a privacy-closed window")

        var annotationContinuation: CheckedContinuation<CaptureAnnotationResult, Error>?
        let delayedAnnotation = PinnedImageController(presentsWindows: false, pasteboard: board, annotate: { _, _ in
            try await withCheckedThrowingContinuation { annotationContinuation = $0 }
        })
        let annotationID = delayedAnnotation.show(data)!
        delayedAnnotation.annotateImage(annotationID); await waitForTasks()
        delayedAnnotation.close(annotationID)
        annotationContinuation?.resume(returning: .init(data: annotated, destination: .copy)); await waitForTasks()
        _ = delayedAnnotation.restoreLast()
        require(delayedAnnotation.sessions[annotationID]!.model.image.width == 100, "Closing during annotation preserves the old pin and rejects a late edit")
        delayedAnnotation.closeAll()
    }

    static func main() async throws {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        visibilityPolicy(); try imageOperations(); try clipboardContent(board)
        let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/private/tmp/pinned-image-test.png")
        try windowInteractions(board, output: output); try await asynchronousLifetime(board)
        print("Pinned image tests passed: \(checks) checks. Synthetic source pixels, hidden windows, isolated pasteboard, and injected async operations only.")
        print("Synthetic pinned image snapshot: \(output.path)")
    }
}
