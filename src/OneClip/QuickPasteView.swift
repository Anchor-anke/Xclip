import SwiftUI
import AppKit

private enum QuickPasteFilter: String, CaseIterable {
    case all, favorites, text, links, images, files
    var title: String {
        switch self {
        case .all: return L("剪贴板", "Clipboard")
        case .favorites: return L("收藏", "Favorites")
        case .text: return L("文本", "Text")
        case .links: return L("链接", "Links")
        case .images: return L("图片", "Images")
        case .files: return L("文件", "Files")
        }
    }
    var icon: String {
        switch self {
        case .all: return "clock.arrow.circlepath"
        case .favorites: return "star.fill"
        case .text: return "text.alignleft"
        case .links: return "link"
        case .images: return "photo"
        case .files: return "folder"
        }
    }
    func includes(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all: return true
        case .favorites: return item.isFavorite
        case .text: return (item.type == .text || item.type == .code) && quickPasteURL(item) == nil
        case .links: return quickPasteURL(item) != nil
        case .images: return item.type == .image
        case .files: return item.type != .image && (!(item.fileURLs ?? []).isEmpty || item.filePath != nil || (item.type != .text && item.type != .code))
        }
    }
}

func quickPasteURL(_ item: ClipboardItem) -> URL? {
    guard item.type == .text else { return nil }
    let text = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.contains(where: { $0.isWhitespace }), let url = URL(string: text),
          ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
    return url
}

func quickPasteKind(_ item: ClipboardItem) -> String {
    quickPasteURL(item) != nil ? L("链接", "Link") : item.type.displayName
}

private enum QuickPasteMessage {
    case localized(String, String)
    case external(String)
    case failure(Error)
    case clipboardError(String, String)

    var text: String {
        switch self {
        case let .localized(zh, en): return L(zh, en)
        case let .external(value): return value
        case let .failure(error): return error.localizedDescription
        case let .clipboardError(zh, en): return ClipboardManager.shared.lastError ?? L(zh, en)
        }
    }
}

