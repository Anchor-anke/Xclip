import SwiftUI
import AppKit

/// Off-screen snapshot harness for this application's views; never captures the user's screen.
enum AppRenderTests {
    @MainActor static func run() throws {
        guard let root = ProcessInfo.processInfo.environment["CCLIP_DATA_DIR"],
              let output = ProcessInfo.processInfo.environment["CCLIP_RENDER_DIR"], !root.isEmpty, !output.isEmpty else { throw ClipboardError.dataCorrupted }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let languages = ProcessInfo.processInfo.environment["CCLIP_RENDER_LANGUAGES"]?
            .split(separator: ",").map(String.init).filter { AppLanguage.supportedCodes.contains($0) }
        let previousLanguage = WorkflowState.shared.language
        defer { if languages != nil { try? WorkflowState.shared.setLanguage(previousLanguage) } }
        let manager = ClipboardManager.shared
        if manager.clipboardItems.isEmpty {
            let text = try manager.addText("Xclip 验收样例 · Research note\n剪贴板历史支持搜索、分类与原格式保留。")
            var pinned = text; pinned.isFavorite = true; pinned.isPinned = true; pinned.tags = ["工作"]; manager.update(pinned)
            _ = try manager.addText("https://example.com/notes")
            _ = try manager.addText("function transform(input) {\n  return input.trim();\n}")
        }
        WorkflowState.shared.document.stack = Array(manager.clipboardItems.prefix(2))
        WorkflowState.shared.document.replies = [.init(title: "资料已收到", group: "工作 / 回复", item: .init(id: UUID(), content: "已收到，谢谢。我会在今天核对后回复。", type: .text, timestamp: Date()))]
        let views: [(String, AnyView)] = [
            ("workspace", AnyView(ContentView())),
            ("history", AnyView(HistoryView())), ("stack", AnyView(StackView())),
            ("replies", AnyView(RepliesView())), ("shelf", AnyView(ShelfView())),
            ("capture", AnyView(CaptureToolsView())), ("automation", AnyView(AutomationToolsView())),
            ("sync", AnyView(LANSyncView())), ("sharing", AnyView(SharingExtensionsView())), ("settings", AnyView(PreferencesView()))
        ]
        for (name, content) in views {
            for dark in [false, true] {
                let width: CGFloat = dark ? 760 : 840
                let view = NSHostingView(rootView: content.environment(\.colorScheme, dark ? .dark : .light).frame(maxWidth: .infinity, maxHeight: .infinity).background(dark ? Color(nsColor: .windowBackgroundColor) : Color.white))
                let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: width, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); view.appearance = window.appearance; window.backgroundColor = dark ? .windowBackgroundColor : .white; window.contentView = view; window.orderBack(nil)
                view.frame = NSRect(x: 0, y: 0, width: width, height: 650)
                // Reuse the same hosting view while changing language to exercise live invalidation.
                for language in languages ?? [previousLanguage] {
                if languages != nil { try WorkflowState.shared.setLanguage(language) }
                view.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ClipboardError.imageProcessingFailed }
                view.appearance?.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw ClipboardError.imageProcessingFailed }
                let suffix = languages != nil ? "-" + language : ""
                try png.write(to: directory.appendingPathComponent(name + suffix + (dark ? "-dark.png" : "-light.png")))
                }
                window.close()
            }
        }
        try renderQuickPaste(in: directory, manager: manager)
        print("AppRenderTests: \(views.count * 2 * (languages?.count ?? 1) + 6) off-screen layout snapshots rendered; native desktop glass compositing requires on-screen verification")
    }

    @MainActor private static func renderQuickPaste(in directory: URL, manager: ClipboardManager) throws {
        let previousItems = manager.clipboardItems
        let previousLocked = PrivacyLock.shared.locked
        defer { manager.clipboardItems = previousItems; PrivacyLock.shared.locked = previousLocked }
        PrivacyLock.shared.locked = false
        let assets = directory.appendingPathComponent("quick-paste-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let brief = assets.appendingPathComponent("项目简报.txt"), notes = assets.appendingPathComponent("Research Notes.md")
        try Data("项目简报\n快速粘贴交互验收样例。".utf8).write(to: brief)
        try Data("# Research Notes\nSynthetic local rendering fixture.\n".utf8).write(to: notes)
        let image = try QuickPasteTests.sampleImageData()
        let now = Date()
        manager.clipboardItems = [
            ClipboardItem(id: UUID(), content: "海岸 · 设计灵感.png", type: .image, timestamp: now, data: image, sourceApp: "com.apple.Preview", sourceAppName: "预览", tags: ["设计"]),
            ClipboardItem(id: UUID(), content: "周五设计评审\n\n14:30 · 三楼会议室\n请带上更新后的交互稿，我们一起核对快捷键与拖拽体验。", type: .text, timestamp: now.addingTimeInterval(-180), isFavorite: true, sourceApp: "com.apple.Notes", sourceAppName: "备忘录", tags: ["工作"]),
            ClipboardItem(id: UUID(), content: "https://example.com/design-notes", type: .text, timestamp: now.addingTimeInterval(-900), sourceApp: "com.apple.Safari", sourceAppName: "Safari 浏览器"),
            ClipboardItem(id: UUID(), content: "项目简报.txt\nResearch Notes.md", type: .file, timestamp: now.addingTimeInterval(-3600), sourceApp: "com.apple.finder", sourceAppName: "访达", fileURLs: [brief.path, notes.path]),
            ClipboardItem(id: UUID(), content: "func paste(_ item: Clip) {\n    panel.hide(animated: true)\n    destination.insert(item)\n}", type: .code, timestamp: now.addingTimeInterval(-7200), sourceApp: "com.apple.dt.Xcode", sourceAppName: "Xcode", tags: ["开发"]),
            ClipboardItem(id: UUID(), content: "灵感随手收好\n需要的时候，拖过去。", type: .text, timestamp: now.addingTimeInterval(-10800), sourceApp: "com.apple.TextEdit", sourceAppName: "文本编辑")
        ]
        for width: CGFloat in [560, 900, 1360] {
            for dark in [false, true] {
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let content = QuickPasteView()
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .frame(width: width, height: 330)
                    // AppKit glass is a WindowServer composition, which cacheDisplay cannot
                    // capture. Use a neutral backing ONLY in this layout fixture.
                    .background(dark ? Color(white: 0.12) : Color(white: 0.96))
                let view = QuickPasteSurface(rootView: content)
                let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: width, height: 330),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = appearance
                view.appearance = appearance
                window.backgroundColor = .clear
                window.isOpaque = false
                window.contentView = view
                window.orderBack(nil)
                defer { window.close() }
                view.frame = NSRect(x: 0, y: 0, width: width, height: 330)
                view.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                let snapshotView = view.hostingView
                guard let bitmap = snapshotView.bitmapImageRepForCachingDisplay(in: snapshotView.bounds) else { throw ClipboardError.imageProcessingFailed }
                appearance?.performAsCurrentDrawingAppearance { snapshotView.cacheDisplay(in: snapshotView.bounds, to: bitmap) }
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw ClipboardError.imageProcessingFailed }
                let suffix = dark ? "-dark" : "-light"
                try png.write(to: directory.appendingPathComponent("quick-paste-\(Int(width))" + suffix + ".png"))
            }
        }
    }
}
