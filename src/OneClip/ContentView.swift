import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QuickLookUI
import CoreImage.CIFilterBuiltins

struct ContentView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject private var lock = PrivacyLock.shared
    @ObservedObject private var workflow = WorkflowState.shared
    @ObservedObject private var clipboard = ClipboardManager.shared
    @State private var section: String? = "history"
    var body: some View {
        Group {
            if lock.locked { UnlockView() }
            else {
                NavigationSplitView {
                    List(selection: $section) {
                        Section(L("资料库", "Library")) {
                            nav("history", "clock", L("剪贴板历史", "History"))
                            nav("favorites", "star", L("收藏", "Favorites"))
                            nav("stack", "square.stack", L("栈粘贴板", "Paste stack"))
                            nav("replies", "text.bubble", L("快捷回复", "Quick replies"))
                            nav("shelf", "tray.and.arrow.down", L("拖拽容器", "Drop shelf"))
                        }
                        Section(L("工具", "Tools")) {
                            Button { DesktopEvents.shared.show?("capture") } label: {
                                HStack {
                                    Label(L("截屏", "Screenshot"), systemImage: "viewfinder")
                                    Spacer(minLength: 4)
                                    Text((workflow.document.shortcuts["capture"] ?? GlobalShortcuts.defaults["capture"])?.label ?? "")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("sidebar.screenshot")
                            .help(L("直接框选并标注屏幕。快捷键可在设置中修改。", "Select and annotate the screen. Change the shortcut in Settings."))
                            nav("automation", "sparkles", L("AI 与脚本", "AI & scripts"))
                            nav("sync", "network", L("局域网共享", "LAN sharing"))
                            nav("sharing", "square.and.arrow.up", L("上传与翻译", "Upload & translate"))
                            nav("settings", "gearshape", L("设置", "Settings"))
                        }
                    }.listStyle(.sidebar).navigationSplitViewColumnWidth(min: 165, ideal: 185, max: 230)
                    HStack(spacing: 8) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable().scaledToFit().frame(width: 28, height: 28)
                            .accessibilityHidden(true)
                        Text("Xclip").font(.headline)
                    }.padding()
                } detail: {
                    switch section {
                    case "favorites": HistoryView(favoritesOnly: true)
                    case "stack": StackView()
                    case "replies": RepliesView()
                    case "shelf": ShelfView()
                    case "automation": AutomationToolsView()
                    case "sync": LANSyncView()
                    case "sharing": SharingExtensionsView()
                    case "settings": PreferencesView()
                    default: HistoryView()
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if !workflow.status.isEmpty || clipboard.lastError != nil {
                        HStack {
                            Image(systemName: "info.circle")
                            Text(clipboard.lastError ?? workflow.status).font(.callout).textSelection(.enabled).lineLimit(3)
                            Spacer()
                            Button(L("关闭", "Dismiss")) { workflow.status = ""; clipboard.lastError = nil }
                        }.padding(10).background(.bar)
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 540)
        .onReceive(NotificationCenter.default.publisher(for: .init("CClipSection"))) { event in
            let destination = event.object as? String ?? "history"
            if destination == "capture" { DesktopEvents.shared.show?("capture") }
            else { section = destination }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("CClipSearch"))) { event in section = "history"; clipboard.searchText = event.object as? String ?? "" }
    }
    private func nav(_ id: String, _ icon: String, _ title: String) -> some View { Label(title, systemImage: icon).tag(id) }
}

func perform(_ operation: () throws -> Void) {
    guard !PrivacyLock.shared.locked else { return }
    do { try operation() } catch { WorkflowState.shared.status = error.localizedDescription }
}

struct HistoryView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    var favoritesOnly = false
    @ObservedObject private var clipboard = ClipboardManager.shared
    @ObservedObject private var workflow = WorkflowState.shared
    @State private var selected = Set<UUID>()
    @State private var type = "all"
    @State private var source = ""
    @State private var tag = "all"
    @State private var recentDays = 0
    @State private var editItem: ClipboardItem?
    @State private var confirmClear = false
    @FocusState private var searchFocused: Bool
    private var items: [ClipboardItem] {
        clipboard.searchItems(with: clipboard.searchText).filter { item in
            (!favoritesOnly || item.isFavorite) && (type == "all" || item.type.rawValue == type)
                && (source.isEmpty || ClipboardSourceInfo.searchText(for: item).localizedStandardContains(source))
                && (tag == "all" || item.tags.contains(tag))
                && (recentDays == 0 || item.timestamp >= Date().addingTimeInterval(-Double(recentDays * 86400)))
        }
    }
    private var selectedItems: [ClipboardItem] { items.filter { selected.contains($0.id) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("搜索内容、来源或分类", "Search content, source or category"), text: $clipboard.searchText)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .onSubmit { workflow.rememberSearch(clipboard.searchText) }
                if !clipboard.searchText.isEmpty { Button { clipboard.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help(L("清除搜索", "Clear search")) }
                Menu { ForEach(workflow.document.searchHistory, id: \.self) { query in Button(query) { clipboard.searchText = query } } } label: { Image(systemName: "clock.arrow.circlepath") }.help(L("搜索历史", "Recent searches"))
            }.padding(14).background(.bar)
            filters
            if items.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text(L("这里会保存你复制的内容", "Your copied content will appear here")).font(.title3)
                    Text(L("支持文本、图片和文件。可搜索、收藏，或按顺序加入栈。", "Text, images and files. Search, save favorites, or add items to a stack.")).foregroundStyle(.secondary)
                    if !clipboard.isMonitoring { Button(L("开始记录", "Start recording")) { clipboard.startMonitoring() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if workflow.document.layout == "list" {
                List(selection: $selected) {
                    ForEach(items) { item in
                        HistoryRow(item: item, query: clipboard.searchText).tag(item.id)
                            .contextMenu { itemMenu(item) }
                            .onDrag { dragProvider(item) }
                            .onTapGesture(count: 2) { PasteCoordinator.shared.paste(item) }
                    }
                }.listStyle(.inset)
            } else {
                ScrollView(workflow.document.layout == "horizontal" ? .horizontal : .vertical) {
                    if workflow.document.layout == "horizontal" {
                        LazyHStack(spacing: 12) { ForEach(items) { card($0) } }.padding()
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) { ForEach(items) { card($0) } }.padding()
                    }
                }
            }
            Divider()
            HStack {
                Text("\(items.count) " + L("条", "items")).foregroundStyle(.secondary)
                if !selected.isEmpty { Text("· \(selected.count) " + L("已选", "selected")).foregroundStyle(.secondary) }
                Spacer()
                BatchDragView(items: selectedItems, title: L("拖出选中项", "Drag selection")).frame(width: 116, height: 26)
                Button(L("入栈", "Stack")) { selectedItems.forEach(workflow.addToStack) }.disabled(selected.isEmpty)
                Button(L("复制", "Copy")) { copySelection() }.disabled(selected.isEmpty)
                Button(L("粘贴", "Paste")) { if let item = selectedItems.first { PasteCoordinator.shared.paste(item) } }.disabled(selected.count != 1).keyboardShortcut(.return, modifiers: [])
            }.padding(12)
        }
        .navigationTitle(favoritesOnly ? L("收藏", "Favorites") : L("剪贴板历史", "Clipboard history"))
        .toolbar {
            ToolbarItemGroup {
                Button { searchFocused = true } label: { Image(systemName: "magnifyingglass") }.help(L("搜索 ⌘F", "Search ⌘F")).keyboardShortcut("f")
                Picker(L("视图", "Layout"), selection: $workflow.document.layout) {
                    Image(systemName: "list.bullet").tag("list")
                    Image(systemName: "square.grid.2x2").tag("grid")
                    Image(systemName: "rectangle.split.3x1").tag("horizontal")
                }.pickerStyle(.segmented).frame(width: 110)
                Button { clipboard.isMonitoring ? clipboard.stopMonitoring() : clipboard.startMonitoring() } label: { Image(systemName: clipboard.isMonitoring ? "pause.circle" : "play.circle") }.help(clipboard.isMonitoring ? L("暂停记录", "Pause capture") : L("开始记录", "Start capture"))
                Button { clipboard.undoDelete() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!clipboard.canUndo).help(L("撤销删除", "Undo deletion")).keyboardShortcut("z")
                Menu {
                    Button(L("全部收藏", "Favorite selection")) { selectedItems.forEach { FavoriteManager.shared.addToFavorites($0) } }.disabled(selected.isEmpty)
                    Button(L("取消选中项收藏", "Unfavorite selection")) { selectedItems.forEach { var value = $0; value.isFavorite = false; clipboard.update(value) } }.disabled(selected.isEmpty)
                    Button(L("保存选中内容…", "Save selection…")) { exportSelection() }.disabled(selected.isEmpty)
                    Button(L("删除选中", "Delete selection"), role: .destructive) { clipboard.deleteItems(selectedItems); selected.removeAll() }.disabled(selected.isEmpty)
                    Divider()
                    Button(L("清理未收藏历史…", "Clear unprotected history…"), role: .destructive) { confirmClear = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onDeleteCommand { clipboard.deleteItems(selectedItems); selected.removeAll() }
        .sheet(item: $editItem) { ClipEditor(item: $0) }
        .confirmationDialog(L("清理历史？收藏和置顶会保留。", "Clear history? Favorites and pinned items will be kept."), isPresented: $confirmClear) { Button(L("清理", "Clear"), role: .destructive) { clipboard.clearAllItems() } }
    }
    private var filters: some View {
        // Keep built-in option labels readable when the sidebar leaves a narrow detail column.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { typeFilter; categoryFilter; timeFilter; sourceFilter }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { typeFilter; categoryFilter; timeFilter }
                sourceFilter
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { typeFilter; categoryFilter }
                HStack(spacing: 8) { timeFilter; sourceFilter }
            }
        }.padding(10)
    }
    private var typeFilter: some View {
        Picker(L("类型", "Type"), selection: $type) {
            Text(L("全部类型", "All types")).tag("all")
            ForEach([ClipboardItemType.text, .image, .file, .video, .audio, .document, .code, .archive, .executable], id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
        }.frame(width: 180)
    }
    private var categoryFilter: some View {
        Picker(L("分类", "Category"), selection: $tag) {
            Text(L("全部分类", "All categories")).tag("all")
            ForEach(workflow.document.categories) { Text($0.name).tag($0.name) }
        }.frame(width: 180)
    }
    private var timeFilter: some View {
        Picker(L("时间", "Time"), selection: $recentDays) {
            Text(L("不限时间", "Any time")).tag(0); Text(L("最近 24 小时", "Last 24h")).tag(1); Text(L("7 天", "7 days")).tag(7); Text(L("30 天", "30 days")).tag(30)
        }.frame(width: 150)
    }
    private var sourceFilter: some View {
        TextField(L("来源应用名称或标识", "Source app name or identifier"), text: $source)
            .textFieldStyle(.roundedBorder).frame(minWidth: 240)
            .accessibilityLabel(L("来源应用名称或标识", "Source app name or identifier"))
    }
    private func card(_ item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ClipPreview(item: item, showsSource: false).frame(height: 155).clipped()
            HistoryRow(item: item, query: clipboard.searchText)
        }.padding(12).frame(width: workflow.document.layout == "horizontal" ? 245 : nil)
            .background(selected.contains(item.id) ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected.contains(item.id) ? Color.accentColor : Color.primary.opacity(0.1)))
            .onTapGesture { if NSEvent.modifierFlags.contains(.command) { if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) } } else { selected = [item.id] } }
            .onTapGesture(count: 2) { PasteCoordinator.shared.paste(item) }
            .contextMenu { itemMenu(item) }.onDrag { dragProvider(item) }
    }
    @ViewBuilder private func itemMenu(_ item: ClipboardItem) -> some View {
        Button(L("复制原格式", "Copy original")) { clipboard.copyToClipboard(item: item) }
        Button(L("粘贴", "Paste")) { PasteCoordinator.shared.paste(item) }
        Button(L("粘贴纯文本", "Paste plain text")) { PasteCoordinator.shared.paste(item, plainText: true) }
        Divider()
        Button(item.isFavorite ? L("取消收藏", "Unfavorite") : L("收藏", "Favorite")) { FavoriteManager.shared.toggleFavorite(item) }
        Button(item.isPinned ? L("取消置顶", "Unpin") : L("置顶", "Pin")) { var value = item; value.isPinned.toggle(); clipboard.update(value) }
        Menu(L("分类", "Category")) { ForEach(workflow.document.categories) { category in
            Button((item.tags.contains(category.name) ? "✓ " : "") + category.name) { var value = item; if value.tags.contains(category.name) { value.tags.removeAll { $0 == category.name } } else { value.tags.append(category.name) }; clipboard.update(value) }
        } }
        Button(L("编辑与预览…", "Edit & preview…")) { editItem = item }
        Button(L("加入栈", "Add to stack")) { workflow.addToStack(item) }
        Button(L("加入拖拽容器", "Add to shelf")) { workflow.document.shelf.append(item) }
        Button(L("存为快捷回复", "Save as reply")) { workflow.document.replies.append(.init(title: String(item.content.prefix(40)), item: item)) }
        Button(L("共享到局域网", "Share over LAN")) { perform { try LANSyncService.shared.publish(item: item) } }
        Button(L("贴在桌面", "Float on desktop")) { FloatingClips.shared.show(item) }
        Divider()
        Button(L("删除", "Delete"), role: .destructive) { clipboard.deleteItem(item) }
    }
    private func copySelection() {
        perform { try clipboard.writeItemsToClipboard(selectedItems) }
    }
    private func exportSelection() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        perform { for item in selectedItems { try saveClip(item, to: directory) } }
    }
}

