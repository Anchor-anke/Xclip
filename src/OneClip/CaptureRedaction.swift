import AppKit
import Vision

struct CaptureRedactionMatch {
    let text: String
    let rect: CGRect
}

enum CaptureRedaction {
    /// Exact, case-sensitive text matches. This does not classify personal or sensitive information.
    static func ranges(of needles: [String], in text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        for needle in Set(needles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }).sorted(by: { $0.count > $1.count }) where needle.count >= 2 {
            var remaining = text.startIndex..<text.endIndex
            while let match = text.range(of: needle, options: .literal, range: remaining) {
                if !result.contains(where: { $0.overlaps(match) }) { result.append(match) }
                remaining = match.upperBound..<text.endIndex
            }
        }
        return result.sorted { $0.lowerBound < $1.lowerBound }
    }
    static func sourceRect(normalized: CGRect, selection: CGRect) -> CGRect {
        CGRect(x: selection.minX + normalized.minX * selection.width, y: selection.minY + (1 - normalized.maxY) * selection.height,
               width: normalized.width * selection.width, height: normalized.height * selection.height)
            .insetBy(dx: -2, dy: -2).integral.intersection(selection)
    }
    static func matches(source: CGImage, sample: CGRect, selection: CGRect) async throws -> [CaptureRedactionMatch] {
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let sample = sample.integral.intersection(bounds), selection = selection.integral.intersection(bounds)
        let sampleImage = try CaptureImageCodec.crop(source, rect: sample)
        let sampleBlocks = try await CaptureRecognitionService.text(CaptureImageCodec.png(sampleImage))
        let needles = sampleBlocks.map(\.text).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= 2 }
        guard !needles.isEmpty else {
            throw CaptureMessage("这个马赛克区域没有识别出至少两个字符。请框住完整文字后重试。", "No text of at least two characters was recognized. Select complete text and retry.")
        }
        let request = VNRecognizeTextRequest()
        let worker = Task.detached(priority: .userInitiated) {
            let image = try CaptureImageCodec.crop(source, rect: selection)
            request.recognitionLevel = .accurate; request.usesLanguageCorrection = true; request.automaticallyDetectsLanguage = true
            let supported = try request.supportedRecognitionLanguages()
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"].filter(supported.contains)
            try Task.checkCancellation(); try VNImageRequestHandler(cgImage: image).perform([request]); try Task.checkCancellation()
            var matches: [CaptureRedactionMatch] = []
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                for range in ranges(of: needles, in: candidate.string) {
                    guard let box = try candidate.boundingBox(for: range) else { continue }
                    let rect = sourceRect(normalized: box.boundingBox, selection: selection)
                    guard rect.width >= 2, rect.height >= 2 else { continue }
                    // The initial mask already protects its own text; only propose additional occurrences.
                    if sample.intersection(rect).width * sample.intersection(rect).height >= rect.width * rect.height * 0.7 { continue }
                    if !matches.contains(where: { $0.rect.intersects(rect) }) { matches.append(.init(text: String(candidate.string[range]), rect: rect)) }
                }
            }
            return matches
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { request.cancel(); worker.cancel() }
    }
}
