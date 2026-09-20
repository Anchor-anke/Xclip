import AppKit

/// Only records still present in the current results can be acted on.
struct HistorySelection {
    let items: [ClipboardItem]
    var ids: Set<UUID> { Set(items.map(\.id)) }
    var isEmpty: Bool { items.isEmpty }
    var canPaste: Bool { items.count == 1 }

    init(ids: Set<UUID>, visibleItems: [ClipboardItem]) {
        items = visibleItems.filter { ids.contains($0.id) }
    }
}

/// History actions report the result of the actual write, including storage failures.
struct HistoryActions {
    let clipboard: ClipboardManager
    let workflow: WorkflowState

    func copy(_ items: [ClipboardItem]) {
        run(items, success: L("已复制 \(items.count) 条内容", "Copied \(items.count) items")) {
            try clipboard.writeItemsToClipboard(items)
        }
    }

    func addToStack(_ items: [ClipboardItem]) {
        run(items, success: L("已加入栈粘贴板，共 \(items.count) 条", "Added \(items.count) items to the paste stack")) {
            try workflow.updateDocument { $0.stack.append(contentsOf: items.map { $0.withNewIdentity() }) }
        }
    }

    func addToShelf(_ item: ClipboardItem) {
        run([item], success: L("已加入拖拽容器", "Added to the drop shelf")) {
            try workflow.updateDocument { $0.shelf.append(item) }
        }
    }

    func saveReply(_ item: ClipboardItem) {
        run([item], success: L("已保存为快捷回复", "Saved as a quick reply")) {
            try workflow.updateDocument { $0.replies.append(.init(title: String(item.content.prefix(40)), item: item)) }
        }
    }

    func export(_ items: [ClipboardItem], to directory: URL) {
        run(items, success: L("已保存 \(items.count) 条内容到 \(directory.lastPathComponent)", "Saved \(items.count) items to \(directory.lastPathComponent)")) {
            for item in items { try saveClip(item, to: directory) }
        }
    }

    private func run(_ items: [ClipboardItem], success: String, operation: () throws -> Void) {
        guard !PrivacyLock.shared.locked else { return }
        clipboard.lastError = nil
        workflow.status = ""
        guard !items.isEmpty else {
            workflow.status = L("请先选择当前列表中的内容", "Select an item in the current results first")
            return
        }
        do {
            try operation()
            workflow.status = clipboard.lastError ?? success
        } catch {
            clipboard.lastError = error.localizedDescription
            workflow.status = error.localizedDescription
        }
    }
}