struct ClipboardTimestamp: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    let timestamp: Date
    var body: some View {
        TimelineView(.periodic(from: timestamp, by: 60)) { context in
            Text(label(relativeTo: context.date))
        }
    }

    private func label(relativeTo now: Date) -> String {
        guard abs(timestamp.timeIntervalSince(now)) >= 60 else {
            return L("刚刚", "Just now")
        }
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: now, to: timestamp
        )
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = appLanguage.locale
        formatter.unitsStyle = .full
        return formatter.localizedString(from: components)
    }
}

struct HistoryRow: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    let item: ClipboardItem
    var query = ""
    private var title: AttributedString {
        var result = AttributedString(String(item.displayContent.prefix(300)))
        if !query.isEmpty, let range = result.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) { result[range].backgroundColor = .yellow.opacity(0.5); result[range].foregroundColor = .black }
        return result
    }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.type.icon).font(.title3).foregroundStyle(Color.accentColor).frame(width: 25).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).lineLimit(2)
                HStack(spacing: 5) {
                    if item.isPinned { Image(systemName: "pin.fill").accessibilityLabel(L("置顶", "Pinned")) }
                    if item.isFavorite { Image(systemName: "star.fill").accessibilityLabel(L("收藏", "Favorite")) }
                    ClipboardTimestamp(timestamp: item.timestamp)
                    Text("·").accessibilityHidden(true)
                    ClipboardSourceBadge(item: item)
                    if !item.tags.isEmpty { Text("· " + item.tags.joined(separator: ", ")) }
                    if WorkflowState.shared.pastedIDs.contains(item.id) { Image(systemName: "checkmark.circle").accessibilityLabel(L("已粘贴", "Pasted")) }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 7)
    }
}
struct ClipPreview: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    let item: ClipboardItem
    var showsSource = true
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsSource {
                ClipboardSourceBadge(item: item).font(.caption).foregroundStyle(.secondary)
            }
            Group {
                if item.type == .image, let image = imageForClip(item) { Image(nsImage: image).resizable().scaledToFit() }
                else if item.type == .text || item.type == .code { ScrollView { Text(item.content).font(item.type == .code ? .system(.body, design: .monospaced) : .body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) } }
                else { VStack { Image(systemName: item.type.icon).font(.system(size: 40)); Text(item.displayContent).lineLimit(3); if let path = item.filePath { Button(L("快速查看", "Quick Look")) { quickLook(URL(fileURLWithPath: path)) } } } }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
func imageForClip(_ item: ClipboardItem) -> NSImage? { item.data.flatMap(NSImage.init(data:)) ?? item.filePath.flatMap(NSImage.init(contentsOfFile:)) }
func dragProvider(_ item: ClipboardItem) -> NSItemProvider {
    if let path = item.filePath { return NSItemProvider(contentsOf: URL(fileURLWithPath: path)) ?? NSItemProvider(object: item.content as NSString) }
    if let image = imageForClip(item) { return NSItemProvider(object: image) }
    return NSItemProvider(object: item.content as NSString)
}
func saveClip(_ item: ClipboardItem, to directory: URL) throws {
    let prefix = String(item.id.uuidString.prefix(8))
    let paths = item.fileURLs ?? item.filePath.map { [$0] } ?? []
    if !paths.isEmpty {
        for (index, path) in paths.enumerated() { let url = URL(fileURLWithPath: path); try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(prefix + "-\(index + 1)-" + url.lastPathComponent)) }
    } else if item.type == .image, let image = imageForClip(item), let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
        try png.write(to: directory.appendingPathComponent(prefix + ".png"))
    } else { try item.content.write(to: directory.appendingPathComponent(prefix + ".txt"), atomically: true, encoding: .utf8) }
}
private final class PreviewSource: NSObject, QLPreviewPanelDataSource {
    static let shared = PreviewSource(); var url: URL?
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { url as NSURL? }
}
func closeClipPreview() {
    PreviewSource.shared.url = nil
    if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared()?.dataSource = nil; QLPreviewPanel.shared()?.orderOut(nil) }
}
func quickLook(_ url: URL) { guard !PrivacyLock.shared.locked else { return }; PreviewSource.shared.url = url; let panel = QLPreviewPanel.shared(); panel?.dataSource = PreviewSource.shared; panel?.reloadData(); panel?.makeKeyAndOrderFront(nil) }

