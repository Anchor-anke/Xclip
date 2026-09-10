import AppKit

/// Editing changes a current record's payload while retaining its provenance and organization.
enum ClipboardEditing {
    static func isTextEditable(_ item: ClipboardItem) -> Bool {
        item.type == .text || (item.type == .code && item.filePath == nil && (item.fileURLs ?? []).isEmpty)
    }

    static func title(for item: ClipboardItem) -> String {
        if isTextEditable(item) { return L("修改内容", "Edit content") }
        if item.type == .image { return L("编辑图片", "Edit image") }
        return L("查看详情", "View details")
    }

    static func saveText(id: UUID, content: String, manager: ClipboardManager = .shared) throws {
        var item = try currentItem(id: id, manager: manager)
        guard isTextEditable(item) else { throw ClipboardEditingError.notEditable }
        item.content = content
        item.data = nil
        item.representations = nil
        _ = try manager.ingest(item)
    }

    static func saveImage(id: UUID, data: Data, manager: ClipboardManager = .shared) throws {
        var item = try currentItem(id: id, manager: manager)
        guard item.type == .image else { throw ClipboardEditingError.notEditable }
        guard NSImage(data: data) != nil else { throw ClipboardError.imageProcessingFailed }
        item.data = data
        item.filePath = nil
        item.fileURLs = nil
        item.representations = nil
        _ = try manager.ingest(item)
    }

    private static func currentItem(id: UUID, manager: ClipboardManager) throws -> ClipboardItem {
        guard !PrivacyLock.shared.locked else { throw ClipboardEditingError.locked }
        guard let item = manager.clipboardItems.first(where: { $0.id == id }) else {
            throw ClipboardEditingError.missingItem
        }
        return item
    }
}

enum ClipboardEditingError: LocalizedError {
    case locked
    case missingItem
    case notEditable

    var errorDescription: String? {
        switch self {
        case .locked:
            return L("剪贴板已锁定，请解锁后再保存。", "The clipboard is locked. Unlock it before saving.")
        case .missingItem:
            return L("这条剪贴板记录已被删除，无法保存修改。", "This clip has been deleted and can no longer be saved.")
        case .notEditable:
            return L("此类内容仅支持预览，无法在这里修改。", "This content supports preview only and cannot be edited here.")
        }
    }
}
