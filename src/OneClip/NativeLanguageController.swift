import AppKit

/// SwiftUI localizes its own content; AppKit's standard menu titles need an explicit refresh.
final class NativeLanguageController {
    static let shared = NativeLanguageController()
    private var observers: [NSObjectProtocol] = []
    private var refreshScheduled = false
    private var isRefreshing = false
    private let pendingMenus = NSHashTable<NSMenu>.weakObjects()

    func start() {
        guard observers.isEmpty else { return }
        for name in [AppLanguage.didChange, NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification, NSMenu.didBeginTrackingNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] event in
                guard let self, !self.isRefreshing else { return }
                if let menu = event.object as? NSMenu { self.pendingMenus.add(menu) }
                if event.name == NSMenu.didBeginTrackingNotification, let menu = event.object as? NSMenu {
                    self.isRefreshing = true
                    self.localize(menu, depth: menu === NSApp?.mainMenu ? 0 : 1)
                    self.isRefreshing = false
                }
                self.scheduleRefresh()
            })
        }
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        // Menu tracking runs in its own run-loop mode. A plain main-queue dispatch
        // can wait until the menu closes, leaving AppKit's refreshed titles visible.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            let menus = self.pendingMenus.allObjects
            self.pendingMenus.removeAllObjects()
            if let menu = NSApp?.mainMenu { self.localize(menu) }
            // AppKit may track a temporary menu copy rather than mainMenu itself.
            for menu in menus where menu !== NSApp?.mainMenu {
                self.refresh(menu, depth: 1)
            }
        }
    }

    func localize(_ menu: NSMenu) {
        refresh(menu, depth: 0)
    }

    private func refresh(_ menu: NSMenu, depth: Int) {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        localize(menu, depth: depth)
    }

    private func localize(_ menu: NSMenu, depth: Int) {
        let groups = [("文件", "File"), ("编辑", "Edit"), ("显示", "View"), ("窗口", "Window"),
                      ("帮助", "Help"), ("格式", "Format"), ("服务", "Services"), ("查找", "Find"), ("拼写和语法", "Spelling and Grammar"),
                      ("替换", "Substitutions"), ("转换", "Transformations"), ("语音", "Speech"), ("自动填充", "AutoFill")]
        for item in menu.items {
            // SwiftUI attaches its own represented objects to the application menu headings.
            // Only nested represented objects can be user-owned history/category submenus.
            if let submenu = item.submenu, depth == 0 || item.representedObject == nil {
                // File/Edit/Window are only application menu headings, never user submenu names.
                let allowedGroups = depth == 0 ? groups : Array(groups.dropFirst(6))
                if let pair = allowedGroups.first(where: { item.title == $0.0 || item.title == $0.1 }) {
                    let title = AppLanguage.text(pair.0, pair.1)
                    setTitle(title, for: item)
                    if submenu.title != title { submenu.title = title }
                }
                localize(submenu, depth: depth + 1)
            }
            // Match actions, never window names or user-provided history strings.
            if let action = item.action, let pair = Self.actionTitles[NSStringFromSelector(action)] {
                let title = AppLanguage.text(pair.0, pair.1)
                setTitle(title, for: item)
            }
            if item.action == #selector(NSWindow.toggleFullScreen(_:)) {
                setTitle(NSApp?.keyWindow?.styleMask.contains(.fullScreen) == true
                    ? AppLanguage.text("退出全屏", "Exit Full Screen") : AppLanguage.text("进入全屏", "Enter Full Screen"), for: item)
            }
        }
    }

    private func setTitle(_ title: String, for item: NSMenuItem) {
        if item.title != title { item.title = title }
        // AppKit/SwiftUI can supply an attributed title for standard editing commands;
        // it takes precedence over title in the displayed menu.
        if let attributed = item.attributedTitle, attributed.string != title {
            let updated = NSMutableAttributedString(attributedString: attributed)
            updated.replaceCharacters(in: NSRange(location: 0, length: updated.length), with: title)
            item.attributedTitle = updated
        }
    }

    private static let actionTitles: [String: (String, String)] = [
        "orderFrontStandardAboutPanel:": ("关于 Xclip", "About Xclip"),
        "hide:": ("隐藏 Xclip", "Hide Xclip"), "hideOtherApplications:": ("隐藏其他应用", "Hide Others"),
        "unhideAllApplications:": ("全部显示", "Show All"), "terminate:": ("退出 Xclip", "Quit Xclip"),
        "undo:": ("撤销", "Undo"), "redo:": ("重做", "Redo"),
        "cut:": ("剪切", "Cut"), "copy:": ("复制", "Copy"), "paste:": ("粘贴", "Paste"),
        "pasteAsPlainText:": ("粘贴并匹配样式", "Paste and Match Style"), "delete:": ("删除", "Delete"),
        "selectAll:": ("全选", "Select All"), "performClose:": ("关闭窗口", "Close Window"),
        "closeAll:": ("全部关闭", "Close All"),
        "performMiniaturize:": ("最小化", "Minimize"), "performZoom:": ("缩放", "Zoom"),
        "arrangeInFront:": ("前置全部窗口", "Bring All to Front"),
        "toggleSidebar:": ("切换侧边栏", "Toggle Sidebar"),
        "toggleToolbarShown:": ("切换工具栏", "Toggle Toolbar"),
        "runToolbarCustomizationPalette:": ("自定义工具栏…", "Customize Toolbar…"),
        "orderFrontCharacterPalette:": ("表情与符号", "Emoji & Symbols"),
        "startDictation:": ("开始听写…", "Start Dictation…"),
        "_handleInsertFromContactsCommand:": ("通讯录…", "Contacts…"),
        "_handleInsertFromPasswordsCommand:": ("密码…", "Passwords…"),
        "_handleInsertFromCreditCardsCommand:": ("信用卡…", "Credit Cards…"),
        "showGuessPanel:": ("显示拼写和语法", "Show Spelling and Grammar"),
        "checkSpelling:": ("立即检查文稿", "Check Document Now"),
        "toggleContinuousSpellChecking:": ("键入时检查拼写", "Check Spelling While Typing"),
        "toggleGrammarChecking:": ("检查拼写时检查语法", "Check Grammar With Spelling"),
        "toggleAutomaticSpellingCorrection:": ("自动纠正拼写", "Correct Spelling Automatically"),
        "orderFrontSubstitutionsPanel:": ("显示替换", "Show Substitutions"),
        "toggleSmartInsertDelete:": ("智能复制粘贴", "Smart Copy/Paste"),
        "toggleAutomaticQuoteSubstitution:": ("智能引号", "Smart Quotes"),
        "toggleAutomaticDashSubstitution:": ("智能破折号", "Smart Dashes"),
        "toggleAutomaticLinkDetection:": ("智能链接", "Smart Links"),
        "toggleAutomaticDataDetection:": ("数据检测器", "Data Detectors"),
        "toggleAutomaticTextReplacement:": ("文本替换", "Text Replacement"),
        "uppercaseWord:": ("变为大写", "Make Upper Case"),
        "lowercaseWord:": ("变为小写", "Make Lower Case"),
        "capitalizeWord:": ("首字母大写", "Capitalize"),
        "startSpeaking:": ("开始朗读", "Start Speaking"), "stopSpeaking:": ("停止朗读", "Stop Speaking"),
        "showHelp:": ("Xclip 帮助", "Xclip Help")
    ]
}
