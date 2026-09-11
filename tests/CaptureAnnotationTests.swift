import AppKit

/// Synthetic pixels only: never captures the desktop, opens windows, or requests permission.
@main
struct CaptureAnnotationTests {
    static var checks = 0

    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        let passed = (try? condition()) ?? false
        precondition(passed, message)
        checks += 1
        print("PASS: \(message)")
    }

    static func geometryTests() {
        let bounds = CGRect(x: 0, y: 0, width: 160, height: 120)
        let rect = CGRect(x: 20, y: 30, width: 60, height: 40)
        require(CaptureSelectionGeometry.clamped(CGRect(x: 80, y: 70, width: -60, height: -40), to: bounds) == rect,
                "Reverse initial drag produces a standardized selection")
        require(CaptureSelectionGeometry.clamped(CGRect(x: -20, y: 15, width: 200, height: 150), to: bounds)
                == CGRect(x: 0, y: 15, width: 160, height: 105), "Selection clips all image edges")
        require(CaptureSelectionGeometry.clamped(CGRect(x: 180, y: 130, width: 20, height: 20), to: bounds)
                == CGRect(x: 160, y: 120, width: 0, height: 0), "A wholly outside drag produces an empty selection")
        require(CaptureSelectionGeometry.clamped(CGRect(x: CGFloat.nan, y: 0, width: 20, height: 20), to: bounds) == .zero,
                "Non-finite selection coordinates are rejected")
        require(CaptureSelectionGeometry.moved(rect, by: CGSize(width: 200, height: -200), within: bounds)
                == CGRect(x: 100, y: 0, width: 60, height: 40), "Move preserves selection dimensions at image boundaries")
        require(CaptureSelectionGeometry.moved(rect, by: CGSize(width: -200, height: 200), within: bounds)
                == CGRect(x: 0, y: 80, width: 60, height: 40), "Move clamps the opposite boundaries")

        let expected: [CaptureSelectionHandle: CGRect] = [
            .topLeft: CGRect(x: 15, y: 23, width: 65, height: 47),
            .top: CGRect(x: 20, y: 23, width: 60, height: 47),
            .topRight: CGRect(x: 20, y: 23, width: 55, height: 47),
            .right: CGRect(x: 20, y: 30, width: 55, height: 40),
            .bottomRight: CGRect(x: 20, y: 30, width: 55, height: 33),
            .bottom: CGRect(x: 20, y: 30, width: 60, height: 33),
            .bottomLeft: CGRect(x: 15, y: 30, width: 65, height: 33),
            .left: CGRect(x: 15, y: 30, width: 65, height: 40)
        ]
        for handle in CaptureSelectionHandle.allCases {
            let result = CaptureSelectionGeometry.resized(rect, handle: handle, by: CGSize(width: -5, height: -7), within: bounds)
            require(result == expected[handle], "\(handle) resizes only its controlled edges")
            for scale: CGFloat in [1, 2] {
                let transform = CGAffineTransform(scaleX: scale, y: scale)
                let scaled = CaptureSelectionGeometry.resized(rect.applying(transform), handle: handle,
                    by: CGSize(width: -5 * scale, height: -7 * scale), within: bounds.applying(transform), minimumSize: 2 * scale)
                require(scaled == result.applying(transform), "\(handle) preserves geometry at \(Int(scale))x pixel mapping")
            }
            for dx: CGFloat in [-1_000, 0, 1_000] {
                for dy: CGFloat in [-1_000, 0, 1_000] {
                    let clipped = CaptureSelectionGeometry.resized(rect, handle: handle,
                        by: CGSize(width: dx, height: dy), within: bounds)
                    require(bounds.contains(clipped) && clipped.width >= 2 && clipped.height >= 2,
                            "\(handle) remains bounded for delta \(Int(dx)),\(Int(dy))")
                }
            }
        }
        require(CaptureSelectionGeometry.resized(rect, handle: .topLeft, by: CGSize(width: 80, height: 70), within: bounds)
                == CGRect(x: 80, y: 70, width: 20, height: 30), "Corner drag crosses both fixed opposite edges")
        require(CaptureSelectionGeometry.resized(rect, handle: .right, by: CGSize(width: -80, height: 90), within: bounds)
                == CGRect(x: 0, y: 30, width: 20, height: 40), "Edge drag can cross to the other side without changing the orthogonal axis")
        require(CaptureSelectionGeometry.resized(rect, handle: .left, by: CGSize(width: 60, height: 0), within: bounds)
                == CGRect(x: 78, y: 30, width: 2, height: 40), "Coincident edges retain the minimum selection size")
        require(CaptureSelectionGeometry.resized(CGRect(x: 0, y: 0, width: 1, height: 1), handle: .bottomRight,
                by: .zero, within: CGRect(x: 0, y: 0, width: 1, height: 1)) == CGRect(x: 0, y: 0, width: 1, height: 1),
                "Image bounds take precedence when smaller than the requested minimum")
        let handles = CaptureSelectionGeometry.handles(for: rect)
        require(handles.map(\.0) == CaptureSelectionHandle.allCases, "Handles have a stable clockwise order")
        require(handles.map(\.1) == [CGPoint(x: 20, y: 30), CGPoint(x: 50, y: 30), CGPoint(x: 80, y: 30),
                                     CGPoint(x: 80, y: 50), CGPoint(x: 80, y: 70), CGPoint(x: 50, y: 70),
                                     CGPoint(x: 20, y: 70), CGPoint(x: 20, y: 50)],
                "Eight handles are positioned at corners and edge midpoints")
        let offsetBounds = CGRect(x: 50, y: 70, width: 160, height: 120)
        require(CaptureSelectionGeometry.moved(rect.offsetBy(dx: 50, dy: 70), by: CGSize(width: 300, height: -300), within: offsetBounds)
                == CGRect(x: 150, y: 70, width: 60, height: 40), "Geometry also supports an offset canvas origin")
    }

    static func fixture(width: Int, height: Int, white: Bool = false) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        if !white {
            for y in 0..<height {
                for x in 0..<width {
                    let index = (y * width + x) * 4
                    bytes[index] = UInt8((x * 19 + y * 7) % 256)
                    bytes[index + 1] = UInt8((x * 5 + y * 23) % 256)
                    bytes[index + 2] = UInt8((x * 11 + y * 3) % 256)
                }
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func bytes(_ image: CGImage) throws -> [UInt8] {
        let context = try CaptureImageCodec.context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let raw = try bytes(image), offset = (y * image.width + x) * 4
        return Array(raw[offset..<(offset + 4)])
    }

    @MainActor static func documentTests() throws {
        let original = fixture(width: 120, height: 100, white: true)
        let document = CaptureAnnotationDocument(image: original)
        require(document.source === original && document.renderedImage === original, "Initial cache reuses the immutable source image")
        require(document.selection == nil && !document.canUndo && !document.canRedo, "A new capture has no selection or annotation history")
        do { _ = try document.export(); preconditionFailure("Export must require a selection") }
        catch { require(error is CaptureMessage, "Export without a selection reports an actionable error") }
        document.setSelection(CGRect(x: 80, y: 45, width: -75, height: -40))
        require(document.selection == CGRect(x: 5, y: 5, width: 75, height: 40), "Document accepts reverse-drag selection")
        let red = ImageEditStroke(tool: .arrow, points: [CGPoint(x: 12, y: 15), CGPoint(x: 65, y: 15)], color: .red, width: 4, text: "")
        try document.append(red)
        let redImage = document.renderedImage
        let redBytes = try bytes(redImage)
        require(document.strokes.count == 1 && document.canUndo && !document.canRedo, "Arrow commits a reversible annotation")
        require(try pixel(document.source, x: 30, y: 15) == [255, 255, 255, 255], "Arrow does not modify the retained source")
        let export = try CaptureImageCodec.decode(document.export())
        require(export.width == 75 && export.height == 40, "Export dimensions match the selected image pixels")
        let arrowPixel = try pixel(export, x: 25, y: 10)
        require(arrowPixel[0] > 240 && arrowPixel[1] < 20, "Export places the arrow at the expected top-left crop coordinates")
        require(try pixel(export, x: 25, y: 30) == [255, 255, 255, 255], "Arrow is not vertically flipped in the crop")
        document.setSelection(CGRect(x: 20, y: 10, width: 70, height: 45))
        require(document.renderedImage === redImage && document.strokes.count == 1, "Moving selection preserves the render cache and absolute annotation coordinates")
        let movedExport = try CaptureImageCodec.decode(document.export())
        require(try pixel(movedExport, x: 10, y: 5)[1] < 20, "Annotation remains at its source position after selection moves")
        document.undo()
        require(document.renderedImage === original && !document.canUndo && document.canRedo, "Undo restores the retained source without allocating another source bitmap")
        require(document.selection == CGRect(x: 20, y: 10, width: 70, height: 45), "Undo does not move the current selection")
        document.redo()
        require(try bytes(document.renderedImage) == redBytes, "Redo restores exactly the committed arrow pixels")
        document.undo()
        try document.append(ImageEditStroke(tool: .rectangle, points: [CGPoint(x: 5, y: 5), CGPoint(x: 20, y: 20)], color: .blue, width: 2, text: ""))
        require(!document.canRedo && document.strokes.count == 1, "A new annotation clears the redo branch")
        let cached = document.renderedImage
        document.resetSelection()
        require(document.selection == nil && document.renderedImage === cached && document.strokes.count == 1,
                "Re-selecting retains the full annotated image")
        document.setSelection(CGRect(x: -5, y: -10, width: 500, height: 500))
        require(document.selection == document.bounds, "A large new selection exposes the full original capture")
        let fullExport = try CaptureImageCodec.decode(document.export())
        require(fullExport.width == original.width && fullExport.height == original.height, "Selection expansion restores the original image extent")
        let priorHistory = document.strokes.count
        try document.append(ImageEditStroke(tool: .crop, points: [CGPoint(x: 5, y: 5), CGPoint(x: 15, y: 15)], color: .red, width: 2, text: ""))
        require(document.strokes.count == priorHistory && document.renderedImage === cached && document.selection?.size == CGSize(width: 10, height: 10),
                "Crop commands change selection without destructively cropping annotation storage")
        document.setSelection(CGRect(x: 2, y: 2, width: 1, height: 10))
        require(document.selection == nil, "Subminimum selections cannot be exported accidentally")

        for scale in [1, 2] {
            let mapped = CaptureAnnotationDocument(image: fixture(width: 80 * scale, height: 60 * scale, white: true))
            mapped.setSelection(CGRect(x: 5 * scale, y: 7 * scale, width: 30 * scale, height: 20 * scale))
            try mapped.append(ImageEditStroke(tool: .pen,
                points: [CGPoint(x: 10 * scale, y: 12 * scale), CGPoint(x: 25 * scale, y: 12 * scale)], color: .red,
                width: CGFloat(2 * scale), text: ""))
            let image = try CaptureImageCodec.decode(mapped.export())
            require(image.width == 30 * scale && image.height == 20 * scale, "\(scale)x export keeps native pixels")
            require(try pixel(image, x: 12 * scale, y: 5 * scale)[1] < 20, "\(scale)x annotations align with the scaled selection")
        }
    }

    @MainActor static func mosaicTests() throws {
        let source = fixture(width: 96, height: 80)
        let document = CaptureAnnotationDocument(image: source)
        document.setSelection(CGRect(x: 20, y: 12, width: 32, height: 24))
        let pen = ImageEditStroke(tool: .pen, points: [CGPoint(x: 20, y: 18), CGPoint(x: 50, y: 18)], color: .red, width: 4, text: "")
        try document.append(pen)
        let penBytes = try bytes(document.renderedImage)
        let mosaic = ImageEditStroke(tool: .mosaic, points: [CGPoint(x: 20, y: 12), CGPoint(x: 52, y: 36)], color: .red, width: 4, text: "")
        try document.append(mosaic)
        let mosaicBytes = try bytes(document.renderedImage)
        let first = try pixel(document.renderedImage, x: 20, y: 12)
        require(try first == pixel(document.renderedImage, x: 31, y: 23), "Mosaic produces actual uniform 12-pixel blocks")
        require(try pixel(document.renderedImage, x: 25, y: 18) != pixel(source, x: 25, y: 18), "Mosaic changes the selected source pixels")
        require(try pixel(document.renderedImage, x: 60, y: 12) == pixel(source, x: 60, y: 12), "Mosaic preserves pixels outside its region")
        require(try pixel(document.renderedImage, x: 25, y: 60) == pixel(source, x: 25, y: 60), "Mosaic uses top-left rows without vertical inversion")
        let exported = try CaptureImageCodec.decode(document.export())
        require(try pixel(exported, x: 0, y: 0) == pixel(exported, x: 11, y: 11), "Cropped PNG includes committed mosaic pixels")
        document.setSelection(CGRect(x: 44, y: 28, width: 30, height: 35))
        let moved = try CaptureImageCodec.decode(document.export())
        let expected = try CaptureImageCodec.decode(CaptureImageCodec.png(CaptureImageCodec.crop(document.renderedImage, rect: document.selection!)))
        require(try bytes(moved) == bytes(expected), "Moving and enlarging selection exports the correct annotated source area")
        try document.append(ImageEditStroke(tool: .arrow, points: [CGPoint(x: 10, y: 50), CGPoint(x: 80, y: 50)], color: .blue, width: 3, text: ""))
        document.undo()
        require(try bytes(document.renderedImage) == mosaicBytes, "Undo replays the mosaic on the prior annotation pixels exactly")
        document.undo()
        require(try bytes(document.renderedImage) == penBytes, "Undoing mosaic restores the earlier annotation")
        document.redo()
        require(try bytes(document.renderedImage) == mosaicBytes, "Redo restores exactly the same mosaic")
        document.undo()
        document.undo()
        require(document.renderedImage === source, "Undoing every annotation recovers the immutable original")
    }

    @MainActor static func inputAndTextTests() throws {
        let document = CaptureAnnotationDocument(image: fixture(width: 160, height: 80, white: true))
        document.setSelection(document.bounds)
        try document.append(ImageEditStroke(tool: .text, points: [CGPoint(x: 8, y: 6)], color: .black, width: 2, text: "截图标注", fontSize: 20))
        let rendered = try bytes(document.renderedImage)
        require(rendered.filter({ $0 < 128 }).count > 100, "Chinese text annotations render visible glyph pixels")
        require(try pixel(document.renderedImage, x: 20, y: 65) == [255, 255, 255, 255], "Text preserves the opposite side of the image")
        document.undo()
        document.redo()
        require(try bytes(document.renderedImage) == rendered, "Text undo and redo produce identical rendering")
        let count = document.strokes.count
        let cached = document.renderedImage
        let invalid = [
            ImageEditStroke(tool: .text, points: [CGPoint(x: 1, y: 1)], color: .black, width: 2, text: " \n "),
            ImageEditStroke(tool: .pen, points: [CGPoint(x: CGFloat.nan, y: 1)], color: .red, width: 2, text: ""),
            ImageEditStroke(tool: .mosaic, points: [CGPoint(x: 1, y: 1)], color: .red, width: .infinity, text: ""),
            ImageEditStroke(tool: .pen, points: [], color: .red, width: 2, text: ""),
            ImageEditStroke(tool: .pen, points: Array(repeating: CGPoint(x: 1, y: 1), count: 100_001), color: .red, width: 2, text: "")
        ]
        for stroke in invalid {
            do { try document.append(stroke); preconditionFailure("Invalid annotation must throw") }
            catch {
                require(document.strokes.count == count && document.renderedImage === cached && document.failure != nil,
                        "Invalid or excessive input preserves the document and reports failure")
            }
        }
    }

    static func annotationGeometryTests() {
        let area = CGRect(x: 0, y: 0, width: 160, height: 120)
        let rectangle = ImageEditStroke(tool: .rectangle, points: [CGPoint(x: 20, y: 30), CGPoint(x: 80, y: 70)], color: .red, width: 4, text: "")
        require(CaptureAnnotationGeometry.bounds(of: rectangle) == CGRect(x: 18, y: 28, width: 64, height: 44), "Object bounds include the visible rectangle stroke")
        require(CaptureAnnotationGeometry.hitTest(rectangle, at: CGPoint(x: 50, y: 30), tolerance: 0), "Rectangle hit testing finds its top edge")
        require(!CaptureAnnotationGeometry.hitTest(rectangle, at: CGPoint(x: 50, y: 50)), "An empty rectangle interior does not steal clicks from another annotation")
        require(CaptureAnnotationGeometry.hitTest(rectangle, at: CGPoint(x: 15, y: 50), tolerance: 4), "Rectangle hit tolerance is measured from the visible edge")
        var ellipse = rectangle; ellipse.tool = .ellipse
        require(CaptureAnnotationGeometry.hitTest(ellipse, at: CGPoint(x: 50, y: 30), tolerance: 0), "Ellipse hit testing finds the curved edge")
        require(!CaptureAnnotationGeometry.hitTest(ellipse, at: CGPoint(x: 50, y: 50)), "Ellipse interior remains available for other objects")
        require(!CaptureAnnotationGeometry.hitTest(ellipse, at: CGPoint(x: 20, y: 30), tolerance: 0), "The empty corner of an ellipse bounding rectangle does not hit")
        var arrow = rectangle; arrow.tool = .arrow; arrow.points = [CGPoint(x: 20, y: 50), CGPoint(x: 100, y: 50)]
        require(CaptureAnnotationGeometry.hitTest(arrow, at: CGPoint(x: 60, y: 50), tolerance: 0), "Arrow shaft is selectable")
        require(CaptureAnnotationGeometry.hitTest(arrow, at: ImageEditingOperations.arrowGeometry(for: arrow)!.headLeft, tolerance: 0), "The rendered arrow head wings are selectable")
        require(!CaptureAnnotationGeometry.hitTest(arrow, at: CGPoint(x: 60, y: 80)), "Arrow hit testing rejects distant points")
        var mosaic = rectangle; mosaic.tool = .mosaic
        require(CaptureAnnotationGeometry.hitTest(mosaic, at: CGPoint(x: 50, y: 50), tolerance: 0), "Mosaic objects can be selected from their covered interior")
        require(CaptureAnnotationGeometry.bounds(of: mosaic) == rectangle.rect, "Mosaic geometry has no decorative stroke expansion")
        var number = rectangle; number.tool = .number; number.points = [CGPoint(x: 50, y: 50)]
        require(CaptureAnnotationGeometry.bounds(of: number) == CGRect(x: 37, y: 37, width: 26, height: 26), "Number bounds match the rendered badge radius")
        require(CaptureAnnotationGeometry.hitTest(number, at: CGPoint(x: 50, y: 50)), "Number badge interiors are selectable")
        require(!CaptureAnnotationGeometry.hitTest(number, at: CGPoint(x: 63, y: 63), tolerance: 0), "Number hit testing follows the circle instead of its square bounds")
        var text = rectangle; text.tool = .text; text.points = [CGPoint(x: 20, y: 20)]; text.text = "中文\n标注"; text.fontSize = 20
        require(CaptureAnnotationGeometry.bounds(of: text) == ImageEditingOperations.textBounds(for: text), "Text selection uses the exact renderer's multiline metrics")
        let textBounds = CaptureAnnotationGeometry.bounds(of: text)
        require(textBounds.height > 20 && CaptureAnnotationGeometry.hitTest(text, at: CGPoint(x: textBounds.midX, y: textBounds.midY)), "Multiline text remains selectable across its rendered extent")
        for tool: ImageEditTool in [.pen, .highlight, .crop] {
            var freehand = rectangle; freehand.tool = tool; freehand.style.effectShape = .brush
            require(!CaptureAnnotationGeometry.hitTest(freehand, at: CGPoint(x: 20, y: 30)), "\(tool) does not participate in editable object hit testing")
        }
        let moved = CaptureAnnotationGeometry.moved(rectangle, by: CGSize(width: 500, height: -500), within: area)
        require(moved.points == [CGPoint(x: 98, y: 2), CGPoint(x: 158, y: 42)], "Object movement clamps the entire visible stroke against screen edges")
        require(moved.width == rectangle.width && moved.color == rectangle.color && moved.tool == rectangle.tool && moved.rect.size == rectangle.rect.size,
                "Constrained movement preserves object geometry and style")
        let movedArrow = CaptureAnnotationGeometry.moved(arrow, by: CGSize(width: -500, height: 500), within: area)
        let movedArrowBounds = CaptureAnnotationGeometry.bounds(of: movedArrow)
        require(abs(movedArrowBounds.minX) < 0.001 && abs(movedArrowBounds.maxY - 120) < 0.001, "Arrow movement keeps its head and shaft inside the allowed area")
        let oversize = CaptureAnnotationGeometry.moved(rectangle, by: CGSize(width: -500, height: -500), within: CGRect(x: 30, y: 40, width: 10, height: 10))
        require(oversize.rect.size == rectangle.rect.size && CaptureAnnotationGeometry.bounds(of: oversize).contains(CGRect(x: 30, y: 40, width: 10, height: 10)),
                "An oversized object translates without shrinking or exposing space inside the permitted area")
        require(CaptureAnnotationGeometry.moved(rectangle, by: CGSize(width: CGFloat.nan, height: 0), within: area).points == rectangle.points,
                "Non-finite movement leaves the annotation untouched")
        require(!CaptureAnnotationGeometry.hitTest(rectangle, at: CGPoint(x: CGFloat.nan, y: 0)), "Non-finite hit-test points are rejected")
    }

    @MainActor static func editingHistoryTests() throws {
        let source = fixture(width: 96, height: 80)
        let document = CaptureAnnotationDocument(image: source)
        document.setSelection(document.bounds)
        let arrow = ImageEditStroke(tool: .arrow, points: [CGPoint(x: 10, y: 20), CGPoint(x: 80, y: 20)], color: .red, width: 4, text: "")
        let mosaic = ImageEditStroke(tool: .mosaic, points: [CGPoint(x: 20, y: 12), CGPoint(x: 60, y: 40)], color: .black, width: 4, text: "")
        let text = ImageEditStroke(tool: .text, points: [CGPoint(x: 10, y: 50)], color: .white, width: 4, text: "旧文字", fontSize: 14)
        try document.append(arrow); try document.append(mosaic); try document.append(text)
        let originalBytes = try bytes(document.renderedImage)
        var replacement = arrow; replacement.color = .blue; replacement.points = [CGPoint(x: 10, y: 30), CGPoint(x: 80, y: 30)]
        let expected = CaptureAnnotationDocument(image: source)
        try expected.append(replacement); try expected.append(mosaic); try expected.append(text)
        let expectedBytes = try bytes(expected.renderedImage)
        let preview = try document.preview(replacing: 0, with: replacement)
        require(try bytes(preview) == expectedBytes && bytes(document.renderedImage) == originalBytes,
                "Replacing an early arrow previews the correct later mosaic without committing pixels")
        require(document.strokes[0].points == arrow.points && !document.canRedo && document.failure == nil,
                "Object previews preserve commands, history branches, and error state")
        try document.replace(at: 0, with: replacement)
        require(document.strokes.map(\.tool) == [.arrow, .mosaic, .text] && document.strokes[0].color == .blue,
                "Replacing an annotation preserves its layer index")
        require(try bytes(document.renderedImage) == expectedBytes, "Replacement replays later mosaic against the changed underlying pixels")
        document.undo()
        require(try bytes(document.renderedImage) == originalBytes && document.strokes[0].points == arrow.points,
                "Undo of replacement restores the exact old object and pixels")
        document.redo()
        require(try bytes(document.renderedImage) == expectedBytes, "Redo of replacement restores the exact new composite")
        try document.remove(at: 1)
        let removedBytes = try bytes(document.renderedImage)
        require(document.strokes.map(\.tool) == [.arrow, .text], "Removing a middle annotation keeps the remaining order")
        document.undo()
        require(try document.strokes.map(\.tool) == [.arrow, .mosaic, .text] && bytes(document.renderedImage) == expectedBytes,
                "Undo of deletion reinserts the object at its original layer with exact mosaic pixels")
        document.redo()
        require(try bytes(document.renderedImage) == removedBytes, "Redo of deletion recreates the exact remaining image")
        document.undo()
        var changedText = text; changedText.text = "修改后的中文"; changedText.fontSize = 18
        try document.replace(at: 2, with: changedText)
        require(!document.canRedo && document.strokes[2].text == changedText.text, "Editing after undo creates a new redo branch")
        let changedBytes = try bytes(document.renderedImage)
        document.redo()
        require(try bytes(document.renderedImage) == changedBytes && document.strokes.count == 3, "Discarded redo operations cannot replay after a new object edit")

        document.undo()
        let retained = try bytes(document.renderedImage)
        require(document.canRedo, "The fixture retains an existing redo branch for atomic-failure checks")
        var invalid = replacement; invalid.width = .infinity
        do { try document.replace(at: 0, with: invalid); preconditionFailure("Invalid replacement must fail") }
        catch { require(document.failure != nil, "Invalid replacement reports an error") }
        let recordedError = document.failure!.localizedDescription
        do { _ = try document.preview(replacing: 0, with: invalid); preconditionFailure("Invalid preview must fail") }
        catch { require(document.failure?.localizedDescription == recordedError, "A rejected preview preserves the prior document error") }
        let recoveredPreview = try document.preview(replacing: 0, with: replacement)
        require(recoveredPreview.width == source.width && document.failure?.localizedDescription == recordedError,
                "A successful preview also preserves the prior document error")
        for index in [-1, 3, Int.max] {
            do { try document.remove(at: index); preconditionFailure("Invalid removal index must fail") }
            catch { require(try document.strokes.count == 3 && document.canRedo && bytes(document.renderedImage) == retained,
                            "Invalid deletion preserves pixels, commands, and redo history") }
            do { try document.replace(at: index, with: replacement); preconditionFailure("Invalid replacement index must fail") }
            catch { require(try document.strokes.count == 3 && document.canRedo && bytes(document.renderedImage) == retained,
                            "Invalid replacement index leaves the document atomic") }
        }
        var crop = replacement; crop.tool = .crop
        do { try document.replace(at: 0, with: crop); preconditionFailure("Crop replacement must fail") }
        catch { require(document.selection == document.bounds && document.canRedo, "An annotation cannot be replaced by a crop command") }
        var excessive = replacement; excessive.points = Array(repeating: CGPoint(x: 10, y: 10), count: 100_001)
        do { try document.replace(at: 0, with: excessive); preconditionFailure("Excessive replacement must fail") }
        catch { require(try document.strokes[0].points == replacement.points && document.canRedo && bytes(document.renderedImage) == retained,
                        "Point limits apply to replacement without destroying the pending redo branch") }
        document.redo()
        require(document.strokes[2].text == changedText.text && document.failure == nil, "Valid redo remains available after failed mutations and clears errors")

        let singleton = CaptureAnnotationDocument(image: source)
        try singleton.append(arrow); try singleton.remove(at: 0)
        require(singleton.strokes.isEmpty && singleton.canUndo && singleton.renderedImage === source,
                "Deleting the final object restores the original bitmap while keeping undo available")
        singleton.undo()
        require(singleton.strokes.count == 1 && singleton.strokes[0].tool == .arrow, "Undo restores a deleted final object")
        singleton.undo()
        require(singleton.strokes.isEmpty && !singleton.canUndo && singleton.canRedo, "Undo can continue past a recovered deletion to the initial state")
        singleton.redo(); singleton.redo()
        require(singleton.strokes.isEmpty && singleton.canUndo && !singleton.canRedo, "Redo replays both insertion and deletion in sequence")
    }

    @MainActor static func main() throws {
        geometryTests()
        annotationGeometryTests()
        try editingHistoryTests()
        try documentTests()
        try mosaicTests()
        try inputAndTextTests()
        print("Capture annotation tests passed: \(checks) checks.")
    }
}
