import AppKit
@preconcurrency import AVFoundation
import AVKit
import CoreImage
import Darwin
import ImageIO
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

private func recordingText(_ chinese: String, _ english: String) -> String { AppLanguage.text(chinese, english) }

struct CaptureRecordingError: LocalizedError {
    let chinese: String
    let english: String
    var errorDescription: String? { recordingText(chinese, english) }
}

struct CaptureRecordingOptions {
    var framesPerSecond = 30
    var delay = 0
    var showsCursor = true
    var systemAudio = false
    var microphone = false
}

enum CaptureRecordingFormat: String, CaseIterable, Identifiable {
    case mp4 = "MP4", gif = "GIF", webp = "WebP"
    var id: String { rawValue }
    var fileExtension: String { rawValue.lowercased() }
    var contentType: UTType { self == .mp4 ? .mpeg4Movie : self == .gif ? .gif : .webP }
}

/// Maps ScreenCaptureKit's host-clock timestamps onto a recording clock with pauses removed.
struct CaptureRecordingTimeline {
    private(set) var origin: CMTime?
    private(set) var pausedAt: CMTime?
    private(set) var pausedDuration = CMTime.zero
    mutating func start(at time: CMTime) {
        guard origin == nil else { return }
        origin = time
        pausedDuration = .zero
    }
    mutating func pause(at time: CMTime) {
        guard pausedAt == nil else { return }
        pausedAt = time
    }
    mutating func resume(at time: CMTime) {
        guard let pausedAt else { return }
        if origin != nil { pausedDuration = pausedDuration + CMTimeMaximum(.zero, time - pausedAt) }
        self.pausedAt = nil
    }
    func elapsed(at time: CMTime) -> CMTime {
        guard let origin else { return .zero }
        return CMTimeMaximum(.zero, (pausedAt.map { CMTimeMinimum(time, $0) } ?? time) - origin - pausedDuration)
    }
    func presentationTime(for time: CMTime) -> CMTime? {
        guard pausedAt == nil, let origin, time.isValid, time >= origin else { return nil }
        return CMTimeMaximum(.zero, time - origin - pausedDuration)
    }
}

struct CaptureRecordingRegion {
    let displayID: CGDirectDisplayID
    let sourceRect: CGRect
    let width: Int
    let height: Int
    static func resolve(_ region: CGRect, displayID: CGDirectDisplayID, displayFrame: CGRect, scale: CGFloat) throws -> Self {
        guard region.minX.isFinite, region.minY.isFinite, region.width.isFinite, region.height.isFinite,
              region.width >= 2, region.height >= 2, scale.isFinite, scale > 0,
              displayFrame.contains(region) else {
            throw CaptureRecordingError(chinese: "录屏范围需要完整位于一块显示器内，请重新框选。", english: "Select a recording region entirely within one display.")
        }
        // H.264 uses even dimensions. Keep large Retina displays within a bounded, supported output size.
        let outputScale = min(scale, 4096 / max(region.width, region.height))
        let width = max(2, Int(floor(region.width * outputScale / 2)) * 2)
        let height = max(2, Int(floor(region.height * outputScale / 2)) * 2)
        return Self(displayID: displayID, sourceRect: region.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY), width: width, height: height)
    }
}

enum CaptureRecordingSampleTiming {
    static func shifting(_ sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard offset.isValid else { return nil }
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0 else { return nil }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count) == noErr else { return nil }
        for index in timing.indices {
            timing[index].presentationTimeStamp = timing[index].presentationTimeStamp + offset
            if timing[index].decodeTimeStamp.isValid { timing[index].decodeTimeStamp = timing[index].decodeTimeStamp + offset }
        }
        var retimed: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &retimed) == noErr else { return nil }
        return retimed
    }
    static func converting(_ sample: CMSampleBuffer, from clock: CMClockOrTimebase, to target: CMClockOrTimebase) -> CMSampleBuffer? {
        let converted = CMSyncConvertTime(sample.presentationTimeStamp, from: clock, to: target)
        return shifting(sample, by: converted - sample.presentationTimeStamp)
    }
}

