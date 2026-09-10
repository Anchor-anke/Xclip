import AppKit

/// Synthetic menus only. This suite never creates NSApplication, opens a window,
/// invokes an action, or reads/writes any pasteboard.
@main
@MainActor
enum NativeLanguageTests {
    private static var checks = 0

    private struct Fixture {
        let menu: NSMenu
        let groups: [(item: NSMenuItem, zh: String, en: String)]
        let actions: [(item: NSMenuItem, selector: String, zh: String, en: String)]
        let userItems: [(item: NSMenuItem, title: String, selector: String, payload: String)]
    }

    static func main() throws {
        let original = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        let originalCode = AppLanguage.shared.code
        try runSuite()
        let restored = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        try expect((original == nil && restored == nil) || (original as? NSObject)?.isEqual(restored) == true,
                   "Original standard language preference restored")
        try expect(AppLanguage.shared.code == originalCode, "Original observable language code restored")
        print("NativeLanguageTests: \(checks) checks passed; synthetic menus only; no application launch, window creation, dispatched actions or pasteboard access.")
    }

    private static func runSuite() throws {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: AppLanguage.preferenceKey)
        let originalCode = AppLanguage.shared.code
        defer {
            AppLanguage.shared.select(originalCode)
            if let original { defaults.set(original, forKey: AppLanguage.preferenceKey) }
            else { defaults.removeObject(forKey: AppLanguage.preferenceKey) }
        }

        let fixture = makeFixture()
        let actionSelectors = fixture.actions.map { NSStringFromSelector($0.item.action!) }
        let actionKeyEquivalents = fixture.actions.map { $0.item.keyEquivalent }
        let originalMembers = members(in: fixture.menu)

