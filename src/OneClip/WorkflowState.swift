import Foundation
import AppKit
import Combine
import LocalAuthentication
import Security
import CryptoKit
import Carbon

func L(_ zh: String, _ en: String) -> String { AppLanguage.text(zh, en) }

struct ClipCategory: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var parentID: UUID?
    var pattern = ""
    var color = "blue"

    enum CodingKeys: String, CodingKey { case id, name, parentID, pattern, color }
    init(id: UUID = UUID(), name: String, parentID: UUID? = nil, pattern: String = "", color: String = "blue") {
        self.id = id; self.name = name; self.parentID = parentID; self.pattern = pattern; self.color = color
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decode(String.self, forKey: .name)
        parentID = try values.decodeIfPresent(UUID.self, forKey: .parentID)
        pattern = try values.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        color = try values.decodeIfPresent(String.self, forKey: .color) ?? "blue"
    }
}
struct QuickReply: Codable, Identifiable {
    var id = UUID()
    var title: String
    var group = ""
    var item: ClipboardItem
    var hotkey: ShortcutSpec?

    enum CodingKeys: String, CodingKey { case id, title, group, item, hotkey }
    init(id: UUID = UUID(), title: String, group: String = "", item: ClipboardItem, hotkey: ShortcutSpec? = nil) {
        self.id = id; self.title = title; self.group = group; self.item = item; self.hotkey = hotkey
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try values.decode(String.self, forKey: .title)
        group = try values.decodeIfPresent(String.self, forKey: .group) ?? ""
        item = try values.decode(ClipboardItem.self, forKey: .item)
        hotkey = try values.decodeIfPresent(ShortcutSpec.self, forKey: .hotkey)
    }
}
struct ShortcutSpec: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt
    var label: String
    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
}
struct WorkflowDocument: Codable {
    var stack: [ClipboardItem] = []
    var shelf: [ClipboardItem] = []
    var replies: [QuickReply] = []
    var categories: [ClipCategory] = []
    var shortcuts: [String: ShortcutSpec] = [:]
    var language = "zh"
    var layout = "list"
    var excludedApps = ""
    var excludedPatterns = ""
    var searchHistory: [String] = []
    var selectionMenu = false
    var finderCut = false
    var edgeReveal = false
    var topShelf = false
    var automaticBackup = false
    var autoRecognizeImages: Bool?
    var moveAfterPaste = false
    var returnAfterPaste = false

    init() {}
    enum CodingKeys: String, CodingKey {
        case stack, shelf, replies, categories, shortcuts, language, layout, excludedApps, excludedPatterns
        case searchHistory, selectionMenu, finderCut, edgeReveal, topShelf, automaticBackup, autoRecognizeImages
        case moveAfterPaste, returnAfterPaste
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        stack = try values.decodeIfPresent([ClipboardItem].self, forKey: .stack) ?? []
        shelf = try values.decodeIfPresent([ClipboardItem].self, forKey: .shelf) ?? []
        replies = try values.decodeIfPresent([QuickReply].self, forKey: .replies) ?? []
        categories = try values.decodeIfPresent([ClipCategory].self, forKey: .categories) ?? []
        shortcuts = try values.decodeIfPresent([String: ShortcutSpec].self, forKey: .shortcuts) ?? [:]
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? "zh"
        layout = try values.decodeIfPresent(String.self, forKey: .layout) ?? "list"
        excludedApps = try values.decodeIfPresent(String.self, forKey: .excludedApps) ?? ""
        excludedPatterns = try values.decodeIfPresent(String.self, forKey: .excludedPatterns) ?? ""
        searchHistory = try values.decodeIfPresent([String].self, forKey: .searchHistory) ?? []
        selectionMenu = try values.decodeIfPresent(Bool.self, forKey: .selectionMenu) ?? false
        finderCut = try values.decodeIfPresent(Bool.self, forKey: .finderCut) ?? false
        edgeReveal = try values.decodeIfPresent(Bool.self, forKey: .edgeReveal) ?? false
        topShelf = try values.decodeIfPresent(Bool.self, forKey: .topShelf) ?? false
        automaticBackup = try values.decodeIfPresent(Bool.self, forKey: .automaticBackup) ?? false
        autoRecognizeImages = try values.decodeIfPresent(Bool.self, forKey: .autoRecognizeImages)
        moveAfterPaste = try values.decodeIfPresent(Bool.self, forKey: .moveAfterPaste) ?? false
        returnAfterPaste = try values.decodeIfPresent(Bool.self, forKey: .returnAfterPaste) ?? false
    }
}

