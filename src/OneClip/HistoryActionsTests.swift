import AppKit
import Foundation

/// Business-result regressions, using an isolated store and named pasteboard.
/// These checks do not simulate clicks or claim to validate SwiftUI hit testing.
enum HistoryActionsTests {
    private static var checks = 0

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else {
            throw NSError(domain: "HistoryActionsTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        checks += 1
        print("PASS history actions \(checks): \(message)")
        fflush(stdout)
    }

    @MainActor static func run(settings: SettingsManager, root: URL) throws {
        guard let isolated = ProcessInfo.processInfo.environment["CCLIP_DATA_DIR"]
                ?? Bundle.main.object(forInfoDictionaryKey: "CClipTestDataDirectory") as? String,
              !isolated.isEmpty else { throw ClipboardError.accessDenied }
        checks = 0
        let directory = root.appendingPathComponent("history-actions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "CClip.HistoryActions.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw ClipboardError.dataCorrupted }
        defer { defaults.removePersistentDomain(forName: suite) }
        let board = NSPasteboard(name: .init("CClip.HistoryActions.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let wasLocked = PrivacyLock.shared.locked
        PrivacyLock.shared.locked = false
        defer { PrivacyLock.shared.locked = wasLocked }

        let store = ClipboardStore(storageDirectory: directory.appendingPathComponent("history"), getCleanupDays: { 0 })
        let manager = ClipboardManager(store: store, board: board, settings: settings)
        let workflowURL = directory.appendingPathComponent("workflow.json")
        let workflow = WorkflowState(fileURL: workflowURL, defaults: defaults)
        let actions = HistoryActions(clipboard: manager, workflow: workflow)
        let first = try manager.addText("Synthetic history first\n保留换行 🧩")
        let second = try manager.addText("Synthetic history second")
        let rtf = Data("{\\rtf1\\ansi Synthetic \\b history\\b0  rich text}".utf8)
        let html = Data("<p>Synthetic <strong>history</strong> rich text</p>".utf8)
        let customType = NSPasteboard.PasteboardType("com.synthetic.history-format")
        board.clearContents()
        try expect(board.setString("Synthetic history rich text", forType: .string)
                   && board.setData(rtf, forType: .rtf) && board.setData(html, forType: .html)
                   && board.setData(Data([2, 4, 8]), forType: customType),
                   "Rich-text fixtures are written only to the named pasteboard")
        guard let rich = try manager.capture(from: board, sourceApp: "com.synthetic.history-actions") else {
            throw ClipboardError.dataCorrupted
        }
        let historyBefore = try store.readItems()
        let memoryBefore = manager.clipboardItems
        try expect(historyBefore.count == 3, "The action fixture has three independently persisted history records")

        let selectedIDs: Set<UUID> = [first.id, second.id, UUID()]
        let selected = HistorySelection(ids: selectedIDs, visibleItems: [second, rich, first])
        try expect(selected.items.map(\.id) == [second.id, first.id]
                   && selected.ids == Set([first.id, second.id]) && !selected.isEmpty && !selected.canPaste,
                   "Effective selection drops missing IDs and follows visible order rather than Set order")
        let filtered = HistorySelection(ids: selectedIDs, visibleItems: [rich])
        try expect(filtered.items.isEmpty && filtered.ids.isEmpty && filtered.isEmpty && !filtered.canPaste,
                   "A filter hiding every selected record leaves no actionable selection")
        let single = HistorySelection(ids: selectedIDs, visibleItems: [rich, first])
        try expect(single.items == [first] && single.ids == Set([first.id]) && single.canPaste,
                   "A multiple selection reduced to one visible record permits single-item paste")
        let deleted = HistorySelection(ids: single.ids, visibleItems: [])
        try expect(deleted.isEmpty && !deleted.canPaste,
                   "Removing the last selected record disables paste without retaining a stale action target")

        manager.lastError = "Synthetic obsolete clipboard error"
        workflow.status = "Synthetic obsolete workflow error"
        actions.copy([rich])
        try expect(board.string(forType: .string) == rich.content && board.data(forType: .rtf) == rtf
                   && board.data(forType: .html) == html && board.data(forType: customType) == Data([2, 4, 8]),
                   "A history copy retains the selected record's original text and rich representations")
        try expect(manager.lastError == nil && !workflow.status.isEmpty
                   && !workflow.status.contains("Synthetic obsolete"),
                   "A successful copy replaces obsolete errors with its current result")
        actions.copy(selected.items)
        try expect(board.string(forType: .string) == second.content + "\n" + first.content,
                   "Copying multiple selected texts preserves visible order, Unicode and line breaks")

        let changeCountBeforeEmpty = board.changeCount
        let textBeforeEmpty = board.string(forType: .string)
        actions.copy(filtered.items)
        try expect(board.changeCount == changeCountBeforeEmpty && board.string(forType: .string) == textBeforeEmpty,
                   "An empty effective selection does not clear or modify the destination pasteboard")
        try expect(!workflow.status.isEmpty, "An empty selection reports that an actionable record is required")

        let warningMarker = "Synthetic history script failure"
        manager.textTransform = { _, _ in
            throw NSError(domain: "HistoryActions.Script", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: warningMarker])
        }
        actions.copy([rich])
        try expect(board.string(forType: .string) == rich.content && board.data(forType: .rtf) == rtf,
                   "A failed copy transformation leaves the original rich text usable")
        try expect(manager.lastError?.contains(warningMarker) == true && workflow.status == manager.lastError,
                   "The action keeps the copy-script warning instead of overwriting it with a success message")
        let beforeFailedBatch = board.changeCount
        let invalidImage = ClipboardItem(id: UUID(), content: "Synthetic invalid batch image", type: .image,
                                         timestamp: Date(), data: Data("not image data".utf8))
        actions.copy([first, invalidImage])
        try expect(workflow.status == ClipboardError.dataCorrupted.localizedDescription
                   && manager.lastError == workflow.status && !workflow.status.contains(warningMarker),
                   "A later batch failure takes precedence over an earlier record's copy-script warning")
        try expect(board.changeCount == beforeFailedBatch && board.string(forType: .string) == rich.content
                   && board.data(forType: .rtf) == rtf && board.data(forType: .html) == html,
                   "A batch that fails after preparing text preserves the entire previous destination clipboard")
        manager.textTransform = nil
        actions.copy([first])
        try expect(manager.lastError == nil && !workflow.status.isEmpty && !workflow.status.contains(warningMarker),
                   "A later successful action clears the previous script warning")

        let existing = ClipboardItem(id: UUID(), content: "Synthetic existing stack item", type: .text, timestamp: Date())
        try workflow.updateDocument { $0.stack = [existing] }
        actions.addToStack([second, rich, first])
        let stackSuccess = workflow.status
        let queued = Array(workflow.document.stack.dropFirst())
        try expect(workflow.document.stack.first == existing && queued.map(\.content) == [second.content, rich.content, first.content],
                   "Adding selected records to the stack appends in order and preserves existing stack content")
        try expect(Set(queued.map(\.id)).count == 3
                   && Set(queued.map(\.id)).isDisjoint(with: Set(historyBefore.map(\.id))),
                   "Every new stack occurrence gets an identity distinct from the history records")
        try expect(queued[1].representations == rich.representations && queued[1].sourceApp == rich.sourceApp,
                   "Stack entries retain rich representations and source metadata")
        let stackOnDisk = try readDocument(workflowURL).stack
        try expect(try persistedBytes(stackOnDisk) == persistedBytes(workflow.document.stack),
                   "A successful stack action has already persisted the complete updated stack")
        actions.addToStack([first])
        try expect(workflow.document.stack.last?.id != queued[2].id
                   && workflow.document.stack.last?.content == first.content,
                   "Queuing the same history record again creates a separate stack occurrence")

        actions.addToShelf(rich)
        let shelfSuccess = workflow.status
        let shelfOnDisk = try readDocument(workflowURL).shelf
        try expect(try persistedBytes(shelfOnDisk) == persistedBytes([rich]) && workflow.document.shelf == [rich],
                   "The shelf action persists the original selected record and its metadata")
        actions.saveReply(first)
        let replySuccess = workflow.status
        let repliesOnDisk = try readDocument(workflowURL).replies
        try expect(try persistedBytes(repliesOnDisk) == persistedBytes(workflow.document.replies)
                   && workflow.document.replies.count == 1 && workflow.document.replies[0].item == first
                   && workflow.document.replies[0].title == String(first.content.prefix(40)),
                   "Saving a quick reply persists its title, stable reply identity and original content")

        let blockedParent = directory.appendingPathComponent("ordinary-file-parent")
        let blockerBytes = Data("Synthetic file that must never become a directory".utf8)
        try blockerBytes.write(to: blockedParent)
        let blocked = WorkflowState(fileURL: blockedParent.appendingPathComponent("workflow.json"), defaults: defaults)
        let blockedActions = HistoryActions(clipboard: manager, workflow: blocked)
        let blockedBefore = try persistedBytes(blocked.document)
        for (name, success, operation) in [
            ("stack", stackSuccess, { blockedActions.addToStack([second, rich, first]) }),
            ("shelf", shelfSuccess, { blockedActions.addToShelf(rich) }),
            ("reply", replySuccess, { blockedActions.saveReply(first) })
        ] {
            operation()
            try expect(!blocked.status.isEmpty && blocked.status != success,
                       "A failed \(name) save reports an error rather than the action's success result")
            try expect(try persistedBytes(blocked.document) == blockedBefore && Data(contentsOf: blockedParent) == blockerBytes,
                       "A failed \(name) save preserves both the published workflow and the blocking file")
        }

        let corruptURL = directory.appendingPathComponent("protected-workflow.json")
        let corruptBytes = Data("{\"stack\":\"Synthetic unreadable workflow\"}".utf8)
        try corruptBytes.write(to: corruptURL)
        let protected = WorkflowState(fileURL: corruptURL, defaults: defaults)
        let protectedBefore = try persistedBytes(protected.document)
        let protectedActions = HistoryActions(clipboard: manager, workflow: protected)
        protectedActions.addToStack([first])
        try expect(protected.storageReadError != nil && protected.status == protected.storageReadError,
                   "Unreadable workflow protection remains visible when an action attempts to save")
        try expect(try Data(contentsOf: corruptURL) == corruptBytes && persistedBytes(protected.document) == protectedBefore,
                   "A protected workflow action cannot overwrite unread data or publish unsaved changes")
        try expect(try persistedBytes(store.readItems()) == persistedBytes(historyBefore) && manager.clipboardItems == memoryBefore,
                   "Copy, stack, shelf, reply and failed workflow actions leave persisted and in-memory history unchanged")
        print("HistoryActionsTests: \(checks) checks passed; isolated business results, no UI click or general clipboard coverage.")
    }

    private static func readDocument(_ url: URL) throws -> WorkflowDocument {
        try JSONDecoder().decode(WorkflowDocument.self, from: Data(contentsOf: url))
    }

    /// Compare every persisted field using the production encoding, which stores
    /// ClipboardItem timestamps at millisecond precision rather than full Date precision.
    private static func persistedBytes<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }
}