/// Every writer operation, including callbacks and finalization, runs on one bounded serial queue.
/// A single last frame is retained so a static screen still reaches the actual stop time.
final class CaptureRecordingWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "local.cclip.recording.writer", qos: .userInitiated)
    let url: URL
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let pixels: AVAssetWriterInputPixelBufferAdaptor
    private let audio: AVAssetWriterInput?
    private let microphone: AVAssetWriterInput?
    private let frameInterval: CMTime
    private var timeline = CaptureRecordingTimeline()
    private var lastVideoTime: CMTime?
    private var lastAudioTime = [String: CMTime]()
    private var lastFrame: CVPixelBuffer?
    private var failure: Error?
    private var finishing = false
    private var finished = false
    private var cancelled = false
    private var finalizationPending = false
    private var completions = [CheckedContinuation<URL, Error>]()
    private var cancellationCompletions = [CheckedContinuation<Void, Never>]()
    var onFailure: (@Sendable (Error) -> Void)?

    init(url: URL, width: Int, height: Int, framesPerSecond: Int, systemAudio: Bool, microphone: Bool) throws {
        guard width >= 2, height >= 2, width <= 4096, height <= 4096,
              width % 2 == 0, height % 2 == 0, [5, 16, 24, 30, 60].contains(framesPerSecond) else {
            throw CaptureRecordingError(chinese: "录屏尺寸或帧率无效。", english: "Invalid recording dimensions or frame rate.")
        }
        self.url = url
        frameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: min(60_000_000, max(2_000_000, width * height * framesPerSecond / 6)),
                AVVideoExpectedSourceFrameRateKey: framesPerSecond, AVVideoMaxKeyFrameIntervalKey: framesPerSecond * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw CaptureRecordingError(chinese: "这台设备无法编码当前录屏尺寸，请缩小范围。", english: "This device cannot encode that recording size. Select a smaller region.")
        }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = true
        pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        func audioInput() -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000])
            input.expectsMediaDataInRealTime = true
            return input
        }
        audio = systemAudio ? audioInput() : nil
        self.microphone = microphone ? audioInput() : nil
        super.init()
        for input in [video, audio, self.microphone].compactMap({ $0 }) {
            guard writer.canAdd(input) else { throw CaptureRecordingError(chinese: "无法建立录屏音视频轨道。", english: "Unable to create a recording media track.") }
            writer.add(input)
        }
        guard writer.startWriting() else { throw writer.error ?? CaptureRecordingError(chinese: "录屏文件无法开始写入。", english: "Unable to start writing the recording.") }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !cancelled, !finishing, failure == nil, sampleBuffer.isValid else { return }
        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, raw == SCFrameStatus.complete.rawValue,
                  let buffer = sampleBuffer.imageBuffer else { return }
            _ = appendVideo(buffer, at: sampleBuffer.presentationTimeStamp)
        } else if type == .audio {
            _ = appendAudio(sampleBuffer, input: audio, key: "system")
        } else if #available(macOS 15.0, *), type == .microphone {
            _ = appendAudio(sampleBuffer, input: microphone, key: "microphone")
        }
    }

    /// Allows deterministic encoding tests to feed generated pixels through the production writer.
    func append(pixelBuffer: CVPixelBuffer, at time: CMTime) async throws -> Bool {
        // The buffer is retained until its serial append completes; the caller must not mutate it.
        let frame = RecordingPixelBuffer(value: pixelBuffer)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let error = self.failure { continuation.resume(throwing: error); return }
                if self.cancelled || self.finishing { continuation.resume(throwing: CancellationError()); return }
                continuation.resume(returning: self.appendVideo(frame.value, at: time))
            }
        }
    }
    func setPaused(_ paused: Bool, at time: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) {
        queue.async {
            guard !self.finishing, !self.cancelled else { return }
            if paused { self.timeline.pause(at: time) } else { self.timeline.resume(at: time) }
        }
    }
    func append(audio sample: CMSampleBuffer, microphone: Bool = false) async throws -> Bool {
        let frame = RecordingAudioBuffer(value: sample)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let error = self.failure { continuation.resume(throwing: error); return }
                if self.cancelled || self.finishing { continuation.resume(throwing: CancellationError()); return }
                continuation.resume(returning: self.appendAudio(frame.value, input: microphone ? self.microphone : self.audio,
                    key: microphone ? "microphone" : "system"))
            }
        }
    }
    fileprivate func consumeMicrophone(_ sample: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !cancelled, !finishing, failure == nil, sample.isValid else { return }
        _ = appendAudio(sample, input: microphone, key: "microphone")
    }
    private func appendVideo(_ buffer: CVPixelBuffer, at time: CMTime) -> Bool {
        guard timeline.pausedAt == nil, video.isReadyForMoreMediaData, time.isValid else { return false }
        if timeline.origin == nil { timeline.start(at: time); writer.startSession(atSourceTime: .zero) }
        guard let outputTime = timeline.presentationTime(for: time), lastVideoTime.map({ outputTime > $0 }) ?? true else { return false }
        guard pixels.append(buffer, withPresentationTime: outputTime) else { report(writer.error); return false }
        lastFrame = buffer; lastVideoTime = outputTime
        return true
    }
    private func appendAudio(_ sample: CMSampleBuffer, input: AVAssetWriterInput?, key: String) -> Bool {
        guard let input, input.isReadyForMoreMediaData,
              let adjusted = timeline.presentationTime(for: sample.presentationTimeStamp),
              lastAudioTime[key].map({ adjusted > $0 }) ?? true else { return false }
        guard let retimed = CaptureRecordingSampleTiming.shifting(sample, by: adjusted - sample.presentationTimeStamp) else { return false }
        if input.append(retimed) { lastAudioTime[key] = adjusted; return true }
        report(writer.error); return false
    }
    private func report(_ error: Error?) {
        guard failure == nil else { return }
        let error = error ?? CaptureRecordingError(chinese: "录屏编码失败，请停止后重新录制。", english: "Recording encoding failed. Stop and record again.")
        failure = error; onFailure?(error)
    }
    func finish(at sourceTime: CMTime? = nil) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if self.cancelled { continuation.resume(throwing: CancellationError()); return }
                if self.finished { continuation.resume(returning: self.url); return }
                if let failure = self.failure { continuation.resume(throwing: failure); return }
                self.completions.append(continuation)
                guard !self.finishing else { return }
                self.finishing = true
                self.finalizationPending = true
                guard let last = self.lastVideoTime, self.lastFrame != nil else {
                    self.writer.cancelWriting()
                    self.complete(.failure(CaptureRecordingError(chinese: "还没有收到录屏画面，请重新开始。", english: "No recording frames arrived. Start again.")))
                    return
                }
                let end = max(last + self.frameInterval, sourceTime.map { self.timeline.elapsed(at: $0) } ?? (last + self.frameInterval))
                self.finalize(end: end, retries: 300)
            }
        }
    }
    private func finalize(end: CMTime, retries: Int) {
        if cancelled { writer.cancelWriting(); complete(.failure(CancellationError())); return }
        if writer.status == .failed { complete(.failure(writer.error ?? CaptureRecordingError(chinese: "录屏写入失败。", english: "Recording write failed."))); return }
        guard video.isReadyForMoreMediaData else {
            guard retries > 0 else { writer.cancelWriting(); complete(.failure(CaptureRecordingError(chinese: "录屏编码器没有响应，请重试。", english: "The recording encoder did not respond. Try again."))); return }
            queue.asyncAfter(deadline: .now() + 0.01) { self.finalize(end: end, retries: retries - 1) }
            return
        }
        if let frame = lastFrame, let last = lastVideoTime, end - frameInterval > last {
            guard pixels.append(frame, withPresentationTime: end - frameInterval) else { complete(.failure(writer.error ?? CaptureRecordingError(chinese: "无法完成录屏最后一帧。", english: "Unable to finish the final recording frame."))); return }
        }
        writer.endSession(atSourceTime: end)
        [video, audio, microphone].compactMap { $0 }.forEach { $0.markAsFinished() }
        writer.finishWriting {
            self.queue.async {
                if self.cancelled { self.complete(.failure(CancellationError())) }
                else if self.writer.status == .completed { self.finished = true; self.complete(.success(self.url)) }
                else { self.complete(.failure(self.writer.error ?? CaptureRecordingError(chinese: "无法完成录屏文件。", english: "Unable to finalize the recording file."))) }
            }
        }
    }
    private func complete(_ result: Result<URL, Error>) {
        lastFrame = nil; finalizationPending = false
        let callbacks = completions; completions.removeAll()
        if case .failure(let error) = result { failure = error }
        callbacks.forEach { $0.resume(with: result) }
        let cancellations = cancellationCompletions; cancellationCompletions.removeAll()
        cancellations.forEach { $0.resume() }
    }
    func cancel() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.cancelled = true
                if self.finalizationPending { self.cancellationCompletions.append(continuation) }
                else {
                    if self.writer.status == .writing { self.writer.cancelWriting() }
                    self.lastFrame = nil
                    continuation.resume()
                }
            }
        }
    }
}

