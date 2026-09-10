import AppKit

enum QuickPasteContextAction: String {
    case edit, favorite, pin, copy, paste, delete
}

/// A native menu belongs to the card that opened it, regardless of selection changes.
final class QuickPasteContextMenu: NSMenu {
    let itemID: UUID
    private let onAction: (QuickPasteContextAction, UUID) -> Void

    init(item: ClipboardItem, onAction: @escaping (QuickPasteContextAction, UUID) -> Void) {
        itemID = item.id
        self.onAction = onAction
        super.init(title: L("剪贴板操作", "Clipboard actions"))
        autoenablesItems = false
        add(.edit, title: ClipboardEditing.title(for: item) + "…", icon: item.type == .image ? "slider.horizontal.3" : "square.and.pencil")
        addItem(.separator())
        add(.favorite, title: item.isFavorite ? L("取消收藏", "Unfavorite") : L("收藏", "Favorite"), icon: item.isFavorite ? "star.slash" : "star")
        add(.pin, title: item.isPinned ? L("取消置顶", "Unpin") : L("置顶", "Pin"), icon: item.isPinned ? "pin.slash" : "pin")
        addItem(.separator())
        add(.copy, title: L("复制", "Copy"), icon: "doc.on.doc")
        add(.paste, title: L("粘贴", "Paste"), icon: "doc.on.clipboard")
        addItem(.separator())
        add(.delete, title: L("删除", "Delete"), icon: "trash")
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func add(_ action: QuickPasteContextAction, title: String, icon: String) {
        let entry = NSMenuItem(title: title, action: #selector(activate(_:)), keyEquivalent: "")
        entry.target = self
        entry.representedObject = action.rawValue
        entry.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        addItem(entry)
    }

    @objc private func activate(_ sender: NSMenuItem) {
        guard !PrivacyLock.shared.locked,
              let value = sender.representedObject as? String,
              let action = QuickPasteContextAction(rawValue: value) else { return }
        // Let native tracking finish before opening an editor or updating cards.
        DispatchQueue.main.async { [onAction, itemID] in onAction(action, itemID) }
    }
}
