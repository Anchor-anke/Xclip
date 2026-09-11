import AppKit

@MainActor
@main
struct CaptureScrollingTests {
    static var checks = 0
    static let region = CGRect(x: 100, y: 100, width: 64, height: 64)
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) {
        precondition((try? value()) == true, message); checks += 1; print("PASS: \(message)")
    }
    static func rejects(_ message: String, _ action: () throws -> Void) {
        do { try action(); preconditionFailure(message) } catch { checks += 1; print("PASS: \(message)") }
    }
    static func fixture(width: Int = 128, height: Int = 128, periodic: Bool = false) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let yy = periodic ? y % 8 : y, i = (y * width + x) * 4
            bytes[i] = UInt8((x * 29 + yy * yy * 13 + yy * 47) % 255)
            bytes[i + 1] = UInt8((x * 7 + yy * 83 + yy * yy * 3) % 255)
            bytes[i + 2] = UInt8((x * 59 + yy * 31) % 255)
        } }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    static func crop(_ image: CGImage, x: Int = 0, y: Int = 0, width: Int = 64, height: Int = 64) -> CGImage {
        image.cropping(to: CGRect(x: x, y: y, width: width, height: height))!
    }
    static func wait(_ condition: @escaping () -> Bool) async {
        for _ in 0..<3000 { if condition() { return }; await Task.yield() }
        preconditionFailure("Async fixture did not reach its expected state")
    }
    static func geometry() throws {
        let display = CGRect(x: -1440, y: 80, width: 1440, height: 900)
        let selected = CGRect(x: -1400, y: 100, width: 640, height: 480)
        let one = try CaptureLiveGeometry(region: selected, display: display, scale: 1)
        require(one.width == 640 && one.height == 480 && one.sourceRect.origin == CGPoint(x: 40, y: 20), "Non-primary display coordinates stay relative to that display")
        let retina = try CaptureLiveGeometry(region: selected, display: display, scale: 2)
        require(retina.width == 1280 && retina.height == 960 && retina.sourceRect == one.sourceRect, "Retina capture retains 2× source pixels without changing the selected points")
        let fractional = try CaptureLiveGeometry(region: CGRect(x: 0.25, y: 0.75, width: 10, height: 12), display: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2)
        require(fractional.width == 21 && fractional.height == 25 && fractional.sourceRect == CGRect(x: 0, y: 0.5, width: 10.5, height: 12.5), "Fractional selections align outward to source-pixel boundaries")
        rejects("Cross-display selections are rejected") { _ = try CaptureLiveGeometry(region: CGRect(x: -20, y: 0, width: 50, height: 40), display: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2) }
        rejects("Invalid pixel scales are rejected") { _ = try CaptureLiveGeometry(region: region, display: CGRect(x: 0, y: 0, width: 1000, height: 1000), scale: .nan) }
        rejects("Oversized sample dimensions are rejected before allocation") { _ = try CaptureLiveGeometry(region: CGRect(x: 0, y: 0, width: 5000, height: 5000), display: CGRect(x: 0, y: 0, width: 6000, height: 6000), scale: 2) }
        func window(_ pid: Int32, _ id: UInt32, _ frame: CGRect) -> [String: Any] {
            [kCGWindowOwnerPID as String: pid, kCGWindowNumber as String: id, kCGWindowLayer as String: 0,
             kCGWindowBounds as String: frame.dictionaryRepresentation, kCGWindowAlpha as String: 1.0]
        }
        let underlying = window(31337, 42, CGRect(x: 50, y: 50, width: 400, height: 400))
        let own = window(10, 11, region)
        require(CaptureScrollEnvironment.target(in: [own, underlying], region: region, excluding: 10)?.windowID == 42, "Own screenshot UI is excluded when identifying the original target")
        let occluder = window(99, 98, CGRect(x: 100, y: 100, width: 10, height: 10))
        require(CaptureScrollEnvironment.target(in: [occluder, underlying], region: region, excluding: 10) == nil, "A window covering only a crop corner blocks capture rather than redirecting the target")
        let outside = window(99, 98, CGRect(x: 800, y: 800, width: 100, height: 100))
        require(CaptureScrollEnvironment.target(in: [outside, underlying], region: region, excluding: 10)?.processID == 31337, "Windows wholly outside the selected crop do not disturb target identification")
    }
    static func documents() throws {
        let source = fixture(), first = crop(source), second = crop(source, y: 24), third = crop(source, y: 48)
        let document = try CaptureScrollDocument(image: first, direction: .vertical)
        require(try document.append(second), "Vertical scrolling finds a genuine 40-pixel overlap")
        require(document.canvas.width == 64 && document.canvas.height == 88, "Vertical join adds exactly the newly exposed source pixels")
        require(try CaptureScrollDocument.identical(document.canvas, crop(source, height: 88)), "Vertical join matches the original page at every pixel")
        require(try !document.append(second) && document.count == 2, "Repeated stationary frames do not grow the document or history")
        require(try document.append(third), "A second forward scroll is matched against the previous viewport")
        require(try CaptureScrollDocument.identical(document.canvas, crop(source, height: 112)), "Multiple joins preserve full source pixels")
        try document.undo()
        require(try document.count == 2 && CaptureScrollDocument.identical(document.canvas, crop(source, height: 88)), "Undo removes only the most recent joined extent")
        try document.undo()
        require(try document.count == 1 && !document.canUndo && CaptureScrollDocument.identical(document.previous, first), "Undo returns both the canvas and matching frame to the initial state")
        try document.append(second)
        require(document.count == 2, "The same viewport can be joined again after undo")
        let horizontal = try CaptureScrollDocument(image: first, direction: .horizontal)
        try horizontal.append(crop(source, x: 24)); try horizontal.append(crop(source, x: 48))
        require(horizontal.canvas.width == 112 && horizontal.canvas.height == 64, "Horizontal scrolling changes width and preserves height")
        require(try CaptureScrollDocument.identical(horizontal.canvas, crop(source, width: 112)), "Horizontal joins preserve the original left-to-right pixel order")
        try horizontal.undo()
        require(try CaptureScrollDocument.identical(horizontal.canvas, crop(source, width: 88)), "Horizontal undo removes the rightmost appended extent")
        rejects("A mismatched pixel scale cannot be stitched") { _ = try document.append(crop(source, width: 128, height: 128)) }
        let unrelated = fixture(width: 64, height: 64).copy(colorSpace: CGColorSpaceCreateDeviceRGB())!
        rejects("An unrelated position with no forward overlap is rejected") { _ = try document.append(unrelated) }
        require(document.count == 2 && document.canvas.height == 88, "A rejected match leaves the document unchanged")
        let stripes = fixture(width: 64, height: 80, periodic: true)
        let repeated = try CaptureScrollDocument(image: crop(stripes), direction: .vertical)
        rejects("Ambiguous repeated page patterns require explicit overlap") { _ = try repeated.append(crop(stripes, y: 5)) }
        require(try repeated.append(crop(stripes, y: 5), overlap: 59), "Manual overlap allows an informed correction of an ambiguous page")
        let flatContext = try CaptureImageCodec.context(width: 64, height: 64)
        flatContext.setFillColor(NSColor.white.cgColor); flatContext.fill(CGRect(x: 0, y: 0, width: 64, height: 64)); let flat = flatContext.makeImage()!
        flatContext.setFillColor(NSColor.lightGray.cgColor); flatContext.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let flatDoc = try CaptureScrollDocument(image: flat, direction: .vertical)
        rejects("A plain background cannot establish an overlap") { _ = try flatDoc.append(flatContext.makeImage()!) }
        require(try !CaptureScrollDocument.identical(first, second), "Different crops sharing a provider are compared by visible pixels")
        let singlePixel = try CaptureImageCodec.context(width: 64, height: 64)
        singlePixel.draw(first, in: CGRect(x: 0, y: 0, width: 64, height: 64)); singlePixel.setFillColor(NSColor.magenta.cgColor)
        singlePixel.fill(CGRect(x: 31, y: 29, width: 1, height: 1))
        require(try !CaptureScrollDocument.identical(first, singlePixel.makeImage()!), "Duplicate detection retains one-pixel changes instead of using a thumbnail hash")
        let limited = try CaptureScrollDocument(image: first, direction: .vertical, maximumPixels: 64 * 88)
        try limited.append(second)
        require(limited.canvas.height == 88, "The exact pixel budget boundary is accepted")
        rejects("A join over the pixel budget is rejected before growing the canvas") { _ = try limited.append(third) }
        require(limited.count == 2 && limited.canvas.height == 88, "A pixel-budget error retains the last exportable image")
        let bounded = try CaptureScrollDocument(image: first, direction: .vertical, historyPixelLimit: 64 * 64)
        try bounded.append(second); try bounded.append(third); try bounded.undo()
        require(!bounded.canUndo && bounded.count == 2, "History evicts oldest viewports while preserving the most recent undo")
        rejects("Invalid manual overlap cannot mutate the document") { _ = try bounded.append(third, overlap: 64) }
    }

    @MainActor
    final class Harness {
        let first: CGImage
        var frames: [CGImage]
        var captureCount = 0
        var scrollCount = 0
        var scrolledDirections: [CaptureScrollDirection] = []
        var targetValue: CaptureScrollTarget? = .init(processID: 31337, windowID: 42, frame: CGRect(x: 50, y: 50, width: 400, height: 400))
        var foreground: pid_t? = 31337
        var pointer = CGPoint(x: 120, y: 120)
        var allowsScroll = true
        var captureError: Error?
        var captureOverride: (() async throws -> CGImage)?
        var afterCapture: ((Int) -> Void)?
        var afterScroll: ((Int) -> Void)?
        var annotate: ((CGImage) async throws -> CaptureAnnotationResult)?
        init(_ first: CGImage) { self.first = first; self.frames = [first] }
        var environment: CaptureScrollEnvironment {
            CaptureScrollEnvironment(capture: { [self] _ in
                captureCount += 1
                let result: CGImage
                if let captureOverride { result = try await captureOverride() }
                else if let captureError { throw captureError }
                else { result = frames.isEmpty ? first : frames.removeFirst() }
                afterCapture?(captureCount); return result
            }, target: { [self] _ in targetValue }, frontmost: { [self] in foreground }, pointer: { [self] in pointer },
               canScroll: { [self] in allowsScroll }, scroll: { [self] target, selected, direction in
                precondition(target == targetValue && selected == CaptureScrollingTests.region)
                scrollCount += 1; scrolledDirections.append(direction); afterScroll?(scrollCount)
            }, sleep: { _ in try Task.checkCancellation(); await Task.yield(); try Task.checkCancellation() }, annotate: annotate)
        }
        func controller() -> CaptureScrollingController { .init(environment: environment, presentsWindows: false) }
    }
    static func controllers() async throws {
        let source = fixture(), first = crop(source), second = crop(source, y: 24), third = crop(source, y: 48)
        let frozen = try CaptureImageCodec.png(fixture(width: 12, height: 12))
        let harness = Harness(first), controller = harness.controller()
        controller.start(region: region, initialImage: frozen)
        require(controller.isActive && controller.preparing && !controller.canExport, "A frozen annotated screenshot is preview-only until a live first frame arrives")
        await wait { !controller.preparing }
        require(try controller.count == 1 && controller.document!.canvas.width == 64 && CaptureScrollDocument.identical(controller.document!.canvas, first), "The first committed frame is freshly captured at source resolution")
        require(harness.captureCount == 1 && harness.scrollCount == 0 && !controller.running, "Opening scrolling capture never automatically scrolls the target")
        require(controller.panel?.isVisible == false, "Fixture controller keeps its real AppKit panel hidden")
        harness.frames = [second]; harness.afterCapture = { index in if index == 2 { harness.captureError = CaptureToolError.noOverlap } }
        controller.begin(); await wait { controller.needsRetry }
        require(controller.count == 2 && !controller.running && controller.canExport && controller.canUndo, "A matching frame is preserved when the next read fails and capture pauses")
        harness.captureError = nil; harness.frames = [third]; harness.afterCapture = { index in if index == 4 { harness.captureError = CaptureToolError.noOverlap } }
        controller.begin(); await wait { controller.needsRetry }
        require(controller.count == 3 && controller.document!.canvas.height == 112, "Retry continues from the last successful viewport without discarding prior joins")
        controller.undo()
        require(controller.count == 2 && !controller.running && !controller.needsRetry, "Controller undo pauses capture and restores the previous join")
        harness.captureError = nil; harness.frames = [third]; harness.afterCapture = nil
        controller.reset(); await wait { !controller.preparing }
        require(try controller.count == 1 && CaptureScrollDocument.identical(controller.document!.canvas, third), "Restart obtains a new live first frame instead of reusing the frozen screenshot")
        var exported: CaptureAnnotationResult?
        controller.onResult = { exported = $0 }; controller.finish(.pin)
        require(!controller.isActive && controller.preview == nil && controller.document == nil, "Export tears down sampling windows and retained images")
        require(try exported != nil && CaptureScrollDocument.identical(CaptureImageCodec.decode(exported!.data), third), "Pin export receives the exact live source pixels")
        if case .action(.pin, region: region) = exported!.destination { checks += 1 } else { preconditionFailure("Pin destination changed") }

        let safe = Harness(first), automatic = safe.controller()
        automatic.start(region: region, initialImage: frozen); await wait { !automatic.preparing }
        automatic.mode = .automatic; safe.allowsScroll = false; automatic.begin()
        require(!automatic.running && safe.scrollCount == 0 && automatic.needsRetry, "Missing Accessibility access blocks only automatic scrolling with recoverable feedback")
        safe.allowsScroll = true; safe.pointer = CGPoint(x: 1, y: 1); automatic.begin(); await wait { !automatic.running }
        require(safe.scrollCount == 0 && automatic.needsRetry, "Automatic mode never scrolls while the pointer is outside the selection")
        safe.pointer = CGPoint(x: 120, y: 120); safe.foreground = 9; automatic.begin(); await wait { !automatic.running }
        require(safe.scrollCount == 0 && automatic.needsRetry, "A different foreground application pauses automatic scrolling before any event")
        safe.foreground = 31337; automatic.direction = .horizontal
        safe.frames = [first, crop(source, x: 24), crop(source, x: 24), crop(source, x: 24), crop(source, x: 24)]
        automatic.begin(); await wait { !automatic.running }
        require(safe.scrollCount == 4 && safe.scrolledDirections.allSatisfy { $0 == .horizontal }, "Explicit automatic mode sends only the requested horizontal scrolls to the selected target")
        require(automatic.count == 2 && !automatic.needsRetry, "Three stationary reads stop automatic scrolling at a page boundary")
        safe.afterScroll = { _ in safe.foreground = 8 }
        safe.frames = [crop(source, x: 24), crop(source, x: 48)]; automatic.begin(); await wait { !automatic.running }
        require(automatic.count == 2 && automatic.needsRetry, "A focus switch after a scroll stops further capture and keeps the last valid image")
        let priorScrolls = safe.scrollCount; safe.foreground = 31337
        safe.targetValue = .init(processID: 31337, windowID: 99, frame: CGRect(x: 50, y: 50, width: 400, height: 400))
        automatic.begin(); await wait { !automatic.running }
        require(safe.scrollCount == priorScrolls && automatic.needsRetry, "A different window in the same application cannot become the automatic target")
        automatic.screenConfigurationChanged()
        require(!automatic.isActive && automatic.document == nil && automatic.preview == nil, "Display layout or Retina scale changes cancel capture and release its images")

        let pending = Harness(first), late = pending.controller()
        var continuation: CheckedContinuation<CGImage, Error>?
        pending.captureOverride = { try await withCheckedThrowingContinuation { continuation = $0 } }
        late.start(region: region, initialImage: frozen); await wait { continuation != nil }
        late.cancel(); continuation?.resume(returning: second); continuation = nil
        for _ in 0..<30 { await Task.yield() }
        require(!late.isActive && late.document == nil && !late.preparing, "A late first-frame completion cannot recreate a cancelled session")

        let suspended = Harness(first), resumed = suspended.controller()
        resumed.start(region: region, initialImage: frozen); await wait { !resumed.preparing }
        suspended.captureOverride = { try await withCheckedThrowingContinuation { continuation = $0 } }
        resumed.begin(); await wait { continuation != nil }; resumed.pause()
        continuation!.resume(returning: second); continuation = nil
        for _ in 0..<30 { await Task.yield() }
        require(resumed.count == 1 && !resumed.running, "Pausing rejects an in-flight viewport instead of appending after the user stopped")
        resumed.begin(); await wait { continuation != nil }
        suspended.captureOverride = nil; suspended.frames = [third]
        resumed.start(region: region, initialImage: frozen); await wait { !resumed.preparing }
        continuation!.resume(returning: second); continuation = nil
        for _ in 0..<30 { await Task.yield() }
        require(try resumed.count == 1 && CaptureScrollDocument.identical(resumed.document!.canvas, third), "A replaced session rejects late pixels from the prior scrolling task")
        resumed.cancel()

        let focus = Harness(first), manually = focus.controller()
        manually.start(region: region, initialImage: frozen); await wait { !manually.preparing }
        focus.foreground = 77; manually.begin(); await wait { !manually.running }
        require(focus.scrollCount == 0 && manually.count == 1 && manually.needsRetry, "Manual capture also pauses when the original window loses focus")
        manually.cancel()
    }
    static func annotationLifecycle() async throws {
        let source = fixture(), first = crop(source), edited = crop(source, x: 20, y: 15, width: 30, height: 25)
        var continuation: CheckedContinuation<CaptureAnnotationResult, Error>?
        let harness = Harness(first)
        harness.annotate = { image in
            require(try CaptureScrollDocument.identical(image, first), "Crop/annotation receives the full-resolution stitched canvas")
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        let controller = harness.controller(), frozen = try CaptureImageCodec.png(first)
        controller.start(region: region, initialImage: frozen); await wait { !controller.preparing }
        var exported: CaptureAnnotationResult?
        controller.onResult = { exported = $0 }; controller.annotate(); await wait { continuation != nil }
        require(controller.editingImage && !controller.running && !controller.canExport, "Annotation pauses live capture and prevents competing exports")
        continuation!.resume(throwing: CaptureToolError.cancelled); continuation = nil
        await wait { !controller.editingImage }
        require(controller.isActive && controller.canExport && exported == nil, "Cancelling crop/annotation returns to the retained scrolling result")
        for action in [CaptureWorkflowAction.longCapture, .recording] {
            controller.annotate(); await wait { continuation != nil }
            continuation!.resume(returning: .init(data: try CaptureImageCodec.png(edited), destination: .action(action, region: region))); continuation = nil
            await wait { !controller.editingImage }
            require(controller.isActive && controller.canExport && exported == nil, "A stitched image cannot be reinterpreted as a live screen region for \(action.rawValue)")
        }
        controller.annotate(); await wait { continuation != nil }
        continuation!.resume(returning: .init(data: try CaptureImageCodec.png(edited), destination: .copy)); continuation = nil
        await wait { !controller.isActive }
        require(try CaptureScrollDocument.identical(CaptureImageCodec.decode(exported!.data), edited), "Confirmed crop/annotation hands off its edited source pixels")
        exported = nil
        controller.start(region: region, initialImage: frozen); await wait { !controller.preparing }
        controller.annotate(); await wait { continuation != nil }; controller.cancel()
        continuation!.resume(returning: .init(data: try CaptureImageCodec.png(edited), destination: .copy)); continuation = nil
        for _ in 0..<30 { await Task.yield() }
        require(exported == nil && !controller.isActive && !controller.editingImage, "Closing a session cancels late annotation output without reopening or exporting")
    }
    static func main() async throws {
        setbuf(stdout, nil); _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        try geometry(); try documents(); try await controllers(); try await annotationLifecycle()
        print("Scrolling capture: \(checks) checks passed")
    }
}
