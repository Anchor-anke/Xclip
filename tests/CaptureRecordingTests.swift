import AppKit
import AVFoundation
import ImageIO

private final class RecordingTestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Error>?
    private var requested = false
    func set(_ task: Task<Void, Error>) { lock.lock(); self.task = task; if requested { task.cancel() }; lock.unlock() }
    func cancel() { lock.lock(); requested = true; task?.cancel(); lock.unlock() }
}

/// Only generated BGRA pixels and PCM sine waves; never opens a stream, window, or microphone.
@main
struct CaptureRecordingTests {
    static var checks = 0
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) {
        precondition((try? value()) == true, message)
        checks += 1; print("PASS: \(message)")
    }
    static func expectFailure(_ message: String, _ body: () async throws -> Void) async {
        do { try await body(); preconditionFailure(message) } catch { require(true, message) }
    }
    static func time(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 60_000) }
    static func pixelBuffer(red: UInt8, green: UInt8 = 0, blue: UInt8 = 0) -> CVPixelBuffer {
        var result: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &result) == kCVReturnSuccess)
        let buffer = result!
        CVPixelBufferLockBaseAddress(buffer, [])
        let pointer = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<64 { for x in 0..<64 {
            let index = y * stride + x * 4
            pointer[index] = blue; pointer[index + 1] = green; pointer[index + 2] = red; pointer[index + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
    static func append(_ buffer: CVPixelBuffer, to writer: CaptureRecordingWriter, at stamp: Double) async throws {
        for _ in 0..<200 {
            if try await writer.append(pixelBuffer: buffer, at: time(stamp)) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        preconditionFailure("Encoder never accepted the generated frame")
    }
    static func audioBuffer(at seconds: Double, frequency: Double) -> CMSampleBuffer {
        var format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
            mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        precondition(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format, layoutSize: 0,
            layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr)
        let count = 1_024
        let samples = (0..<(count * 2)).map { Float(sin(Double($0 / 2) / 48_000 * frequency * 2 * .pi) * 0.2) }
        var block: CMBlockBuffer?
        precondition(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: samples.count * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: samples.count * 4, flags: 0, blockBufferOut: &block) == noErr)
        samples.withUnsafeBytes { bytes in precondition(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!,
            blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes.count) == noErr) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: time(seconds), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        precondition(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: description, sampleCount: count, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
        return sample!
    }
    static func microphoneClock() -> CMTimebase {
        var clock: CMTimebase?
        precondition(CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &clock) == noErr)
        precondition(CMTimebaseSetRateAndAnchorTime(clock!, rate: 1, anchorTime: time(50), immediateSourceTime: time(200)) == noErr)
        return clock!
    }
    static func appendAudio(_ sample: CMSampleBuffer, to writer: CaptureRecordingWriter, microphone: Bool) async throws {
        for _ in 0..<200 {
            if try await writer.append(audio: sample, microphone: microphone) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        preconditionFailure("Encoder never accepted generated audio")
    }
    static func color(_ image: CGImage) -> [UInt8] {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: 4))
    }
    static func frame(_ url: URL, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: time(seconds)).image
    }
    static func timelineAndRegion() throws {
        var timeline = CaptureRecordingTimeline()
        require(timeline.presentationTime(for: time(50)) == nil, "A frame cannot be retimed before recording starts")
        timeline.pause(at: time(40)); timeline.resume(at: time(45)); timeline.start(at: time(50))
        require(timeline.presentationTime(for: time(50)) == .zero, "A pause before the first frame does not offset recording time")
        timeline.start(at: time(55))
        require(timeline.origin == time(50), "Repeated start preserves the first frame origin")
        timeline.pause(at: time(51)); timeline.pause(at: time(52))
        require(timeline.presentationTime(for: time(52)) == nil, "Paused frames are discarded")
        require(timeline.elapsed(at: time(60)) == time(1), "Stopping while paused excludes the entire pause")
        timeline.resume(at: time(54)); timeline.resume(at: time(56))
        require(timeline.presentationTime(for: time(55)) == time(2), "Resume removes the pause once, including repeated pause/resume calls")
        require(timeline.presentationTime(for: time(49)) == nil, "Frames older than the recording origin are discarded")
        let region = try CaptureRecordingRegion.resolve(CGRect(x: -980, y: -70, width: 101, height: 77), displayID: 5,
            displayFrame: CGRect(x: -1_000, y: -100, width: 1_000, height: 800), scale: 2)
        require(region.sourceRect == CGRect(x: 20, y: 30, width: 101, height: 77), "Quartz global points convert to display-local points on a negative-origin display")
        require(region.width == 202 && region.height == 154 && region.displayID == 5, "Retina scale affects output pixels, never the logical source rectangle")
        let capped = try CaptureRecordingRegion.resolve(CGRect(x: 0, y: 0, width: 4_001, height: 3_003), displayID: 1,
            displayFrame: CGRect(x: 0, y: 0, width: 5_000, height: 4_000), scale: 2)
        require(capped.width == 4_096 && capped.height % 2 == 0 && capped.height <= 4_096, "Large Retina recordings preserve aspect ratio with even H.264 dimensions bounded to 4096")
        do {
            _ = try CaptureRecordingRegion.resolve(CGRect(x: -1, y: 0, width: 20, height: 20), displayID: 1,
                displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2)
            preconditionFailure("Cross-display region should fail")
        } catch { require(true, "Cross-display selection fails before a recording starts") }
    }
    static func encoding(in directory: URL) async throws -> URL {
        let source = directory.appendingPathComponent("generated.mov")
        let writer = try CaptureRecordingWriter(url: source, width: 64, height: 64, framesPerSecond: 24, systemAudio: false, microphone: false)
        let red = pixelBuffer(red: 240), blue = pixelBuffer(red: 0, blue: 240)
        for index in 0..<6 { try await append(red, to: writer, at: 100 + Double(index) / 24) }
        writer.setPaused(true, at: time(100.25))
        let accepted = try await writer.append(pixelBuffer: blue, at: time(100.5))
        require(!accepted, "The production writer drops frames while paused")
        writer.setPaused(false, at: time(101.25))
        for index in 6..<12 { try await append(blue, to: writer, at: 101 + Double(index) / 24) }
        async let first = writer.finish(at: time(102))
        async let second = writer.finish(at: time(102))
        let outputs = try await (first, second)
        require(outputs.0 == source && outputs.1 == source, "Concurrent stop requests drain one finalization and return the same file")
        let duration = try await AVURLAsset(url: source).load(.duration).seconds
        require(abs(duration - 1) < 0.05, "Encoded duration removes the one-second pause and extends the static last frame to stop time")
        let firstColor = color(try await frame(source, at: 0.05)), lastColor = color(try await frame(source, at: 0.85))
        require(firstColor[0] > 180 && firstColor[2] < 40, "H.264 decoding preserves the first red synthetic frame")
        require(lastColor[2] > 180 && lastColor[0] < 40, "The final static interval decodes to the last blue frame")
        let repeated = try await writer.finish()
        require(repeated == source, "Stop after completed recording is idempotent")
        await expectFailure("Completed writers reject further video frames") { _ = try await writer.append(pixelBuffer: red, at: time(103)) }
        await writer.cancel(); await writer.cancel()
        require(FileManager.default.fileExists(atPath: source.path), "Cancel releases a completed writer without deleting the caller's recording")
        return source
    }
    static func exports(source: URL, in directory: URL) async throws {
        let mp4 = directory.appendingPathComponent("trimmed.mp4")
        try await CaptureRecordingExporter.export(source: source, destination: mp4, format: .mp4, start: 0.125, end: 0.75)
        let asset = AVURLAsset(url: mp4), duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        require(abs(duration - 0.625) < 0.06 && tracks.count == 1, "A real MP4 export trims the selected time range and retains one video track")
        let mp4Color = color(try await frame(mp4, at: 0.5))
        require(mp4Color[2] > 180 && mp4Color[0] < 40, "Trimmed MP4 remains decodable with the expected blue content")
        let gif = directory.appendingPathComponent("trimmed.gif")
        try await CaptureRecordingExporter.export(source: source, destination: gif, format: .gif, start: 0.125, end: 0.75, gifFPS: 16)
        let images = CGImageSourceCreateWithURL(gif as CFURL, nil)!
        require(CGImageSourceGetCount(images) == 10, "GIF encodes the expected ten frames from the trimmed range")
        let first = color(CGImageSourceCreateImageAtIndex(images, 0, nil)!), last = color(CGImageSourceCreateImageAtIndex(images, 9, nil)!)
        require(first[0] > 180 && first[2] < 40 && last[2] > 180 && last[0] < 40, "GIF frame decoding preserves temporal red-to-blue content")
        let properties = CGImageSourceCopyPropertiesAtIndex(images, 0, nil) as! [CFString: Any]
        let timing = properties[kCGImagePropertyGIFDictionary] as! [CFString: Any]
        let delay = (timing[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue ?? 0
        require(abs(delay - 0.0625) < 0.011, "GIF stores playback frame delay rather than only static images")
        let data = try Data(contentsOf: mp4)
        await expectFailure("An existing export destination is rejected") {
            try await CaptureRecordingExporter.export(source: source, destination: mp4, format: .mp4, start: 0, end: 0.5)
        }
        require(try Data(contentsOf: mp4) == data, "A failed export never removes or overwrites the preexisting destination")
        let invalid = directory.appendingPathComponent("invalid.gif")
        await expectFailure("An invalid trim range is rejected before output creation") {
            try await CaptureRecordingExporter.export(source: source, destination: invalid, format: .gif, start: 0.8, end: 0.4)
        }
        require(!FileManager.default.fileExists(atPath: invalid.path), "Invalid trim leaves no output file")
        let cancelled = directory.appendingPathComponent("cancelled.gif")
        let task = Task {
            try await CaptureRecordingExporter.export(source: source, destination: cancelled, format: .gif, start: 0, end: 1, gifFPS: 30)
        }
        task.cancel()
        await expectFailure("Cancelled GIF export terminates through cancellation") { try await task.value }
        require(!FileManager.default.fileExists(atPath: cancelled.path), "Cancelled GIF export removes its partial output")
    }
    static func audio(in directory: URL) async throws {
        let source = directory.appendingPathComponent("audio.mov")
        let writer = try CaptureRecordingWriter(url: source, width: 64, height: 64, framesPerSecond: 24, systemAudio: true, microphone: true)
        let microphoneClock = microphoneClock()
        try await append(pixelBuffer(red: 0, green: 230), to: writer, at: 200)
        for index in 0..<46 {
            let stamp = 200 + Double(index * 1_024) / 48_000
            try await appendAudio(audioBuffer(at: stamp, frequency: 440), to: writer, microphone: false)
            let microphone = audioBuffer(at: stamp - 150, frequency: 700)
            let synchronized = CaptureRecordingSampleTiming.converting(microphone, from: microphoneClock, to: CMClockGetHostTimeClock())!
            try await appendAudio(synchronized, to: writer, microphone: true)
        }
        let output = try await writer.finish(at: time(201))
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
        require(tracks.count == 2, "Generated system and microphone PCM encode into independent AAC source tracks")
        let mp4 = directory.appendingPathComponent("audio.mp4")
        try await CaptureRecordingExporter.export(source: source, destination: mp4, format: .mp4, start: 0, end: 1)
        let asset = AVURLAsset(url: mp4), mixed = try await asset.loadTracks(withMediaType: .audio)
        require(mixed.count == 1, "MP4 export mixes system and microphone audio into one playback track")
        let reader = try AVAssetReader(asset: asset)
        let audio = AVAssetReaderTrackOutput(track: mixed[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(audio); require(reader.startReading(), "The mixed AAC track can be decoded as PCM")
        var sampleCount = 0, hasSound = false
        while let sample = audio.copyNextSampleBuffer() {
            sampleCount += sample.numSamples
            if let block = sample.dataBuffer {
                let length = CMBlockBufferGetDataLength(block)
                var bytes = [UInt8](repeating: 0, count: length)
                let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
                if status == noErr { hasSound = hasSound || bytes.contains { $0 != 0 } }
            }
        }
        require(reader.status == .completed && sampleCount > 40_000 && hasSound, "Exported audio contains decodable non-silent generated samples")
        let microphoneSample = audioBuffer(at: 50, frequency: 500)
        let synchronized = CaptureRecordingSampleTiming.converting(microphoneSample, from: microphoneClock, to: CMClockGetHostTimeClock())!
        require(abs(synchronized.presentationTimeStamp.seconds - 200) < 0.0001, "The macOS 14 microphone timebase converts to ScreenCaptureKit's host clock")
        require(synchronized.numSamples == microphoneSample.numSamples && synchronized.duration == microphoneSample.duration,
            "Microphone clock conversion preserves audio sample count and duration")
        require(synchronized.dataBuffer === microphoneSample.dataBuffer, "Microphone synchronization shares the PCM buffer without copying or accumulating samples")
    }
    static func webp(source: URL, in directory: URL) async throws {
        let helper = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".build/recording-webp/XclipWebP")
        require(FileManager.default.isExecutableFile(atPath: helper.path), "The tests use the built project WebP helper, never an external PATH tool")
        let output = directory.appendingPathComponent("trimmed.webp")
        try await CaptureRecordingExporter.export(source: source, destination: output, format: .webp, start: 0.125, end: 0.75, gifFPS: 16, webpHelper: helper)
        guard let images = CGImageSourceCreateWithURL(output as CFURL, nil) else { preconditionFailure("WebP output must decode") }
        let count = CGImageSourceGetCount(images)
        require(count >= 2 && count <= 10, "The bundled official encoder creates decodable animated WebP with repeated frames coalesced")
        let first = color(CGImageSourceCreateImageAtIndex(images, 0, nil)!), last = color(CGImageSourceCreateImageAtIndex(images, count - 1, nil)!)
        require(first[0] > 180 && first[2] < 40 && last[2] > 180 && last[0] < 40, "WebP decoding preserves both the red and blue recording frames")
        let missing = directory.appendingPathComponent("missing.webp")
        await expectFailure("Missing bundled encoder produces a recoverable export error") {
            try await CaptureRecordingExporter.export(source: source, destination: missing, format: .webp, start: 0, end: 1,
                webpHelper: directory.appendingPathComponent("missing-helper"))
        }
        require(!FileManager.default.fileExists(atPath: missing.path), "A missing WebP helper leaves no pretend output")
        let cancelled = directory.appendingPathComponent("cancelled.webp"), cancellation = RecordingTestCancellation()
        let task = Task {
            try await CaptureRecordingExporter.export(source: source, destination: cancelled, format: .webp, start: 0, end: 1,
                gifFPS: 30, webpHelper: helper) { progress in if progress > 0.05 { cancellation.cancel() } }
        }
        cancellation.set(task)
        await expectFailure("Cancelling after WebP frame delivery terminates and drains the actual encoder process") { try await task.value }
        require(!FileManager.default.fileExists(atPath: cancelled.path), "Cancelled WebP encoding removes its output after the helper exits")
    }
    static func lifecycle(in directory: URL) async throws {
        await expectFailure("Invalid dimensions fail before creating an encoder") {
            _ = try CaptureRecordingWriter(url: directory.appendingPathComponent("invalid.mov"), width: 63, height: 64, framesPerSecond: 24, systemAudio: false, microphone: false)
        }
        let empty = try CaptureRecordingWriter(url: directory.appendingPathComponent("empty.mov"), width: 64, height: 64, framesPerSecond: 24, systemAudio: false, microphone: false)
        let microphone = CaptureRecordingMicrophone(writer: empty)
        await microphone.stop(); await microphone.stop()
        require(true, "Stopping the macOS 14 microphone before startup drains repeatedly without discovering a device")
        await expectFailure("A cancelled macOS 14 microphone cannot reopen a device on a late start") { try await microphone.start() }
        await expectFailure("Stopping before the first frame reports a recoverable error") { _ = try await empty.finish() }
        await empty.cancel(); await empty.cancel()
        require(true, "Cancel after a failed empty recording drains and is idempotent")
        let cancelled = try CaptureRecordingWriter(url: directory.appendingPathComponent("cancelled.mov"), width: 64, height: 64, framesPerSecond: 24, systemAudio: false, microphone: false)
        let buffer = pixelBuffer(red: 210)
        try await append(buffer, to: cancelled, at: 300)
        let finishing = Task { try await cancelled.finish(at: time(302)) }
        await cancelled.cancel(); _ = await finishing.result
        await expectFailure("Cancel racing with finish drains before subsequent stop is rejected") { _ = try await cancelled.finish() }
        await expectFailure("Cancelled writers reject new video frames") { _ = try await cancelled.append(pixelBuffer: buffer, at: time(303)) }
        let shortURL = directory.appendingPathComponent("short.mov")
        let short = try CaptureRecordingWriter(url: shortURL, width: 64, height: 64, framesPerSecond: 60, systemAudio: false, microphone: false)
        try await append(buffer, to: short, at: 350); _ = try await short.finish(at: time(350))
        let shortDuration = try await AVURLAsset(url: shortURL).load(.duration).seconds
        let shortMP4 = directory.appendingPathComponent("short.mp4")
        try await CaptureRecordingExporter.export(source: shortURL, destination: shortMP4, format: .mp4, start: 0, end: shortDuration)
        let shortFrame = try await frame(shortMP4, at: 0)
        require(shortDuration < 0.05 && shortFrame.width == 64, "A single-frame quick recording remains exportable instead of getting stuck at the trim minimum")
        let longURL = directory.appendingPathComponent("long.mov")
        let long = try CaptureRecordingWriter(url: longURL, width: 64, height: 64, framesPerSecond: 5, systemAudio: false, microphone: false)
        try await append(buffer, to: long, at: 400); _ = try await long.finish(at: time(800))
        let gif = directory.appendingPathComponent("oversized.gif")
        await expectFailure("GIF frame limits reject an excessive-duration export before decoding frames") {
            try await CaptureRecordingExporter.export(source: longURL, destination: gif, format: .gif, start: 0, end: 400, gifFPS: 30)
        }
        require(!FileManager.default.fileExists(atPath: gif.path), "Rejected oversized GIF leaves no partial file")
    }
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xclip-recording-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try timelineAndRegion()
        let source = try await encoding(in: directory)
        try await exports(source: source, in: directory)
        try await webp(source: source, in: directory)
        try await audio(in: directory)
        try await lifecycle(in: directory)
        print("Capture recording tests passed: \(checks) checks; synthetic media only.")
    }
}
