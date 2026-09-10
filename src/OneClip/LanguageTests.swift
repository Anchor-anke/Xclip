import Foundation
import Combine

/// Exercises language persistence with synthetic documents; never opens history or captures the screen.
@MainActor
enum LanguageTests {
    private static var checks = 0

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else {
            throw NSError(domain: "XclipLanguageTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        checks += 1
        print("PASS Language \(checks): \(message)")
    }

    static func run() throws {
        checks = 0
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xclip-language-tests-\(UUID().uuidString)")
        let suite = "Xclip.LanguageTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw NSError(domain: "XclipLanguageTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot create isolated defaults"])
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try preferenceSelection(defaults)
        try workflowPersistence(root: root, defaults: defaults)
        try corruptDocumentProtection(root: root, defaults: defaults)
        try sharedTranslationConsistency()
        print("LanguageTests: \(checks) checks passed. Temporary workflows and restored language preferences only.")
    }

    private static func preferenceSelection(_ defaults: UserDefaults) throws {
        defaults.removeObject(forKey: AppLanguage.preferenceKey)
        let language = AppLanguage(defaults: defaults)
        try expect(language.code == "zh" && language.locale.identifier == "zh_CN", "A missing preference selects Chinese and its locale")
        try expect(language.text("中文", "English") == "中文", "Instance translation uses the injected preference")
        try expect(defaults.object(forKey: AppLanguage.preferenceKey) == nil, "Reading a missing preference does not write defaults")

        var notifications = 0
        var published: [String] = []
        let observer = NotificationCenter.default.addObserver(forName: AppLanguage.didChange, object: language, queue: .main) { _ in
            notifications += 1
        }
        let subscription = language.$code.dropFirst().sink { published.append($0) }
        defer { NotificationCenter.default.removeObserver(observer); subscription.cancel() }
        language.select("en")
        try expect(language.code == "en" && language.locale.identifier == "en_US" && language.text("中文", "English") == "English", "Selecting English updates the observable value, locale and translation")
        try expect(defaults.string(forKey: AppLanguage.preferenceKey) == "en", "Selecting a language persists it to the injected defaults")
        try expect(notifications == 1 && published == ["en"], "A selection publishes one value and one language notification")
        language.select("en")
        try expect(notifications == 1 && published == ["en"], "Selecting the current language does not emit duplicate updates")
        try expect(AppLanguage(defaults: defaults).code == "en", "A fresh language service restores the saved choice")
        language.select("zh")
        try expect(language.code == "zh" && notifications == 2 && published == ["en", "zh"], "Switching back to Chinese publishes and persists the new choice")
        defaults.set("unsupported", forKey: AppLanguage.preferenceKey)
        try expect(AppLanguage(defaults: defaults).code == "zh", "An unsupported stored language falls back safely to Chinese")
    }

    private static func workflowPersistence(root: URL, defaults: UserDefaults) throws {
        let file = root.appendingPathComponent("workflow.json")
        let sample = ClipboardItem(id: UUID(), content: "用户原文 User text: 你好 & Hello", type: .text, timestamp: Date(timeIntervalSince1970: 1_700_000_000), tags: ["自定义 Tag"])
        var document = WorkflowDocument()
        document.language = "en"
        document.stack = [sample]
        document.shelf = [sample]
        document.categories = [ClipCategory(name: "我的分组 Inbox", pattern: "原文|User")]
        document.replies = [QuickReply(title: "自定义 FAQ", item: sample)]
        document.searchHistory = ["用户输入 Search"]
        let original = try JSONEncoder().encode(document)
        try original.write(to: file)
        defaults.set("zh", forKey: AppLanguage.preferenceKey)
        let globalCode = AppLanguage.shared.code
        let globalPreference = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey) as? String
        let state = WorkflowState(fileURL: file, defaults: defaults)
        try expect(state.language == "en" && defaults.string(forKey: AppLanguage.preferenceKey) == "en", "An existing workflow language takes precedence over conflicting defaults")
        try expect(try Data(contentsOf: file) == original, "Loading a workflow synchronizes defaults without rewriting the original file")
        defaults.set("zh", forKey: AppLanguage.preferenceKey)
        try state.reloadFromDisk()
        try expect(state.language == "en" && defaults.string(forKey: AppLanguage.preferenceKey) == "en", "Explicit reload also resolves a preference conflict in favor of the workflow")
        try expect(try Data(contentsOf: file) == original, "Explicit reload preserves the workflow bytes")
        try expect(AppLanguage.shared.code == globalCode && UserDefaults.standard.object(forKey: AppLanguage.preferenceKey) as? String == globalPreference, "Injected workflow defaults never change the live language preference")

        for code in ["zh", "en"] {
            try state.setLanguage(code)
            let saved = try JSONDecoder().decode(WorkflowDocument.self, from: Data(contentsOf: file))
            try expect(state.language == code && saved.language == code && defaults.string(forKey: AppLanguage.preferenceKey) == code, "Switching to \(code) persists to the document and defaults together")
            try expect(saved.stack == [sample] && saved.shelf == [sample] && saved.categories == document.categories && saved.replies.first?.title == document.replies.first?.title && saved.replies.first?.item == sample && saved.searchHistory == document.searchHistory, "Switching to \(code) preserves user content, tags, reply titles and searches")
            try expect(WorkflowState(fileURL: file, defaults: defaults).language == code, "Reopening the workflow restores \(code)")
        }
        let savedBytes = try Data(contentsOf: file)
        try state.setLanguage("unsupported")
        try expect(state.language == "en" && defaults.string(forKey: AppLanguage.preferenceKey) == "en" && Data(contentsOf: file) == savedBytes, "Unsupported workflow language choices leave all persisted values unchanged")

        let absent = root.appendingPathComponent("new-workflow.json")
        defaults.set("en", forKey: AppLanguage.preferenceKey)
        let fresh = WorkflowState(fileURL: absent, defaults: defaults)
        try expect(fresh.language == "en" && !FileManager.default.fileExists(atPath: absent.path), "A new workflow inherits the language without creating a file during initialization")
    }

