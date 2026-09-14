import Foundation
import CryptoKit

enum ClipboardItemType: String, Codable {
    case text = "text"
    case image = "image"
    case file = "file"
    case video = "video"
    case audio = "audio"
    case document = "document"
    case code = "code"
    case archive = "archive"
    case executable = "executable"
}

extension ClipboardItemType {
    var icon: String {
        switch self {
        case .text:
            return "doc.text"
        case .image:
            return "photo"
        case .file:
            return "doc"
        case .video:
            return "video"
        case .audio:
            return "music.note"
        case .document:
            return "doc.text"
        case .code:
            return "chevron.left.forwardslash.chevron.right"
        case .archive:
            return "archivebox"
        case .executable:
            return "app"
        }
    }
    
    var displayName: String {
        switch self {
        case .text:
            return AppLanguage.text("文本", "Text")
        case .image:
            return AppLanguage.text("图片", "Image")
        case .file:
            return AppLanguage.text("文件", "File")
        case .video:
            return AppLanguage.text("视频", "Video")
        case .audio:
            return AppLanguage.text("音频", "Audio")
        case .document:
            return AppLanguage.text("文档", "Document")
        case .code:
            return AppLanguage.text("代码", "Code")
        case .archive:
            return AppLanguage.text("压缩包", "Archive")
        case .executable:
            return AppLanguage.text("应用程序", "Application")
        }
    }
}

struct ClipboardItem: Identifiable, Codable, Equatable {
    let id: UUID
    private var inlineContent: String
    var contentReference: ClipboardBlobReference?
    var contentCharacterCount: Int?
    /// Existing consumers keep the full-text API; previews use displayContent instead.
    var content: String {
        get { (try? fullContent()) ?? inlineContent }
        set { inlineContent = newValue; contentReference = nil; contentCharacterCount = nil }
    }
    var previewContent: String { inlineContent }
    func fullContent() throws -> String {
        guard let reference = contentReference else { return inlineContent }
        guard let text = String(data: try reference.read(), encoding: .utf8) else { throw ClipboardBlobError.corrupted }
        return text
    }
    let type: ClipboardItemType
    let timestamp: Date
    var data: Data?
    var filePath: String?
    var isFavorite: Bool
    var isPinned: Bool
    /// Application bundle identifier observed when the clipboard change was captured.
    var sourceApp: String?
    /// Capture-time display name remains readable when the application is no longer installed.
    var sourceAppName: String?
    var tags: [String]
    /// Raw pasteboard representations preserve rich text and application-specific formats.
    private var inlineRepresentations: [String: Data]?
    var representationReferences: [String: ClipboardBlobReference]?
    var representations: [String: Data]? {
        get { try? resolvedRepresentations() }
        set { inlineRepresentations = newValue; representationReferences = nil }
    }
    func resolvedRepresentations() throws -> [String: Data]? {
        guard inlineRepresentations != nil || representationReferences != nil else { return nil }
        var result = inlineRepresentations ?? [:]
        for (type, reference) in representationReferences ?? [:] { result[type] = try reference.read() }
        return result
    }
    var representationDigests: [String: String] {
        var result = representationReferences?.mapValues(\.sha256) ?? [:]
        for (key, bytes) in inlineRepresentations ?? [:] { result[key] = ClipboardBlobReference.digest(bytes) }
        return result
    }
    var contentDigest: String { contentReference?.sha256 ?? ClipboardBlobReference.digest(Data(inlineContent.utf8)) }
    func withNewIdentity() -> ClipboardItem {
        var result = ClipboardItem(id: UUID(), content: inlineContent, type: type, timestamp: timestamp,
            data: data, filePath: filePath, isFavorite: isFavorite, isPinned: isPinned, sourceApp: sourceApp,
            sourceAppName: sourceAppName, tags: tags, representations: inlineRepresentations, fileURLs: fileURLs)
        result.contentReference = contentReference; result.contentCharacterCount = contentCharacterCount
        result.representationReferences = representationReferences; result.retainAttachments()
        return result
    }
    var residentPayloadBytes: Int {
        inlineContent.utf8.count + (data?.count ?? 0) + (inlineRepresentations?.values.reduce(0) { $0 + $1.count } ?? 0)
    }
    var payloadReferences: [ClipboardBlobReference] {
        Array((representationReferences ?? [:]).values) + (contentReference.map { [$0] } ?? [])
    }
    /// Shared by copies of a record, including asynchronous operations and undo snapshots.
    private var attachmentLease: ClipboardAttachmentLease?
    mutating func retainAttachments() {
        attachmentLease = ClipboardAttachmentLease(paths: Set(payloadReferences.map(\.path) + (fileURLs ?? []) + (filePath.map { [$0] } ?? [])))
    }
    mutating func externalizePayload(write: (Data) throws -> ClipboardBlobReference) throws {
        if contentReference == nil, inlineContent.utf8.count > 16 * 1024 {
            contentCharacterCount = inlineContent.count
            contentReference = try write(Data(inlineContent.utf8))
            inlineContent = String(inlineContent.prefix(1400))
        }
        if let formats = inlineRepresentations, formats.values.reduce(0, { $0 + $1.count }) > 16 * 1024 {
            var references = representationReferences ?? [:]
            for (type, bytes) in formats { references[type] = try write(bytes) }
            representationReferences = references
            inlineRepresentations = nil
        }
        retainAttachments()
    }
    mutating func remapPayloadReferences(_ replacements: [String: String]) {
        if let reference = contentReference, let path = replacements[reference.path] { contentReference = reference.relocated(to: path) }
        representationReferences = representationReferences?.mapValues { reference in
            replacements[reference.path].map { reference.relocated(to: $0) } ?? reference
        }
        retainAttachments()
    }
    func materialized() throws -> ClipboardItem {
        var item = self
        item.content = try fullContent()
        item.representations = try resolvedRepresentations()
        return item
    }
    /// Paths to independently retained files; multiple files keep their original names.
    var fileURLs: [String]?