private struct RecordingPixelBuffer: @unchecked Sendable { let value: CVPixelBuffer }
private struct RecordingAudioBuffer: @unchecked Sendable { let value: CMSampleBuffer }
// AVAssetExportSession supports cancellation from another execution context.
private struct RecordingExportCancellation: @unchecked Sendable { let session: AVAssetExportSession }

/// macOS 14 microphone capture, using the same bounded writer queue as ScreenCaptureKit audio.
/// Construction and stopping never discover a device or request permission; only explicit start does.
final class CaptureRecordingMicrophone: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession(), output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "local.cclip.recording.microphone", qos: .userInitiated)
    private let writer: CaptureRecordingWriter
    private let onFailure: @Sendable (Error) -> Void
    private var stopped = false
    private var observers = [NSObjectProtocol]()
    init(writer: CaptureRecordingWriter, onFailure: @escaping @Sendable (Error) -> Void = { _ in }) {
        self.writer = writer; self.onFailure = onFailure
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard !self.stopped else { throw CancellationError() }
                    if self.session.isRunning { continuation.resume(); return }
                    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                        throw CaptureRecordingError(chinese: "麦克风未获授权，请关闭麦克风或在系统设置允许。", english: "Microphone access is unavailable. Disable it or allow access in System Settings.")
                    }
                    guard let device = AVCaptureDevice.default(for: .audio) else {
                        throw CaptureRecordingError(chinese: "没有可用的麦克风，请连接设备或关闭麦克风。", english: "No microphone is available. Connect one or disable microphone recording.")
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    self.session.beginConfiguration()
                    do {
                        guard self.session.canAddInput(input), self.session.canAddOutput(self.output) else {
                            throw CaptureRecordingError(chinese: "无法连接麦克风，请检查设备是否可用。", english: "Unable to connect the microphone. Check that the device is available.")
                        }
                        self.session.addInput(input); self.session.addOutput(self.output)
                        // Native PCM can be mono/stereo at the hardware sample rate; AVAssetWriter converts to AAC.
                        self.output.setSampleBufferDelegate(self, queue: self.writer.queue)
                        self.session.commitConfiguration()
                    } catch { self.session.commitConfiguration(); throw error }
                    for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
                        self.observers.append(NotificationCenter.default.addObserver(forName: name, object: self.session, queue: nil) { [weak self] notification in
                            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error ??
                                CaptureRecordingError(chinese: "麦克风录制被中断，录制已停止。", english: "Microphone capture was interrupted. Recording stopped.")
                            self?.queue.async { [weak self] in guard let self, !self.stopped else { return }; self.onFailure(error) }
                        })
                    }
                    self.session.startRunning()
                    guard self.session.isRunning else {
                        throw CaptureRecordingError(chinese: "麦克风无法开始录制，请检查设备或关闭麦克风重试。", english: "The microphone could not start. Check the device or retry without microphone audio.")
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func stop() async {
        await withCheckedContinuation { continuation in queue.async {
            self.stopped = true
            self.output.setSampleBufferDelegate(nil, queue: nil)
            if self.session.isRunning { self.session.stopRunning() }
            self.observers.forEach { NotificationCenter.default.removeObserver($0) }; self.observers.removeAll()
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }
            self.session.commitConfiguration()
            // Flush any microphone callback already delivered before allowing writer finalization.
            self.writer.queue.async { continuation.resume() }
        } }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let clock = session.synchronizationClock,
              let hostSample = CaptureRecordingSampleTiming.converting(sampleBuffer, from: clock, to: CMClockGetHostTimeClock()) else { return }
        writer.consumeMicrophone(hostSample)
    }
}

/// A bundled encoder consumes a single RGBA frame at a time. Cancellation terminates it and drains exit.
private final class RecordingWebPEncoder: @unchecked Sendable {
    private let process = Process(), input = Pipe(), errors = Pipe(), lock = NSLock()
    private var cancelled = false
    init(helper: URL, destination: URL, width: Int, height: Int, fps: Int, count: Int, duration: Double) {
        process.executableURL = helper
        process.arguments = [String(width), String(height), String(fps), String(count), String(Int((duration * 1000).rounded())), destination.path]
        process.standardInput = input; process.standardOutput = FileHandle.nullDevice; process.standardError = errors
    }
    func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        // A terminated child must produce an ordinary write error, never SIGPIPE in the app.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw CaptureRecordingError(chinese: "无法建立 WebP 编码通道。", english: "Unable to create the WebP encoder channel.")
        }
        try process.run()
        try? input.fileHandleForReading.close()
        try? errors.fileHandleForWriting.close()
    }
    func append(_ image: CGImage) throws {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue), let pixels = context.data else {
            throw CaptureRecordingError(chinese: "无法读取 WebP 动画帧。", english: "Unable to read a WebP animation frame.")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        try input.fileHandleForWriting.write(contentsOf: Data(bytes: pixels, count: image.width * image.height * 4))
    }
    func finish() async throws {
        try? input.fileHandleForWriting.close()
        await drain()
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            let detail = (try? errors.fileHandleForReading.readToEnd()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw CaptureRecordingError(chinese: "WebP 编码失败，请缩短片段后重试。\n" + String(detail.prefix(400)),
                english: "WebP encoding failed. Try a shorter clip.\n" + String(detail.prefix(400)))
        }
    }
    func drain() async {
        await withCheckedContinuation { continuation in DispatchQueue.global(qos: .userInitiated).async {
            if self.process.processIdentifier != 0 { self.process.waitUntilExit() }
            continuation.resume()
        } }
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if process.isRunning { process.terminate() }
    }
    deinit { try? input.fileHandleForWriting.close(); try? errors.fileHandleForReading.close() }
}

