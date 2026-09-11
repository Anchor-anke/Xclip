import AppKit

/// Generated pixels and an offscreen NSTextView only; no desktop capture, window, clipboard, or permission request.
@main
struct ImageEditingRenderingTests {
    static var checks = 0
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) {
        precondition((try? value()) == true, message)
        checks += 1
        print("PASS: \(message)")
    }
    static func white(width: Int = 320, height: Int = 240) throws -> CGImage {
        let context = try CaptureImageCodec.context(width: width, height: height)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
    static func bytes(_ image: CGImage) throws -> [UInt8] {
        let context = try CaptureImageCodec.context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> [UInt8] {
        let raw = try bytes(image), index = (y * image.width + x) * 4
        return Array(raw[index..<(index + 4)])
    }
    static func inkBounds(_ image: CGImage) throws -> CGRect {
        let raw = try bytes(image)
        var minX = image.width, minY = image.height, maxX = -1, maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                let index = (y * image.width + x) * 4
                if raw[index] < 220 || raw[index + 1] < 220 || raw[index + 2] < 220 {
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        return maxX >= minX ? CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1) : .zero
    }
    static func preview(_ stroke: ImageEditStroke, on image: CGImage) throws -> CGImage {
        let context = try CaptureImageCodec.context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ImageEditingOperations.draw(stroke, in: context, imageHeight: CGFloat(image.height))
        return context.makeImage()!
    }
    @MainActor static func nativeEditor(for stroke: ImageEditStroke, size: CGSize) -> NSTextView {
        let editor = NSTextView(frame: CGRect(origin: .zero, size: size))
        editor.isRichText = false
        editor.isEditable = false; editor.isSelectable = false; editor.drawsBackground = false
        editor.textContainerInset = .zero
        editor.isHorizontallyResizable = true; editor.isVerticallyResizable = true
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.containerSize = CGSize(width: 1_000_000, height: 1_000_000)
        editor.typingAttributes = ImageEditingOperations.textAttributes(for: stroke)
        editor.textStorage?.setAttributedString(NSAttributedString(string: stroke.text,
            attributes: ImageEditingOperations.textAttributes(for: stroke)))
        editor.layoutManager?.ensureLayout(for: editor.textContainer!)
        return editor
    }
    @MainActor static func nativeText(_ stroke: ImageEditStroke, on image: CGImage) throws -> CGImage {
        let editor = nativeEditor(for: stroke, size: CGSize(width: image.width, height: image.height))
        let context = try CaptureImageCodec.context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.translateBy(x: 0, y: CGFloat(image.height)); context.scaleBy(x: 1, y: -1)
        context.translateBy(x: stroke.points[0].x, y: stroke.points[0].y)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        editor.draw(editor.bounds)
        return context.makeImage()!
    }
    static func arrowTests() throws {
        let image = try white()
        var arrow = ImageEditStroke(tool: .arrow, points: [CGPoint(x: 20, y: 64), CGPoint(x: 140, y: 64)], color: .red, width: 6, text: "")
        let painted = try ImageEditingOperations.apply(arrow, to: image)
        require(try pixel(painted, 70, 64)[1] < 20, "Arrow preserves a continuous solid shaft")
        require(try pixel(painted, 126, 60)[1] < 20, "Arrowhead interior is filled, beyond the shaft and away from the old open wings")
        require(try pixel(painted, 120, 57)[1] < 20, "Arrowhead has a broad filled base")
        require(try pixel(painted, 111, 54) == [255,255,255,255], "Arrowhead does not spill behind its base")
        require(try bytes(preview(arrow, on: image)) == bytes(painted), "Arrow preview and committed rendering have identical pixels")
        require(try bytes(CaptureImageCodec.decode(CaptureImageCodec.png(painted))) == bytes(painted), "PNG export preserves solid arrowhead pixels")
        for end in [CGPoint(x: 54, y: 50), CGPoint(x: 46, y: 50), CGPoint(x: 50, y: 54), CGPoint(x: 50, y: 46)] {
            arrow.points = [CGPoint(x: 50, y: 50), end]; arrow.width = 12
            let short = try ImageEditingOperations.apply(arrow, to: image)
            let ink = try inkBounds(short)
            require(!ink.isEmpty && CGRect(x: 45, y: 45, width: 10, height: 10).contains(ink),
                    "A four-pixel arrow scales its head and shaft without long backward barbs: \(end)")
        }
        arrow.points = [CGPoint(x: 50, y: 50), CGPoint(x: 50, y: 50)]
        require(ImageEditingOperations.arrowGeometry(for: arrow) == nil, "A zero-length arrow has no invented direction")
        require(try bytes(ImageEditingOperations.apply(arrow, to: image)) == bytes(image), "A zero-length arrow leaves pixels unchanged")
    }
    @MainActor static func textTests() throws {
        let image = try white(width: 600, height: 280)
        var stroke = ImageEditStroke(tool: .text, points: [CGPoint(x: 24, y: 18)], color: .black, width: 6, text: "截图 Text\n第二行 gyp", fontSize: 24)
        let attributes = ImageEditingOperations.textAttributes(for: stroke)
        require((attributes[.font] as? NSFont) == NSFont.systemFont(ofSize: 24, weight: .medium), "Shared text attributes preserve the existing medium font and explicit point size")
        let bounds = ImageEditingOperations.textBounds(for: stroke)
        let editor = nativeEditor(for: stroke, size: CGSize(width: 600, height: 280))
        let used = editor.layoutManager!.usedRect(for: editor.textContainer!)
        require(bounds.origin == stroke.points[0], "Text bounds retain the source-pixel top-left anchor")
        require(bounds.width == ceil(used.width) && bounds.height == ceil(used.height), "Text bounds agree with native NSTextView TextKit layout for Chinese and explicit newlines")
        let painted = try ImageEditingOperations.apply(stroke, to: image)
        let native = try nativeText(stroke, on: image)
        require(try !inkBounds(painted).isEmpty && inkBounds(painted) == inkBounds(native), "Committed glyph placement matches an offscreen native NSTextView without an anchor jump")
        require(try bounds.contains(inkBounds(painted)), "Shared text bounds contain the rendered glyph pixels")
        require(try bytes(preview(stroke, on: image)) == bytes(painted), "Text preview and export rendering use identical TextKit placement")
        require(try pixel(painted, 25, 240) == [255,255,255,255], "Multiline text uses top-left pixels and leaves the opposite image edge unchanged")
        stroke.text = "مرحبا"
        let rightToLeft = ImageEditingOperations.textBounds(for: stroke)
        let rightToLeftImage = try ImageEditingOperations.apply(stroke, to: image)
        require(rightToLeft.width > 0 && rightToLeft.width < 300 && rightToLeft.origin == stroke.points[0],
                "Right-to-left text keeps a finite natural width at the explicit left anchor")
        require(try !inkBounds(rightToLeftImage).isEmpty && rightToLeft.contains(inkBounds(rightToLeftImage)),
                "Right-to-left glyphs render inside their shared source bounds")
        stroke.text = "Hello"
        let oneLine = ImageEditingOperations.textBounds(for: stroke)
        stroke.text = "Hello\n\n"
        let blankLines = ImageEditingOperations.textBounds(for: stroke)
        require(blankLines.height == oneLine.height * 3 && blankLines.width == oneLine.width, "Text bounds preserve both final explicit blank lines")
        stroke.text = ""; stroke.fontSize = nil
        let fallbackFont = ImageEditingOperations.textAttributes(for: stroke)[.font] as! NSFont
        require(fallbackFont.pointSize == 30, "Older image-editor strokes without fontSize retain their width-based font size")
        require(ImageEditingOperations.textBounds(for: stroke).height == ceil(NSLayoutManager().defaultLineHeight(for: fallbackFont)), "An empty inline editor receives a correctly sized first line")
        stroke.text = String(repeating: "A", count: 500) + "\nEXTRA"
        let limited = ImageEditingOperations.textBounds(for: stroke)
        stroke.text = String(repeating: "A", count: 500)
        require(ImageEditingOperations.textBounds(for: stroke) == limited, "Measurement and rendering retain the same 500-character annotation limit")
    }
    @MainActor static func main() throws {
        try arrowTests()
        try textTests()
        print("Image editing rendering tests passed: \(checks) checks.")
    }
}