    init(id: UUID, content: String, type: ClipboardItemType, timestamp: Date,
         data: Data? = nil, filePath: String? = nil, isFavorite: Bool = false,
         isPinned: Bool = false, sourceApp: String? = nil, sourceAppName: String? = nil, tags: [String] = [],
         representations: [String: Data]? = nil, fileURLs: [String]? = nil) {
        self.id = id
        self.inlineContent = content
        self.type = type
        self.timestamp = timestamp
        self.data = data
        self.filePath = filePath
        self.isFavorite = isFavorite
        self.isPinned = isPinned
        self.sourceApp = sourceApp
        self.sourceAppName = sourceAppName
        self.tags = tags
        self.inlineRepresentations = representations
        self.fileURLs = fileURLs
        retainAttachments()
    }

    /// Localize the generated image label without changing stored content or clipboard bytes.
    var displayContent: String {
        type == .image && inlineContent == "Image" ? AppLanguage.text("图片", "Image") : inlineContent
    }

    enum CodingKeys: String, CodingKey {
        case id, content, type, timestamp, data, filePath, isFavorite
        case isPinned, sourceApp, sourceAppName, tags, representations, fileURLs
        case contentReference, representationReferences, contentCharacterCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        inlineContent = try container.decode(String.self, forKey: .content)
        contentReference = try container.decodeIfPresent(ClipboardBlobReference.self, forKey: .contentReference)
        contentCharacterCount = try container.decodeIfPresent(Int.self, forKey: .contentCharacterCount)
        type = try container.decode(ClipboardItemType.self, forKey: .type)
        if let dateString = try? container.decode(String.self, forKey: .timestamp) {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = fractional.date(from: dateString) ?? ISO8601DateFormatter().date(from: dateString) else {
                throw DecodingError.dataCorruptedError(forKey: .timestamp, in: container, debugDescription: "Invalid item timestamp")
            }
            timestamp = date
        } else {
            // The original OneClip schema writes ISO dates and accepts Unix seconds.
            let seconds = try container.decode(Double.self, forKey: .timestamp)
            guard seconds.isFinite else {
                throw DecodingError.dataCorruptedError(forKey: .timestamp, in: container, debugDescription: "Invalid item timestamp")
            }
            timestamp = Date(timeIntervalSince1970: seconds)
        }
        data = try container.decodeIfPresent(Data.self, forKey: .data)
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp)
        sourceAppName = try container.decodeIfPresent(String.self, forKey: .sourceAppName)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        inlineRepresentations = try container.decodeIfPresent([String: Data].self, forKey: .representations)
        representationReferences = try container.decodeIfPresent([String: ClipboardBlobReference].self, forKey: .representationReferences)
        fileURLs = try container.decodeIfPresent([String].self, forKey: .fileURLs)
        retainAttachments()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(inlineContent, forKey: .content)
        try container.encodeIfPresent(contentReference, forKey: .contentReference)
        try container.encodeIfPresent(contentCharacterCount, forKey: .contentCharacterCount)
        try container.encodeIfPresent(representationReferences, forKey: .representationReferences)
        try container.encode(type, forKey: .type)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try container.encode(formatter.string(from: timestamp), forKey: .timestamp)
        try container.encodeIfPresent(data, forKey: .data)
        try container.encodeIfPresent(filePath, forKey: .filePath)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encodeIfPresent(sourceApp, forKey: .sourceApp)
        try container.encodeIfPresent(sourceAppName, forKey: .sourceAppName)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(inlineRepresentations, forKey: .representations)
        try container.encodeIfPresent(fileURLs, forKey: .fileURLs)
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.inlineContent == rhs.inlineContent && lhs.contentReference == rhs.contentReference
        && lhs.type == rhs.type && lhs.timestamp == rhs.timestamp && lhs.data == rhs.data && lhs.filePath == rhs.filePath
        && lhs.isFavorite == rhs.isFavorite && lhs.isPinned == rhs.isPinned && lhs.sourceApp == rhs.sourceApp
        && lhs.sourceAppName == rhs.sourceAppName && lhs.tags == rhs.tags && lhs.fileURLs == rhs.fileURLs
        && lhs.inlineRepresentations == rhs.inlineRepresentations && lhs.representationReferences == rhs.representationReferences
    }

}