struct ClipEditor: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    let item: ClipboardItem
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var markdown = false
    @State private var qr: NSImage?
    @State private var saveError: Error?
    var body: some View {
        VStack(spacing: 14) {
            HStack { Text(ClipboardEditing.title(for: item)).font(.title2); Spacer(); Button(L("关闭", "Close"), action: close).keyboardShortcut(.cancelAction) }
            Text(ClipboardSourceInfo.detail(for: item))
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if item.type == .image, let image = imageForClip(item), let data = image.tiffRepresentation {
                ImageEditorView(imageData: data, onExport: saveImage)
            } else if ClipboardEditing.isTextEditable(item) {
                if markdown { ScrollView { Text(.init(content)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
                else { TextEditor(text: $content).font(.system(.body, design: .monospaced)).border(Color.secondary.opacity(0.2)) }
                HStack {
                    Toggle(L("Markdown 预览", "Markdown preview"), isOn: $markdown).toggleStyle(.switch)
                    Button(L("分词", "Tokenize")) { let words = content.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }; WorkflowState.shared.splitLines(words.joined(separator: "\n")); WorkflowState.shared.status = L("已按空白分词并加入栈。", "Words split by whitespace were added to the stack.") }
                    Button(L("二维码", "QR code")) { let filter = CIFilter.qrCodeGenerator(); filter.message = Data(content.utf8); if let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), let cg = CIContext().createCGImage(image, from: image.extent) { qr = NSImage(cgImage: cg, size: .zero) } }
                    Menu(L("导出", "Export")) { ForEach(["txt", "md", "rtf"], id: \.self) { ext in Button(ext.uppercased()) { exportText(ext) } } }
                    Spacer()
                    Button(L("保存", "Save"), action: saveText).keyboardShortcut(.defaultAction)
                }
                if let qr { Image(nsImage: qr).interpolation(.none).resizable().scaledToFit().frame(height: 180); Button(L("复制二维码", "Copy QR")) { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([qr]) } }
            } else { ClipPreview(item: item, showsSource: false) }
            if let saveError {
                Text(saveError.localizedDescription).font(.callout).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }.padding(20).frame(minWidth: 640, minHeight: 490).onAppear { content = item.content }
    }
    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
    private func saveText() {
        do { try ClipboardEditing.saveText(id: item.id, content: content); close() }
        catch { saveError = error }
    }
    private func saveImage(_ data: Data) {
        do { try ClipboardEditing.saveImage(id: item.id, data: data); close() }
        catch { saveError = error }
    }
    private func exportText(_ ext: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = L("剪贴板内容", "clip") + "." + ext
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            if ext == "rtf" {
                let text = NSAttributedString(string: content)
                guard let data = text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [:]) else { throw ClipboardError.dataCorrupted }
                try data.write(to: url)
            } else { try content.write(to: url, atomically: true, encoding: .utf8) }
        }
    }
}