@MainActor
private final class CaptureRecordingSource: NSObject, SCStreamDelegate {
    let writer: CaptureRecordingWriter
    let width: Int
    let height: Int
    private var stream: SCStream!
    private var startTask: Task<Void, Error>?
    private var stopping = false
    private var started = false
    private var microphone: CaptureRecordingMicrophone?
    var onFailure: ((Error) -> Void)?

    static func prepare(region: CGRect, options: CaptureRecordingOptions, url: URL) async throws -> CaptureRecordingSource {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.frame.contains(region) }) else {
            throw CaptureRecordingError(chinese: "录屏选区跨越显示器或显示器已断开，请重新框选。", english: "The region crosses displays or its display disconnected. Select it again.")
        }
        let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
        let target = try CaptureRecordingRegion.resolve(region, displayID: display.displayID, displayFrame: display.frame, scale: CGFloat(filter.pointPixelScale))
        let config = SCStreamConfiguration()
        config.sourceRect = target.sourceRect
        config.width = target.width; config.height = target.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.framesPerSecond))
        config.queueDepth = 4
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = options.showsCursor
        config.capturesAudio = options.systemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000; config.channelCount = 2
        if #available(macOS 15.0, *) { config.captureMicrophone = options.microphone }
        let writer = try CaptureRecordingWriter(url: url, width: target.width, height: target.height,
            framesPerSecond: options.framesPerSecond, systemAudio: options.systemAudio, microphone: options.microphone)
        let source = CaptureRecordingSource(writer: writer, width: target.width, height: target.height)
        if #unavailable(macOS 15.0), options.microphone {
            source.microphone = CaptureRecordingMicrophone(writer: writer) { [weak source] error in
                Task { @MainActor in guard let source, !source.stopping else { return }; source.onFailure?(error) }
            }
        }
        source.stream = SCStream(filter: filter, configuration: config, delegate: source)
        do {
            try source.stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
            if options.systemAudio { try source.stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue) }
            if #available(macOS 15.0, *), options.microphone {
                try source.stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue)
            }
        } catch {
            await writer.cancel()
            throw error
        }
        return source
    }
    private init(writer: CaptureRecordingWriter, width: Int, height: Int) { self.writer = writer; self.width = width; self.height = height }
    func start() async throws {
        guard !stopping else { throw CancellationError() }
        try await microphone?.start()
        guard !stopping else { throw CancellationError() }
        let task = Task { try await self.stream.startCapture() }
        startTask = task
        do { try await task.value; started = true; startTask = nil }
        catch { startTask = nil; throw error }
        if stopping { try? await stream.stopCapture(); started = false; throw CancellationError() }
    }
    func stop() async {
        stopping = true
        _ = await startTask?.result
        await microphone?.stop()
        if started { try? await stream.stopCapture(); started = false }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in if !self.stopping { self.onFailure?(error) } }
    }
}

/// Exports one frame at a time. No array of decoded recording frames is retained.
enum CaptureRecordingExporter {
    static var bundledWebPHelper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/XclipWebP") }
    static func export(source: URL, destination: URL, format: CaptureRecordingFormat,
                       start: Double, end: Double, gifFPS: Int = 16,
                       webpHelper: URL? = nil,
                       progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard !FileManager.default.fileExists(atPath: destination.path), source.standardizedFileURL != destination.standardizedFileURL else {
            throw CaptureRecordingError(chinese: "导出目标已存在，请使用新的临时文件。", english: "The export destination already exists. Use a new temporary file.")
        }
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        let minimumDuration = min(0.05, duration)
        guard duration.isFinite, duration > 0, start.isFinite, end.isFinite, start >= 0,
              end <= duration + 0.001, end - start >= minimumDuration - 0.0001 else {
            throw CaptureRecordingError(chinese: "请选择有效的剪辑起点和终点。", english: "Choose valid trim start and end points.")
        }
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: min(end, duration) - start, preferredTimescale: 600))
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: destination) } }
        if format == .mp4 {
            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality),
                  exporter.supportedFileTypes.contains(.mp4) else {
                throw CaptureRecordingError(chinese: "当前录制无法导出为 MP4。", english: "This recording cannot be exported as MP4.")
            }
            exporter.outputURL = destination; exporter.outputFileType = .mp4
            exporter.timeRange = range; exporter.shouldOptimizeForNetworkUse = true
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if audioTracks.count > 1 {
                let mix = AVMutableAudioMix()
                mix.inputParameters = audioTracks.map { track in let input = AVMutableAudioMixInputParameters(track: track); input.setVolume(1, at: .zero); return input }
                exporter.audioMix = mix
            }
            let progressTask = Task {
                while !Task.isCancelled { progress(Double(exporter.progress)); try? await Task.sleep(nanoseconds: 150_000_000) }
            }
            defer { progressTask.cancel() }
            let cancellation = RecordingExportCancellation(session: exporter)
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                await exporter.export()
                try Task.checkCancellation()
                guard exporter.status == .completed else { throw exporter.error ?? CaptureRecordingError(chinese: "MP4 导出失败，请选择其他位置重试。", english: "MP4 export failed. Try another destination.") }
            } onCancel: { cancellation.session.cancelExport() }
        } else {
            guard [5, 10, 16, 24, 30].contains(gifFPS) else { throw CaptureRecordingError(chinese: "动图帧率无效。", english: "Invalid animation frame rate.") }
            let frameCount = Int(ceil(range.duration.seconds * Double(gifFPS)))
            guard frameCount <= 1_800 else {
                throw CaptureRecordingError(chinese: "动图最多导出 1800 帧，请缩短剪辑范围或降低帧率；长视频可保存为 MP4。", english: "Animation export is limited to 1,800 frames. Trim the clip or lower FPS; save longer recordings as MP4.")
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 960, height: 960)
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            if format == .webp {
                let helper = webpHelper ?? bundledWebPHelper
                guard FileManager.default.isExecutableFile(atPath: helper.path) else {
                    throw CaptureRecordingError(chinese: "当前应用缺少 WebP 编码组件，请重新安装完整构建。", english: "The WebP encoder is missing. Reinstall a complete build.")
                }
                try Task.checkCancellation()
                let first = try await generator.image(at: range.start).image
                let encoder = RecordingWebPEncoder(helper: helper, destination: destination, width: first.width, height: first.height,
                    fps: gifFPS, count: frameCount, duration: range.duration.seconds)
                do {
                    try await withTaskCancellationHandler {
                        try encoder.start()
                        for index in 0..<frameCount {
                            try Task.checkCancellation()
                            let frame = index == 0 ? first : try await generator.image(at: CMTime(seconds: start + Double(index) / Double(gifFPS), preferredTimescale: 60_000)).image
                            try autoreleasepool { try encoder.append(frame) }
                            progress(Double(index + 1) / Double(frameCount) * 0.95)
                        }
                        try await encoder.finish()
                    } onCancel: { generator.cancelAllCGImageGeneration(); encoder.cancel() }
                } catch {
                    encoder.cancel(); await encoder.drain()
                    try Task.checkCancellation()
                    throw error
                }
            } else {
            guard let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
                throw CaptureRecordingError(chinese: "无法创建 GIF 文件，请检查保存位置。", english: "Unable to create a GIF at that location.")
            }
            CGImageDestinationSetProperties(output, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            try await withTaskCancellationHandler {
                for index in 0..<frameCount {
                    try Task.checkCancellation()
                    let seconds = start + Double(index) / Double(gifFPS)
                    let frame = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 60_000)).image
                    let delay = min(1 / Double(gifFPS), range.end.seconds - seconds)
                    autoreleasepool {
                        CGImageDestinationAddImage(output, frame, [kCGImagePropertyGIFDictionary:
                            [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
                    }
                    progress(Double(index + 1) / Double(frameCount))
                }
                try Task.checkCancellation()
                guard CGImageDestinationFinalize(output) else { throw CaptureRecordingError(chinese: "GIF 编码失败，请缩短范围后重试。", english: "GIF encoding failed. Try a shorter clip.") }
            } onCancel: { generator.cancelAllCGImageGeneration() }
            }
        }
        succeeded = true; progress(1)
    }
}