/// Immutable bytes are shared by content digest, never decoded with the history index.
struct ClipboardBlobReference: Codable, Equatable {
    let path: String
    let byteCount: Int
    let sha256: String
    func relocated(to path: String) -> Self { .init(path: path, byteCount: byteCount, sha256: sha256) }
    func read() throws -> Data {
        let url = URL(fileURLWithPath: path)
        guard path.hasPrefix("/"), let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size == byteCount else { throw ClipboardBlobError.corrupted }
        // Mapping avoids another large heap copy; the reader owns the mapping for its operation.
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard bytes.count == byteCount, Self.digest(bytes) == sha256 else { throw ClipboardBlobError.corrupted }
        return bytes
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

enum ClipboardBlobError: LocalizedError {
    case corrupted
    var errorDescription: String? { AppLanguage.text("历史内容文件缺失或校验失败，未更改剪贴板。", "History content is missing or failed verification; the clipboard was not changed.") }
}

/// Weak registry: a live snapshot in a view, undo stack or task protects its files.
final class ClipboardAttachmentLease {
    private final class Weak { weak var value: ClipboardAttachmentLease?; init(_ value: ClipboardAttachmentLease) { self.value = value } }
    private static let lock = NSLock()
    private static var registry: [UUID: Weak] = [:]
    private let id = UUID()
    let paths: Set<String>
    init(paths: Set<String>) {
        self.paths = paths
        Self.lock.lock(); Self.registry[id] = Weak(self); Self.lock.unlock()
    }
    deinit { Self.lock.lock(); Self.registry.removeValue(forKey: id); Self.lock.unlock() }
    static var livePaths: Set<String> {
        lock.lock(); let entries = Array(registry.values); lock.unlock()
        return Set(entries.compactMap(\.value).flatMap(\.paths))
    }
}
