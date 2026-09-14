import AppKit
import SwiftUI
import ImageIO

/// Only downsampled pixels enter this cache. Original clipboard/export bytes never do.
final class ClipboardThumbnailCache: @unchecked Sendable {
    static let shared = ClipboardThumbnailCache()
    static let didClear = Notification.Name("XclipThumbnailCacheCleared")
    struct Statistics { let bytes: Int; let count: Int; let pending: Int }
    private struct Entry { let image: CGImage; let cost: Int; var access: UInt64 }
    private final class Job {
        let id = UUID()
        var callbacks: [UUID: (CGImage?) -> Void] = [:]
        var operation: Operation?
    }
    private let lock = NSLock()
    private let queue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "Xclip.thumbnail"; queue.maxConcurrentOperationCount = 2; queue.qualityOfService = .userInitiated
        return queue
    }()
    private var entries: [String: Entry] = [:]
    private var jobs: [String: Job] = [:]
    private var clock: UInt64 = 0
    private var bytes = 0
    let budget: Int
    private var pressure: DispatchSourceMemoryPressure?
    init(budget: Int = 64 * 1024 * 1024) {
        self.budget = max(0, budget)
        pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure?.setEventHandler { [weak self] in self?.clear() }
        pressure?.resume()
    }
    deinit { pressure?.cancel() }
    var statistics: Statistics { lock.lock(); defer { lock.unlock() }; return .init(bytes: bytes, count: entries.count, pending: jobs.count) }
    static func key(for item: ClipboardItem, pixels: Int) -> String {
        let source: String
        if let data = item.data { source = ClipboardBlobReference.digest(data) }
        else if let path = item.filePath {
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            source = path + ":\(values?.fileSize ?? 0):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        } else { source = item.id.uuidString }
        return source + ":\(pixels)"
    }
    func request(item: ClipboardItem, pixels: Int, completion: @escaping (CGImage?) -> Void) -> (String, UUID) {
        let pixels = max(64, min(1024, pixels)), key = Self.key(for: item, pixels: max(64, min(1024, pixels)))
        let ticket = UUID()
        lock.lock()
        clock &+= 1
        if var entry = entries[key] {
            entry.access = clock; entries[key] = entry; lock.unlock()
            DispatchQueue.main.async { completion(entry.image) }; return (key, ticket)
        }
        if let job = jobs[key] { job.callbacks[ticket] = completion; lock.unlock(); return (key, ticket) }
        let job = Job(); job.callbacks[ticket] = completion; jobs[key] = job
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation, weak job] in
            guard let self, let operation, !operation.isCancelled, let job else { return }
            let image = autoreleasepool { Self.decode(item: item, pixels: pixels) }
            self.lock.lock()
            guard self.jobs[key]?.id == job.id else { self.lock.unlock(); return }
            let callbacks = Array(job.callbacks.values)
            self.jobs.removeValue(forKey: key)
            if !operation.isCancelled, let image, !callbacks.isEmpty { self.insert(image, key: key) }
            self.lock.unlock()
            if !operation.isCancelled { DispatchQueue.main.async { callbacks.forEach { $0(image) } } }
        }
        job.operation = operation; lock.unlock(); queue.addOperation(operation)
        return (key, ticket)
    }
    func cancel(_ ticket: (String, UUID)) {
        lock.lock(); defer { lock.unlock() }
        guard let job = jobs[ticket.0] else { return }
        job.callbacks.removeValue(forKey: ticket.1)
        if job.callbacks.isEmpty { job.operation?.cancel(); jobs.removeValue(forKey: ticket.0) }
    }
    private func insert(_ image: CGImage, key: String) {
        let cost = image.bytesPerRow * image.height
        guard cost <= budget else { return }
        if let previous = entries.removeValue(forKey: key) { bytes -= previous.cost }
        while bytes + cost > budget, let oldest = entries.min(by: { $0.value.access < $1.value.access }) {
            bytes -= oldest.value.cost; entries.removeValue(forKey: oldest.key)
        }
        clock &+= 1; entries[key] = Entry(image: image, cost: cost, access: clock); bytes += cost
    }
    func clear() {
        lock.lock(); entries.removeAll(); bytes = 0
        let pending = jobs.values.flatMap { Array($0.callbacks.values) }
        jobs.values.forEach { $0.operation?.cancel() }; jobs.removeAll(); lock.unlock()
        DispatchQueue.main.async {
            pending.forEach { $0(nil) }
            NotificationCenter.default.post(name: Self.didClear, object: nil)
        }
    }
    static func decode(item: ClipboardItem, pixels: Int) -> CGImage? {
        let source: CGImageSource?
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        if let data = item.data { source = CGImageSourceCreateWithData(data as CFData, options) }
        else if let path = item.filePath { source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, options) }
        else { return nil }
        guard let source,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 100_000, height <= 100_000, Double(width) * Double(height) <= 200_000_000 else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, min(1024, pixels))
        ] as CFDictionary)
    }
}

@MainActor
private final class ClipboardThumbnailModel: ObservableObject {
    @Published var image: NSImage?
    @Published var failed = false
    private var ticket: (String, UUID)?
    private var generation = 0
    func load(_ item: ClipboardItem, pixels: Int) {
        cancel(); failed = false
        let token = generation
        ticket = ClipboardThumbnailCache.shared.request(item: item, pixels: pixels) { [weak self] image in
            guard let self, self.generation == token else { return }
            self.image = image.map { NSImage(cgImage: $0, size: .zero) }; self.failed = image == nil
        }
    }
    func cancel() {
        generation += 1
        if let ticket { ClipboardThumbnailCache.shared.cancel(ticket) }
        ticket = nil; image = nil
    }
    deinit { if let ticket { ClipboardThumbnailCache.shared.cancel(ticket) } }
}

struct ClipboardThumbnail: View {
    let item: ClipboardItem
    var fill = false
    @Environment(\.displayScale) private var scale
    @StateObject private var model = ClipboardThumbnailModel()
    var body: some View {
        GeometryReader { geometry in
            let pixels = min(1024, max(64, Int(ceil(max(geometry.size.width, geometry.size.height) * scale / 64)) * 64))
            let key = ClipboardThumbnailCache.key(for: item, pixels: pixels)
            Group {
                if let image = model.image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
                } else if model.failed {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                } else { ProgressView().controlSize(.small) }
            }
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
            .onAppear { model.load(item, pixels: pixels) }
            .onChange(of: key) { _, _ in model.load(item, pixels: pixels) }
            .onDisappear { model.cancel() }
            .accessibilityLabel(AppLanguage.text("图片预览", "Image preview"))
        }
    }
}