@MainActor
final class CaptureRecordingController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = CaptureRecordingController()
    enum Phase: Equatable { case closed, ready, countdown(Int), starting, recording, paused, finishing, preview, exporting, closing }
    @Published private(set) var phase: Phase = .closed
    @Published var fps = 30
    @Published var delay = 0
    @Published var showsCursor = true
    @Published var systemAudio = false
    @Published var microphone = false
    @Published private(set) var elapsed = 0.0
    @Published private(set) var message = ""
    @Published private(set) var progress = 0.0
    @Published private(set) var duration = 0.0
    @Published var trimStart = 0.0
    @Published var trimEnd = 0.0
    @Published var format: CaptureRecordingFormat = .mp4
    @Published var gifFPS = 16
    @Published private(set) var player: AVPlayer?
    private var region = CGRect.zero
    private var control: NSPanel?
    private var border: NSPanel?
    private var playback: NSWindow?
    private var activeSavePanel: NSSavePanel?
    private var source: CaptureRecordingSource?
    private var recordingURL: URL?
    private var directory: URL?
    private var task: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var generation = UUID()
    private var observers = [NSObjectProtocol]()
    private var clock: Timer?
    private var activeSince: Date?
    private var accumulated = 0.0
    private var exported = false
    var isActive: Bool { phase != .closed }
    var canConfigure: Bool { phase == .ready }
    var minimumTrimDuration: Double { min(0.05, max(0.001, duration)) }
    var microphoneSupported: Bool { true }
    var statusText: String {
        switch phase {
        case .ready: return recordingText("准备录制", "Ready")
        case .countdown(let seconds): return recordingText("倒计时", "Starting in") + " \(seconds)"
        case .starting: return recordingText("正在连接屏幕…", "Connecting to screen…")
        case .recording: return recordingText("录制中", "Recording")
        case .paused: return recordingText("已暂停", "Paused")
        case .finishing: return recordingText("正在完成录制…", "Finishing…")
        case .exporting: return recordingText("正在导出…", "Exporting…")
        default: return ""
        }
    }

    func start(region: CGRect) {
        guard !isActive else {
            guard phase != .closing else { return }
            let window = phase == .preview || phase == .exporting ? playback : control
            reveal(window)
            return
        }
        guard region.minX.isFinite, region.minY.isFinite, region.width.isFinite, region.height.isFinite, region.width >= 2, region.height >= 2 else { return }
        self.region = region; generation = UUID(); elapsed = 0; message = ""; phase = .ready; exported = false
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.interrupted(recordingText("显示器设置已变化，录制已停止。", "Display settings changed. Recording stopped.")) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        })
        showControls()
    }
    func toggleRecording() {
        switch phase {
        case .ready: begin()
        case .recording, .paused: stop()
        default: break
        }
    }
    func pauseOrResume() {
        if phase == .recording {
            accumulated = elapsed; activeSince = nil; source?.writer.setPaused(true); phase = .paused
        } else if phase == .paused {
            activeSince = Date(); source?.writer.setPaused(false); phase = .recording
        }
        refreshBorder()
    }
    private func begin() {
        guard phase == .ready else { return }
        message = ""; phase = .starting
        let token = generation
        let options = CaptureRecordingOptions(framesPerSecond: fps, delay: delay, showsCursor: showsCursor, systemAudio: systemAudio, microphone: microphone && microphoneSupported)
        task = Task { @MainActor in
            do {
                if !CGPreflightScreenCaptureAccess() {
                    _ = CGRequestScreenCaptureAccess()
                    guard CGPreflightScreenCaptureAccess() else { throw CaptureRecordingError(chinese: "屏幕录制权限尚未生效，请在系统设置允许当前 Xclip 并完全退出后重启。", english: "Screen Recording access is unavailable. Allow this Xclip in System Settings, fully quit, then reopen it.") }
                }
                if options.microphone {
                    guard let usage = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String, !usage.isEmpty else {
                        throw CaptureRecordingError(chinese: "当前构建缺少麦克风用途说明；请关闭麦克风或更新应用后重试。", english: "This build lacks a microphone usage description. Disable the microphone or update the app.")
                    }
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    var allowed = status == .authorized
                    if status == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for: .audio) }
                    guard allowed else { throw CaptureRecordingError(chinese: "麦克风未获授权，可在系统设置开启，或关闭麦克风继续录屏。", english: "Microphone access was denied. Enable it in System Settings or record without a microphone.") }
                }
                for remaining in stride(from: options.delay, to: 0, by: -1) {
                    try Task.checkCancellation(); guard self.generation == token else { return }
                    self.phase = .countdown(remaining)
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                try Task.checkCancellation(); guard self.generation == token else { return }
                self.phase = .starting
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("xclip-recording-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                self.directory = folder
                let live = try await CaptureRecordingSource.prepare(region: self.region, options: options, url: folder.appendingPathComponent("recording.mov"))
                guard self.generation == token, !Task.isCancelled else { await live.writer.cancel(); return }
                self.source = live
                live.onFailure = { [weak self] error in self?.interrupted(error.localizedDescription) }
                live.writer.onFailure = { [weak self] error in Task { @MainActor in if self?.generation == token { self?.interrupted(error.localizedDescription) } } }
                try await live.start()
                try Task.checkCancellation(); guard self.generation == token else { return }
                self.phase = .recording; self.elapsed = 0; self.accumulated = 0; self.activeSince = Date()
                self.clock?.invalidate()
                self.clock = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
                self.refreshBorder(); self.task = nil
            } catch {
                guard self.generation == token else { return }
                await self.source?.stop(); await self.source?.writer.cancel(); self.source = nil
                self.message = error.localizedDescription; self.phase = .ready; self.task = nil
                if let directory = self.directory { try? FileManager.default.removeItem(at: directory); self.directory = nil }
                self.refreshBorder()
            }
        }
    }
    private func tick() {
        if phase == .recording, let activeSince { elapsed = accumulated + Date().timeIntervalSince(activeSince) }
        if elapsed >= 1_800 { interrupted(recordingText("已达到 30 分钟上限，录制已停止。", "The 30-minute recording limit was reached.")); return }
        if let url = source?.writer.url,
           let values = try? url.resourceValues(forKeys: [.fileSizeKey, .volumeAvailableCapacityForImportantUsageKey]),
           (values.fileSize ?? 0) > 2_000_000_000 || (values.volumeAvailableCapacityForImportantUsage ?? Int64.max) < 100_000_000 {
            interrupted(recordingText("录制文件达到限制或磁盘空间不足，已停止录制。", "Recording stopped because the file limit was reached or disk space is low."))
        }
    }
    func stop() {
        guard phase == .recording || phase == .paused, let live = source else { return }
        let token = generation, stopTime = CMClockGetTime(CMClockGetHostTimeClock())
        phase = .finishing; clock?.invalidate(); clock = nil; activeSince = nil; refreshBorder()
        task = Task { @MainActor in
            do {
                await live.stop()
                let url = try await live.writer.finish(at: stopTime)
                let duration = try await AVURLAsset(url: url).load(.duration).seconds
                try Task.checkCancellation(); guard self.generation == token else { return }
                self.source = nil; self.recordingURL = url; self.duration = duration
                self.trimStart = 0; self.trimEnd = duration; self.phase = .preview; self.task = nil
                self.control?.orderOut(nil); self.border?.orderOut(nil); self.showPlayback(url)
            } catch {
                guard self.generation == token else { return }
                await live.writer.cancel(); self.source = nil
                self.message = error.localizedDescription; self.phase = .ready; self.task = nil; self.refreshBorder()
                if let directory = self.directory { try? FileManager.default.removeItem(at: directory); self.directory = nil }
            }
        }
    }
    private func interrupted(_ message: String) {
        self.message = message
        if phase == .recording || phase == .paused { stop() }
        else if phase == .ready || { if case .countdown = phase { return true }; return false }() || phase == .starting { cancel() }
    }
    func cancel() {
        guard phase != .closed, phase != .closing else { return }
        generation = UUID(); let token = generation
        let pending = task, live = source, folder = directory
        pending?.cancel(); activeSavePanel?.cancel(nil)
        source = nil; task = nil; phase = .closing
        clock?.invalidate(); clock = nil; player?.pause(); player = nil
        control?.orderOut(nil); control?.contentView = nil; control = nil
        border?.orderOut(nil); border = nil
        playback?.orderOut(nil); playback?.contentView = nil; playback = nil
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers.removeAll()
        cleanupTask = Task { @MainActor in
            await live?.stop(); await live?.writer.cancel(); await pending?.value
            if let folder { try? FileManager.default.removeItem(at: folder) }
            guard self.generation == token else { return }
            self.directory = nil; self.recordingURL = nil; self.phase = .closed; self.cleanupTask = nil
        }
    }
    func waitUntilFinished() async { await task?.value; await cleanupTask?.value }
    func requestClose() {
        if [.recording, .paused, .finishing, .preview, .exporting].contains(phase), !exported {
            let alert = NSAlert(); alert.messageText = recordingText("放弃这次录制？", "Discard this recording?")
            alert.informativeText = recordingText("尚未保存的录制内容会被删除。", "Unsaved recording content will be deleted.")
            alert.addButton(withTitle: recordingText("继续编辑", "Keep editing")); alert.addButton(withTitle: recordingText("放弃录制", "Discard"))
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        cancel()
    }
    func recordAgain() {
        guard phase == .preview else { return }
        if !exported {
            let alert = NSAlert(); alert.messageText = recordingText("重新录制？", "Record again?")
            alert.informativeText = recordingText("当前尚未保存的录制将被删除。", "The current unsaved recording will be deleted.")
            alert.addButton(withTitle: recordingText("取消", "Cancel")); alert.addButton(withTitle: recordingText("重新录制", "Record again"))
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        player?.pause(); player = nil; playback?.orderOut(nil)
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil; recordingURL = nil; elapsed = 0; message = ""; exported = false; phase = .ready
        control?.orderFrontRegardless(); border?.orderFrontRegardless(); refreshBorder()
    }
    func save() {
        guard phase == .preview, let recordingURL, let directory else { return }
        let panel = NSSavePanel(); activeSavePanel = panel
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "Xclip-\(Int(Date().timeIntervalSince1970)).\(format.fileExtension)"
        panel.title = recordingText("保存录屏", "Save recording")
        let response = panel.runModal(); activeSavePanel = nil
        guard response == .OK, let destination = panel.url, phase == .preview else { return }
        let token = generation, chosenFormat = format, start = trimStart, end = trimEnd, fps = gifFPS
        phase = .exporting; progress = 0; message = ""; player?.pause()
        let output = directory.appendingPathComponent("export-\(UUID().uuidString).\(chosenFormat.fileExtension)")
        task = Task { @MainActor in
            defer { try? FileManager.default.removeItem(at: output) }
            do {
                try await CaptureRecordingExporter.export(source: recordingURL, destination: output, format: chosenFormat,
                    start: start, end: end, gifFPS: fps) { [weak self] progress in Task { @MainActor in if self?.generation == token { self?.progress = progress } } }
                try Task.checkCancellation(); guard self.generation == token else { return }
                let access = destination.startAccessingSecurityScopedResource()
                defer { if access { destination.stopAccessingSecurityScopedResource() } }
                let staging = destination.deletingLastPathComponent().appendingPathComponent(".xclip-export-\(UUID().uuidString).\(chosenFormat.fileExtension)")
                defer { try? FileManager.default.removeItem(at: staging); try? FileManager.default.removeItem(at: output) }
                try FileManager.default.copyItem(at: output, to: staging)
                if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging) }
                else { try FileManager.default.moveItem(at: staging, to: destination) }
                self.exported = true; self.message = recordingText("已保存：", "Saved: ") + destination.path
                self.phase = .preview; self.task = nil
            } catch {
                guard self.generation == token else { return }
                self.message = error is CancellationError ? recordingText("已取消导出，可以继续编辑。", "Export cancelled. You can continue editing.") : error.localizedDescription
                self.phase = .preview; self.task = nil
            }
        }
    }
    func cancelExport() { if phase == .exporting { task?.cancel() } }
    func updatePlaybackRange() {
        player?.currentItem?.forwardPlaybackEndTime = CMTime(seconds: trimEnd, preferredTimescale: 600)
        player?.currentItem?.reversePlaybackEndTime = CMTime(seconds: trimStart, preferredTimescale: 600)
    }
    func previewSelection() {
        guard phase == .preview else { return }
        updatePlaybackRange()
        player?.seek(to: CMTime(seconds: trimStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player?.play()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { requestClose(); return false }

    private func appKitRegion() -> CGRect {
        let main = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID() }
        return CGRect(x: region.minX, y: (main?.frame.maxY ?? 0) - region.maxY, width: region.width, height: region.height)
    }
    private func reveal(_ window: NSWindow?) {
        guard let window else { return }
        if NSApp.isHidden {
            // Cmd+H hid the whole app. Reveal only this workflow, leaving Settings and other windows out of the way.
            NSApp.windows.filter { $0 !== control && $0 !== border && $0 !== playback }.forEach { $0.orderOut(nil) }
        }
        NSApp.unhideWithoutActivation()
        if window === control { border?.orderFrontRegardless() }
        window.makeKeyAndOrderFront(nil)
    }
    private func showControls() {
        let selection = appKitRegion()
        let outline = NSPanel(contentRect: selection.insetBy(dx: -3, dy: -3), styleMask: [.borderless], backing: .buffered, defer: false)
        outline.isOpaque = false; outline.backgroundColor = .clear; outline.hasShadow = false
        outline.level = .floating; outline.ignoresMouseEvents = true; outline.sharingType = .none
        outline.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        outline.contentView = CaptureRecordingOutline(frame: CGRect(origin: .zero, size: outline.frame.size))
        border = outline
        let size = CGSize(width: 650, height: 138)
        let screen = NSScreen.screens.first { $0.frame.intersects(selection) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? selection
        let below = CGRect(x: selection.minX, y: selection.minY - size.height - 12, width: size.width, height: size.height)
        let above = CGRect(x: selection.minX, y: selection.maxY + 12, width: size.width, height: size.height)
        var frame = bounds.contains(below) ? below : bounds.contains(above) ? above : CGRect(x: bounds.minX + 12, y: bounds.minY + 12, width: size.width, height: size.height)
        frame.origin.x = max(bounds.minX, min(frame.minX, bounds.maxX - frame.width))
        let panel = CaptureRecordingPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = recordingText("Xclip 录屏", "Xclip Recording")
        panel.identifier = NSUserInterfaceItemIdentifier("capture-recording-controls")
        panel.isExcludedFromWindowsMenu = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.level = .floating
        panel.hidesOnDeactivate = false; panel.isMovableByWindowBackground = true; panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: CaptureRecordingControls(controller: self))
        control = panel
        // ScreenshotSession restores the former app/window before handing off. The recorder owns the next key window.
        reveal(panel)
    }
    private func refreshBorder() {
        let outline = border?.contentView as? CaptureRecordingOutline
        outline?.color = phase == .recording ? .systemRed : phase == .paused ? .systemOrange : .systemBlue
        outline?.needsDisplay = true
    }
    private func showPlayback(_ url: URL) {
        player = AVPlayer(url: url)
        let window = playback ?? NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 650), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = recordingText("Xclip 录屏回放", "Xclip Recording Playback"); window.delegate = self
        window.isReleasedWhenClosed = false; window.minSize = CGSize(width: 640, height: 580)
        window.contentView = NSHostingView(rootView: CaptureRecordingPlayback(controller: self))
        window.center(); playback = window; reveal(window); NSApp.activate(ignoringOtherApps: true)
        player?.play()
    }
}

