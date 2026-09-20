import AppKit

/// Calls the production view with local events. No events are posted to the system and no screen is captured.
@main
struct CaptureAnnotationInteractionTests {
    static var checks = 0

    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        precondition((try? condition()) == true, message)
        checks += 1
        print("PASS: \(message)")
    }

    static func fixture() -> CGImage {
        let width = 1800, height = 1200
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if x < 170 {
                    bytes[offset] = 29; bytes[offset + 1] = 42; bytes[offset + 2] = 65
                } else if y < 120 {
                    bytes[offset] = 237; bytes[offset + 1] = 242; bytes[offset + 2] = 250
                } else if (800..<1200).contains(x), (300..<650).contains(y) {
                    bytes[offset] = UInt8((x * 19 + y * 7) % 256)
                    bytes[offset + 1] = UInt8((x * 5 + y * 23) % 256)
                    bytes[offset + 2] = UInt8((x * 11 + y * 3) % 256)
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

    static func pixel(_ bytes: [UInt8], width: Int, x: Int, y: Int) -> [UInt8] {
        let offset = (y * width + x) * 4
        return Array(bytes[offset..<(offset + 4)])
    }

    @MainActor static func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView, flags: NSEvent.ModifierFlags = [], clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: flags,
                           timestamp: 0, windowNumber: view.window!.windowNumber, context: nil, eventNumber: 1,
                           clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    @MainActor static func key(_ code: UInt16, _ characters: String = "", flags: NSEvent.ModifierFlags = [], in view: NSView) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: view.window!.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    @MainActor static func drag(_ view: CaptureAnnotationView, from start: CGPoint, to end: CGPoint, flags: NSEvent.ModifierFlags = []) {
        view.mouseDown(with: mouse(.leftMouseDown, at: start, in: view, flags: flags))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: end, in: view, flags: flags))
        view.mouseUp(with: mouse(.leftMouseUp, at: end, in: view, flags: flags))
    }

    @MainActor static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    @MainActor static func inlineEditor(_ view: NSView) -> NSTextView? {
        descendants(view).compactMap { $0 as? NSTextView }.first
    }

    @MainActor static func snapshot(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("Unable to allocate the off-screen component snapshot") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Unable to encode the synthetic component snapshot") }
        try png.write(to: url, options: .atomic)
    }

    @MainActor static func editExistingObjects(source: CGImage) throws {
        let view = CaptureAnnotationView(frame: CGRect(x: 0, y: 0, width: 900, height: 600), image: source, selectsFullImage: false)
        let window = NSWindow(contentRect: CGRect(x: -5000, y: -5000, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.contentView = nil; window.close() }
        drag(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 850, y: 500))
        let selection = view.document.selection
        view.keyDown(with: key(0, "a", in: view))
        drag(view, from: CGPoint(x: 150, y: 140), to: CGPoint(x: 330, y: 230))
        view.keyDown(with: key(0, "a", in: view))
        view.keyDown(with: key(51, in: view))
        require(view.document.strokes.count == 1, "Delete without a selected annotation leaves the drawing unchanged")
        drag(view, from: CGPoint(x: 240, y: 185), to: CGPoint(x: 260, y: 205))
        require(view.document.strokes.count == 1 && view.document.strokes[0].points == [CGPoint(x: 340, y: 320), CGPoint(x: 700, y: 500)], "Dragging an existing arrow body with the arrow tool moves that object instead of adding another")
        require(view.document.selection == selection, "Moving an annotation preserves the capture selection")
        drag(view, from: CGPoint(x: 170, y: 167), to: CGPoint(x: 190, y: 180))
        require(view.document.strokes[0].points == [CGPoint(x: 380, y: 360), CGPoint(x: 700, y: 500)], "Dragging within eight display points of the arrow tail changes only its start endpoint")
        drag(view, from: CGPoint(x: 357, y: 250), to: CGPoint(x: 370, y: 260))
        require(view.document.strokes[0].points == [CGPoint(x: 380, y: 360), CGPoint(x: 740, y: 520)], "Dragging within eight display points of the arrow tip changes only its end endpoint")
        drag(view, from: CGPoint(x: 370, y: 260), to: CGPoint(x: 890, y: 580))
        require(view.document.strokes[0].points == [CGPoint(x: 380, y: 360), CGPoint(x: 1700, y: 1000)], "Dragging an arrow endpoint outside the crop clamps it to the selection boundary")
        drag(view, from: CGPoint(x: 850, y: 500), to: CGPoint(x: 190, y: 180))
        require(view.document.strokes[0].points == [CGPoint(x: 380, y: 360), CGPoint(x: 1700, y: 1000)], "Collapsing an arrow endpoint onto its other endpoint preserves the original arrow")
        _ = view.performKeyEquivalent(with: key(6, "z", flags: .command, in: view))
        require(view.document.strokes[0].points == [CGPoint(x: 380, y: 360), CGPoint(x: 740, y: 520)], "A rejected zero-length arrow edit adds no undo step")
        drag(view, from: CGPoint(x: 280, y: 220), to: CGPoint(x: 280, y: 220))

        guard let properties = view.subviews.compactMap({ $0 as? NSVisualEffectView }).first(where: { $0.subviews.contains { $0 is NSSlider } }),
              let width = properties.subviews.compactMap({ $0 as? NSPopUpButton }).first(where: { $0.itemTitles.contains("6 px") }),
              let blue = properties.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.tag == 5 }) else { fatalError("Expected annotation property controls") }
        width.selectItem(withTitle: "6 px"); _ = width.sendAction(width.action!, to: width.target)
        blue.performClick(nil)
        let arrowColor = view.document.strokes[0].color.usingColorSpace(.sRGB)!
        require(view.document.strokes.count == 1 && view.document.strokes[0].width == 6 && arrowColor.blueComponent > 0.95 && arrowColor.redComponent < 0.05, "Changing color and width updates the selected arrow in place")

        view.keyDown(with: key(15, "r", in: view))
        drag(view, from: CGPoint(x: 400, y: 130), to: CGPoint(x: 550, y: 280))
        view.keyDown(with: key(15, "r", in: view))
        drag(view, from: CGPoint(x: 475, y: 130), to: CGPoint(x: 495, y: 140))
        require(view.document.strokes.count == 2 && view.document.strokes[1].rect == CGRect(x: 840, y: 280, width: 300, height: 300), "Dragging an existing rectangle border moves the rectangle without duplicating it")

        view.keyDown(with: key(46, "m", in: view))
        drag(view, from: CGPoint(x: 650, y: 180), to: CGPoint(x: 780, y: 280))
        guard let strength = properties.subviews.compactMap({ $0 as? NSSlider }).first else { fatalError("Expected mosaic strength slider") }
        strength.doubleValue = 20; _ = strength.sendAction(strength.action!, to: strength.target)
        require(view.document.strokes[2].width == 20 && view.document.strokes[0].width == 6 && view.document.strokes[1].width == 6, "Mosaic strength updates only its selected mask and preserves other annotation widths")
        view.keyDown(with: key(15, "r", in: view))
        drag(view, from: CGPoint(x: 450, y: 330), to: CGPoint(x: 560, y: 390))
        require(view.document.strokes.last?.tool == .rectangle && view.document.strokes.last?.width == 6, "A new rectangle keeps the previous line width after changing mosaic strength")
        view.keyDown(with: key(46, "m", in: view))
        drag(view, from: CGPoint(x: 700, y: 230), to: CGPoint(x: 690, y: 240))
        require(view.document.strokes.count == 4 && view.document.strokes[2].rect == CGRect(x: 1280, y: 380, width: 260, height: 200), "The mosaic tool picks and moves an existing mask without adding another mask")
        let beforeDelete = try bytes(view.document.renderedImage)
        let lastRectangle = view.document.strokes.last!.points
        view.keyDown(with: key(51, in: view))
        require(view.document.strokes.count == 3 && !view.document.strokes.contains(where: { $0.tool == .mosaic }) && view.document.strokes.last?.points == lastRectangle, "Delete removes the selected earlier mosaic and preserves the more recently drawn rectangle")
        _ = view.performKeyEquivalent(with: key(6, "z", flags: .command, in: view))
        let afterUndoDelete = try bytes(view.document.renderedImage)
        require(view.document.strokes.count == 4 && view.document.strokes[2].tool == .mosaic && afterUndoDelete == beforeDelete, "Undo restores a deleted object at its original drawing order with identical pixels")

        view.keyDown(with: key(17, "t", in: view))
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 200, y: 350), in: view))
        guard let firstEditor = inlineEditor(view) else { fatalError("Expected original text editor") }
        firstEditor.insertText("二次编辑", replacementRange: NSRange(location: NSNotFound, length: 0))
        firstEditor.keyDown(with: key(36, "\r", flags: .command, in: firstEditor))
        view.keyDown(with: key(17, "t", in: view))
        drag(view, from: CGPoint(x: 220, y: 356), to: CGPoint(x: 240, y: 366))
        require(view.document.strokes.count == 5 && view.document.strokes[4].points == [CGPoint(x: 440, y: 720)], "Dragging existing text moves its anchor without creating a new text object")
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 225, y: 365), in: view, clickCount: 2))
        guard let secondEditor = inlineEditor(view) else { fatalError("Double-clicking text must reopen its editor") }
        require(secondEditor.string == "二次编辑" && secondEditor.enclosingScrollView?.frame.origin == CGPoint(x: 220, y: 360), "Double-clicking existing text reopens its exact content at its moved anchor")
        secondEditor.setSelectedRange(NSRange(location: 0, length: secondEditor.string.utf16.count))
        secondEditor.insertText("已修改", replacementRange: NSRange(location: NSNotFound, length: 0))
        secondEditor.keyDown(with: key(36, "\r", flags: .command, in: secondEditor))
        require(view.document.strokes.count == 5 && view.document.strokes[4].text == "已修改" && view.document.strokes[4].points == [CGPoint(x: 440, y: 720)], "Committing a second text edit replaces the original object while preserving its position")
        _ = view.performKeyEquivalent(with: key(6, "z", flags: .command, in: view))
        require(view.document.strokes[4].text == "二次编辑" && view.document.strokes[4].points == [CGPoint(x: 440, y: 720)], "Undoing a text edit restores its content without undoing the previous move")
        _ = view.performKeyEquivalent(with: key(6, "z", flags: .command, in: view))
        require(view.document.strokes[4].points == [CGPoint(x: 400, y: 700)], "A second undo restores the independently committed text move")
        require(!window.isVisible, "Annotation editing tests keep their host window hidden")
    }

    @MainActor static func toolbarTests(source: CGImage) {
        let view = CaptureAnnotationView(frame: CGRect(x: 0, y: 0, width: 900, height: 600), image: source, selectsFullImage: false)
        let window = NSWindow(contentRect: CGRect(x: -5000, y: -5000, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.contentView = nil; window.close() }
        drag(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 850, y: 500))
        let bars = view.subviews.compactMap { $0 as? NSVisualEffectView }
        guard let toolbar = bars.first(where: { $0.subviews.contains { ($0 as? NSButton)?.tag == 104 } }),
              let properties = bars.first(where: { $0.subviews.contains { $0 is NSSlider } }) else { fatalError("Expected two floating toolbars") }
        let regions: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 20, y: 20), CGPoint(x: 240, y: 140)),
            (CGPoint(x: 650, y: 20), CGPoint(x: 880, y: 140)),
            (CGPoint(x: 20, y: 450), CGPoint(x: 240, y: 590)),
            (CGPoint(x: 650, y: 450), CGPoint(x: 880, y: 590)),
            (.zero, CGPoint(x: 900, y: 600))
        ]
        for (index, region) in regions.enumerated() {
            view.reset(); drag(view, from: region.0, to: region.1)
            require(!toolbar.isHidden && properties.isHidden && view.bounds.contains(toolbar.frame), "Region \(index + 1) shows its main toolbar inside the screen and hides properties in selection mode")
            for (code, shortcut) in [(UInt16(0), "a"), (UInt16(17), "t"), (UInt16(46), "m")] {
                view.keyDown(with: key(code, shortcut, in: view))
                require(!properties.isHidden && view.bounds.contains(toolbar.frame) && view.bounds.contains(properties.frame) && !toolbar.frame.intersects(properties.frame), "Region \(index + 1) keeps \(shortcut.uppercased()) controls in separate visible bars inside screen bounds")
            }
        }
        let buttons = toolbar.subviews.compactMap { $0 as? NSButton }
        require(toolbar.frame.height == 40 && properties.frame.height == 40 && buttons.count == 19 && Set(buttons.map { $0.frame.minY }).count == 1, "The main toolbar has one 40-point row and properties occupy their own 40-point row")
        require(buttons.allSatisfy { toolbar.bounds.contains($0.frame) }, "All main toolbar controls remain within their row")
        require(!window.isVisible, "Toolbar layout tests keep their host window hidden")
    }

    @MainActor static func lazyToolbarTests(source: CGImage) {
        let view = CaptureAnnotationView(frame: CGRect(x: 0, y: 0, width: 900, height: 600), image: source, selectsFullImage: false)
        let window = NSWindow(contentRect: CGRect(x: -5000, y: -5000, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.contentView = nil; window.close() }
        require(descendants(view).allSatisfy { !($0 is NSButton) && !($0 is NSVisualEffectView) },
                "The initial selection canvas creates no editing buttons or toolbars")
        require(descendants(view).compactMap { $0 as? NSTextField }.count == 2,
                "The initial canvas retains its selection hint and size labels")
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100), in: view))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 600, y: 400), in: view))
        require(view.document.selection != nil && descendants(view).allSatisfy { !($0 is NSButton) && !($0 is NSVisualEffectView) },
                "An unfinished region drag keeps editing controls unbuilt")
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 600, y: 400), in: view))
        let bars = view.subviews.compactMap { $0 as? NSVisualEffectView }
        guard let toolbar = bars.first(where: { $0.subviews.contains { ($0 as? NSButton)?.tag == 104 } }) else {
            fatalError("Completing the first region must create its action toolbar")
        }
        let controls = descendants(view).compactMap { $0 as? NSButton }
        let identities = Set(controls.map(ObjectIdentifier.init))
        require(bars.count == 2 && !toolbar.isHidden && !controls.isEmpty,
                "Completing the first region creates both toolbars and shows the main actions")
        for index in 1...2 {
            view.reset()
            require(view.document.selection == nil && bars.allSatisfy(\.isHidden),
                    "Reset \(index) hides the existing toolbars without leaving a selection")
            drag(view, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 600, y: 400))
            require(!toolbar.isHidden && Set(descendants(view).compactMap { $0 as? NSButton }.map(ObjectIdentifier.init)) == identities
                    && Set(view.subviews.compactMap { $0 as? NSVisualEffectView }.map(ObjectIdentifier.init)) == Set(bars.map(ObjectIdentifier.init)),
                    "Reselection \(index) reuses the same controls and toolbar instances without duplicates")
        }

        let selectAll = CaptureAnnotationView(frame: view.frame, image: source, selectsFullImage: false)
        window.contentView = selectAll
        require(selectAll.performKeyEquivalent(with: key(0, "a", flags: .command, in: selectAll)), "Command-A selects the display from the initial canvas")
        require(selectAll.document.selection == CGRect(x: 0, y: 0, width: source.width, height: source.height)
                    && selectAll.subviews.compactMap { $0 as? NSVisualEffectView }.contains { !$0.isHidden && $0.subviews.contains { ($0 as? NSButton)?.tag == 104 } },
                "Command-A builds and reveals the initial action toolbar")

        let fullImage = CaptureAnnotationView(frame: view.frame, image: source, selectsFullImage: true)
        window.contentView = fullImage
        require(fullImage.document.selection == CGRect(x: 0, y: 0, width: source.width, height: source.height)
                    && fullImage.subviews.compactMap { $0 as? NSVisualEffectView }.contains { !$0.isHidden && $0.subviews.contains { ($0 as? NSButton)?.tag == 104 } },
                "Full-image mode starts with its selected image and visible action toolbar")
        require(!window.isVisible, "Lazy-toolbar tests keep their host window hidden")
    }

    @MainActor static func windowCandidateTests(source: CGImage) throws {
        let front = CGRect(x: 200, y: 200, width: 600, height: 500)
        let back = CGRect(x: 400, y: 350, width: 800, height: 500)
        let view = CaptureAnnotationView(frame: CGRect(x: 0, y: 0, width: 900, height: 600), image: source,
                                         selectsFullImage: false, windowRegions: [front, back])
        let window = NSWindow(contentRect: CGRect(x: -5000, y: -5000, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.contentView = nil; window.close() }
        var outputs = 0
        view.onCopy = { _ in outputs += 1 }; view.onSave = { _ in outputs += 1 }
        let overlap = CGPoint(x: 250, y: 200)
        view.mouseMoved(with: mouse(.mouseMoved, at: overlap, in: view))
        require(view.document.selection == nil && outputs == 0, "Hovering a window candidate previews it without selecting or exporting")
        require(descendants(view).allSatisfy { !($0 is NSButton) && !($0 is NSVisualEffectView) },
                "Hovering a window candidate does not construct editing toolbars")
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("Unable to render the window candidate preview") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let preview = try bytes(bitmap.cgImage!)
        let frontOnly = pixel(preview, width: bitmap.pixelsWide, x: 125 * bitmap.pixelsWide / 900, y: 125 * bitmap.pixelsHigh / 600)
        let backOnly = pixel(preview, width: bitmap.pixelsWide, x: 550 * bitmap.pixelsWide / 900, y: 350 * bitmap.pixelsHigh / 600)
        require(frontOnly[1] > 240 && backOnly[1] < 200, "Overlapping candidates highlight the first array entry while the lower candidate stays dimmed")
        drag(view, from: overlap, to: overlap)
        require(view.document.selection == front && outputs == 0, "Clicking overlapping candidates selects the first candidate without copying")
        drag(view, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 230, y: 210))
        require(view.document.selection == CGRect(x: 260, y: 220, width: 600, height: 500), "A clicked window selection remains movable")
        view.reset()
        drag(view, from: overlap, to: overlap, flags: .control)
        require(view.document.selection == front && outputs == 0, "Control-clicking a candidate only selects it and does not copy")
        view.reset()
        view.mouseDown(with: mouse(.leftMouseDown, at: overlap, in: view))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 251, y: 201), in: view))
        require(view.document.selection == front, "Movement below three display points retains the window candidate")
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 260, y: 215), in: view))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 260, y: 215), in: view))
        require(view.document.selection == CGRect(x: 500, y: 400, width: 20, height: 30) && outputs == 0, "Dragging beyond three points switches from window picking to a manual selection")

        let reversed = CaptureAnnotationView(frame: view.frame, image: source, selectsFullImage: false, windowRegions: [back, front])
        window.contentView = reversed
        drag(reversed, from: overlap, to: overlap)
        require(reversed.document.selection == back, "Reversing candidate order reverses overlap priority")
        require(!window.isVisible, "Window candidate tests keep their host window hidden")
    }

    @MainActor static func outerHandleTests(source: CGImage) {
        // A 972×776 view fits this source at exactly 0.5 scale, with a (36, 88) image origin.
        let view = CaptureAnnotationView(frame: CGRect(x: 0, y: 0, width: 972, height: 776), image: source, selectsFullImage: true)
        let window = NSWindow(contentRect: CGRect(x: -5000, y: -5000, width: 972, height: 776), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.contentView = nil; window.close() }
        drag(view, from: CGPoint(x: 33, y: 388), to: CGPoint(x: 86, y: 388))
        require(view.document.selection == CGRect(x: 100, y: 0, width: 1700, height: 1200), "The outer half of a left handle responds even outside the fitted source image")
        _ = view.performKeyEquivalent(with: key(0, "a", flags: .command, in: view))
        drag(view, from: CGPoint(x: 939, y: 691), to: CGPoint(x: 886, y: 638))
        require(view.document.selection == CGRect(x: 0, y: 0, width: 1700, height: 1100), "The outer half of a bottom-right handle resizes both edges outside the source image")
        require(!window.isVisible, "Outer-handle tests keep their host window hidden")
    }

    @MainActor static func chooseAdvanced(_ tool: ImageEditTool, in view: CaptureAnnotationView) {
        let item = NSMenuItem(title: tool.title, action: nil, keyEquivalent: "")
        item.representedObject = tool.rawValue
        _ = view.perform(NSSelectorFromString("menuAction:"), with: item)
    }
    @MainActor static func advancedInteractions(source: CGImage) throws {
        let view = CaptureAnnotationView(frame: CGRect(x: 0, y: 0, width: 900, height: 600), image: source, selectsFullImage: false)
        let window = NSWindow(contentRect: CGRect(x: -5000, y: -5000, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.contentView = nil; window.close() }
        drag(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 850, y: 500))
        chooseAdvanced(.polyline, in: view)
        for point in [CGPoint(x: 120, y: 120), CGPoint(x: 240, y: 120), CGPoint(x: 240, y: 220)] {
            view.mouseDown(with: mouse(.leftMouseDown, at: point, in: view)); view.mouseUp(with: mouse(.leftMouseUp, at: point, in: view))
        }
        require(view.document.strokes.isEmpty, "Polyline clicks accumulate nodes without prematurely committing strokes")
        view.keyDown(with: key(36, "\r", in: view))
        require(view.document.strokes.count == 1 && view.document.strokes[0].points == [CGPoint(x: 240, y: 240), CGPoint(x: 480, y: 240), CGPoint(x: 480, y: 440)], "Return commits the complete multi-node polyline once")
        drag(view, from: CGPoint(x: 240, y: 120), to: CGPoint(x: 270, y: 140))
        require(view.document.strokes.count == 1 && view.document.strokes[0].points[1] == CGPoint(x: 540, y: 280), "A committed polyline exposes draggable intermediate nodes")
        chooseAdvanced(.polyline, in: view)
        drag(view, from: CGPoint(x: 360, y: 100), to: CGPoint(x: 360, y: 100))
        drag(view, from: CGPoint(x: 460, y: 145), to: CGPoint(x: 460, y: 145), flags: .shift)
        view.keyDown(with: key(51, in: view))
        view.keyDown(with: key(53, in: view))
        require(view.document.strokes.count == 1, "Delete removes an uncommitted node and Escape discards the pending polyline")
        chooseAdvanced(.line, in: view)
        drag(view, from: CGPoint(x: 320, y: 300), to: CGPoint(x: 430, y: 347), flags: .shift)
        let line = view.document.strokes.last!
        require(line.tool == .line && abs((line.points.last!.x - line.points[0].x) - (line.points.last!.y - line.points[0].y)) < 0.01 || line.tool == .line && line.points.last!.y == line.points[0].y, "Shift constrains a straight line to horizontal or 45-degree directions")
        chooseAdvanced(.line, in: view)
        let start = CGPoint(x: line.points[0].x / 2, y: line.points[0].y / 2), end = CGPoint(x: line.points.last!.x / 2, y: line.points.last!.y / 2)
        let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        drag(view, from: middle, to: CGPoint(x: middle.x + 20, y: middle.y + 30), flags: .option)
        require(view.document.strokes.count == 3 && view.document.strokes[1].points == line.points && view.document.strokes[2].points != line.points, "Option-drag copies an annotation and leaves its original command intact")
        chooseAdvanced(.magnify, in: view)
        drag(view, from: CGPoint(x: 500, y: 140), to: CGPoint(x: 550, y: 180))
        let lensIndex = view.document.strokes.count - 1, lens = view.document.strokes.last!
        require(lens.tool == .magnify && lens.style.magnifierSourceRect == CGRect(x: 1000, y: 280, width: 100, height: 80), "Magnifier dragging establishes an independent source rectangle")
        drag(view, from: CGPoint(x: 525, y: 160), to: CGPoint(x: 650, y: 250))
        require(view.document.strokes[lensIndex].style.magnifierSourceRect == lens.style.magnifierSourceRect && view.document.strokes[lensIndex].points != lens.points, "Dragging a magnifier moves its lens while retaining its sampled source")
        drag(view, from: CGPoint(x: 525, y: 160), to: CGPoint(x: 545, y: 175), flags: .control)
        require(view.document.strokes[lensIndex].style.magnifierSourceRect == CGRect(x: 1040, y: 310, width: 100, height: 80), "Control-drag moves the selected lens source independently")
        for tool in [ImageEditTool.blur, .eraser, .spotlight, .watermark, .inpaint] {
            chooseAdvanced(tool, in: view)
            let before = view.document.strokes.count
            drag(view, from: CGPoint(x: 370, y: 380), to: CGPoint(x: 400, y: 405))
            require(view.document.strokes.count == before + 1 && view.document.strokes.last?.tool == tool, "The \(tool.title) menu entry creates a real committed annotation through dragging")
        }
        let watermark = view.document.strokes.first { $0.tool == .watermark }!
        require(!watermark.text.contains("{date}") && !watermark.text.contains("{time}") && watermark.text.contains("Xclip"), "Watermark date and time variables resolve when the user draws it")
        let beforeClear = try bytes(view.document.renderedImage), count = view.document.strokes.count
        let clear = NSMenuItem(); clear.representedObject = "clear"
        _ = view.perform(NSSelectorFromString("menuAction:"), with: clear)
        require(view.document.strokes.isEmpty, "The clear annotations menu removes the entire annotation list")
        _ = view.performKeyEquivalent(with: key(6, "z", flags: .command, in: view))
        require(try view.document.strokes.count == count && bytes(view.document.renderedImage) == beforeClear, "Undo restores all cleared advanced effects with their original pixels")
        var rotated = ImageEditStroke(tool: .rectangle, points: [CGPoint(x: 500, y: 500), CGPoint(x: 680, y: 620)], color: .blue, width: 4, text: "")
        rotated.style.rotation = .pi / 4
        try view.document.append(rotated); chooseAdvanced(.rectangle, in: view)
        let rotation = ImageEditingOperations.rotationTransform(for: rotated)
        let topLeft = rotated.points[0].applying(rotation), corner = rotated.points[1].applying(rotation)
        let target = CGPoint(x: 720, y: 650).applying(rotation)
        drag(view, from: CGPoint(x: corner.x / 2, y: corner.y / 2), to: CGPoint(x: corner.x / 2, y: corner.y / 2))
        drag(view, from: CGPoint(x: corner.x / 2, y: corner.y / 2), to: CGPoint(x: target.x / 2, y: target.y / 2))
        let changed = view.document.strokes.last!, fixedCorner = changed.points[0].applying(ImageEditingOperations.rotationTransform(for: changed))
        require(hypot(fixedCorner.x - topLeft.x, fixedCorner.y - topLeft.y) < 0.1 && changed.rect.width > rotated.rect.width, "Dragging a rotated rectangle handle expands its local dimensions while keeping the opposite displayed corner fixed")
        require(!window.isVisible, "Advanced interaction tests never show a capture window")
    }
    @MainActor static func initialActionTests(source: CGImage) {
        let view = CaptureAnnotationView(frame: CGRect(x: 0, y: 0, width: 900, height: 600), image: source, selectsFullImage: false, initialAction: .ocr)
        let window = NSWindow(contentRect: CGRect(x: -5000, y: -5000, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.contentView = nil; window.close() }
        var calls = 0, action: CaptureWorkflowAction?, region: CGRect?
        view.onAction = { value, _, selection in calls += 1; action = value; region = selection }
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100), in: view))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 400, y: 300), in: view))
        require(calls == 0, "A dedicated OCR shortcut waits for the user to finish selecting")
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 400, y: 300), in: view))
        require(calls == 1 && action == .ocr && region == CGRect(x: 200, y: 200, width: 600, height: 400), "Finishing the first selection invokes its requested workflow with source coordinates")
        drag(view, from: CGPoint(x: 200, y: 180), to: CGPoint(x: 210, y: 190))
        require(calls == 1, "The initial workflow action cannot fire twice when selection later changes")
    }

    @MainActor static func main() throws {
        guard let identifier = Bundle.main.bundleIdentifier, identifier.hasPrefix("local.cclip.capture-interaction.") else {
            fatalError("Run scripts/test-capture-interaction.sh to isolate the test preferences domain")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let defaults = UserDefaults.standard
        defer { defaults.removePersistentDomain(forName: identifier) }
        ImageEditorPreferences().save(to: defaults)
        let source = fixture(), sourcePixels = try bytes(source)
        try windowCandidateTests(source: source)
        outerHandleTests(source: source)
        try editExistingObjects(source: source)
        lazyToolbarTests(source: source)
        toolbarTests(source: source)
        try advancedInteractions(source: source)
        initialActionTests(source: source)
        ImageEditorPreferences().save(to: defaults)
        let view = CaptureAnnotationView(frame: CGRect(x: 0, y: 0, width: 900, height: 600), image: source, selectsFullImage: false)
        let window = NSWindow(contentRect: CGRect(x: -5000, y: -5000, width: 900, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        var copied: [Data] = [], saved: [Data] = [], cancelled = 0, selections = 0
        view.onCopy = { copied.append($0) }
        view.onSave = { saved.append($0) }
        view.onCancel = { cancelled += 1 }
        view.onBeginSelection = { selections += 1 }

        let selectionStart = CGPoint(x: 100, y: 100), selectionEnd = CGPoint(x: 600, y: 400)
        drag(view, from: selectionStart, to: selectionEnd)
        require(view.document.selection == CGRect(x: 200, y: 200, width: 1000, height: 600), "Local drag maps 900×600 points into a 1800×1200 source")
        require(copied.isEmpty && saved.isEmpty && selections == 1, "Releasing a selection leaves it editable without exporting")

        let handleCases: [(CGPoint, CGRect)] = [
            (CGPoint(x: 100, y: 100), CGRect(x: 220, y: 230, width: 980, height: 570)),
            (CGPoint(x: 350, y: 100), CGRect(x: 200, y: 230, width: 1000, height: 570)),
            (CGPoint(x: 600, y: 100), CGRect(x: 200, y: 230, width: 1020, height: 570)),
            (CGPoint(x: 600, y: 250), CGRect(x: 200, y: 200, width: 1020, height: 600)),
            (CGPoint(x: 600, y: 400), CGRect(x: 200, y: 200, width: 1020, height: 630)),
            (CGPoint(x: 350, y: 400), CGRect(x: 200, y: 200, width: 1000, height: 630)),
            (CGPoint(x: 100, y: 400), CGRect(x: 220, y: 200, width: 980, height: 630)),
            (CGPoint(x: 100, y: 250), CGRect(x: 220, y: 200, width: 980, height: 600))
        ]
        for (index, entry) in handleCases.enumerated() {
            view.reset(); drag(view, from: selectionStart, to: selectionEnd)
            drag(view, from: entry.0, to: CGPoint(x: entry.0.x + 10, y: entry.0.y + 15))
            require(view.document.selection == entry.1, "Handle \(index + 1) hit testing resizes the intended source edges at 2× scale")
        }
        require(copied.isEmpty && saved.isEmpty, "All eight handle adjustments preserve the pending capture")

        let edgeCases: [(CGPoint, CGPoint, CGRect)] = [
            (CGPoint(x: 220, y: 100), CGPoint(x: 220, y: 110), CGRect(x: 200, y: 220, width: 1000, height: 580)),
            (CGPoint(x: 100, y: 180), CGPoint(x: 110, y: 180), CGRect(x: 220, y: 200, width: 980, height: 600)),
            (CGPoint(x: 600, y: 320), CGPoint(x: 590, y: 320), CGRect(x: 200, y: 200, width: 980, height: 600)),
            (CGPoint(x: 450, y: 400), CGPoint(x: 450, y: 390), CGRect(x: 200, y: 200, width: 1000, height: 580))
        ]
        for (index, entry) in edgeCases.enumerated() {
            view.reset(); drag(view, from: selectionStart, to: selectionEnd)
            drag(view, from: entry.0, to: entry.1)
            require(view.document.selection == entry.2, "Dragging edge segment \(index + 1) away from its visible handles resizes the matching selection boundary")
        }

        view.reset(); drag(view, from: selectionStart, to: selectionEnd)
        drag(view, from: CGPoint(x: 350, y: 250), to: CGPoint(x: 370, y: 230))
        require(view.document.selection == CGRect(x: 240, y: 160, width: 1000, height: 600), "Dragging the interior moves the selection without resizing")
        view.keyDown(with: key(124, in: view))
        view.keyDown(with: key(125, in: view))
        view.keyDown(with: key(123, flags: .shift, in: view))
        view.keyDown(with: key(126, flags: .shift, in: view))
        require(view.document.selection == CGRect(x: 242, y: 162, width: 999, height: 599), "Plain arrows move one source pixel while Shift arrows shrink the corresponding boundary by one pixel")
        view.keyDown(with: key(123, flags: .control, in: view))
        view.keyDown(with: key(126, flags: .control, in: view))
        require(view.document.selection == CGRect(x: 241, y: 161, width: 1000, height: 600), "Control arrows expand the corresponding boundary by one source pixel")
        view.keyDown(with: key(36, "\r", in: view))
        require(copied.count == 1, "Return invokes one copy callback")
        let movedExport = try CaptureImageCodec.decode(copied[0])
        require(movedExport.width == 1000 && movedExport.height == 600, "The exported crop retains its source pixel dimensions")
        require(pixel(try bytes(movedExport), width: 1000, x: 0, y: 0) == pixel(sourcePixels, width: 1800, x: 241, y: 161), "The exported origin follows the moved and nudged selection")

        view.keyDown(with: key(0, "a", in: view))
        drag(view, from: CGPoint(x: 180, y: 160), to: CGPoint(x: 400, y: 260))
        require(view.document.strokes.count == 1 && view.document.strokes[0].tool == .arrow, "A selects the arrow tool and a drag commits one arrow")
        require(view.document.strokes[0].points == [CGPoint(x: 360, y: 320), CGPoint(x: 800, y: 520)], "Arrow endpoints use source coordinates")
        let arrowPixels = try bytes(view.document.renderedImage)
        let arrowPoint = pixel(arrowPixels, width: 1800, x: 580, y: 420)
        require(arrowPoint[0] > 240 && arrowPoint[1] < 20 && arrowPoint[2] < 20, "The arrow visibly renders at its expected source midpoint")
        require(view.performKeyEquivalent(with: key(6, "z", flags: .command, in: view)), "Command-Z is handled by the canvas")
        require(try bytes(view.document.renderedImage) == sourcePixels, "Undo removes the arrow pixels")
        require(view.performKeyEquivalent(with: key(6, "z", flags: [.command, .shift], in: view)), "Shift-Command-Z is handled by the canvas")
        require(try bytes(view.document.renderedImage) == arrowPixels, "Redo restores the exact arrow rendering")

        view.keyDown(with: key(46, "m", in: view))
        let mosaicStart = CGPoint(x: 450, y: 200), mosaicEnd = CGPoint(x: 550, y: 300)
        view.mouseDown(with: mouse(.leftMouseDown, at: mosaicStart, in: view))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: mosaicEnd, in: view))
        require(view.document.strokes.count == 1, "A pending mosaic preview does not prematurely commit history")
        view.mouseUp(with: mouse(.leftMouseUp, at: mosaicEnd, in: view))
        require(view.document.strokes.count == 2 && view.document.strokes.last?.tool == .mosaic, "M selects mosaic and release commits the mask once")
        let mosaicPixels = try bytes(view.document.renderedImage)
        require(pixel(mosaicPixels, width: 1800, x: 940, y: 430) != pixel(arrowPixels, width: 1800, x: 940, y: 430), "The mosaic changes pixels inside the dragged area")
        require(pixel(mosaicPixels, width: 1800, x: 1150, y: 620) == pixel(arrowPixels, width: 1800, x: 1150, y: 620), "The mosaic preserves nearby pixels outside its area")
        require(view.performKeyEquivalent(with: key(8, "c", flags: .command, in: view)), "Command-C exports through the canvas callback")
        require(copied.count == 2, "Command-C invokes only one additional export")
        let annotatedExport = try CaptureImageCodec.decode(copied[1])
        require(pixel(try bytes(annotatedExport), width: 1000, x: 699, y: 269) == pixel(mosaicPixels, width: 1800, x: 940, y: 430), "Export permanently includes the mosaic at the correct crop-relative coordinate")

        view.keyDown(with: key(17, "t", in: view))
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 200, y: 170), in: view))
        guard let editor = descendants(view).compactMap({ $0 as? NSTextView }).first else { fatalError("Text tool must create an inline NSTextView") }
        require(window.firstResponder === editor, "Clicking with the text tool focuses a native inline text editor")
        editor.setMarkedText("中文标注", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        require(editor.hasMarkedText(), "The inline editor accepts native marked text for Chinese composition")
        editor.insertText("中文标注", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.insertText("\n选区可调整", replacementRange: NSRange(location: NSNotFound, length: 0))
        require(!editor.hasMarkedText() && editor.string == "中文标注\n选区可调整", "Committing marked text retains Chinese and multiline content")
        editor.keyDown(with: key(36, "\r", flags: .command, in: editor))
        require(descendants(view).compactMap({ $0 as? NSTextView }).isEmpty, "Command-Return finishes and removes the inline editor")
        require(view.document.strokes.last?.text == "中文标注\n选区可调整" && view.document.strokes.last?.points == [CGPoint(x: 400, y: 340)], "The text annotation retains exact content and its clicked source position")
        require(copied.count == 2 && saved.isEmpty, "Finishing text does not finish or copy the screenshot")
        require(try bytes(view.document.renderedImage) != mosaicPixels, "Committed Chinese text adds visible image pixels")

        let beforeEdgeText = try bytes(view.document.renderedImage)
        let countBeforeEdgeText = view.document.strokes.count
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 605, y: 365), in: view))
        require(inlineEditor(view) == nil && view.document.strokes.count == countBeforeEdgeText, "An edge click with less than 24 points of space does not create or reposition a text object")
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 575, y: 340), in: view))
        guard let edgeEditor = descendants(view).compactMap({ $0 as? NSTextView }).first,
              let edgeScroll = edgeEditor.enclosingScrollView else { fatalError("Expected an inline editor beside the selection edges") }
        let displayedSelection = CGRect(x: 120.5, y: 80.5, width: 500, height: 300)
        require(displayedSelection.contains(edgeScroll.frame), "Text entered near the right and bottom edges keeps its editor inside the selection")
        let edgeAnchor = CGPoint(x: edgeScroll.frame.minX * 2, y: edgeScroll.frame.minY * 2)
        require(edgeAnchor == CGPoint(x: 1150, y: 680), "The edge text editor preserves the exact clicked source anchor")
        require(!edgeEditor.drawsBackground && !edgeScroll.drawsBackground, "Inline text editing remains transparent over the captured image")
        edgeEditor.insertText("靠边文字", replacementRange: NSRange(location: NSNotFound, length: 0))
        edgeEditor.keyDown(with: key(36, "\r", flags: .command, in: edgeEditor))
        require(view.document.strokes.last?.points == [edgeAnchor] && view.document.strokes.last?.text == "靠边文字", "Committed edge text uses the visible editor origin as its source anchor")
        let edgeTextPixels = try bytes(view.document.renderedImage)
        var minimumChangedX = Int.max, minimumChangedY = Int.max
        for y in Int(edgeAnchor.y)..<Int(edgeAnchor.y + 60) {
            for x in Int(edgeAnchor.x)..<Int(edgeAnchor.x + 200) {
                if pixel(edgeTextPixels, width: 1800, x: x, y: y) != pixel(beforeEdgeText, width: 1800, x: x, y: y) {
                    minimumChangedX = min(minimumChangedX, x)
                    minimumChangedY = min(minimumChangedY, y)
                }
            }
        }
        require(minimumChangedX < Int(edgeAnchor.x + 24) && minimumChangedY < Int(edgeAnchor.y + 24), "Edge text produces first-character ink beside its exact clicked anchor")

        require(view.performKeyEquivalent(with: key(1, "s", flags: .command, in: view)), "Command-S invokes the save callback without opening a dialog in the component")
        require(saved.count == 1 && copied.count == 2, "Saving and copying use distinct callbacks")
        require(try bytes(CaptureImageCodec.decode(saved[0])) == bytes(CaptureImageCodec.decode(view.document.export())), "The save callback receives the complete current PNG")
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 250, y: 300), in: view))
        guard let discardedEditor = descendants(view).compactMap({ $0 as? NSTextView }).first else { fatalError("Expected another inline editor") }
        discardedEditor.insertText("丢弃这段", replacementRange: NSRange(location: NSNotFound, length: 0))
        let strokeCount = view.document.strokes.count
        discardedEditor.keyDown(with: key(53, "\u{1b}", in: discardedEditor))
        require(view.document.strokes.count == strokeCount && descendants(view).compactMap({ $0 as? NSTextView }).isEmpty, "Escape in uncommitted text discards that text")
        require(cancelled == 0 && copied.count == 2, "Discarding text leaves the capture active without copying")

        view.keyDown(with: key(9, "v", in: view))
        guard CommandLine.arguments.count > 1 else { fatalError("Provide an output path for the synthetic view snapshot") }
        let snapshotURL = URL(fileURLWithPath: CommandLine.arguments[1])
        try snapshot(view, to: snapshotURL)
        view.keyDown(with: key(0, "a", in: view))
        let propertiesURL = snapshotURL.deletingLastPathComponent().appendingPathComponent("pixpin-properties.png")
        try snapshot(view, to: propertiesURL)
        view.reset()
        view.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: view.bounds.maxX - 3, y: view.bounds.maxY - 3), in: view))
        let loupeURL = snapshotURL.deletingLastPathComponent().appendingPathComponent("pixpin-loupe.png")
        try snapshot(view, to: loupeURL)
        view.keyDown(with: key(53, "\u{1b}", in: view))
        require(cancelled == 1 && copied.count == 2 && saved.count == 1, "Escape cancels through its callback without copying or saving")
        require(!window.isVisible, "The test window remains hidden for the entire interaction suite")
        print("Capture annotation interaction tests passed: \(checks) checks. Local component events and synthetic pixels only; no screen capture, system event posting, or general pasteboard access.")
        print("Synthetic layout snapshot: \(CommandLine.arguments[1])")
        print("Synthetic properties snapshot: \(propertiesURL.path)")
        print("Synthetic loupe snapshot: \(loupeURL.path)")
    }
}