struct StackView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject private var state = WorkflowState.shared
    @State private var text = ""
    @State private var separator = "\\n"
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("依次粘贴，让多次复制有顺序", "Give multiple copies a paste order")).font(.title2)
                Spacer()
                Toggle(L("收集新复制", "Collect copies"), isOn: $state.stackCollecting).toggleStyle(.switch)
            }
            HStack {
                Toggle(L("⌘V 依次粘贴", "Sequential ⌘V paste"), isOn: $state.stackPasting).toggleStyle(.switch).onChange(of: state.stackPasting) { _, _ in DesktopEvents.shared.configure() }
                Text(L("需要辅助功能权限；按列表从上到下。", "Requires Accessibility. Items are pasted top to bottom.")).foregroundStyle(.secondary)
            }
            List {
                ForEach(Array(state.document.stack.enumerated()), id: \.element.id) { index, item in
                    HStack {
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                        HistoryRow(item: item)
                        Button { if index > 0 { state.document.stack.swapAt(index, index - 1) } } label: { Image(systemName: "arrow.up") }.disabled(index == 0).help(L("上移", "Move up"))
                        Button { PasteCoordinator.shared.paste(item) { if let current = state.document.stack.firstIndex(where: { $0.id == item.id }) { state.document.stack.remove(at: current) } } } label: { Image(systemName: "doc.on.clipboard") }.help(L("粘贴此项", "Paste item"))
                        Button { state.document.stack.remove(at: index) } label: { Image(systemName: "minus.circle") }.help(L("移除", "Remove"))
                    }.onDrag { dragProvider(item) }
                }.onMove { state.document.stack.move(fromOffsets: $0, toOffset: $1) }
            }.overlay { if state.document.stack.isEmpty { Text(L("从历史菜单加入项目，或在下方按行添加。", "Add items from history or split text below.")).foregroundStyle(.secondary) } }
            HStack {
                TextField(L("输入内容，换行拆分", "Enter text to split by lines"), text: $text, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                Button(L("按行加入", "Split lines")) { state.splitLines(text); text = "" }.disabled(text.isEmpty)
            }
            HStack {
                Text(L("分隔符", "Separator"))
                TextField("\\n", text: $separator).frame(width: 90).help(L("\\n 表示换行，\\t 表示制表符", "\\n inserts a newline; \\t inserts a tab"))
                Button(L("合并复制", "Copy joined")) { let delimiter = separator.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t"); let item = ClipboardItem(id: UUID(), content: state.document.stack.map(\.content).joined(separator: delimiter), type: .text, timestamp: Date()); ClipboardManager.shared.copyToClipboard(item: item) }.disabled(state.document.stack.isEmpty)
                Spacer()
                Button(L("清空栈", "Clear stack")) { state.document.stack.removeAll(); state.stackPasting = false }
            }
        }.padding(20).navigationTitle(L("栈粘贴板", "Paste stack"))
    }
}