private final class CaptureRecordingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
private final class CaptureRecordingOutline: NSView {
    var color = NSColor.systemBlue
    override func draw(_ dirtyRect: NSRect) { color.setStroke(); let line = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5)); line.lineWidth = 2; line.stroke() }
}

private struct CaptureRecordingControls: View {
    @ObservedObject var controller: CaptureRecordingController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Label(controller.statusText, systemImage: controller.phase == .recording ? "record.circle.fill" : "video")
                    .foregroundStyle(controller.phase == .recording ? Color.red : Color.primary)
                Text(Self.time(controller.elapsed)).monospacedDigit().font(.title3)
                Spacer()
                if controller.phase == .recording || controller.phase == .paused {
                    Button { controller.pauseOrResume() } label: { Label(controller.phase == .paused ? recordingText("继续", "Resume") : recordingText("暂停", "Pause"), systemImage: controller.phase == .paused ? "play.fill" : "pause.fill") }
                }
                Button { controller.toggleRecording() } label: {
                    Label(controller.phase == .ready ? recordingText("开始录制", "Record") : recordingText("结束", "Stop"), systemImage: controller.phase == .ready ? "record.circle" : "stop.fill")
                }.buttonStyle(.borderedProminent).tint(.red).disabled(![.ready, .recording, .paused].contains(controller.phase))
                Button { controller.requestClose() } label: { Image(systemName: "xmark") }.help(recordingText("关闭录屏", "Close recording"))
            }
            HStack(spacing: 12) {
                Picker("FPS", selection: $controller.fps) { ForEach([5,16,24,30,60], id: \.self) { Text("\($0)").tag($0) } }.frame(width: 100)
                Picker(recordingText("延迟", "Delay"), selection: $controller.delay) { ForEach([0,1,2,3,5,10], id: \.self) { Text("\($0)s").tag($0) } }.frame(width: 112)
                Toggle(recordingText("光标", "Cursor"), isOn: $controller.showsCursor)
                Toggle(recordingText("系统声音", "System audio"), isOn: $controller.systemAudio)
                Toggle(recordingText("麦克风", "Microphone"), isOn: $controller.microphone).disabled(!controller.microphoneSupported)
                    .help(recordingText("仅开启后请求麦克风权限", "Microphone access is requested only when enabled"))
            }.disabled(!controller.canConfigure).font(.callout)
            if controller.message.isEmpty {
                Text(recordingText("选区中的真实屏幕会持续录制；Xclip 控制窗口不会录入。截屏快捷键可开始或结束录制。", "Records live content in the region and excludes Xclip windows. Use the screenshot shortcut to start or stop."))
                    .font(.caption).foregroundStyle(.secondary)
            } else { Text(controller.message).font(.caption).foregroundStyle(.orange).lineLimit(2) }
        }.padding(12).background(Color.white, in: RoundedRectangle(cornerRadius: 9))
            .overlay(alignment: .topTrailing) {
                if controller.phase == .starting || controller.phase == .finishing { ProgressView().controlSize(.small).padding(12) }
            }.preferredColorScheme(.light)
    }
    static func time(_ seconds: Double) -> String { String(format: "%02d:%02d", Int(max(0, seconds)) / 60, Int(max(0, seconds)) % 60) }
}