        for language in ["en", "zh", "en", "zh"] {
            AppLanguage.shared.select(language)
            NativeLanguageController.shared.localize(fixture.menu)
            for group in fixture.groups {
                let expected = language == "en" ? group.en : group.zh
                try expect(group.item.title == expected, "\(language): group title \(group.en)")
                try expect(group.item.submenu?.title == expected, "\(language): submenu title \(group.en)")
            }
            for action in fixture.actions {
                try expect(action.item.title == (language == "en" ? action.en : action.zh), "\(language): action title \(action.selector)")
                try expect(action.item.action.map(NSStringFromSelector) == action.selector, "\(language): selector preserved \(action.selector)")
            }
            for user in fixture.userItems {
                try expect(user.item.title == user.title, "\(language): user title preserved \(user.title)")
                try expect(user.item.action.map(NSStringFromSelector) == user.selector, "\(language): user selector preserved")
                try expect(user.item.representedObject as? String == user.payload, "\(language): user payload preserved")
            }
            try expect(members(in: fixture.menu) == originalMembers, "\(language): recursive menu membership and order preserved")
            try expect(fixture.actions.map { NSStringFromSelector($0.item.action!) } == actionSelectors, "\(language): action order preserved")
            try expect(fixture.actions.map { $0.item.keyEquivalent } == actionKeyEquivalents, "\(language): keyboard shortcuts preserved")

            let before = titles(in: fixture.menu)
            NativeLanguageController.shared.localize(fixture.menu)
            try expect(titles(in: fixture.menu) == before, "\(language): repeated localization is idempotent")
        }
        try policyRegressions()
        try representedObjectRegressions()
        try attributedTitleRegressions()
    }

    private static func makeFixture() -> Fixture {
        let menu = NSMenu(title: "Synthetic main menu")
        menu.autoenablesItems = false
        var groups: [(item: NSMenuItem, zh: String, en: String)] = []
        var actions: [(item: NSMenuItem, selector: String, zh: String, en: String)] = []
        var userItems: [(item: NSMenuItem, title: String, selector: String, payload: String)] = []

        func group(_ zh: String, _ en: String, in parent: NSMenu, startChinese: Bool = false) -> NSMenu {
            let item = NSMenuItem(title: startChinese ? zh : en, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: item.title)
            submenu.autoenablesItems = false
            item.submenu = submenu
            parent.addItem(item)
            groups.append((item, zh, en))
            return submenu
        }

        func action(_ selector: String, _ zh: String, _ en: String, in parent: NSMenu, key: String = "") {
            let item = NSMenuItem(title: "Synthetic untranslated action", action: NSSelectorFromString(selector), keyEquivalent: key)
            parent.addItem(item)
            actions.append((item, selector, zh, en))
        }

        func user(_ title: String, selector: String, in parent: NSMenu) {
            let item = NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: "")
            let payload = "Synthetic user payload: \(title)"
            item.representedObject = payload
            parent.addItem(item)
            userItems.append((item, title, selector, payload))
        }

        let appItem = NSMenuItem(title: "Xclip", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Xclip")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        action("orderFrontStandardAboutPanel:", "关于 Xclip", "About Xclip", in: appMenu)
        action("hide:", "隐藏 Xclip", "Hide Xclip", in: appMenu, key: "h")
        action("terminate:", "退出 Xclip", "Quit Xclip", in: appMenu, key: "q")
        _ = group("服务", "Services", in: appMenu)

        let file = group("文件", "File", in: menu)
        action("performClose:", "关闭窗口", "Close Window", in: file, key: "w")
        action("closeAll:", "全部关闭", "Close All", in: file)
        let edit = group("编辑", "Edit", in: menu, startChinese: true)
        action("undo:", "撤销", "Undo", in: edit, key: "z")
        action("redo:", "重做", "Redo", in: edit)
        action("cut:", "剪切", "Cut", in: edit, key: "x")
        action("copy:", "复制", "Copy", in: edit, key: "c")
        action("paste:", "粘贴", "Paste", in: edit, key: "v")
        action("pasteAsPlainText:", "粘贴并匹配样式", "Paste and Match Style", in: edit)
        action("delete:", "删除", "Delete", in: edit)
        action("selectAll:", "全选", "Select All", in: edit, key: "a")
        action("startDictation:", "开始听写…", "Start Dictation…", in: edit)
        _ = group("查找", "Find", in: edit)
        _ = group("拼写和语法", "Spelling and Grammar", in: edit, startChinese: true)
        _ = group("替换", "Substitutions", in: edit)
        _ = group("转换", "Transformations", in: edit, startChinese: true)
        _ = group("语音", "Speech", in: edit)
        let autofill = group("自动填充", "AutoFill", in: edit)
        action("_handleInsertFromContactsCommand:", "通讯录…", "Contacts…", in: autofill)
        action("_handleInsertFromPasswordsCommand:", "密码…", "Passwords…", in: autofill)
        action("_handleInsertFromCreditCardsCommand:", "信用卡…", "Credit Cards…", in: autofill)
        let view = group("显示", "View", in: menu, startChinese: true)
        action("toggleSidebar:", "切换侧边栏", "Toggle Sidebar", in: view)
        action("toggleToolbarShown:", "切换工具栏", "Toggle Toolbar", in: view)
        let window = group("窗口", "Window", in: menu)
        action("performMiniaturize:", "最小化", "Minimize", in: window, key: "m")
        action("performZoom:", "缩放", "Zoom", in: window)
        action("arrangeInFront:", "前置全部窗口", "Bring All to Front", in: window)
        user("File", selector: "makeKeyAndOrderFront:", in: window)
        user("文件", selector: "makeKeyAndOrderFront:", in: window)
        user("我的草稿 English notes", selector: "makeKeyAndOrderFront:", in: window)
        let help = group("帮助", "Help", in: menu, startChinese: true)
        action("showHelp:", "Xclip 帮助", "Xclip Help", in: help)

        let historyItem = NSMenuItem(title: "Synthetic clipboard history", action: nil, keyEquivalent: "")
        let history = NSMenu(title: historyItem.title)
        historyItem.submenu = history
        menu.addItem(historyItem)
        for title in ["File", "编辑", "Copy", "复制", "用户文本: hello 你好"] {
            user(title, selector: "activateHistoryItem:", in: history)
        }
        return Fixture(menu: menu, groups: groups, actions: actions, userItems: userItems)
    }

    private static func members(in menu: NSMenu) -> [ObjectIdentifier] {
        menu.items.flatMap { item in
            [ObjectIdentifier(item)] + (item.submenu.map(members(in:)) ?? [])
        }
    }

    private static func titles(in menu: NSMenu) -> [String] {
        [menu.title] + menu.items.flatMap { item in
            [item.title] + (item.submenu.map(titles(in:)) ?? [])
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw NSError(domain: "NativeLanguageTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        checks += 1
        print("PASS \(checks): \(message)")
        fflush(stdout)
    }

    /// Regression probes for both issues found during the menu policy audit.
    private static func policyRegressions() throws {
        AppLanguage.shared.select("zh")
        let menu = NSMenu(title: "Synthetic policy probes")
        let fullScreen = NSMenuItem(title: "Enter Full Screen", action: NSSelectorFromString("toggleFullScreen:"), keyEquivalent: "f")
        menu.addItem(fullScreen)
        let historyItem = NSMenuItem(title: "Synthetic history", action: nil, keyEquivalent: "")
        let historyMenu = NSMenu(title: historyItem.title)
        historyItem.submenu = historyMenu
        menu.addItem(historyItem)
        let userGroup = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        userGroup.representedObject = "Synthetic user-defined history group"
        userGroup.submenu = NSMenu(title: "File")
        userGroup.submenu?.addItem(NSMenuItem(title: "Synthetic user content", action: NSSelectorFromString("activateHistoryItem:"), keyEquivalent: ""))
        historyMenu.addItem(userGroup)
        NativeLanguageController.shared.localize(menu)
        try expect(fullScreen.title == "进入全屏", "zh: full-screen action localized with no active application")
        try expect(fullScreen.action.map(NSStringFromSelector) == "toggleFullScreen:", "Full-screen selector preserved")
        try expect(userGroup.title == "File" && userGroup.submenu?.title == "File", "User submenu name matching a standard heading is preserved")
        try expect(userGroup.representedObject as? String == "Synthetic user-defined history group", "User submenu payload preserved")
        try expect(NSApp == nil, "The complete suite never initializes NSApplication")
    }

    /// SwiftUI decorates standard root items with represented objects. A user's nested
    /// category can use the same metadata mechanism, so only its subtree stays untouched.
    private static func representedObjectRegressions() throws {
        let menu = NSMenu(title: "Synthetic represented-object menu")
        menu.autoenablesItems = false
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let headingWrapper = NSObject()
        edit.representedObject = headingWrapper
        let editMenu = NSMenu(title: "Edit")
        editMenu.autoenablesItems = false
        edit.submenu = editMenu
        menu.addItem(edit)

        let copy = NSMenuItem(title: "Copy", action: NSSelectorFromString("copy:"), keyEquivalent: "c")
        let actionWrapper = NSObject()
        let actionTarget = NSObject()
        copy.representedObject = actionWrapper
        copy.target = actionTarget
        copy.keyEquivalentModifierMask = [.command, .shift]
        copy.isEnabled = false
        copy.state = .on
        copy.tag = 73
        copy.toolTip = "Synthetic unchanged tooltip"
        editMenu.addItem(copy)

        let nested = NSMenuItem(title: "Speech", action: nil, keyEquivalent: "")
        let userWrapper = NSObject()
        nested.representedObject = userWrapper
        let userMenu = NSMenu(title: "Speech")
        userMenu.autoenablesItems = false
        nested.submenu = userMenu
        editMenu.addItem(nested)
        let userText = NSMenuItem(title: "用户草稿 Copy", action: NSSelectorFromString("copy:"), keyEquivalent: "")
        let userPayload = "用户原文 User content 你好 & Hello"
        userText.representedObject = userPayload
        userMenu.addItem(userText)
        let userGroup = NSMenuItem(title: "Transformations", action: nil, keyEquivalent: "")
        userGroup.submenu = NSMenu(title: "Transformations")
        userGroup.submenu?.addItem(NSMenuItem(title: "User-owned Paste", action: NSSelectorFromString("paste:"), keyEquivalent: ""))
        userMenu.addItem(userGroup)
        let originalUserTitles = titles(in: userMenu)
        let originalMembers = members(in: menu)

        for language in ["zh", "en", "zh"] {
            AppLanguage.shared.select(language)
            NativeLanguageController.shared.localize(menu)
            let headingTitle = language == "en" ? "Edit" : "编辑"
            try expect(edit.title == headingTitle && editMenu.title == headingTitle,
                       "\(language): a SwiftUI-style root wrapper does not block standard heading localization")
            try expect(copy.title == (language == "en" ? "Copy" : "复制"),
                       "\(language): wrapped standard actions below the root still localize")
            try expect((edit.representedObject as? NSObject) === headingWrapper && (copy.representedObject as? NSObject) === actionWrapper,
                       "\(language): SwiftUI-style represented objects retain their identity")
            try expect(copy.action.map(NSStringFromSelector) == "copy:" && copy.target === actionTarget && copy.keyEquivalent == "c" && copy.keyEquivalentModifierMask == [.command, .shift],
                       "\(language): action target, selector and keyboard modifiers are preserved")
            try expect(!copy.isEnabled && copy.state == .on && copy.tag == 73 && copy.toolTip == "Synthetic unchanged tooltip",
                       "\(language): action enablement, state, tag and tooltip are preserved")
            try expect(nested.title == "Speech" && titles(in: userMenu) == originalUserTitles,
                       "\(language): nested user submenu names and standard-looking descendant actions are preserved")
            try expect((nested.representedObject as? NSObject) === userWrapper && userText.representedObject as? String == userPayload,
                       "\(language): nested user wrappers and original text payloads are preserved")
            try expect(members(in: menu) == originalMembers, "\(language): wrapped menu membership and order are unchanged")
        }
        try expect(NSApp == nil, "Represented-object regression tests do not initialize NSApplication")
    }

    private static func attributedTitleRegressions() throws {
        let style: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.red, .kern: 0.75,
            .underlineStyle: NSUnderlineStyle.single.rawValue, .baselineOffset: 1.5
        ]
        let menu = NSMenu(title: "Synthetic attributed menus")
        menu.autoenablesItems = false
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        edit.attributedTitle = NSAttributedString(string: "编辑", attributes: style)
        edit.title = "Edit"
        edit.representedObject = NSObject()
        let submenu = NSMenu(title: "Edit")
        submenu.autoenablesItems = false
        edit.submenu = submenu
        menu.addItem(edit)
        let copy = NSMenuItem(title: "Copy", action: NSSelectorFromString("copy:"), keyEquivalent: "c")
        copy.attributedTitle = NSAttributedString(string: "拷贝", attributes: style)
        copy.title = "Copy"
        submenu.addItem(copy)
        let plain = NSMenuItem(title: "Paste", action: NSSelectorFromString("paste:"), keyEquivalent: "v")
        submenu.addItem(plain)
        let empty = NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        empty.attributedTitle = NSAttributedString(string: "")
        submenu.addItem(empty)
        let user = NSMenuItem(title: "用户标题 Copy", action: NSSelectorFromString("activateHistoryItem:"), keyEquivalent: "")
        let originalUserTitle = NSAttributedString(string: "用户原文 User text", attributes: style)
        user.attributedTitle = originalUserTitle
        user.title = "用户标题 Copy"
        user.representedObject = "Synthetic user payload"
        submenu.addItem(user)

        for language in ["en", "zh", "en"] {
            AppLanguage.shared.select(language)
            NativeLanguageController.shared.localize(menu)
            let headingTitle = language == "en" ? "Edit" : "编辑"
            let actionTitle = language == "en" ? "Copy" : "复制"
            try expect(edit.title == headingTitle && edit.attributedTitle?.string == headingTitle,
                       "\(language): attributed root headings match the selected language")
            try expect(copy.title == actionTitle && copy.attributedTitle?.string == actionTitle,
                       "\(language): an attributed action title updates even when its plain title was already correct")
            for item in [edit, copy] {
                guard let attributed = item.attributedTitle else {
                    throw NSError(domain: "NativeLanguageTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "An attributed title was removed"])
                }
                try expect((0..<attributed.length).allSatisfy { (attributed.attributes(at: $0, effectiveRange: nil) as NSDictionary).isEqual(to: style) },
                           "\(language): attributed \(item === edit ? "heading" : "action") keeps color, kerning, underline and baseline styling")
            }
            try expect(plain.attributedTitle == nil, "\(language): ordinary menu items do not gain attributed titles")
            try expect(empty.attributedTitle?.string == (language == "en" ? "Undo" : "撤销"), "\(language): empty attributed action titles are updated safely")
            try expect(user.title == "用户标题 Copy" && user.attributedTitle?.isEqual(to: originalUserTitle) == true && user.representedObject as? String == "Synthetic user payload",
                       "\(language): user-owned attributed text and styles stay unchanged")
            let before = copy.attributedTitle!
            NativeLanguageController.shared.localize(menu)
            try expect(copy.attributedTitle?.isEqual(to: before) == true, "\(language): repeated attribute localization is idempotent")
        }
        try expect(NSApp == nil, "Attributed-title regression tests do not initialize NSApplication")
    }
}
