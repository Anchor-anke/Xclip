import AppKit

/// All selection and annotation coordinates are image pixels, measured from the top-left.
enum CaptureSelectionHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

enum CaptureSelectionGeometry {
    /// Standardizes reverse drags and clips every edge without rounding display-scale coordinates.
    static func clamped(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        guard finite(rect), finite(bounds) else { return .zero }
        let area = bounds.standardized
        let proposed = rect.standardized
        let left = clamp(proposed.minX, area.minX, area.maxX)
        let right = clamp(proposed.maxX, area.minX, area.maxX)
        let top = clamp(proposed.minY, area.minY, area.maxY)
        let bottom = clamp(proposed.maxY, area.minY, area.maxY)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    static func moved(_ rect: CGRect, by delta: CGSize, within bounds: CGRect) -> CGRect {
        let safe = clamped(rect, to: bounds)
        guard finite(bounds), delta.width.isFinite, delta.height.isFinite else { return safe }
        let area = bounds.standardized
        return CGRect(x: clamp(safe.minX + delta.width, area.minX, area.maxX - safe.width),
                      y: clamp(safe.minY + delta.height, area.minY, area.maxY - safe.height),
                      width: safe.width, height: safe.height)
    }

    /// `rect` and `delta` are the initial rectangle and the total drag since mouse-down.
    /// Crossing the opposite edge reverses the dragged axis while keeping that edge anchored.
    static func resized(_ rect: CGRect, handle: CaptureSelectionHandle, by delta: CGSize,
                        within bounds: CGRect, minimumSize: CGFloat = 2) -> CGRect {
        let safe = clamped(rect, to: bounds)
        guard finite(bounds), delta.width.isFinite, delta.height.isFinite else { return safe }
        let area = bounds.standardized
        let minimum = minimumSize.isFinite ? max(0, minimumSize) : 2
        var x = (safe.minX, safe.maxX), y = (safe.minY, safe.maxY)
        switch handle {
        case .topLeft, .bottomLeft, .left:
            x = resizedAxis(moving: safe.minX + delta.width, anchor: safe.maxX,
                            originallyBefore: true, low: area.minX, high: area.maxX, minimum: minimum)
        case .topRight, .bottomRight, .right:
            x = resizedAxis(moving: safe.maxX + delta.width, anchor: safe.minX,
                            originallyBefore: false, low: area.minX, high: area.maxX, minimum: minimum)
        case .top, .bottom: break
        }
        switch handle {
        case .topLeft, .topRight, .top:
            y = resizedAxis(moving: safe.minY + delta.height, anchor: safe.maxY,
                            originallyBefore: true, low: area.minY, high: area.maxY, minimum: minimum)
        case .bottomLeft, .bottomRight, .bottom:
            y = resizedAxis(moving: safe.maxY + delta.height, anchor: safe.minY,
                            originallyBefore: false, low: area.minY, high: area.maxY, minimum: minimum)
        case .left, .right: break
        }
        return CGRect(x: x.0, y: y.0, width: x.1 - x.0, height: y.1 - y.0)
    }

    static func handles(for rect: CGRect) -> [(CaptureSelectionHandle, CGPoint)] {
        guard finite(rect) else { return [] }
        let rect = rect.standardized
        return [(.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
                (.top, CGPoint(x: rect.midX, y: rect.minY)),
                (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
                (.right, CGPoint(x: rect.maxX, y: rect.midY)),
                (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
                (.bottom, CGPoint(x: rect.midX, y: rect.maxY)),
                (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
                (.left, CGPoint(x: rect.minX, y: rect.midY))]
    }

    private static func resizedAxis(moving: CGFloat, anchor: CGFloat, originallyBefore: Bool,
                                    low: CGFloat, high: CGFloat, minimum: CGFloat) -> (CGFloat, CGFloat) {
        var moving = clamp(moving, low, high)
        let minimum = min(minimum, high - low)
        if abs(moving - anchor) < minimum {
            let before = moving == anchor ? originallyBefore : moving < anchor
            let preferred = anchor + (before ? -minimum : minimum)
            let alternate = anchor + (before ? minimum : -minimum)
            if preferred >= low && preferred <= high { moving = preferred }
            else if alternate >= low && alternate <= high { moving = alternate }
            else { return (low, high) }
        }
        return (min(moving, anchor), max(moving, anchor))
    }

    private static func finite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.minX.isFinite && rect.maxX.isFinite && rect.minY.isFinite && rect.maxY.isFinite
    }

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(high, max(low, value))
    }
}

/// Geometry shared by object handles, hit testing and source-pixel movement.
enum CaptureAnnotationGeometry {
    static func bounds(of stroke: ImageEditStroke) -> CGRect {
        guard (try? ImageEditingOperations.validate(stroke)) != nil else { return .zero }
        let box = ImageEditingOperations.unrotatedBounds(for: stroke)
        return stroke.tool == .watermark ? box : box.applying(ImageEditingOperations.rotationTransform(for: stroke))
    }
    static func hitTest(_ stroke: ImageEditStroke, at point: CGPoint, tolerance: CGFloat = 6) -> Bool {
        guard (try? ImageEditingOperations.validate(stroke)) != nil, point.x.isFinite, point.y.isFinite, tolerance.isFinite,
              stroke.tool != .pen && stroke.tool != .crop else { return false }
        let point = stroke.tool == .watermark ? point : point.applying(ImageEditingOperations.rotationTransform(for: stroke).inverted())
        let padding = max(0, tolerance)
        func pathHit(_ path: CGPath, filled: Bool, width: CGFloat = 0) -> Bool {
            if filled && path.contains(point) { return true }
            return path.copy(strokingWithWidth: max(0.01, width + padding * 2), lineCap: .round, lineJoin: .round, miterLimit: 10).contains(point)
        }
        switch stroke.tool {
        case .text, .watermark:
            return ImageEditingOperations.unrotatedBounds(for: stroke).insetBy(dx: -padding, dy: -padding).contains(point)
        case .number:
            guard let center = stroke.points.first else { return false }
            if hypot(point.x - center.x, point.y - center.y) <= max(13, stroke.width * 3) + padding { return true }
            if !stroke.text.isEmpty { return ImageEditingOperations.unrotatedBounds(for: stroke).insetBy(dx: -padding, dy: -padding).contains(point) }
            if stroke.points.count > 1 { return segmentDistance(point, from: center, to: stroke.points[1]) <= stroke.width + padding }
            return false
        case .rectangle, .ellipse:
            return pathHit(ImageEditingOperations.shapePath(for: stroke), filled: stroke.style.filled, width: stroke.style.filled ? 0 : stroke.width)
        case .mosaic, .blur, .inpaint, .eraser, .spotlight:
            if stroke.tool == .eraser && stroke.style.effectShape == .brush { return false }
            return pathHit(ImageEditingOperations.effectPath(for: stroke), filled: true)
        case .magnify:
            let rect = ImageEditingOperations.magnifierDestinationRect(for: stroke)
            let path = stroke.style.effectShape == .ellipse ? CGPath(ellipseIn: rect, transform: nil) : CGPath(rect: rect, transform: nil)
            return pathHit(path, filled: true, width: stroke.width)
        case .highlight:
            if stroke.style.effectShape != .brush { return pathHit(ImageEditingOperations.effectPath(for: stroke), filled: true) }
            return false
        case .line, .polyline:
            for index in 1..<stroke.points.count where segmentDistance(point, from: stroke.points[index - 1], to: stroke.points[index]) <= stroke.width / 2 + padding { return true }
            if stroke.style.startHead != .none || stroke.style.endHead != .none {
                return ImageEditingOperations.unrotatedBounds(for: stroke).insetBy(dx: -padding, dy: -padding).contains(point)
            }
            return false
        case .arrow:
            guard let arrow = ImageEditingOperations.arrowGeometry(for: stroke) else { return false }
            if stroke.style.arrowStyle == .triangle {
                let dx = arrow.tip.x - arrow.tail.x, dy = arrow.tip.y - arrow.tail.y, length = hypot(dx, dy)
                let half = min(max(4, stroke.width * 1.6), length * 0.25)
                let path = CGMutablePath(); path.addLines(between: [arrow.tip,
                    CGPoint(x: arrow.tail.x - dy / length * half, y: arrow.tail.y + dx / length * half),
                    CGPoint(x: arrow.tail.x + dy / length * half, y: arrow.tail.y - dx / length * half)])
                path.closeSubpath(); return pathHit(path, filled: true)
            }
            func headHit(_ arrow: ImageEditingOperations.ArrowGeometry) -> Bool {
                let path = CGMutablePath(); path.addLines(between: [arrow.headLeft, arrow.tip, arrow.headRight])
                if stroke.style.arrowStyle != .open { path.closeSubpath() }
                return pathHit(path, filled: stroke.style.arrowStyle != .open && stroke.style.arrowStyle != .hollow, width: stroke.style.arrowStyle == .open || stroke.style.arrowStyle == .hollow ? arrow.shaftWidth : 0)
            }
            if segmentDistance(point, from: arrow.tail, to: stroke.style.arrowStyle == .open ? arrow.tip : arrow.base) <= arrow.shaftWidth / 2 + padding || headHit(arrow) { return true }
            if stroke.style.arrowStyle == .doubleEnded {
                var reverse = stroke; reverse.points.reverse()
                if let arrow = ImageEditingOperations.arrowGeometry(for: reverse), headHit(arrow) { return true }
            }
            if !stroke.text.isEmpty { return ImageEditingOperations.unrotatedBounds(for: stroke).insetBy(dx: -padding, dy: -padding).contains(point) }
            return false
        case .pen, .crop: return false
        }
    }
    /// Moves the visible object as a rigid body. A magnifier's explicit source rectangle stays fixed.
    static func moved(_ stroke: ImageEditStroke, by delta: CGSize, within area: CGRect) -> ImageEditStroke {
        guard (try? ImageEditingOperations.validate(stroke)) != nil, delta.width.isFinite, delta.height.isFinite,
              area.minX.isFinite, area.maxX.isFinite, area.minY.isFinite, area.maxY.isFinite, area.width >= 0, area.height >= 0 else { return stroke }
        let box = bounds(of: stroke)
        func translation(_ requested: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { min(max(low, high), max(min(low, high), requested)) }
        let dx = translation(delta.width, area.minX - box.minX, area.maxX - box.maxX)
        let dy = translation(delta.height, area.minY - box.minY, area.maxY - box.maxY)
        var result = stroke; result.points = stroke.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return result
    }
    private static func segmentDistance(_ point: CGPoint, from start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x, dy = end.y - start.y, lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let position = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        return hypot(point.x - start.x - position * dx, point.y - start.y - position * dy)
    }
}

/// Retains the full source so adjusting the crop never erases pixels or changes annotation positions.
/// History stores bounded drawing changes, not one full-screen bitmap per undo step.
@MainActor
final class CaptureAnnotationDocument {
    let source: CGImage
    private(set) var selection: CGRect?
    private(set) var strokes: [ImageEditStroke] = []
    private(set) var renderedImage: CGImage
    private(set) var failure: Error?
    private(set) var revision: UInt64 = 0
    private struct Change {
        let index: Int
        let before: ImageEditStroke?
        let after: ImageEditStroke?
        var beforeAll: [ImageEditStroke]? = nil
        var afterAll: [ImageEditStroke]? = nil
        var pointCount: Int { (before?.points.count ?? 0) + (after?.points.count ?? 0)
            + (beforeAll?.reduce(0) { $0 + $1.points.count } ?? 0) + (afterAll?.reduce(0) { $0 + $1.points.count } ?? 0) }
    }
    private var undoChanges: [Change] = []
    private var redoChanges: [Change] = []
    private var pointCount = 0
    private static let maximumStrokes = 1_024
    private static let maximumPoints = 100_000
    private static let maximumHistoryChanges = 1_024
    private static let maximumHistoryPoints = 200_000

    var canUndo: Bool { !undoChanges.isEmpty }
    var canRedo: Bool { !redoChanges.isEmpty }
    var bounds: CGRect { CGRect(x: 0, y: 0, width: source.width, height: source.height) }

    init(image: CGImage) {
        source = image
        renderedImage = image
    }

    func setSelection(_ rect: CGRect) {
        let safe = CaptureSelectionGeometry.clamped(rect, to: bounds)
        selection = safe.width >= 2 && safe.height >= 2 ? safe : nil
    }

    func resetSelection() {
        selection = nil
    }

    func append(_ stroke: ImageEditStroke) throws {
        do {
            let committed = try validated(stroke)
            if committed.tool == .crop {
                setSelection(committed.rect)
                failure = nil
                return
            }
            try validateResources(strokeCount: strokes.count + 1, pointCount: pointCount + committed.points.count)
            let result = try ImageEditingOperations.apply(committed, to: renderedImage, source: source)
            var proposed = strokes; proposed.append(committed)
            commit(Change(index: strokes.count, before: nil, after: committed), strokes: proposed, image: result)
        } catch {
            failure = error
            throw error
        }
    }

    func append(contentsOf additions: [ImageEditStroke]) throws {
        guard !additions.isEmpty else { return }
        do {
            let proposed = try appending(additions), result = try render(proposed)
            commit(Change(index: strokes.count, before: nil, after: nil, beforeAll: strokes, afterAll: proposed), strokes: proposed, image: result)
        } catch { failure = error; throw error }
    }
    func preview(appending additions: [ImageEditStroke]) throws -> CGImage { try render(appending(additions)) }
    private func appending(_ additions: [ImageEditStroke]) throws -> [ImageEditStroke] {
        let committed = try additions.map(validated)
        guard !committed.contains(where: { $0.tool == .crop }) else { throw CaptureToolError.invalidImage }
        try validateResources(strokeCount: strokes.count + committed.count, pointCount: pointCount + committed.reduce(0) { $0 + $1.points.count })
        return strokes + committed
    }

    func replace(at index: Int, with stroke: ImageEditStroke) throws {
        do {
            let proposed = try replacing(index, with: stroke)
            let result = try render(proposed)
            commit(Change(index: index, before: strokes[index], after: proposed[index]), strokes: proposed, image: result)
        } catch {
            failure = error
            throw error
        }
    }

    func remove(at index: Int) throws {
        do {
            try validateIndex(index)
            var proposed = strokes; let removed = proposed.remove(at: index)
            let result = try render(proposed)
            commit(Change(index: index, before: removed, after: nil), strokes: proposed, image: result)
        } catch {
            failure = error
            throw error
        }
    }

    func removeAll() throws {
        guard !strokes.isEmpty else { return }
        commit(Change(index: 0, before: nil, after: nil, beforeAll: strokes, afterAll: []), strokes: [], image: source)
    }

    /// Returns a replacement rendering without changing strokes, errors, or either history branch.
    func preview(replacing index: Int, with stroke: ImageEditStroke) throws -> CGImage {
        try render(replacing(index, with: stroke))
    }

    func undo() {
        guard let change = undoChanges.last else { return }
        do {
            let proposed = applying(change, forward: false)
            let result = try render(proposed)
            undoChanges.removeLast(); redoChanges.append(change)
            accept(proposed, image: result)
        } catch { failure = error }
    }

    func redo() {
        guard let change = redoChanges.last else { return }
        do {
            let proposed = applying(change, forward: true)
            let result = try render(proposed)
            redoChanges.removeLast(); undoChanges.append(change)
            accept(proposed, image: result)
        } catch { failure = error }
    }

    func export() throws -> Data {
        guard let selection else {
            throw CaptureMessage("请先选择截图区域。", "Select a screenshot area first.")
        }
        return try CaptureImageCodec.png(CaptureImageCodec.crop(renderedImage, rect: selection))
    }

    private func validated(_ stroke: ImageEditStroke) throws -> ImageEditStroke {
        try ImageEditingOperations.validate(stroke)
        var committed = stroke
        committed.text = String(stroke.text.prefix(500))
        if [.text, .watermark].contains(committed.tool) && committed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CaptureMessage("请输入标注文字。", "Enter annotation text.")
        }
        return committed
    }

    private func validateIndex(_ index: Int) throws {
        guard strokes.indices.contains(index) else {
            throw CaptureMessage("这条标注已不存在，请重新选择。", "This annotation no longer exists. Select an annotation again.")
        }
    }
    private func validateResources(strokeCount: Int, pointCount: Int) throws {
        guard strokeCount <= Self.maximumStrokes, pointCount <= Self.maximumPoints else {
            throw CaptureMessage("这张截图的标注已达上限，请先保存当前截图。", "This screenshot has reached its annotation limit. Save the current screenshot first.")
        }
    }
    private func replacing(_ index: Int, with stroke: ImageEditStroke) throws -> [ImageEditStroke] {
        try validateIndex(index)
        let committed = try validated(stroke)
        guard committed.tool != .crop else {
            throw CaptureMessage("裁剪区域不能替换标注，请调整截图选区。", "A crop cannot replace an annotation. Adjust the capture selection instead.")
        }
        try validateResources(strokeCount: strokes.count, pointCount: pointCount - strokes[index].points.count + committed.points.count)
        var proposed = strokes; proposed[index] = committed
        return proposed
    }
    private func applying(_ change: Change, forward: Bool) -> [ImageEditStroke] {
        if let all = forward ? change.afterAll : change.beforeAll { return all }
        let old = forward ? change.before : change.after
        let new = forward ? change.after : change.before
        var proposed = strokes
        if old != nil { proposed.remove(at: change.index) }
        if let new { proposed.insert(new, at: change.index) }
        return proposed
    }
    private func commit(_ change: Change, strokes proposed: [ImageEditStroke], image: CGImage) {
        redoChanges.removeAll()
        undoChanges.append(change)
        var historyPoints = undoChanges.reduce(0) { $0 + $1.pointCount }
        while undoChanges.count > Self.maximumHistoryChanges || historyPoints > Self.maximumHistoryPoints {
            historyPoints -= undoChanges.removeFirst().pointCount
        }
        accept(proposed, image: image)
    }
    private func accept(_ proposed: [ImageEditStroke], image: CGImage) {
        revision &+= 1
        strokes = proposed
        pointCount = proposed.reduce(0) { $0 + $1.points.count }
        renderedImage = image
        failure = nil
    }

    private func render(_ commands: [ImageEditStroke]) throws -> CGImage {
        try ImageEditingOperations.render(commands, source: source)
    }
}