    private static func corruptDocumentProtection(root: URL, defaults: UserDefaults) throws {
        let file = root.appendingPathComponent("corrupt-workflow.json")
        let original = Data("{\"language\":\"en\",\"stack\":\"invalid synthetic type\"}".utf8)
        try original.write(to: file)
        defaults.set("zh", forKey: AppLanguage.preferenceKey)
        let state = WorkflowState(fileURL: file, defaults: defaults)
        let previousLanguage = state.language
        try expect(state.storageReadError != nil, "A malformed workflow enters read-protection mode")
        do {
            try state.setLanguage("en")
            throw NSError(domain: "XclipLanguageTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "A protected workflow accepted a language change"])
        } catch let error as NSError where error.domain == "CClip.Workflow" {
            checks += 1
            print("PASS Language \(checks): A protected workflow rejects a language change")
        }
        try expect(state.language == previousLanguage && defaults.string(forKey: AppLanguage.preferenceKey) == "zh", "A rejected language change leaves the active language and defaults intact")
        try expect(try Data(contentsOf: file) == original, "A rejected language change preserves every original corrupt byte")
    }

    private static func sharedTranslationConsistency() throws {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: AppLanguage.preferenceKey)
        let previousCode = AppLanguage.shared.code
        defer {
            AppLanguage.shared.select(previousCode)
            if let previousValue { defaults.set(previousValue, forKey: AppLanguage.preferenceKey) }
            else { defaults.removeObject(forKey: AppLanguage.preferenceKey) }
        }
        let message = CaptureMessage("已保存 2 段", "Saved 2 frames")
        let automationMessage = AutomationMessage("处理完成", "Finished")
        let archiveError = ClipboardStorageError.invalidArchive("缺少附件", "Missing attachment")
        let externalDatabaseError = ClipboardStorageError.database("SQLITE synthetic raw diagnostic 42")
        for code in ["zh", "en", "zh"] {
            AppLanguage.shared.select(code)
            let expected = code == "en" ? "English" : "中文"
            try expect(L("中文", "English") == expected && CaptureLocalization.text("中文", "English") == expected && AutomationL("中文", "English") == expected && AppLanguage.text("中文", "English") == expected, "Main, capture and automation translators agree in \(code)")
            try expect(message.text == (code == "en" ? "Saved 2 frames" : "已保存 2 段") && automationMessage.text == (code == "en" ? "Finished" : "处理完成"), "Previously created status messages update to \(code)")
            try expect(archiveError.localizedDescription == (code == "en" ? "Invalid backup: Missing attachment" : "备份无效：缺少附件"), "Previously created archive errors update to \(code)")
            try expect(externalDatabaseError.localizedDescription.hasSuffix("SQLITE synthetic raw diagnostic 42"), "External database diagnostics remain unchanged in \(code)")
        }
    }
}