class WorkflowState: ObservableObject {
    static let shared = WorkflowState()
    @Published var document: WorkflowDocument { didSet { if !isLoading { save() } } }
    @Published private(set) var storageReadError: String?
    @Published var status = ""
    @Published var stackCollecting = false
    @Published var stackPasting = false
    @Published var pastedIDs: Set<UUID> = []
    var language: String { document.language }
    private let file: URL
    private let defaults: UserDefaults
    private var isLoading = false
    private var languageObserver: NSObjectProtocol?
    private var storageReadFailure: Error?
    init(fileURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.file = fileURL ?? StoragePaths.dataDirectory.appendingPathComponent("workflow.json")
        self.defaults = defaults
        document = WorkflowDocument()
        do { try reloadFromDisk() }
        catch { status = error.localizedDescription }
        if defaults === UserDefaults.standard {
            languageObserver = NotificationCenter.default.addObserver(forName: AppLanguage.didChange, object: AppLanguage.shared, queue: .main) { [weak self] _ in
                guard let self else { return }
                if let error = self.storageReadFailure {
                    self.storageReadError = self.storageErrorDescription(error)
                    self.status = self.storageReadError ?? ""
                } else { self.status = "" }
            }
        }
    }
    deinit { if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) } }

    func setLanguage(_ code: String) throws {
        guard AppLanguage.supportedCodes.contains(code) else { return }
        var updated = document
        updated.language = code
        try persist(updated)
        isLoading = true
        document = updated
        isLoading = false
    }

    private func storageErrorDescription(_ error: Error) -> String {
        L("工作流文件无法读取，原文件已保留；修复或恢复后重新加载才能保存：", "The workflow file could not be read. The original is preserved; repair or restore it and reload before saving: ") + error.localizedDescription
    }
    /// Successful reloading is the only way to lift protection after an unreadable file.
    /// Reading an older document never rewrites it just to add new default fields.
    func reloadFromDisk() throws {
        let previousReadError = storageReadError
        do {
            var loaded: WorkflowDocument
            if FileManager.default.fileExists(atPath: file.path) {
                loaded = try JSONDecoder().decode(WorkflowDocument.self, from: Data(contentsOf: file))
            } else {
                loaded = WorkflowDocument()
                loaded.language = AppLanguage.normalized(defaults.string(forKey: AppLanguage.preferenceKey))
            }
            loaded.language = AppLanguage.normalized(loaded.language)
            isLoading = true
            document = loaded
            isLoading = false
            storageReadError = nil
            storageReadFailure = nil
            AppLanguage.synchronize(loaded.language, defaults: defaults)
            if let previousReadError, status == previousReadError { status = "" }
        } catch {
            storageReadFailure = error
            storageReadError = storageErrorDescription(error)
            status = storageReadError!
            throw NSError(domain: "CClip.Workflow", code: 1, userInfo: [NSLocalizedDescriptionKey: storageReadError!])
        }
    }
    private func requireWritableStorage() throws {
        if let storageReadError {
            throw NSError(domain: "CClip.Workflow", code: 1, userInfo: [NSLocalizedDescriptionKey: storageReadError])
        }
    }
    private func persist(_ value: WorkflowDocument) throws {
        try requireWritableStorage()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        AppLanguage.synchronize(value.language, defaults: defaults)
    }
    func save() {
        do { try persist(document) }
        catch { status = error.localizedDescription }
    }
    func addToStack(_ item: ClipboardItem) {
        // Every stack occurrence has its own identity, even when the same clip is queued twice.
        document.stack.append(ClipboardItem(id: UUID(), content: item.content, type: item.type,
            timestamp: item.timestamp, data: item.data, filePath: item.filePath,
            isFavorite: item.isFavorite, isPinned: item.isPinned, sourceApp: item.sourceApp, sourceAppName: item.sourceAppName,
            tags: item.tags, representations: item.representations, fileURLs: item.fileURLs))
    }
    func splitLines(_ text: String) {
        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            document.stack.append(ClipboardItem(id: UUID(), content: line, type: .text, timestamp: Date()))
        }
    }
    func rememberSearch(_ query: String) {
        guard !query.isEmpty else { return }
        document.searchHistory.removeAll { $0 == query }
        document.searchHistory.insert(query, at: 0)
        document.searchHistory = Array(document.searchHistory.prefix(20))
    }
    func applyRules(_ item: ClipboardItem) -> ClipboardItem {
        var result = item
        for category in document.categories where !category.pattern.isEmpty {
            if item.content.range(of: category.pattern, options: .regularExpression) != nil, !result.tags.contains(category.name) {
                result.tags.append(category.name)
            }
        }
        return result
    }
    func exportReplies(to url: URL) throws {
        var archive = try HistoryArchive.make(items: [], additionalItems: document.replies.map(\.item))
        let snapshots = archive.additionalItems ?? []
        var replies = document.replies
        for index in replies.indices { replies[index].item = snapshots[index] }
        archive.extraFiles = ["replies.json": try JSONEncoder().encode(replies)]
        try JSONEncoder().encode(archive).write(to: url, options: .atomic)
    }
    func importReplies(from url: URL, using destinationStore: ClipboardStore? = nil) throws {
        try requireWritableStorage()
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 128 * 1024 * 1024 else { throw ClipboardError.dataCorrupted }
        let store = destinationStore ?? ClipboardManager.shared.store
        var archive: HistoryArchive
        var replies: [QuickReply]
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("cclip-replies-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        if let portable = try? JSONDecoder().decode(HistoryArchive.self, from: bytes) {
            try portable.validate()
            guard portable.items.isEmpty, let metadata = portable.extraFiles?["replies.json"] else { throw ClipboardError.dataCorrupted }
            replies = try JSONDecoder().decode([QuickReply].self, from: metadata)
            archive = portable
        } else {
            let legacy = try JSONDecoder().decode([ReplyArchive].self, from: bytes)
            replies = []
            for var entry in legacy {
                var paths: [String] = []
                for attachment in entry.attachments {
                    guard !attachment.name.isEmpty, attachment.name == URL(fileURLWithPath: attachment.name).lastPathComponent,
                          attachment.name != ".", attachment.name != "..", !attachment.name.contains("\\") else { throw ClipboardError.dataCorrupted }
                    let directory = staging.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                    let destination = directory.appendingPathComponent(attachment.name)
                    try attachment.data.write(to: destination, options: .withoutOverwriting)
                    paths.append(destination.path)
                }
                let wasFileList = entry.reply.item.fileURLs != nil
                entry.reply.item.filePath = paths.first
                entry.reply.item.fileURLs = wasFileList || entry.reply.item.type != .image ? (paths.isEmpty ? nil : paths) : nil
                if entry.reply.item.type != .text, !paths.isEmpty { entry.reply.item.data = nil }
                replies.append(entry.reply)
            }
            archive = try HistoryArchive.make(items: [], additionalItems: replies.map(\.item))
        }
        let snapshots = archive.additionalItems ?? []
        guard snapshots.count == replies.count,
              zip(replies, snapshots).allSatisfy({ $0.item.id == $1.id }) else { throw ClipboardError.dataCorrupted }
        // Import auxiliary snapshots in one transaction; templates do not pollute normal history.
        let portableURL = staging.appendingPathComponent("portable.backup")
        try JSONEncoder().encode(archive).write(to: portableURL, options: .atomic)
        let imported = try store.importWorkspaceBackup(from: portableURL)
        var additions: [QuickReply] = []
        for index in replies.indices {
            var reply = replies[index]
            reply.id = UUID(); reply.hotkey = nil
            reply.item = imported.additionalItems[index]
            additions.append(reply)
        }
        var updated = document
        updated.replies.append(contentsOf: additions)
        // Verify the durable write before publishing the imported templates.
        try persist(updated)
        document = updated
    }
    private struct ReplyArchive: Codable { var reply: QuickReply; var attachments: [ReplyAttachment] }
    private struct ReplyAttachment: Codable { var name: String; var data: Data }
}

