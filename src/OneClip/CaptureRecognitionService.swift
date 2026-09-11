import AppKit
import Vision

struct CaptureRecognizedBlock {
    var text: String
    /// Normalized top-left coordinates, independent of image scale.
    var rect: CGRect
    var confidence: Float
}

enum CaptureRecognitionService {
    static func text(_ data: Data, language: String = "") async throws -> [CaptureRecognizedBlock] {
        let request = VNRecognizeTextRequest()
        let worker = Task.detached(priority: .userInitiated) {
            let image = try CaptureImageCodec.decode(data)
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = language.isEmpty
            let supported = try request.supportedRecognitionLanguages()
            request.recognitionLanguages = (language.isEmpty ? ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"] : [language]).filter { supported.contains($0) }
            try Task.checkCancellation()
            try VNImageRequestHandler(cgImage: image).perform([request])
            try Task.checkCancellation()
            return (request.results ?? []).compactMap { observation -> CaptureRecognizedBlock? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let r = observation.boundingBox
                return .init(text: candidate.string, rect: CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height), confidence: candidate.confidence)
            }.sorted { $0.rect.minY < $1.rect.minY }
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { request.cancel(); worker.cancel() }
    }
    static func barcodes(_ data: Data) async throws -> String {
        let request = VNDetectBarcodesRequest()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try VNImageRequestHandler(cgImage: CaptureImageCodec.decode(data)).perform([request])
            try Task.checkCancellation()
            return (request.results ?? []).compactMap { observation in
                observation.payloadStringValue.map { "\(observation.symbology.rawValue)\n\($0)" }
            }.joined(separator: "\n\n")
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { request.cancel(); worker.cancel() }
    }
    /// Recover row/column alignment from OCR boxes; empty cells are preserved.
    static func table(_ blocks: [CaptureRecognizedBlock]) -> [[String]] {
        guard !blocks.isEmpty else { return [] }
        var rows: [[CaptureRecognizedBlock]] = []
        for block in blocks.sorted(by: { $0.rect.midY < $1.rect.midY }) {
            if let last = rows.last, let representative = last.first,
               abs(representative.rect.midY - block.rect.midY) < max(representative.rect.height, block.rect.height) * 0.55 {
                rows[rows.count - 1].append(block)
            } else { rows.append([block]) }
        }
        let widest = rows.max(by: { $0.count < $1.count })!.sorted { $0.rect.minX < $1.rect.minX }
        let anchors = widest.map { $0.rect.minX }
        return rows.map { row in
            var cells = Array(repeating: "", count: anchors.count)
            for block in row.sorted(by: { $0.rect.minX < $1.rect.minX }) {
                let column = anchors.indices.min { abs(anchors[$0] - block.rect.minX) < abs(anchors[$1] - block.rect.minX) } ?? 0
                cells[column] += (cells[column].isEmpty ? "" : " ") + block.text
            }
            return cells
        }
    }
    static func tsv(_ table: [[String]]) -> String {
        table.map { $0.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t") }.joined(separator: "\n")
    }
    static func cleanFormula(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```"), let end = result.firstIndex(of: "\n") {
            result = String(result[result.index(after: end)...])
            if result.hasSuffix("```") { result.removeLast(3) }
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)"), ("$", "$")] {
            if result.hasPrefix(open), result.hasSuffix(close), result.count >= open.count + close.count {
                return String(result.dropFirst(open.count).dropLast(close.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return result
    }
}