private struct CaptureRecordingPlayback: View {
    @ObservedObject var controller: CaptureRecordingController
    var body: some View {
        VStack(spacing: 16) {
            if let player = controller.player { VideoPlayer(player: player).frame(minHeight: 260) }
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text(recordingText("保留片段", "Keep segment")).font(.headline); Spacer()
                    Button(recordingText("预览片段", "Preview segment")) { controller.previewSelection() }
                }
                HStack { Text(recordingText("起点", "Start")).frame(width: 45); Slider(value: $controller.trimStart, in: 0...max(0, controller.trimEnd - controller.minimumTrimDuration)); Text(String(format: "%.2fs", controller.trimStart)).monospacedDigit().frame(width: 65) }
                HStack { Text(recordingText("终点", "End")).frame(width: 45); Slider(value: $controller.trimEnd, in: min(controller.duration, controller.trimStart + controller.minimumTrimDuration)...max(0.001, controller.duration)); Text(String(format: "%.2fs", controller.trimEnd)).monospacedDigit().frame(width: 65) }
                HStack {
                    Picker(recordingText("格式", "Format"), selection: $controller.format) { ForEach(CaptureRecordingFormat.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(width: 215)
                    if controller.format != .mp4 {
                        Picker("FPS", selection: $controller.gifFPS) { ForEach([5,10,16,24,30], id: \.self) { Text("\($0)").tag($0) } }.frame(width: 100)
                        Text(recordingText("动图无声音，最长边 960 像素", "Animations are silent; longest edge 960 px")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }.disabled(controller.phase == .exporting)
            if controller.phase == .exporting {
                HStack { ProgressView(value: controller.progress); Text("\(Int(controller.progress * 100))%").monospacedDigit(); Button(recordingText("取消导出", "Cancel export")) { controller.cancelExport() } }
            }
            if !controller.message.isEmpty { Text(controller.message).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
            HStack {
                Button(recordingText("重新录制", "Record again")) { controller.recordAgain() }.disabled(controller.phase == .exporting)
                Spacer()
                Button(recordingText("关闭", "Close")) { controller.requestClose() }
                Button(recordingText("保存…", "Save…")) { controller.save() }.buttonStyle(.borderedProminent).disabled(controller.phase != .preview || controller.trimEnd - controller.trimStart < controller.minimumTrimDuration - 0.0001)
            }
        }.padding(20).onChange(of: controller.trimStart) { _, value in controller.updatePlaybackRange(); controller.player?.seek(to: CMTime(seconds: value, preferredTimescale: 600)) }
            .onChange(of: controller.trimEnd) { _, _ in controller.updatePlaybackRange() }
    }
}