struct RepliesView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject private var state = WorkflowState.shared
    @State private var search = ""
    @State private var title = ""
    @State private var text = ""
    @State private var group = ""
    @State private var editing: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(L("搜索快捷回复", "Search replies"), text: $search).textFieldStyle(.roundedBorder)
            List {
                ForEach(state.document.replies.filter { search.isEmpty || ($0.title + $0.group + $0.item.content).localizedStandardContains(search) }) { reply in
                    HStack {
                        VStack(alignment: .leading) { Text(reply.title).font(.headline); Text(reply.group).font(.caption).foregroundStyle(.secondary); Text(reply.item.displayContent).lineLimit(2) }
                        Spacer()
                        if let hotkey = reply.hotkey { Text(hotkey.label).font(.caption) }
                        Button(L("粘贴", "Paste")) { PasteCoordinator.shared.paste(reply.item) }
                        Menu {
                            Button(L("编辑", "Edit")) { editing = reply.id; title = reply.title; text = reply.item.content; group = reply.group }
                            Button(L("设置快捷键…", "Set shortcut…")) { ShortcutRecorder.shared.record { spec in if let index = state.document.replies.firstIndex(where: { $0.id == reply.id }) { state.document.replies[index].hotkey = spec; NotificationCenter.default.post(name: .init("CClipShortcutsChanged"), object: nil) } } }
                            Button(L("清除快捷键", "Clear shortcut")) { if let i = state.document.replies.firstIndex(where: { $0.id == reply.id }) { state.document.replies[i].hotkey = nil; NotificationCenter.default.post(name: .init("CClipShortcutsChanged"), object: nil) } }
                            Button(L("删除", "Delete"), role: .destructive) { state.document.replies.removeAll { $0.id == reply.id }; NotificationCenter.default.post(name: .init("CClipShortcutsChanged"), object: nil) }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }.padding(.vertical, 6)
                }.onMove { state.document.replies.move(fromOffsets: $0, toOffset: $1) }
            }
            Divider()
            HStack { TextField(L("标题", "Title"), text: $title); TextField(L("分类 / 子分类", "Group / subgroup"), text: $group) }.textFieldStyle(.roundedBorder)
            TextEditor(text: $text).frame(height: 90).border(Color.secondary.opacity(0.2))
            HStack {
                Button(L("添加图片或文件…", "Add images or files…")) { addFiles() }
                Spacer()
                if editing != nil { Button(L("取消编辑", "Cancel edit")) { editing = nil; text = ""; title = "" } }
                Button(editing == nil ? L("添加回复", "Add reply") : L("保存", "Save")) { saveReply() }.disabled(title.isEmpty || text.isEmpty)
            }
        }.padding(20).navigationTitle(L("快捷回复", "Quick replies"))
        .toolbar { Menu(L("导入 / 导出", "Import / export")) {
            Button(L("导出模板…", "Export templates…")) { let p = NSSavePanel(); p.nameFieldStringValue = L("快捷回复", "replies") + ".cclipreplies"; if p.runModal() == .OK, let url = p.url { perform { try state.exportReplies(to: url) } } }
            Button(L("导入模板…", "Import templates…")) { let p = NSOpenPanel(); if p.runModal() == .OK, let url = p.url { perform { try state.importReplies(from: url) } } }
        } }
    }
    private func saveReply() {
        if let editing, let index = state.document.replies.firstIndex(where: { $0.id == editing }) {
            state.document.replies[index].title = title; state.document.replies[index].group = group
            if state.document.replies[index].item.type == .text { state.document.replies[index].item.content = text; state.document.replies[index].item.representations = nil }
        } else { state.document.replies.append(.init(title: title, group: group, item: .init(id: UUID(), content: text, type: .text, timestamp: Date()))) }
        NotificationCenter.default.post(name: .init("CClipShortcutsChanged"), object: nil)
        editing = nil; title = ""; text = ""
    }
    private func addFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        perform {
            var item = ClipboardItem(id: UUID(), content: panel.urls.map(\.lastPathComponent).joined(separator: "\n"), type: .file, timestamp: Date(), filePath: panel.urls[0].path)
            item.fileURLs = panel.urls.map(\.path); item = try ClipboardManager.shared.store.upsert(item)
            state.document.replies.append(.init(title: title.isEmpty ? item.content : title, group: group, item: item))
        }
    }
}