/// UI lock: does not claim database encryption. No clipboard surface is accessible while locked.
class PrivacyLock: ObservableObject {
    /// Pure decision state: a completion is valid only for the current authentication attempt.
    /// Kept separate from Keychain and LAContext so cancellation races can be tested without credentials.
    struct AuthenticationGate {
        private var generation: UInt64 = 0
        private(set) var activeAttempt: UInt64?
        mutating func begin() -> UInt64 {
            generation &+= 1
            activeAttempt = generation
            return generation
        }
        mutating func invalidate() {
            generation &+= 1
            activeAttempt = nil
        }
        mutating func finish(_ attempt: UInt64) -> Bool {
            guard activeAttempt == attempt else { return false }
            activeAttempt = nil
            return true
        }
    }
    static let shared = PrivacyLock()
    @Published var locked = false
    @Published private var errorProvider: (() -> String)?
    var error: String { errorProvider?() ?? "" }
    private func setError(_ chinese: String, _ english: String, underlying: Error? = nil) {
        errorProvider = { underlying?.localizedDescription ?? L(chinese, english) }
    }
    @Published var busy = false
    private var failures = 0
    private var retryAfter = Date.distantPast
    private var authenticationGate = AuthenticationGate()
    private var authenticationContext: LAContext?
    private let account = "history-password-v1"
    var enabled: Bool { readSecret() != nil }
    private init() { locked = readSecret() != nil }
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.cclip.privacy", kSecAttrAccount as String: account] }
    private func readSecret() -> Data? {
        var q = query; q[kSecReturnData as String] = true
        var value: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess else { return nil }
        return value as? Data
    }
    private func derive(_ password: String, salt: Data) -> Data {
        var digest = Data(SHA256.hash(data: salt + Data(password.utf8)))
        for _ in 0..<100_000 { digest = Data(SHA256.hash(data: digest + salt)) }
        return digest
    }
    func setPassword(_ password: String) throws {
        guard password.count >= 8 else { throw NSError(domain: "CClip", code: 1, userInfo: [NSLocalizedDescriptionKey: L("密码至少需要 8 个字符。", "Use at least 8 characters.")]) }
        guard !locked else { throw ClipboardError.dataCorrupted }
        var salt = Data(count: 32)
        let result = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard result == errSecSuccess else { throw ClipboardError.dataCorrupted }
        let data = salt + derive(password, salt: salt)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw ClipboardError.dataCorrupted }
        } else if status != errSecSuccess { throw ClipboardError.dataCorrupted }
        objectWillChange.send()
    }
    func unlock(password: String) {
        guard !busy else { return }
        guard Date() >= retryAfter else { setError("请稍后重试。", "Please wait before retrying."); return }
        guard let expected = readSecret(), expected.count == 64 else { setError("请先设置密码。", "Set a password first."); return }
        let attempt = authenticationGate.begin()
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let actual = self.derive(password, salt: expected.prefix(32))
            let match = zip(actual, expected.suffix(32)).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
            DispatchQueue.main.async {
                guard self.authenticationGate.finish(attempt) else { return }
                self.busy = false
                if match { self.locked = false; self.errorProvider = nil; self.failures = 0 }
                else { self.failures += 1; self.retryAfter = Date().addingTimeInterval(Double(min(30, self.failures * 2))); self.setError("密码不正确。", "Incorrect password.") }
            }
        }
    }
    func unlockBiometric() {
        guard !busy else { return }
        let context = LAContext(); var failure: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &failure) else { setError("系统验证不可用", "Authentication unavailable", underlying: failure); return }
        let attempt = authenticationGate.begin()
        authenticationContext = context
        busy = true
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: L("解锁剪贴板历史", "Unlock clipboard history")) { success, failure in
            DispatchQueue.main.async {
                guard self.authenticationGate.finish(attempt) else { return }
                self.authenticationContext = nil
                self.busy = false
                if success { self.locked = false; self.errorProvider = nil; self.failures = 0 }
                else { self.setError("已取消", "Cancelled", underlying: failure) }
            }
        }
    }
    private func invalidateAuthentication() {
        // Invalidate the token before the context: invalidate() may itself deliver an auth callback.
        authenticationGate.invalidate()
        let context = authenticationContext
        authenticationContext = nil
        busy = false
        context?.invalidate()
    }
    func lock() {
        invalidateAuthentication()
        guard enabled else { setError("先在设置中添加密码。", "Set a password in Settings first."); return }
        locked = true
        NotificationCenter.default.post(name: .init("CClipLocked"), object: nil)
    }
    func removePassword() { guard !locked else { return }; SecItemDelete(query as CFDictionary); objectWillChange.send() }
}

/// Typed local URL contract. Mutating commands always require an in-app review.
enum ClipRoute: Equatable {
    case show, search(String), add(String), stack(String), capture
    static func parse(_ url: URL) throws -> ClipRoute {
        guard ["xclip", "cclip", "oneclip-dev"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw ClipboardError.dataCorrupted }
        let values = parts.queryItems ?? []
        guard Set(values.map(\.name)).count == values.count else { throw ClipboardError.dataCorrupted }
        func value(_ name: String) throws -> String {
            guard let text = values.first(where: { $0.name == name })?.value, !text.isEmpty, text.utf8.count <= 1_048_576 else { throw ClipboardError.dataCorrupted }
            return text
        }
        switch url.host {
        case "show": return .show
        case "search": return .search(try value("q"))
        case "add": return .add(try value("text"))
        case "stack": return .stack(try value("text"))
        case "capture": return .capture
        default: throw ClipboardError.dataCorrupted
        }
    }
}
