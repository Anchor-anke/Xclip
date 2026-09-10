import Foundation

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
    var content: String
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
    var representations: [String: Data]?
    /// Paths to independently retained files; multiple files keep their original names.
    var fileURLs: [String]?

    init(id: UUID, content: String, type: ClipboardItemType, timestamp: Date,
         data: Data? = nil, filePath: String? = nil, isFavorite: Bool = false,
         isPinned: Bool = false, sourceApp: String? = nil, sourceAppName: String? = nil, tags: [String] = [],
         representations: [String: Data]? = nil, fileURLs: [String]? = nil) {
        self.id = id
        self.content = content
        self.type = type
        self.timestamp = timestamp
        self.data = data
        self.filePath = filePath
        self.isFavorite = isFavorite
        self.isPinned = isPinned
        self.sourceApp = sourceApp
        self.sourceAppName = sourceAppName
        self.tags = tags
        self.representations = representations
        self.fileURLs = fileURLs
    }

    /// Localize the generated image label without changing stored content or clipboard bytes.
    var displayContent: String {
        type == .image && content == "Image" ? AppLanguage.text("图片", "Image") : content
    }

    enum CodingKeys: String, CodingKey {
        case id, content, type, timestamp, data, filePath, isFavorite
        case isPinned, sourceApp, sourceAppName, tags, representations, fileURLs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        content = try container.decode(String.self, forKey: .content)
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
        representations = try container.decodeIfPresent([String: Data].self, forKey: .representations)
        fileURLs = try container.decodeIfPresent([String].self, forKey: .fileURLs)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(content, forKey: .content)
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
        try container.encodeIfPresent(representations, forKey: .representations)
        try container.encodeIfPresent(fileURLs, forKey: .fileURLs)
    }
}