struct ShelfView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject private var state = WorkflowState.shared
    @State private var targeted = false
    var body: some View {
        VStack(spacing: 16) {
            Label(L("文件与图片的临时落脚处", "A temporary home for files and images"), systemImage: "tray.and.arrow.down").font(.title2)
            Text(L("拖进来暂存，再拖到其他应用。也可以用添加按钮。", "Drop items here, then drag them into another app. You can also use Add.")).foregroundStyle(.secondary)
            List {
                ForEach(Array(state.document.shelf.enumerated()), id: \.offset) { index, item in
                    HStack { HistoryRow(item: item); Spacer(); Button(L("复制", "Copy")) { ClipboardManager.shared.copyToClipboard(item: item) }; Button { state.document.shelf.remove(at: index) } label: { Image(systemName: "xmark.circle") }.help(L("移除", "Remove")) }.onDrag { dragProvider(item) }
                }
            }.overlay(RoundedRectangle(cornerRadius: 10).stroke(targeted ? Color.accentColor : .clear, lineWidth: 3))
            HStack {
                Button(L("添加文件…", "Add files…")) { let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = true; if panel.runModal() == .OK { addURLs(panel.urls) } }
                BatchDragView(items: state.document.shelf, title: L("全部拖出", "Drag all")).frame(width: 105, height: 26)
                Button(L("批量复制", "Copy all")) { perform { try ClipboardManager.shared.writeItemsToClipboard(state.document.shelf) } }.disabled(state.document.shelf.isEmpty)
                Spacer(); Button(L("清空容器", "Clear shelf")) { state.document.shelf.removeAll() }
            }
        }.padding(20).navigationTitle(L("拖拽容器", "Drop shelf"))
            .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier, UTType.utf8PlainText.identifier], isTargeted: $targeted) { providers in
                for provider in providers {
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { value, _ in
                            let url = (value as? URL) ?? (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                            if let url { DispatchQueue.main.async { addURLs([url]) } }
                        }
                    } else if provider.canLoadObject(ofClass: NSImage.self) {
                        _ = provider.loadObject(ofClass: NSImage.self) { object, _ in if let image = object as? NSImage, let data = image.tiffRepresentation { DispatchQueue.main.async { perform { let item = try ClipboardManager.shared.addImage(data); state.document.shelf.append(item) } } } }
                    } else {
                        _ = provider.loadObject(ofClass: NSString.self) { value, _ in if let text = value as? String { DispatchQueue.main.async { guard !PrivacyLock.shared.locked else { return }; state.document.shelf.append(.init(id: UUID(), content: text, type: .text, timestamp: Date())) } } }
                    }
                }; return !providers.isEmpty
            }
    }
    private func addURLs(_ urls: [URL]) { perform { for url in urls where url.isFileURL { var item = ClipboardItem(id: UUID(), content: url.lastPathComponent, type: ClipboardManager.fileType(url), timestamp: Date(), filePath: url.path); item.fileURLs = [url.path]; item = try ClipboardManager.shared.store.upsert(item); state.document.shelf.append(item) } } }
}

struct UnlockView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject private var lock = PrivacyLock.shared
    @State private var password = ""
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield").font(.system(size: 48)).foregroundStyle(Color.accentColor)
            Text(L("剪贴板已锁定", "Clipboard is locked")).font(.title)
            SecureField(L("密码", "Password"), text: $password).textFieldStyle(.roundedBorder).frame(width: 280).onSubmit { lock.unlock(password: password); password = "" }
            HStack { Button(L("解锁", "Unlock")) { lock.unlock(password: password); password = "" }; Button(L("使用系统验证", "Use system authentication")) { lock.unlockBiometric() } }.disabled(lock.busy)
            if lock.busy { ProgressView().controlSize(.small) }
            if !lock.error.isEmpty { Text(lock.error).foregroundStyle(.red) }
            Text(L("锁定期间暂停捕获，隐藏历史、快捷面板和共享内容。", "Capture pauses and all history, quick panels and sharing are hidden while locked.")).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
