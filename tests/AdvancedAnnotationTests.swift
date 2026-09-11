import AppKit

/// Exercises production rendering and history with generated pixels only.
@main
struct AdvancedAnnotationTests {
    static var checks = 0
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        precondition((try? condition()) == true, message); checks += 1; print("PASS: \(message)")
    }
    static func fixture(width: Int = 192, height: Int = 160, white: Bool = false, gradient: Bool = false) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        if !white { for y in 0..<height { for x in 0..<width {
            let at = (y * width + x) * 4
            bytes[at] = UInt8(gradient ? min(240, x + y / 3) : (x * 31 + y * 7) % 256)
            bytes[at + 1] = UInt8(gradient ? min(240, 30 + y) : (x * 5 + y * 23) % 256)
            bytes[at + 2] = UInt8(gradient ? min(240, 20 + x / 2 + y / 2) : (x * 11 + y * 3) % 256)
        } } }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    static func bytes(_ image: CGImage) throws -> [UInt8] {
        let context = try CaptureImageCodec.context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    static func pixel(_ data: [UInt8], width: Int = 192, x: Int, y: Int) -> [UInt8] { Array(data[((y * width + x) * 4)..<((y * width + x) * 4 + 4)]) }
    static func stroke(_ tool: ImageEditTool, _ start: CGPoint = CGPoint(x: 30, y: 30), _ end: CGPoint = CGPoint(x: 100, y: 90)) -> ImageEditStroke {
        ImageEditStroke(tool: tool, points: [start, end], color: .red, width: 4, text: "", fontSize: 20)
    }
    static func changedPixels(_ before: [UInt8], _ after: [UInt8]) -> Int {
        stride(from: 0, to: before.count, by: 4).filter { before[$0..<$0 + 4] != after[$0..<$0 + 4] }.count
    }
    static func vectorTests() throws {
        let white = fixture(white: true), original = try bytes(white)
        var rectangle = stroke(.rectangle); rectangle.style.filled = true
        let filled = try bytes(ImageEditingOperations.apply(rectangle, to: white))
        require(pixel(filled, x: 60, y: 60) == [255, 0, 0, 255], "Filled rectangles affect interior pixels")
        require(CaptureAnnotationGeometry.hitTest(rectangle, at: CGPoint(x: 60, y: 60)), "Filled rectangle interiors are selectable")
        rectangle.style.cornerRadius = 20
        let rounded = try bytes(ImageEditingOperations.apply(rectangle, to: white))
        require(pixel(rounded, x: 31, y: 31) == [255, 255, 255, 255] && pixel(rounded, x: 60, y: 60) == [255, 0, 0, 255], "Rounded fills preserve corner pixels while filling the center")
        require(!CaptureAnnotationGeometry.hitTest(rectangle, at: CGPoint(x: 31, y: 31), tolerance: 0), "Rounded-corner hit testing follows the actual path")
        rectangle.style.rotation = .pi / 4
        let rotated = try bytes(ImageEditingOperations.apply(rectangle, to: white))
        require(rotated != rounded && CaptureAnnotationGeometry.bounds(of: rectangle).width > rectangle.rect.width, "Object rotation changes pixels and selection bounds together")
        require(CaptureAnnotationGeometry.hitTest(rectangle, at: CGPoint(x: 60, y: 60).applying(ImageEditingOperations.rotationTransform(for: rectangle))), "Rotated shape hit testing maps the pointer back into shape coordinates")
        var ellipse = stroke(.ellipse); ellipse.style.filled = true; ellipse.style.arcSweep = .pi
        let sector = try bytes(ImageEditingOperations.apply(ellipse, to: white))
        require(pixel(sector, x: 65, y: 75) == [255, 0, 0, 255] && pixel(sector, x: 65, y: 40) == [255, 255, 255, 255], "Ellipse sectors render the selected half and preserve the other half")
        ellipse.style.arcInnerRatio = 0.5
        let annular = try bytes(ImageEditingOperations.apply(ellipse, to: white))
        require(pixel(annular, x: 65, y: 64) == [255, 255, 255, 255], "An inner arc radius leaves the sector center unfilled")
        var line = stroke(.line, CGPoint(x: 10, y: 20), CGPoint(x: 170, y: 20))
        let solid = try bytes(ImageEditingOperations.apply(line, to: white))
        line.style.lineStyle = .dashed
        let dashed = try bytes(ImageEditingOperations.apply(line, to: white))
        let gapCount = (15..<165).filter { pixel(dashed, x: $0, y: 20) == [255, 255, 255, 255] }.count
        require(gapCount > 10 && gapCount < 120 && changedPixels(original, dashed) < changedPixels(original, solid), "Dashed lines contain real transparent gaps")
        line.style.lineStyle = .dotted
        require(try bytes(ImageEditingOperations.apply(line, to: white)) != dashed, "Dotted and dashed line styles produce distinct pixels")
        var polyline = stroke(.polyline); polyline.points = [CGPoint(x: 20, y: 30), CGPoint(x: 70, y: 30), CGPoint(x: 70, y: 100)]
        polyline.style.endHead = .filled; polyline.style.startHead = .circle
        let polyPixels = try bytes(ImageEditingOperations.apply(polyline, to: white))
        require(pixel(polyPixels, x: 45, y: 30) == [255, 0, 0, 255] && pixel(polyPixels, x: 70, y: 70) == [255, 0, 0, 255], "Polyline rendering follows every node instead of connecting only its ends")
        require(CaptureAnnotationGeometry.hitTest(polyline, at: CGPoint(x: 70, y: 70)), "Polyline segment interiors are selectable")
        var arrow = stroke(.arrow, CGPoint(x: 20, y: 60), CGPoint(x: 160, y: 60))
        var images = Set<Data>()
        for style in ImageEditArrowStyle.allCases {
            arrow.style.arrowStyle = style
            images.insert(Data(try bytes(ImageEditingOperations.apply(arrow, to: white))))
            require(CaptureAnnotationGeometry.hitTest(arrow, at: CGPoint(x: 100, y: 60)), "\(style.rawValue) arrow has selectable visible geometry")
        }
        require(images.count == ImageEditArrowStyle.allCases.count, "Every exposed arrow style renders a distinct shape")
        var alpha = stroke(.rectangle); alpha.style.filled = true; alpha.color = .red.withAlphaComponent(0.25)
        let translucent = try bytes(ImageEditingOperations.apply(alpha, to: white))
        require((189...193).contains(Int(pixel(translucent, x: 60, y: 60)[1])), "Annotation color alpha blends with the underlying image")
        var highlighter = stroke(.highlight); highlighter.style.effectShape = .rectangle; highlighter.style.blendMode = .multiply; highlighter.color = .yellow
        let highlighted = try bytes(ImageEditingOperations.apply(highlighter, to: white))
        require(pixel(highlighted, x: 60, y: 60) == [255, 255, 0, 255], "Rectangle highlighter supports multiply blending")
        highlighter.style.blendMode = .normal
        require(try bytes(ImageEditingOperations.apply(highlighter, to: white)) != highlighted, "Normal and multiply highlighting have different visible effects")
    }
    static func textTests() throws {
        require(ImageEditingOperations.sequenceLabel(27, style: .alphabetic) == "AA", "Alphabetic sequences continue beyond Z")
        require(ImageEditingOperations.sequenceLabel(99, style: .roman) == "XCIX", "Roman sequences handle subtractive notation")
        require(ImageEditingOperations.sequenceLabel(52, style: .decimal) == "52", "Decimal sequence labels retain numeric values")
        let white = fixture(white: true)
        var text = stroke(.text, CGPoint(x: 20, y: 20)); text.points = [CGPoint(x: 20, y: 20)]; text.text = "中文 annotation wrapping tests"
        let natural = ImageEditingOperations.textBounds(for: text)
        text.style.wrapMode = .word; text.style.wrapWidth = 80
        let wrapped = ImageEditingOperations.textBounds(for: text)
        require(wrapped.height > natural.height && wrapped.width <= 81, "Word wrapping constrains text width and creates additional lines")
        text.style.wrapMode = .character
        require(ImageEditingOperations.textBounds(for: text).height > natural.height, "Character wrapping also supports long unbroken strings")
        text.text = "Style"; text.style.wrapMode = .none; text.style.bold = true; text.style.italic = true
        text.style.fontName = NSFont.monospacedSystemFont(ofSize: 20, weight: .regular).fontName
        let font = ImageEditingOperations.font(for: text)
        require(NSFontManager.shared.traits(of: font).contains(.boldFontMask), "Text font selection applies the bold trait")
        let attributes = ImageEditingOperations.textAttributes(for: text)
        require(NSFontManager.shared.traits(of: font).contains(.italicFontMask) || attributes[.obliqueness] != nil, "Italic text uses a font trait or explicit synthetic obliqueness")
        let plain = try bytes(ImageEditingOperations.apply(text, to: white))
        text.style.outlineWidth = 2; text.style.outlineColor = .blue
        let outlined = try bytes(ImageEditingOperations.apply(text, to: white))
        require(outlined != plain && (attributes[.font] as? NSFont)?.fontName == font.fontName, "Glyph outlines render independently of the chosen font")
        text.style.backgroundColor = .green; text.style.backgroundPadding = 6; text.style.backgroundRadius = 4
        let background = try bytes(ImageEditingOperations.apply(text, to: white))
        require(pixel(background, x: 18, y: 25)[1] > 200 && pixel(background, x: 18, y: 25)[0] < 30, "Text backgrounds render behind the glyphs and extend into padding")
        require(ImageEditingOperations.textBounds(for: text).minX == 12, "Text geometry includes both background padding and outline thickness")
        text.style.rotation = .pi / 5
        require(try bytes(ImageEditingOperations.apply(text, to: white)) != background, "Styled text rotates in the exported image")
        var number = stroke(.number, CGPoint(x: 50, y: 50), CGPoint(x: 130, y: 80)); number.number = 28; number.style.sequenceStyle = .alphabetic; number.text = "说明"
        require(try changedPixels(bytes(white), bytes(ImageEditingOperations.apply(number, to: white))) > 500, "Sequence badges render their label, attached arrow, and caption")
        let old = Data("{\"toolRawValue\":\"文字\",\"red\":0.2,\"green\":0.4,\"blue\":0.6,\"lineWidth\":6,\"textSize\":32,\"number\":8}".utf8)
        let decoded = try JSONDecoder().decode(ImageEditorPreferences.self, from: old)
        require(decoded.alpha == 1 && decoded.textSize == 32 && decoded.number == 8, "Adding alpha preferences preserves existing saved editor settings")
    }
    @MainActor static func pixelEffectTests() throws {
        let source = fixture(), original = try bytes(source)
        var mosaic = stroke(.mosaic, CGPoint(x: 20, y: 35), CGPoint(x: 140, y: 35)); mosaic.style.effectShape = .brush; mosaic.width = 20; mosaic.style.effectStrength = 5
        let mask = try bytes(ImageEditingOperations.apply(mosaic, to: source, source: source))
        require(pixel(mask, x: 60, y: 35) != pixel(original, x: 60, y: 35), "Brush mosaic changes pixels along its path")
        require(pixel(mask, x: 60, y: 90) == pixel(original, x: 60, y: 90), "Brush mosaic preserves unrelated rows and uses top-left coordinates")
        var blur = stroke(.blur); blur.style.effectStrength = 8
        let blurred = try bytes(ImageEditingOperations.apply(blur, to: source, source: source))
        let before = (40..<85).map { Int(pixel(original, x: $0, y: 60)[0]) }
        let after = (40..<85).map { Int(pixel(blurred, x: $0, y: 60)[0]) }
        require(after.max()! - after.min()! < (before.max()! - before.min()!) / 3, "Blur lowers local high-frequency contrast")
        require(pixel(blurred, x: 110, y: 100) == pixel(original, x: 110, y: 100), "Blur sampling beyond its boundary does not modify outside pixels")
        blur.style.effectShape = .ellipse
        let ellipticBlur = try bytes(ImageEditingOperations.apply(blur, to: source, source: source))
        require(pixel(ellipticBlur, x: 31, y: 31) == pixel(original, x: 31, y: 31), "Ellipse blur preserves corners outside its mask")
        let document = CaptureAnnotationDocument(image: source); document.setSelection(document.bounds)
        var fill = stroke(.rectangle, CGPoint(x: 10, y: 10), CGPoint(x: 160, y: 120)); fill.style.filled = true
        try document.append(fill)
        let painted = try bytes(document.renderedImage)
        var eraser = stroke(.eraser, CGPoint(x: 20, y: 35), CGPoint(x: 140, y: 35)); eraser.style.effectShape = .brush; eraser.width = 20
        try document.append(eraser)
        let erased = try bytes(document.renderedImage)
        require(pixel(erased, x: 60, y: 35) == pixel(original, x: 60, y: 35), "Eraser restores immutable source pixels rather than clearing them transparent")
        require(pixel(erased, x: 60, y: 80) == [255, 0, 0, 255], "Eraser preserves earlier annotations outside its stroke")
        document.undo(); require(try bytes(document.renderedImage) == painted, "Undo restores the exact annotation before local erasing")
        document.redo(); require(try bytes(document.renderedImage) == erased, "Redo reproduces local erasing exactly")
        var late = stroke(.line, CGPoint(x: 30, y: 35), CGPoint(x: 100, y: 35)); late.color = .blue
        try document.append(late)
        require(try pixel(bytes(document.renderedImage), x: 60, y: 35) == [0, 0, 255, 255], "Annotations drawn after an eraser remain visible over the restored source")
        let complete = try bytes(document.renderedImage)
        try document.removeAll(); require(document.strokes.isEmpty && document.renderedImage === source && document.canUndo, "Clear-all removes annotations as one reversible operation")
        document.undo(); require(try bytes(document.renderedImage) == complete && document.strokes.count == 3, "Undo clear-all restores the complete ordered command list")
        document.redo(); require(document.strokes.isEmpty, "Redo clear-all removes the recovered annotations again")
        var spot = stroke(.spotlight); spot.style.showsBorder = false; spot.style.spotlightOpacity = 0.6
        let spotlight = try bytes(ImageEditingOperations.apply(spot, to: source))
        require(pixel(spotlight, x: 60, y: 60) == pixel(original, x: 60, y: 60), "Spotlight keeps the highlighted region's source pixels unchanged")
        require(Int(pixel(spotlight, x: 120, y: 120)[0]) < Int(pixel(original, x: 120, y: 120)[0]), "Spotlight exports a darkened surrounding area")
        spot.style.rotation = .pi / 4
        let rotated = try bytes(ImageEditingOperations.apply(spot, to: source))
        require(pixel(rotated, x: 180, y: 10)[0] < pixel(original, x: 180, y: 10)[0], "Rotating a spotlight preserves full-image darkening coverage")
    }
    static func watermarkAndMagnifierTests() throws {
        let source = fixture(), original = try bytes(source)
        var watermark = stroke(.watermark, CGPoint(x: 10, y: 10), CGPoint(x: 180, y: 150)); watermark.text = "水印"; watermark.fontSize = 16
        watermark.style.watermarkPlacement = .bottomRight; watermark.color = .white.withAlphaComponent(0.5)
        let corner = try bytes(ImageEditingOperations.apply(watermark, to: source))
        require(pixel(corner, x: 30, y: 30) == pixel(original, x: 30, y: 30) && changedPixels(original, corner) > 20, "Corner watermark changes only its positioned text area")
        watermark.style.watermarkPlacement = .tiled; watermark.style.watermarkSpacing = 15
        let tiled = try bytes(ImageEditingOperations.apply(watermark, to: source))
        require(changedPixels(original, tiled) > changedPixels(original, corner) * 2, "Tiled watermarks repeat over their selected area")
        require(pixel(tiled, x: 5, y: 5) == pixel(original, x: 5, y: 5), "Watermark tiling is clipped to its requested area")
        var magnify = stroke(.magnify, CGPoint(x: 140, y: 80), CGPoint(x: 160, y: 100))
        magnify.style.magnifierSourceRect = CGRect(x: 20, y: 20, width: 20, height: 20); magnify.style.magnification = 2
        magnify.style.showsBorder = false; magnify.style.connectorStyle = .none; magnify.style.antialias = false
        let enlarged = try bytes(ImageEditingOperations.apply(magnify, to: source, source: source))
        require(ImageEditingOperations.magnifierDestinationRect(for: magnify) == CGRect(x: 130, y: 70, width: 40, height: 40), "Magnifier destination size follows its independent source rectangle and zoom")
        require(pixel(enlarged, x: 139, y: 79) == pixel(original, x: 24, y: 24), "Magnifier exports nearest-neighbour source pixels at the correct top-left coordinates")
        require(pixel(enlarged, x: 100, y: 120) == pixel(original, x: 100, y: 120), "Magnifier leaves pixels outside its destination unchanged")
        var annotation = stroke(.rectangle, CGPoint(x: 20, y: 20), CGPoint(x: 40, y: 40)); annotation.style.filled = true
        let painted = try ImageEditingOperations.apply(annotation, to: source)
        let withMarks = try bytes(ImageEditingOperations.apply(magnify, to: painted, source: source))
        require(pixel(withMarks, x: 140, y: 80) == [255, 0, 0, 255], "Magnifier can sample annotations below it")
        magnify.style.includesAnnotations = false
        let withoutMarks = try bytes(ImageEditingOperations.apply(magnify, to: painted, source: source))
        require(pixel(withoutMarks, x: 139, y: 79) == pixel(original, x: 24, y: 24), "Disabling lower annotations samples immutable source without deleting the actual annotations")
        require(pixel(withoutMarks, x: 25, y: 25) == [255, 0, 0, 255], "Magnifier annotation visibility does not remove marks outside the lens")
        magnify.style.effectShape = .ellipse
        let ellipse = try bytes(ImageEditingOperations.apply(magnify, to: source, source: source))
        require(pixel(ellipse, x: 131, y: 71) == pixel(original, x: 131, y: 71), "Ellipse magnifiers clip the enlargement to their visible lens")
    }
    @MainActor static func repairAndHistoryTests() throws {
        let source = fixture(width: 128, height: 128, gradient: true), original = try bytes(source)
        var obstruction = stroke(.rectangle, CGPoint(x: 40, y: 40), CGPoint(x: 80, y: 80)); obstruction.style.filled = true; obstruction.color = .red
        let damaged = try ImageEditingOperations.apply(obstruction, to: source), damagedBytes = try bytes(damaged)
        let repair = stroke(.inpaint, CGPoint(x: 40, y: 40), CGPoint(x: 80, y: 80))
        let repaired = try bytes(ImageEditingOperations.apply(repair, to: damaged, source: source))
        var initialError = 0, repairError = 0
        for y in 42..<78 { for x in 42..<78 {
            let at = (y * 128 + x) * 4
            for c in 0..<3 { initialError += abs(Int(damagedBytes[at + c]) - Int(original[at + c])); repairError += abs(Int(repaired[at + c]) - Int(original[at + c])) }
        } }
        require(repairError < initialError / 3, "Local boundary diffusion reconstructs a smooth gradient substantially better than leaving the obstruction")
        require(pixel(repaired, width: 128, x: 45, y: 45) != pixel(repaired, width: 128, x: 75, y: 75), "Repair preserves varying boundary colours instead of substituting one solid fill")
        require(pixel(repaired, width: 128, x: 20, y: 20) == pixel(original, width: 128, x: 20, y: 20), "Repair preserves pixels outside its mask")
        let doc = CaptureAnnotationDocument(image: source); doc.setSelection(doc.bounds)
        try doc.append(obstruction); try doc.append(repair)
        let accepted = try bytes(doc.renderedImage)
        var moved = repair; moved.points = [CGPoint(x: 44, y: 44), CGPoint(x: 76, y: 76)]
        let preview = try doc.preview(replacing: 1, with: moved)
        require(try bytes(doc.renderedImage) == accepted, "Effect replacement preview does not mutate the accepted image")
        try doc.replace(at: 1, with: moved)
        require(try bytes(doc.renderedImage) == bytes(preview), "Effect replacement commits exactly its preview pixels")
        doc.undo(); require(try bytes(doc.renderedImage) == accepted, "Undo replays source-dependent repair deterministically")
        var invalid = moved; invalid.style.effectStrength = .nan
        do { try doc.replace(at: 1, with: invalid); preconditionFailure("Invalid effect style must throw") }
        catch { require(try doc.canRedo && bytes(doc.renderedImage) == accepted, "Invalid effect style preserves image and redo history") }
        var unsupported = repair; unsupported.points = [.zero, CGPoint(x: 128, y: 128)]
        do { try doc.append(unsupported); preconditionFailure("Repair without surrounding pixels must fail") }
        catch { require(try doc.strokes.count == 2 && bytes(doc.renderedImage) == accepted, "A full-frame repair with no boundary fails atomically") }
        doc.redo(); require(try bytes(doc.renderedImage) == bytes(preview), "Redo remains valid after rejected pixel effects")
    }
    @MainActor static func standaloneEditorTests() throws {
        let source = fixture(), original = try bytes(source), model = ImageEditorModel(data: try CaptureImageCodec.png(source))
        var mark = stroke(.rectangle, CGPoint(x: 30, y: 30), CGPoint(x: 100, y: 100)); mark.style.filled = true
        let eraser = stroke(.eraser, CGPoint(x: 30, y: 30), CGPoint(x: 100, y: 100))
        model.edit(mark); model.edit(eraser)
        require(try model.failure == nil && bytes(model.image!) == original, "The standalone editor supplies its immutable source to erasing")
        model.undo(); model.undo()
        model.edit(stroke(.crop, CGPoint(x: 10, y: 10), CGPoint(x: 150, y: 140)))
        let cropped = try bytes(model.image!)
        model.edit(mark); model.edit(eraser)
        require(try model.failure == nil && bytes(model.image!) == cropped, "Cropping transforms the standalone eraser source along with the edited image")
        model.undo(); model.undo(); model.undo(); model.rotate()
        let rotated = try bytes(model.image!)
        model.edit(mark); model.edit(eraser)
        require(try model.failure == nil && bytes(model.image!) == rotated, "Undo and rotation preserve the matching immutable source for later erasing")
    }
    @MainActor static func redactionTests() async throws {
        require(CaptureToolbarConfiguration.sanitized([.blur, .crop, .blur, .text, .arrow]) == [.blur, .text, .arrow], "Toolbar customization preserves order while excluding crop and duplicate slots")
        require(CaptureToolbarConfiguration.sanitized(ImageEditTool.allCases).count == 8, "A custom toolbar is bounded to eight annotation slots plus selection")
        let text = "CODE 4827 / CODE 4827 / code 4827"
        let ranges = CaptureRedaction.ranges(of: ["CODE 4827", "CODE", "C"], in: text)
        require(ranges.map { String(text[$0]) } == ["CODE 4827", "CODE 4827"], "Matching redaction keeps exact case-sensitive occurrences, prefers full phrases, and rejects single-character needles")
        let mapped = CaptureRedaction.sourceRect(normalized: CGRect(x: 0.25, y: 0.6, width: 0.2, height: 0.1), selection: CGRect(x: 100, y: 200, width: 800, height: 400))
        require(mapped == CGRect(x: 298, y: 318, width: 164, height: 45) || mapped == CGRect(x: 298, y: 318, width: 164, height: 44), "OCR bottom-left boxes map to padded top-left source coordinates")
        let white = fixture(width: 900, height: 300)
        var first = stroke(.text, CGPoint(x: 25, y: 30)); first.points = [CGPoint(x: 25, y: 30)]; first.text = "CODE 4827"; first.fontSize = 48; first.color = .black
        first.style.fontName = "Helvetica-Bold"
        var second = first; second.points = [CGPoint(x: 470, y: 180)]
        let source = try ImageEditingOperations.render([first, second], source: white)
        let sample = ImageEditingOperations.textBounds(for: first).insetBy(dx: -8, dy: -8)
        let matches = try await CaptureRedaction.matches(source: source, sample: sample, selection: CGRect(x: 0, y: 0, width: 900, height: 300))
        require(matches.count == 1 && matches[0].text == "CODE 4827" && matches[0].rect.minX > 420 && matches[0].rect.minY > 150 && matches[0].rect.intersects(ImageEditingOperations.textBounds(for: second)), "Real on-device Vision OCR locates the second synthetic text occurrence and excludes the already masked sample")
        let doc = CaptureAnnotationDocument(image: source); doc.setSelection(doc.bounds)
        let original = try bytes(source), masks = matches.map { stroke(.mosaic, $0.rect.origin, CGPoint(x: $0.rect.maxX, y: $0.rect.maxY)) }
        let preview = try doc.preview(appending: masks)
        require(doc.strokes.isEmpty && doc.revision == 0, "Batch redaction preview does not mutate the document or revision")
        try doc.append(contentsOf: masks)
        require(try bytes(doc.renderedImage) == bytes(preview), "Batch redaction commits precisely the shown preview")
        doc.undo(); require(try doc.strokes.isEmpty && bytes(doc.renderedImage) == original, "One undo removes the whole batch of automatically matched redactions")
        doc.redo(); require(try bytes(doc.renderedImage) == bytes(preview), "Redo restores the matched redaction batch deterministically")
    }
    @MainActor static func main() async throws {
        try vectorTests(); try textTests(); try pixelEffectTests(); try watermarkAndMagnifierTests(); try repairAndHistoryTests(); try standaloneEditorTests(); try await redactionTests()
        print("Advanced annotation tests passed: \(checks) checks. Synthetic pixels only; no capture or external requests.")
    }
}