struct QuickPasteView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    var onOpen: () -> Void = {}
    var onClose: () -> Void = {}
    var onDragBegan: () -> Void = {}
    var onDragEnded: (Bool) -> Void = { _ in }
    var onEdit: (ClipboardItem, @escaping () -> Void) -> Void = { _, closed in closed() }
    var onContextMenuTrackingChanged: (Bool) -> Void = { _ in }
    @ObservedObject private var clipboard = ClipboardManager.shared
    @ObservedObject private var lock = PrivacyLock.shared
    @ObservedObject private var workflow = WorkflowState.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var query = ""
    @State private var filter: QuickPasteFilter = .all
    @State private var selection: UUID?
    @State private var message: QuickPasteMessage?
    @State private var items: [ClipboardItem] = []
    @State private var dragging = false
    @State private var contextMenuOpen = false
    @State private var editing = false
    @FocusState private var searchFocused: Bool

    private var messageText: String { message?.text ?? "" }
    private var textColor: Color { colorScheme == .dark ? Color(white: 0.95) : Color(white: 0.10) }
    private var selectedItem: ClipboardItem? { items.first { $0.id == selection } ?? items.first }
    private var selectedIndex: Int { items.firstIndex { $0.id == selection } ?? 0 }

    var body: some View {
        Group {
            if lock.locked { UnlockView() }
            else {
                VStack(spacing: 0) {
                    toolbar.padding(.horizontal, 18).frame(height: 52)
                    Divider().opacity(0.22).padding(.horizontal, 18)
                    cardStrip
                    footer.padding(.horizontal, 18).frame(height: 35)
                }
                .disabled(editing)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .background(QuickPasteKeyReader(handle: handleKey))
                .onAppear { refreshItems(clipboard.clipboardItems); searchFocused = true }
                .onReceive(clipboard.$clipboardItems) { refreshItems($0) }
                .onChange(of: query) { _, _ in resetSelection() }
                .onChange(of: filter) { _, _ in resetSelection() }
                .onChange(of: workflow.status) { _, value in message = .external(value) }
            }
        }
        .foregroundStyle(textColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("搜索剪贴板", "Search clipboard"), text: $query)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .accessibilityLabel(L("搜索剪贴板", "Search clipboard"))
                if !query.isEmpty {
                    Button { query = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help(L("清除搜索", "Clear search"))
                }
            }
            .padding(.horizontal, 10).frame(minWidth: 125, idealWidth: 200, maxWidth: 230).frame(height: 30)
            .background(Color(nsColor: .controlBackgroundColor).opacity(reduceTransparency ? 1 : 0.36), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(colorScheme == .dark ? 0.12 : 0.45), lineWidth: 0.7))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(QuickPasteFilter.allCases, id: \.self) { value in
                        Button { filter = value } label: {
                            Label(value.title, systemImage: value.icon)
                                .font(.system(size: 12, weight: filter == value ? .semibold : .medium))
                                .padding(.horizontal, 11).frame(height: 29)
                                .background(filter == value ? Color.accentColor.opacity(0.14) : .clear, in: Capsule())
                                .foregroundStyle(filter == value ? Color.accentColor : textColor)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(filter == value ? .isSelected : [])
                    }
                }
            }
            Button(action: onOpen) { Image(systemName: "square.grid.2x2").frame(width: 26, height: 28) }
                .buttonStyle(.plain).help(L("打开资料库", "Open library"))
                .accessibilityLabel(L("打开资料库", "Open library"))
            Button(action: onClose) { Image(systemName: "xmark").frame(width: 26, height: 28) }
                .buttonStyle(.plain).help(L("关闭 · Esc", "Close · Esc"))
                .accessibilityLabel(L("关闭快速粘贴", "Close quick paste"))
        }
    }

    private var cardStrip: some View {
        ScrollViewReader { proxy in
            Group {
                if items.isEmpty {
                    VStack(spacing: 9) {
                        Image(systemName: query.isEmpty ? "doc.on.clipboard" : "magnifyingglass").font(.system(size: 28)).foregroundStyle(.secondary)
                        Text(query.isEmpty && filter == .all ? L("复制一点内容，从这里开始", "Copy something to get started") : L("没有找到匹配的内容", "No matching clips"))
                            .font(.system(size: 15, weight: .medium))
                        Text(L("复制的文字、图片和文件会出现在这里", "Copied text, images and files appear here"))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 14) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                QuickPasteDragView(
                                    item: item,
                                    content: AnyView(QuickPasteCard(item: item, index: index, selected: selectedItem?.id == item.id).environment(\.colorScheme, colorScheme)),
                                    isSelected: selectedItem?.id == item.id,
                                    onSelect: { selection = item.id; searchFocused = false; message = nil },
                                    onActivate: { paste(item) },
                                    onDragBegan: { dragging = true; onDragBegan() },
                                    onDragEnded: { success in
                                        dragging = false
                                        if !success {
                                            message = .localized("未完成拖放，可重试或点击“复制”后粘贴。", "Drop not completed. Try again, or copy and paste instead.")
                                        }
                                        onDragEnded(success)
                                    },
                                    onContextAction: performContextAction,
                                    onContextMenuTrackingChanged: { active in contextMenuOpen = active; onContextMenuTrackingChanged(active) },
                                    isInteractionEnabled: !editing
                                )
                                .frame(width: 196, height: 226)
                                .id(item.id)
                            }
                        }.padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 7)
                            .background(QuickPasteWheelScroll(isEnabled: !dragging && !editing && !contextMenuOpen))
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .onChange(of: selection) { _, id in
                if let id {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { proxy.scrollTo(id) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if messageText.isEmpty {
                Image(systemName: "hand.draw").foregroundStyle(.secondary)
                Text(L("拖出即可粘贴", "Drag a card to paste")).font(.system(size: 12, weight: .medium))
                Text(L("滚轮浏览 · ← → 选择 · ↵ 粘贴 · ⌘1–9", "Scroll to browse · ← → Select · ↵ Paste · ⌘1–9"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(messageText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).help(messageText)
            }
            Spacer(minLength: 0)
            if clipboard.canUndo {
                Button { clipboard.undoDelete(); message = .clipboardError("已撤销删除", "Deletion undone") } label: { Image(systemName: "arrow.uturn.backward") }
                    .help(L("撤销删除", "Undo deletion")).accessibilityLabel(L("撤销删除", "Undo deletion"))
            }
            Text(items.isEmpty ? "0" : "\(selectedIndex + 1) / \(items.count)")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            Button { if let selectedItem { copy(selectedItem) } } label: { Image(systemName: "doc.on.doc") }
                .help(L("复制选中内容", "Copy selected clip")).disabled(selectedItem == nil)
                .accessibilityLabel(L("复制选中内容", "Copy selected clip"))
            Button(L("粘贴", "Paste")) { if let selectedItem { paste(selectedItem) } }
                .disabled(selectedItem == nil)
        }.buttonStyle(.borderless)
    }

    private func refreshItems(_ source: [ClipboardItem]) {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        items = source.filter { item in
            guard filter.includes(item) else { return false }
            guard !words.isEmpty else { return true }
            let searchable = ([item.content, ClipboardSourceInfo.searchText(for: item)] + item.tags).joined(separator: " ")
            return words.allSatisfy { searchable.localizedStandardContains($0) }
        }
        if selection == nil || !items.contains(where: { $0.id == selection }) { selection = items.first?.id }
    }
    private func resetSelection() {
        refreshItems(clipboard.clipboardItems)
        selection = items.first?.id; message = nil
    }
    private func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        selection = items[min(items.count - 1, max(0, selectedIndex + delta))].id
    }
    private func paste(_ item: ClipboardItem) {
        guard !lock.locked, !editing else { return }
        workflow.status = ""; message = nil
        PasteCoordinator.shared.paste(item, completion: onClose)
        message = .external(workflow.status)
    }
    private func copy(_ item: ClipboardItem) {
        guard !lock.locked, !editing else { return }
        do { try clipboard.writeToClipboard(item); onClose() }
        catch { message = .failure(error) }
    }
    private func performContextAction(_ action: QuickPasteContextAction, id: UUID) {
        guard !lock.locked, !editing, !dragging,
              var item = clipboard.clipboardItems.first(where: { $0.id == id }) else { return }
        selection = id
        searchFocused = false
        do {
            switch action {
            case .edit:
                editing = true
                onEdit(item) { editing = false }
            case .favorite:
                item.isFavorite.toggle()
                try clipboard.ingest(item)
                message = item.isFavorite ? .localized("已收藏", "Added to favorites") : .localized("已取消收藏", "Removed from favorites")
            case .pin:
                item.isPinned.toggle()
                try clipboard.ingest(item)
                message = item.isPinned ? .localized("已置顶", "Pinned") : .localized("已取消置顶", "Unpinned")
            case .copy: copy(item)
            case .paste: paste(item)
            case .delete:
                clipboard.deleteItem(item)
                message = .clipboardError("已删除，可在右侧撤销", "Deleted. Undo on the right.")
            }
        } catch { message = .failure(error) }
    }
    private func handleKey(_ event: NSEvent) -> Bool {
        guard !lock.locked, !dragging, !contextMenuOpen, !editing else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            if event.charactersIgnoringModifiers?.lowercased() == "f" { searchFocused = true; return true }
            if let text = event.charactersIgnoringModifiers, let digit = Int(text), (1...9).contains(digit) {
                if items.indices.contains(digit - 1) { paste(items[digit - 1]) }; return true
            }
            return false
        }
        // The field editor must keep arrows for moving the caret and choosing IME candidates.
        let editor = (NSApp.keyWindow?.firstResponder as? NSTextView)
        if editor?.hasMarkedText() == true { return false }
        switch event.keyCode {
        case 53: onClose(); return true
        case 36, 76: if let selectedItem { paste(selectedItem) }; return true
        case 123, 124:
            guard !searchFocused || query.isEmpty, !flags.contains(.option), !flags.contains(.shift) else { return false }
            moveSelection(event.keyCode == 123 ? -1 : 1); return true
        case 125: moveSelection(1); return true
        case 126: moveSelection(-1); return true
        default: return false
        }
    }
}

private struct QuickPasteCard: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    let item: ClipboardItem
    let index: Int
    let selected: Bool
    private var url: URL? { quickPasteURL(item) }
    private var tint: Color {
        if url != nil { return Color(red: 0.12, green: 0.48, blue: 0.31) }
        switch item.type {
        case .image: return Color(red: 0.76, green: 0.18, blue: 0.34)
        case .code: return Color(red: 0.40, green: 0.30, blue: 0.68)
        case .audio, .video: return Color(red: 0.65, green: 0.25, blue: 0.47)
        case .text: return Color(red: 0.13, green: 0.39, blue: 0.76)
        default: return Color(red: 0.58, green: 0.36, blue: 0.12)
        }
    }
    private var kind: String { quickPasteKind(item) }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ClipboardSourceInfo.name(for: item))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).truncationMode(.tail)
                        .accessibilityLabel(ClipboardSourceInfo.detail(for: item))
                    ClipboardTimestamp(timestamp: item.timestamp).font(.system(size: 10)).opacity(0.85).lineLimit(1)
                }
                Spacer(minLength: 0)
                sourceIcon
            }
            .foregroundStyle(.primary).padding(.horizontal, 12).frame(height: 53)
            .background(tint.opacity(colorScheme == .dark ? 0.16 : 0.07))
            .help(ClipboardSourceInfo.detail(for: item))
            preview.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            HStack(spacing: 5) {
                if item.isFavorite { Image(systemName: "star.fill").foregroundStyle(tint) }
                if item.isPinned { Image(systemName: "pin.fill").foregroundStyle(tint) }
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                Label(kind, systemImage: url == nil ? item.type.icon : "link")
                    .lineLimit(1).layoutPriority(1)
                Spacer(minLength: 2)
                if index < 9 { Text("⌘\(index + 1)").monospaced() }
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 30)
                .help(ClipboardSourceInfo.detail(for: item) + "\n" + metadata)
        }
        .foregroundStyle(colorScheme == .dark ? Color(white: 0.95) : Color(white: 0.10))
        .background(Color(nsColor: .controlBackgroundColor).opacity(reduceTransparency ? 1 : (colorScheme == .dark ? 0.66 : 0.64)))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(selected ? Color.accentColor : Color.white.opacity(colorScheme == .dark ? 0.16 : 0.70), lineWidth: selected ? 2.5 : 0.8))
        .shadow(color: .black.opacity(selected ? 0.10 : 0.04), radius: selected ? 4 : 2, y: 2)
        .padding(4)
    }
    private var sourceIcon: some View {
        Group {
            if let icon = ClipboardSourceInfo.icon(for: item) {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: ClipboardSourceInfo.isKnown(item) ? "app" : "questionmark.app")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 31, height: 31)
                    .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .frame(width: 31, height: 31)
        .accessibilityHidden(true)
    }
    @ViewBuilder private var preview: some View {
        if item.type == .image, let image = imageForClip(item) {
            GeometryReader { geometry in
                Image(nsImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
            }
        } else if let url {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "link.circle.fill").font(.system(size: 33)).foregroundStyle(tint)
                Text(url.host ?? "").font(.system(size: 15, weight: .semibold)).lineLimit(2)
                Text(item.content).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                Spacer(minLength: 0)
            }.padding(13).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if item.type == .text || (item.type == .code && item.filePath == nil) {
            Text(String(item.content.prefix(1400)))
                .font(.system(size: 13, design: item.type == .code ? .monospaced : .default))
                .lineSpacing(3).lineLimit(7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(13)
        } else {
            VStack(spacing: 10) {
                if let path = item.filePath ?? item.fileURLs?.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().scaledToFit().frame(width: 55, height: 55)
                    Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(2)
                } else {
                    Image(systemName: item.type.icon).font(.system(size: 38)).foregroundStyle(tint)
                    Text(item.displayContent).font(.system(size: 12)).lineLimit(3)
                }
            }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private var metadata: String {
        if item.type == .text || item.type == .code { return "\(item.content.count) " + L("个字符", "characters") }
        if let files = item.fileURLs, files.count > 1 { return "\(files.count) " + L("个文件", "files") }
        return kind
    }
}

private struct QuickPasteKeyReader: NSViewRepresentable {
    var handle: (NSEvent) -> Bool
    func makeNSView(context: Context) -> QuickPasteKeyView { QuickPasteKeyView() }
    func updateNSView(_ view: QuickPasteKeyView, context: Context) { view.handle = handle }
}
private final class QuickPasteKeyView: NSView {
    var handle: ((NSEvent) -> Bool)?
    private var monitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window, window.isVisible else { return event }
            return self.handle?(event) == true ? nil : event
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
