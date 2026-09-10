import Foundation
import AppKit
import VisionKit

/// Run: xcrun swiftc -swift-version 5 -parse-as-library src/OneClip/CaptureTools.swift src/OneClip/ImageEditorView.swift tests/CaptureTests.swift -o /private/tmp/oneclip-capture-tests && /private/tmp/oneclip-capture-tests
/// Vision OCR requires normal macOS graphics-service access; restricted execution may need sandbox approval.
/// These tests use generated pixels only; they never capture a screen or request any permission.
@main
struct CaptureTests {
    static var checks = 0
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
        print("PASS: \(message)")
        fflush(stdout)
    }
    static func fixture(width: Int, height: Int, solid: (UInt8, UInt8, UInt8)? = nil) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let hash = UInt32(truncatingIfNeeded: (x + 1) * 73856093 ^ (y + 1) * 19349663)
                bytes[index] = solid?.0 ?? UInt8(truncatingIfNeeded: hash)
                bytes[index + 1] = solid?.1 ?? UInt8(truncatingIfNeeded: hash >> 8)
                bytes[index + 2] = solid?.2 ?? UInt8(truncatingIfNeeded: hash >> 16)
            }
        }
        let data = Data(bytes)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    static func bytes(_ image: CGImage) throws -> [UInt8] {
        let context = try CaptureImageCodec.context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    static func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let raw = try bytes(image), start = (y * image.width + x) * 4
        return Array(raw[start..<(start + 4)])
    }
    @MainActor static func permissionRegressionTests() throws {
        var available = false
        var checksPerformed = 0
        var requestsPerformed = 0
        let permission = CaptureScreenPermission(preflight: {
            checksPerformed += 1
            return available
        }, request: {
            requestsPerformed += 1
            return false
        })
        require(permission.state == .unknown && checksPerformed == 0 && requestsPerformed == 0,
                "Constructing permission state does not inspect or request screen access")
        require(permission.refresh() == .unavailable && checksPerformed == 1 && requestsPerformed == 0,
                "Refreshing unavailable permission is read-only")
        available = true
        require(permission.refresh() == .granted && requestsPerformed == 0,
                "Returning from settings refreshes newly granted permission without prompting")
        try permission.prepareForCapture()
        try permission.requireAccess()
        require(permission.state == .granted && requestsPerformed == 0,
                "Already authorized captures never request permission again")
        available = false
        do { try permission.requireAccess(); preconditionFailure("Expected revoked permission") }
        catch CaptureToolError.permissionDenied { checks += 1 }
        require(requestsPerformed == 0,
                "A permission revoked after hiding the app fails without a hidden authorization prompt")
        do { try permission.prepareForCapture(); preconditionFailure("Expected denied permission") }
        catch CaptureToolError.permissionDenied { checks += 1 }
        require(permission.state == .unavailable && requestsPerformed == 1,
                "A denied capture request records unavailable access")

        var restartRequests = 0
        let needsRestart = CaptureScreenPermission(preflight: { false }, request: {
            restartRequests += 1
            return true
        })
        do { try needsRestart.prepareForCapture(); preconditionFailure("Expected restart requirement") }
        catch CaptureToolError.permissionRestartRequired { checks += 1 }
        require(needsRestart.state == .restartRequired && restartRequests == 1,
                "Granting consent without effective process access requires a restart")

        for requestResult in [true, false] {
            var accessAfterRequest = false
            var promptCount = 0
            let newlyGranted = CaptureScreenPermission(preflight: { accessAfterRequest }, request: {
                promptCount += 1
                accessAfterRequest = true
                return requestResult
            })
            try newlyGranted.prepareForCapture()
            require(newlyGranted.state == .granted && promptCount == 1,
                    "Effective access after a request wins over its \(requestResult) return value")
        }
    }

    static func commandResultRegressionTests(png: Data) throws {
        let successful = CaptureCommandResult(status: 0, stderr: "", imageData: png, wasCancelled: false)
        let successfulData = try successful.validatedImage(interactive: true, permissionAvailable: true)
        require(successfulData == png, "A successful screen capture preserves its image bytes")
        let stalePreflightData = try successful.validatedImage(interactive: true, permissionAvailable: false)
        require(stalePreflightData == png, "A valid capture is accepted even if the subsequent preflight is stale")
        let warned = CaptureCommandResult(status: 0, stderr: "synthetic warning", imageData: png, wasCancelled: false)
        let warnedData = try warned.validatedImage(interactive: false, permissionAvailable: true)
        require(warnedData == png, "Nonfatal command diagnostics do not discard a successful image")

        let cancelled = CaptureCommandResult(status: 0, stderr: "", imageData: png, wasCancelled: true)
        do { _ = try cancelled.validatedImage(interactive: true, permissionAvailable: false); preconditionFailure("Expected explicit cancellation") }
        catch CaptureToolError.cancelled { checks += 1 }
        let denied = CaptureCommandResult(status: 1, stderr: "synthetic capture failure", imageData: nil, wasCancelled: false)
        do { _ = try denied.validatedImage(interactive: true, permissionAvailable: false); preconditionFailure("Expected unavailable permission") }
        catch CaptureToolError.permissionDenied { checks += 1 }
        let deniedSilently = CaptureCommandResult(status: 1, stderr: "", imageData: nil, wasCancelled: false)
        do { _ = try deniedSilently.validatedImage(interactive: true, permissionAvailable: false); preconditionFailure("Expected permission before inferred cancellation") }
        catch CaptureToolError.permissionDenied { checks += 1 }
        for status in [Int32(0), Int32(1)] {
            let dismissed = CaptureCommandResult(status: status, stderr: "", imageData: nil, wasCancelled: false)
            do { _ = try dismissed.validatedImage(interactive: true, permissionAvailable: true); preconditionFailure("Expected interactive dismissal") }
            catch CaptureToolError.cancelled { checks += 1 }
        }

        let failures: [(String, CaptureCommandResult, Bool)] = [
            ("Interactive failures with diagnostics are not reported as cancellation", denied, true),
            ("Noninteractive silent failures are not reported as cancellation", deniedSilently, false),
            ("Signal 15 without explicit cancellation remains a command failure",
             CaptureCommandResult(status: 15, stderr: "", imageData: nil, wasCancelled: false), true),
            ("Unexpected exit codes remain failures even for interactive capture",
             CaptureCommandResult(status: 2, stderr: "", imageData: nil, wasCancelled: false), true),
            ("Malformed image output is reported as a capture failure",
             CaptureCommandResult(status: 0, stderr: "", imageData: Data("invalid PNG".utf8), wasCancelled: false), true),
            ("A nonzero exit status does not accept a leftover image",
             CaptureCommandResult(status: 1, stderr: "synthetic failure", imageData: png, wasCancelled: false), true)
        ]
        for (message, result, interactive) in failures {
            do { _ = try result.validatedImage(interactive: interactive, permissionAvailable: true); preconditionFailure(message) }
            catch CaptureToolError.captureCommandFailed(let diagnostic) {
                require(!diagnostic.isEmpty, message)
            }
        }
        let verbose = CaptureCommandResult(status: 1, stderr: String(repeating: "x", count: 1000), imageData: nil, wasCancelled: false)
        do { _ = try verbose.validatedImage(interactive: true, permissionAvailable: true); preconditionFailure("Expected bounded diagnostics") }
        catch CaptureToolError.captureCommandFailed(let diagnostic) {
            require(!diagnostic.isEmpty && diagnostic.count <= 400, "Capture failure diagnostics have a bounded display length")
        }
    }
    @MainActor static func main() async throws {
        let source = fixture(width: 120, height: 240)
        let encoded = try CaptureImageCodec.png(source)
        try permissionRegressionTests()
        try commandResultRegressionTests(png: encoded)
        let decoded = try CaptureImageCodec.decode(encoded)
        require(decoded.width == 120 && decoded.height == 240, "PNG dimension roundtrip")
        let sourceBytes = try bytes(source), decodedBytes = try bytes(decoded)
        require(sourceBytes == decodedBytes, "PNG lossless pixel roundtrip")
        do { _ = try CaptureImageCodec.decode(Data("invalid".utf8)); preconditionFailure("Expected invalid image") }
        catch CaptureToolError.invalidImage { checks += 1 }
        do { _ = try CaptureImageCodec.context(width: 100_000, height: 100_000); preconditionFailure("Expected pixel limit") }
        catch CaptureToolError.imageTooLarge { checks += 1 }

        let crop = try CaptureImageCodec.crop(source, rect: CGRect(x: 10, y: 20, width: 30, height: 40))
        require(crop.width == 30 && crop.height == 40, "Crop dimensions")
        let croppedTop = try pixel(crop, x: 0, y: 0), sourceCropTop = try pixel(source, x: 10, y: 20)
        require(croppedTop == sourceCropTop, "Crop uses top-left selection coordinates")
        let rotation = try CaptureImageCodec.rotateClockwise(crop)
        require(rotation.width == 40 && rotation.height == 30, "Rotation exchanges dimensions")
        let rotatedTop = try pixel(rotation, x: 0, y: 0), cropBottom = try pixel(crop, x: 0, y: 39)
        require(rotatedTop == cropBottom, "Clockwise rotation maps bottom-left to top-left")
        var fullRotation = crop
        for _ in 0..<4 { fullRotation = try CaptureImageCodec.rotateClockwise(fullRotation) }
        let cropBytes = try bytes(crop), rotatedBytes = try bytes(fullRotation)
        require(cropBytes == rotatedBytes, "Four rotations preserve pixels")

        let previous = try CaptureImageCodec.crop(source, rect: CGRect(x: 0, y: 0, width: 120, height: 150))
        let next = try CaptureImageCodec.crop(source, rect: CGRect(x: 0, y: 93, width: 120, height: 147))
        let overlap = try LongCaptureStitcher.detectOverlap(previous: previous, next: next)
        require(overlap == 57, "Automatic overlap identifies 57 rows")
        let joined = try LongCaptureStitcher.append(canvas: previous, previous: previous, next: next)
        require(joined.image.height == 240 && joined.overlap == 57, "Long capture dimensions")
        let joinedBytes = try bytes(joined.image)
        require(joinedBytes == sourceBytes, "Long capture removes duplicate rows with exact pixel order")
        let manual = try LongCaptureStitcher.append(canvas: previous, previous: previous, next: next, overlap: 57)
        let manualBytes = try bytes(manual.image)
        require(manualBytes == sourceBytes, "Manual overlap matches automatic output")
        let zero = try LongCaptureStitcher.append(canvas: previous, previous: previous, next: next, overlap: 0)
        require(zero.image.height == 297, "Zero overlap concatenates")
        do { _ = try LongCaptureStitcher.detectOverlap(previous: previous, next: previous); preconditionFailure("Expected identical-frame rejection") }
        catch CaptureToolError.noOverlap { checks += 1 }
        let horizontalSource = fixture(width: 240, height: 120)
        let left = try CaptureImageCodec.crop(horizontalSource, rect: CGRect(x: 0, y: 0, width: 150, height: 120))
        let right = try CaptureImageCodec.crop(horizontalSource, rect: CGRect(x: 93, y: 0, width: 147, height: 120))
        let horizontalOverlap = try LongCaptureStitcher.detectOverlap(previous: left, next: right, direction: .horizontal)
        require(horizontalOverlap == 57, "Horizontal overlap identifies 57 columns")
        let horizontalJoin = try LongCaptureStitcher.append(canvas: left, previous: left, next: right, direction: .horizontal)
        let horizontalBytes = try bytes(horizontalJoin.image), horizontalSourceBytes = try bytes(horizontalSource)
        require(horizontalJoin.image.width == 240 && horizontalJoin.image.height == 120, "Horizontal stitching dimensions")
        require(horizontalBytes == horizontalSourceBytes, "Horizontal stitching preserves all pixels in correct order")
        let horizontalManual = try LongCaptureStitcher.append(canvas: left, previous: left, next: right, overlap: 57, direction: .horizontal)
        let horizontalManualBytes = try bytes(horizontalManual.image)
        require(horizontalManualBytes == horizontalSourceBytes, "Horizontal manual overlap preserves pixels")
        let horizontalZero = try LongCaptureStitcher.append(canvas: left, previous: left, next: right, overlap: 0, direction: .horizontal)
        require(horizontalZero.image.width == 297, "Horizontal zero overlap concatenates")
        do { _ = try LongCaptureStitcher.append(canvas: left, previous: left, next: crop, direction: .horizontal); preconditionFailure("Expected horizontal height mismatch") }
        catch CaptureToolError.incompatibleFrames { checks += 1 }
        let solidA = fixture(width: 120, height: 120, solid: (255, 0, 0))
        let solidB = fixture(width: 120, height: 140, solid: (255, 0, 0))
        do { _ = try LongCaptureStitcher.detectOverlap(previous: solidA, next: solidB); preconditionFailure("Expected flat-background rejection") }
        catch CaptureToolError.noOverlap { checks += 1 }
        do { _ = try LongCaptureStitcher.append(canvas: previous, previous: previous, next: crop); preconditionFailure("Expected width mismatch") }
        catch CaptureToolError.incompatibleFrames { checks += 1 }
        do { _ = try LongCaptureStitcher.append(canvas: previous, previous: previous, next: next, overlap: -1); preconditionFailure("Expected invalid overlap") }
        catch CaptureToolError.noOverlap { checks += 1 }

        let white = fixture(width: 100, height: 80, solid: (255, 255, 255))
        let pen = ImageEditStroke(tool: .pen, points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 10)], color: .red, width: 6, text: "")
        let painted = try ImageEditingOperations.apply(pen, to: white)
        let paintedPoint = try pixel(painted, x: 20, y: 10), outside = try pixel(painted, x: 20, y: 70)
        require(paintedPoint[0] > 240 && paintedPoint[1] < 20, "Pen uses top-left coordinates")
        require(outside == [255, 255, 255, 255], "Pen preserves outside pixels")
        let rectangle = ImageEditStroke(tool: .rectangle, points: [CGPoint(x: 15, y: 15), CGPoint(x: 45, y: 45)], color: .red, width: 4, text: "")
        let outlined = try ImageEditingOperations.apply(rectangle, to: white)
        let outlinePixel = try pixel(outlined, x: 15, y: 30), centerPixel = try pixel(outlined, x: 30, y: 30)
        require(outlinePixel[1] < 20 && centerPixel == [255, 255, 255, 255], "Rectangle outlines selection without filling center")
        let arrow = ImageEditStroke(tool: .arrow, points: [CGPoint(x: 15, y: 15), CGPoint(x: 60, y: 60)], color: .red, width: 4, text: "")
        let arrowImage = try ImageEditingOperations.apply(arrow, to: white)
        let arrowPixel = try pixel(arrowImage, x: 40, y: 40)
        require(arrowPixel[1] < 20, "Arrow renders the directed line")
        let highlight = ImageEditStroke(tool: .highlight, points: [CGPoint(x: 10, y: 20), CGPoint(x: 70, y: 20)], color: .red, width: 4, text: "")
        let highlighted = try ImageEditingOperations.apply(highlight, to: white)
        let highlightedPixel = try pixel(highlighted, x: 40, y: 20)
        require(highlightedPixel[0] > 240 && highlightedPixel[1] > 140 && highlightedPixel[1] < 220, "Highlighter preserves underlying image through transparency")
        let ellipse = ImageEditStroke(tool: .ellipse, points: [CGPoint(x: 15, y: 15), CGPoint(x: 45, y: 45)], color: .red, width: 4, text: "")
        let ellipseImage = try ImageEditingOperations.apply(ellipse, to: white)
        let ellipseEdge = try pixel(ellipseImage, x: 30, y: 15), ellipseCenter = try pixel(ellipseImage, x: 30, y: 30)
        require(ellipseEdge[1] < 20 && ellipseCenter == [255, 255, 255, 255], "Ellipse outlines selection and leaves center clear")
        let numbered = try ImageEditingOperations.apply(ImageEditStroke(tool: .number, points: [CGPoint(x: 40, y: 40)], color: .red, width: 4, text: "", number: 7), to: white)
        let numberEdge = try pixel(numbered, x: 40, y: 30), numberOutside = try pixel(numbered, x: 10, y: 10)
        require(numberEdge[0] > 240 && numberEdge[1] < 20 && numberOutside == [255,255,255,255], "Number marker renders locally without changing outside pixels")
        let mosaic = ImageEditStroke(tool: .mosaic, points: [CGPoint(x: 20, y: 20), CGPoint(x: 60, y: 60)], color: .red, width: 5, text: "")
        let mosaiced = try ImageEditingOperations.apply(mosaic, to: source)
        let oldInside = try pixel(source, x: 30, y: 30), newInside = try pixel(mosaiced, x: 30, y: 30)
        let oldOutside = try pixel(source, x: 70, y: 70), newOutside = try pixel(mosaiced, x: 70, y: 70)
        require(oldInside != newInside, "Mosaic modifies selected pixels")
        require(oldOutside == newOutside, "Mosaic preserves outside pixels")
        let model = ImageEditorModel(data: try CaptureImageCodec.png(white))
        model.edit(pen)
        require(model.undoCount == 1 && model.redoCount == 0, "Edit records undo state")
        model.undo()
        let undoBytes = try bytes(model.image!), whiteBytes = try bytes(white)
        require(undoBytes == whiteBytes && model.redoCount == 1, "Undo restores original image")
        model.redo()
        let redoBytes = try bytes(model.image!), paintedBytes = try bytes(painted)
        require(redoBytes == paintedBytes, "Redo restores annotation")
        model.undo(); model.rotate()
        require(model.redoCount == 0, "New edit clears redo branch")
        model.clear()
        require(model.image == nil && model.undoCount == 0 && model.redoCount == 0, "Editor dismissal clears image and undo history")
        let cancelledOCR = Task { try await CaptureService.shared.recognizeText(in: encoded) }
        cancelledOCR.cancel()
        do { _ = try await cancelledOCR.value; preconditionFailure("Expected OCR cancellation") }
        catch is CancellationError { checks += 1 }
        let suiteName = "local.cclip.capture-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = ImageEditorPreferences(toolRawValue: ImageEditTool.ellipse.rawValue, red: 0.1, green: 0.5, blue: 0.8, lineWidth: 12, textSize: 48, number: 6)
        preferences.save(to: defaults)
        require(ImageEditorPreferences.load(from: defaults) == preferences, "Editor preferences persist to an isolated defaults namespace")
        var invalidPreferences = preferences
        invalidPreferences.lineWidth = -30; invalidPreferences.textSize = 900; invalidPreferences.number = -1
        invalidPreferences.save(to: defaults)
        let repairedPreferences = ImageEditorPreferences.load(from: defaults)
        require(repairedPreferences.lineWidth == 2 && repairedPreferences.textSize == 144 && repairedPreferences.number == 1, "Editor preferences clamp invalid values")
        var notificationText: String?
        let observer = NotificationCenter.default.addObserver(forName: Notification.Name("CClipTranslateText"), object: nil, queue: nil) { notification in
            notificationText = notification.userInfo?["text"] as? String
        }
        CaptureTextOutput.send("Synthetic OCR result", to: .translate)
        NotificationCenter.default.removeObserver(observer)
        require(notificationText == "Synthetic OCR result", "OCR translation notification carries exact input text")
        let ocrBase = fixture(width: 1000, height: 260, solid: (255, 255, 255))
        let label = ImageEditStroke(tool: .text, points: [CGPoint(x: 40, y: 40)], color: .black, width: 12, text: "OneClip OCR 2026")
        let labelled = try ImageEditingOperations.apply(label, to: ocrBase)
        let labelledBytes = try bytes(labelled), baseBytes = try bytes(ocrBase)
        require(labelledBytes != baseBytes, "Text annotation renders pixels")
        let ocrData = try CaptureImageCodec.png(labelled)
        try ocrData.write(to: URL(fileURLWithPath: "/private/tmp/oneclip-ocr-synthetic.png"))
        let recognized = try await CaptureService.shared.recognizeText(in: ocrData)
        require(recognized.localizedCaseInsensitiveContains("OneClip") && recognized.contains("2026"), "Vision recognizes synthetic text locally")
        if ImageAnalyzer.isSupported {
            let liveAnalysis = try await ImageAnalyzer().analyze(labelled, orientation: .up, configuration: .init(.text))
            require(liveAnalysis.transcript.localizedCaseInsensitiveContains("OneClip") && liveAnalysis.transcript.contains("2026"), "VisionKit Live Text analyzes the synthetic image")
        } else { print("Live Text runtime test skipped: this device reports ImageAnalyzer.isSupported = false.") }
        print("Capture tests passed: \(checks) checks. Synthetic images only; no screen capture or permissions requested.")
    }
}
