import AppKit
import CoreImage
import WebKit

@main
struct CaptureWorkflowTests {
    static var checks = 0
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw NSError(domain: "CaptureWorkflowTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1; print("PASS: \(message)"); fflush(stdout)
    }
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); print("CaptureWorkflowTests: \(checks) checks passed"); exit(0) }
            catch { print("FAIL: \(error)"); exit(1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { print("FAIL: workflow test timeout"); exit(2) }
        app.run()
    }
    @MainActor static func run() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let rect = CaptureSelectionSizing.exact(x: 780, y: -30, width: 320, height: 400, ratio: 16 / 9, in: bounds)
        try require(rect == CGRect(x: 480, y: 0, width: 320, height: 180), "Exact size preserves ratio and shifts inside source bounds")
        try require(CaptureSelectionSizing.exact(x: .nan, y: 0, width: 320, height: 200, ratio: nil, in: bounds) == .zero, "Invalid coordinates never escape geometry checks")
        let suite = "Xclip.WorkflowTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        CaptureSelectionMemory.remember(rect, in: bounds, defaults: defaults)
        CaptureSelectionMemory.remember(rect, in: bounds, defaults: defaults)
        try require(CaptureSelectionMemory.items(in: bounds, defaults: defaults).count == 1, "Recent region deduplicates source geometry")
        try require(CaptureSelectionMemory.items(in: CGRect(x: 0, y: 0, width: 1600, height: 1200), defaults: defaults).isEmpty, "Recent region cannot migrate to a different pixel grid")
        let preferences = CapturePreferences(defaults: defaults)
        preferences.format = .jpeg; preferences.delay = 3
        try require(CapturePreferences(defaults: defaults).format == .jpeg && CapturePreferences(defaults: defaults).delay == 3, "Export and delay preferences round trip without live defaults")
        let context = try CaptureImageCodec.context(width: 800, height: 240)
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 800, height: 240))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAttributedString(string: "XCLIP 2468\nCapture workflow", attributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black]).draw(at: CGPoint(x: 35, y: 70))
        NSGraphicsContext.restoreGraphicsState()
        let fixture = context.makeImage()!, png = try CaptureImageCodec.png(fixture)
        let exports = FileManager.default.temporaryDirectory.appendingPathComponent("Xclip-ExportTests-\(UUID())")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: exports) }
        let saved = exports.appendingPathComponent("image.png")
        try CaptureOutputCodec.writeNew(png, to: saved)
        try require(try Data(contentsOf: saved) == png, "Quick export atomically moves a complete image into a new destination")
        do { try CaptureOutputCodec.writeNew(Data("replacement".utf8), to: saved); throw CaptureMessage("Existing export was overwritten", "Existing export was overwritten") }
        catch { try require(!(error is CaptureMessage && error.localizedDescription == "Existing export was overwritten"), "Quick export refuses a duplicate filename") }
        try require(try Data(contentsOf: saved) == png && FileManager.default.contentsOfDirectory(atPath: exports.path) == ["image.png"], "Duplicate quick export preserves the original image and removes its staging file")
        try require(try CaptureOutput.quickSave(png, allowsWrite: { false }) == nil, "A cancelled quick export returns before a save panel or file write")
        for format in [CaptureOutputFormat.png, .jpeg, .heic, .tiff] {
            let data = try CaptureOutputCodec.encode(fixture, format: format)
            let decoded = try CaptureImageCodec.decode(data)
            try require(decoded.width == 800 && decoded.height == 240, "\(format.rawValue) encodes and decodes actual image dimensions")
        }
        let pdf = try CaptureOutputCodec.encode(fixture, format: .pdf)
        let pdfDocument = CGPDFDocument(CGDataProvider(data: pdf as CFData)!)
        try require(pdfDocument?.numberOfPages == 1 && pdfDocument?.page(at: 1)?.getBoxRect(.mediaBox).size == CGSize(width: 800, height: 240), "PDF export contains one correctly sized image page")
        let rounded = try CaptureOutputCodec.decorated(fixture, radius: 20, shadow: false)
        let sample = NSBitmapImageRep(cgImage: rounded)
        try require((sample.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) == 0, "Rounded export has transparent corners")
        let shadow = try CaptureOutputCodec.decorated(fixture, radius: 20, shadow: true)
        try require(shadow.width == 848 && shadow.height == 288, "Export reserves space for the shadow")
        let blocks = try await CaptureRecognitionService.text(png, language: "en-US")
        try require(blocks.map(\.text).joined(separator: " ").contains("2468"), "Vision OCR recognizes synthetic source text")
        try require(blocks.allSatisfy { $0.rect.minX >= 0 && $0.rect.maxX <= 1 && $0.rect.minY >= 0 && $0.rect.maxY <= 1 }, "OCR boxes use normalized top-left coordinates")
        let table: [CaptureRecognizedBlock] = [
            .init(text: "Name", rect: CGRect(x: 0.1, y: 0.1, width: 0.12, height: 0.04), confidence: 1),
            .init(text: "Count", rect: CGRect(x: 0.5, y: 0.105, width: 0.1, height: 0.04), confidence: 1),
            .init(text: "Apple", rect: CGRect(x: 0.1, y: 0.3, width: 0.14, height: 0.04), confidence: 1),
            .init(text: "8", rect: CGRect(x: 0.5, y: 0.5, width: 0.02, height: 0.04), confidence: 1)
        ]
        try require(CaptureRecognitionService.tsv(CaptureRecognitionService.table(table)) == "Name\tCount\nApple\t\n\t8", "Table reconstruction preserves empty cells and row alignment")
        let qr = CIFilter(name: "CIQRCodeGenerator")!
        qr.setValue(Data("xclip-synthetic-qr".utf8), forKey: "inputMessage")
        let qrImage = qr.outputImage!.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let qrCG = CIContext().createCGImage(qrImage, from: qrImage.extent)!
        let payload = try await CaptureRecognitionService.barcodes(CaptureImageCodec.png(qrCG))
        try require(payload.contains("xclip-synthetic-qr"), "Vision decodes an actual synthetic QR image")
        try require(CaptureRecognitionService.cleanFormula("```latex\n$$x^2$$\n```") == "x^2", "Formula service output normalizes common fences")
        let formula = CaptureFormulaPreview()
        formula.set("\\frac{a^2+b^2}{c} = \\sqrt{2}")
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = formula.webView
        defer { formula.close(); window.contentView = nil; window.close() }
        var math = ""
        for _ in 0..<100 {
            if let value = try? await formula.mathML(), !value.isEmpty { math = value; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try require(math.contains("<math") && math.contains("<mfrac>"), "Bundled offline KaTeX renders real MathML in WebKit")
        let rendered = try await formula.png(), renderedImage = try CaptureImageCodec.decode(rendered)
        try require(renderedImage.width >= 360 && renderedImage.height >= 160, "Native formula snapshot produces a Retina PNG")
        if CommandLine.arguments.count > 1 { try rendered.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic) }
        formula.set(Array(repeating: "x", count: 40).joined(separator: "+"))
        let wide = try CaptureImageCodec.decode(try await formula.png())
        let widePixels = NSBitmapImageRep(cgImage: wide)
        var rightHandInk = false
        for x in stride(from: wide.width * 3 / 4, to: wide.width - 20, by: 4) {
            for y in stride(from: 20, to: wide.height - 20, by: 4) {
                if let color = widePixels.colorAt(x: x, y: y), color.alphaComponent > 0.8, color.redComponent < 0.5 { rightHandInk = true; break }
            }
            if rightHandInk { break }
        }
        try require(wide.width > 1280 && rightHandInk, "A formula wider than its preview exports the right-hand content, not only the visible viewport")
        formula.set("\\definitelyUnknownCommand{")
        do { _ = try await formula.mathML(); throw CaptureMessage("Invalid LaTeX was exported", "Invalid LaTeX was exported") }
        catch { try require(!(error is CaptureMessage && error.localizedDescription == "Invalid LaTeX was exported"), "Invalid formula produces an actionable parse error") }
        formula.set("');globalThis.injected=1;//")
        _ = try? await formula.mathML()
        let injected = try await formula.webView.evaluateJavaScript("typeof globalThis.injected") as? String
        try require(injected == "undefined", "Formula input is data and cannot inject JavaScript")
        formula.set("x^2")
        _ = try await formula.webView.evaluateJavaScript("window.fontWait=false;window.fontGate=new Promise(r=>window.releaseFonts=r);Object.defineProperty(document.fonts,'ready',{configurable:true,get(){window.fontWait=true;return window.fontGate}});true")
        let changed = Task { @MainActor in try await formula.png() }
        for _ in 0..<100 {
            if try await formula.webView.evaluateJavaScript("window.fontWait") as? Bool == true { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        formula.set("y^3")
        _ = try await formula.webView.evaluateJavaScript("window.releaseFonts();true")
        do { _ = try await changed.value; throw CaptureMessage("Changed formula was exported", "Changed formula was exported") }
        catch { try require(!(error is CaptureMessage && error.localizedDescription == "Changed formula was exported"), "Editing during a real WebKit font wait invalidates the pending formula export") }
        _ = try await formula.webView.evaluateJavaScript("Object.defineProperty(document.fonts,'ready',{configurable:true,value:Promise.resolve(document.fonts)});window.formulaBounds=()=>({width:4097,height:80});true")
        do { _ = try await formula.png(); throw CaptureMessage("Oversized formula was exported", "Oversized formula was exported") }
        catch { try require(!(error is CaptureMessage && error.localizedDescription == "Oversized formula was exported"), "Formula export applies its size limit to Retina output pixels before snapshot allocation") }
        formula.close()
        do { _ = try await formula.mathML(); throw CaptureMessage("Closed formula was exported", "Closed formula was exported") }
        catch { try require(!(error is CaptureMessage && error.localizedDescription == "Closed formula was exported"), "Closed formula previews reject asynchronous exports") }
    }
}
