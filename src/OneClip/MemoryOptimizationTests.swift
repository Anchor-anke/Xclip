import AppKit
import Darwin

/// Runs only from the isolated app smoke entry point. Never touches the general pasteboard.
enum MemoryOptimizationTests {
    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }
    @MainActor static func run(root: URL) throws {
        var checks = 0
        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw NSError(domain: "MemoryOptimizationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 512, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4096, bitsPerPixel: 32)!
        memset(bitmap.bitmapData!, 128, 4096 * 512)
        let png = bitmap.representation(using: .png, properties: [:])!
        let tiff = bitmap.representation(using: .tiff, properties: [:])!
        let item = ClipboardItem(id: UUID(), content: "Image", type: .image, timestamp: Date(), data: png, representations: ["public.png": png, "public.tiff": tiff])
        let board = NSPasteboard(name: .init("Xclip.MemoryTests.\(UUID())"))
        defer { board.releaseGlobally() }
        let settings = SettingsManager.shared
        let persistence = settings.enableHistoryPersistence, maxItems = settings.maxItems
        defer { settings.enableHistoryPersistence = persistence; settings.maxItems = maxItems }
        settings.enableHistoryPersistence = true; settings.maxItems = 0
        let store = ClipboardStore(storageDirectory: root.appendingPathComponent("memory-regression"), getCleanupDays: { 0 })
        let manager = ClipboardManager(store: store, board: board, settings: settings)
        let before = store.decodedRecordCount
        let saved = try manager.ingest(item)
        try expect(store.decodedRecordCount == before, "Capturing an item updates the index without re-decoding history")
        try expect(manager.residentHistoryBytes < 16 * 1024, "Image representations are absent from resident history")
        try manager.writeToClipboard(saved, board: board)
        try expect(board.data(forType: .png) == png && board.data(forType: .tiff) == tiff, "Both original image formats survive lazy loading")
        manager.deleteItem(saved)
        try expect(manager.residentUndoBytes < 16 * 1024 && manager.canUndo, "Delete undo retains references instead of full images")
        manager.undoDelete()
        try expect(manager.clipboardItems.contains(where: { $0.id == saved.id }), "Reference-backed deletion can be undone")
        let writers = try QuickPasteDragPayload.writers(for: saved, manager: manager)
        try expect(!writers.isEmpty, "Lazy image formats remain usable for native drag payloads")
        let reference = saved.representationReferences!["public.tiff"]!
        try Data([9]).write(to: URL(fileURLWithPath: reference.path))
        board.clearContents(); board.setString("synthetic sentinel", forType: .string)
        do { try manager.writeToClipboard(saved, board: board); throw ClipboardError.storageFailure }
        catch ClipboardBlobError.corrupted { checks += 1 }
        try expect(board.string(forType: .string) == "synthetic sentinel", "Missing/corrupt bytes never replace a working pasteboard")
        try tiff.write(to: URL(fileURLWithPath: reference.path))

        let cache = ClipboardThumbnailCache(budget: 200 * 1024)
        var delivered = 0
        let completion: (CGImage?) -> Void = { image in
            if let image, max(image.width, image.height) <= 256 { delivered += 1 }
        }
        _ = cache.request(item: saved, pixels: 256, completion: completion)
        _ = cache.request(item: saved, pixels: 256, completion: completion)
        let deadline = Date().addingTimeInterval(10)
        while delivered < 2 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        try expect(delivered == 2 && cache.statistics.count == 1, "Concurrent thumbnail consumers share one downsampled result")
        try expect(cache.statistics.bytes <= cache.budget, "Thumbnail pixels stay within the actual byte budget")
        cache.clear()
        try expect(cache.statistics.bytes == 0 && cache.statistics.pending == 0, "Cache clearing releases entries and cancels pending work")

        var cycleFootprints: [UInt64] = []
        for _ in 0..<20 {
            var done = false
            _ = cache.request(item: saved, pixels: 256) { _ in done = true }
            let limit = Date().addingTimeInterval(5)
            while !done && Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            try expect(done, "Repeated thumbnail decode completes")
            cache.clear()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            cycleFootprints.append(footprint())
        }
        print("Memory thumbnail cycles (physical footprint bytes): \(cycleFootprints)")
        try expect(cache.statistics.bytes == 0 && cache.statistics.pending == 0, "Twenty thumbnail cycles leave no cached or queued resources")

        let editor = ImageEditorModel(data: png, allowsDiskHistory: true, historyBudget: 1024)
        editor.rotate(); editor.rotate(); editor.rotate()
        try expect(editor.undoCount == 3 && editor.historyResidentBytes <= 1024, "Persistent editing spills old checkpoints while keeping undo steps")
        editor.undo(); editor.undo(); editor.undo()
        let restoredImage = try CaptureImageCodec.decode(editor.export())
        try expect(restoredImage.width == 1024 && restoredImage.height == 512 && editor.failure == nil, "Spilled checkpoints restore the source dimensions")
        editor.redo()
        try expect(editor.image?.width == 512 && editor.image?.height == 1024, "Redo reads back the correct spilled image")
        editor.clear()
        try expect(editor.undoCount == 0 && editor.redoCount == 0 && editor.image == nil, "Closing editing releases all checkpoint state")
        let memoryEditor = ImageEditorModel(data: png, allowsDiskHistory: false, historyBudget: 1024)
        memoryEditor.rotate(); memoryEditor.rotate()
        try expect(memoryEditor.historyResidentBytes <= 1024, "Memory-only editing also obeys its history budget")

        let pins = PinnedImageController(presentsWindows: false, pasteboard: board)
        pins.historyBudget = 1024; pins.allowsDiskHistory = { true }
        let id = pins.show(png)!
        pins.sessions[id]!.model.setOpacity(0.5)
        pins.close(id)
        try expect(pins.historyCount == 1 && pins.historyResidentBytes <= 1024, "Closed pin recovery can release decoded pixels")
        try expect(pins.restoreLast() && pins.sessions[id]?.model.opacity == 0.5, "Pin recovery preserves identity and display state")
        pins.closeAll()
        let activeTemporary = try SessionTemporaryFiles.create(prefix: "xclip-edit-")
        defer { try? FileManager.default.removeItem(at: activeTemporary) }
        SessionTemporaryFiles.cleanupOrphans(now: Date().addingTimeInterval(10 * 86_400))
        try expect(FileManager.default.fileExists(atPath: activeTemporary.path), "Temporary cleanup never removes an active process's files")
        let abandoned = try SessionTemporaryFiles.create(prefix: "xclip-edit-")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run(); process.waitUntilExit()
        let marker = abandoned.appendingPathComponent(".xclip-session-owner")
        var owner = try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as! [String: Any]
        owner["pid"] = process.processIdentifier
        owner["created"] = Date().addingTimeInterval(-2 * 86_400).timeIntervalSinceReferenceDate
        try JSONSerialization.data(withJSONObject: owner).write(to: marker)
        SessionTemporaryFiles.cleanupOrphans()
        try expect(!FileManager.default.fileExists(atPath: abandoned.path), "Expired owned directories of an exited process are reclaimed")
        print("MemoryOptimizationTests: \(checks) checks passed; isolated data and named pasteboards.")
    }
}
