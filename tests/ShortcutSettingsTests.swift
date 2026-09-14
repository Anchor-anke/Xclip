import AppKit

/// Pure production helpers, Codable models and inactive recording lifecycle; no app launch or hotkey registration.
@main
struct ShortcutSettingsTests {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        precondition((try? condition()) ?? false, message)
        print("PASS: \(message)")
    }

    static func main() throws {
        localizedSettingsLabels()
        try clearAndRestoreShortcuts()
        // WorkflowState is a fatal sentinel in this test executable. An unintended
        // register(actions: [:]) would reach it before any reply could be registered.
        let inactive = GlobalShortcuts.shared
        inactive.pauseForShortcutRecording()
        inactive.pauseForShortcutRecording()
        inactive.resumeAfterShortcutRecording()
        inactive.resumeAfterShortcutRecording()
        require(inactive.errors.isEmpty, "Canceling and repeatedly closing a never-registered recorder leaves shortcut registration inactive")
        let capture = GlobalShortcuts.defaults["capture"]!
        require(capture.keyCode == 0 && capture.flags == .control && capture.label == "⌃A", "Existing capture key and Ctrl+A default remain compatible")
        var document = WorkflowDocument()
        require(GlobalShortcuts.conflictDescription(for: capture, excluding: "capture", in: document) == nil, "Keeping the current screenshot shortcut is allowed")
        let history = GlobalShortcuts.defaults["history"]!
        require(GlobalShortcuts.conflictDescription(for: history, excluding: "capture", in: document) != nil, "Screenshot cannot steal a default app shortcut")

        let custom = ShortcutSpec(keyCode: 17, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, label: "⌃⌥T")
        document.shortcuts["history"] = custom
        require(GlobalShortcuts.conflictDescription(for: history, excluding: "capture", in: document) == nil, "A replaced default becomes available")
        require(GlobalShortcuts.conflictDescription(for: custom, excluding: "capture", in: document) != nil, "A saved custom app shortcut remains protected")
        var capsLockVariant = custom
        capsLockVariant.modifiers |= NSEvent.ModifierFlags.capsLock.rawValue
        capsLockVariant.label = "a different display label"
        require(GlobalShortcuts.conflictDescription(for: capsLockVariant, excluding: "capture", in: document) != nil, "Conflict detection uses the key and meaningful modifiers, ignoring labels and Caps Lock")

        let item = ClipboardItem(id: UUID(), content: "Synthetic reply", type: .text, timestamp: Date())
        document.replies = [QuickReply(title: "Example reply", item: item, hotkey: capture)]
        require(GlobalShortcuts.conflictDescription(for: capture, excluding: "capture", in: document)?.contains("Example reply") == true, "A conflicting quick reply is identified before a screenshot binding is saved or reset")
        document.replies = []
        document.shortcuts["pinClipboard"] = history
        require(GlobalShortcuts.conflictDescription(for: history, excluding: "captureLong", in: document) != nil, "Optional pin and scrolling shortcuts participate in conflict detection")
        require(GlobalShortcuts.conflictDescription(for: history, excluding: "pinClipboard", in: document) == nil, "An optional shortcut can keep its existing binding")
        document.shortcuts["capture"] = custom
        let serialized = try JSONEncoder().encode(document)
        let reloaded = try JSONDecoder().decode(WorkflowDocument.self, from: serialized)
        require(reloaded.shortcuts["capture"] == custom, "Saved screenshot binding survives the existing workflow format")
        require(reloaded.shortcuts["pinClipboard"] == history, "Optional pin bindings persist with the existing shortcut document")
        require(try JSONDecoder().decode(WorkflowDocument.self, from: Data("{}".utf8)).shortcuts["capture"] == nil, "Older workflow files continue to use the default binding")

        let arrow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .shift, .capsLock], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124)!
        let arrowSpec = ShortcutRecorder.spec(for: arrow)
        require(arrowSpec.label == "⌃⇧→" && arrowSpec.flags == [.control, .shift], "Recorder gives navigation keys readable labels and ignores Caps Lock")
        let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51)!
        require(ShortcutRecorder.spec(for: delete).label == "⌘⌫", "Recorder does not persist an invisible Delete character")
        print("All shortcut settings checks passed without registering global shortcuts.")
    }

    static func clearAndRestoreShortcuts() throws {
        let capture = GlobalShortcuts.defaults["capture"]!
        let custom = ShortcutSpec(keyCode: 17, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, label: "⌃⌥T")
        var document = WorkflowDocument()
        require(GlobalShortcuts.effectiveShortcut(for: "capture", in: document) == capture, "An unconfigured screenshot action uses its default shortcut")
        document.clearShortcut(for: "capture")
        require(GlobalShortcuts.effectiveShortcut(for: "capture", in: document) == nil, "Clearing a default shortcut disables it instead of falling back to the default")
        require(GlobalShortcuts.conflictDescription(for: capture, excluding: "history", in: document) == nil, "Clearing a default shortcut releases its combination for another action")

        document.setShortcut(capture, for: "history")
        require(GlobalShortcuts.conflictDescription(for: capture, excluding: "capture", in: document) != nil, "Restoring a cleared default detects when another action now uses its combination")
        document.clearShortcut(for: "history")
        require(document.shortcuts["history"] == nil && GlobalShortcuts.effectiveShortcut(for: "history", in: document) == nil, "Clearing a custom shortcut removes the override and also disables its original default")
        require(GlobalShortcuts.conflictDescription(for: capture, excluding: "capture", in: document) == nil, "Clearing the custom binding makes the original shortcut available to restore")

        document.setShortcut(custom, for: "pinClipboard")
        require(GlobalShortcuts.effectiveShortcut(for: "pinClipboard", in: document) == custom, "An optional action can use a custom shortcut")
        document.clearShortcut(for: "pinClipboard")
        require(document.shortcuts["pinClipboard"] == nil && GlobalShortcuts.effectiveShortcut(for: "pinClipboard", in: document) == nil, "Clearing an optional action removes its shortcut")
        require(GlobalShortcuts.conflictDescription(for: custom, excluding: "capture", in: document) == nil, "Clearing an optional shortcut releases its custom combination")

        let serialized = try JSONEncoder().encode(document)
        var reloaded = try JSONDecoder().decode(WorkflowDocument.self, from: serialized)
        require(reloaded.disabledShortcuts == Set(["capture", "history", "pinClipboard"]), "Disabled shortcut choices survive workflow serialization")
        for action in ["capture", "history", "pinClipboard"] {
            require(GlobalShortcuts.effectiveShortcut(for: action, in: reloaded) == nil, "\(action) remains disabled after reloading the workflow")
        }
        reloaded.shortcuts["capture"] = custom
        require(GlobalShortcuts.effectiveShortcut(for: "capture", in: reloaded) == nil, "An explicit disabled choice takes precedence over a stored shortcut override")
        reloaded.setShortcut(custom, for: "capture")
        require(!reloaded.disabledShortcuts.contains("capture") && GlobalShortcuts.effectiveShortcut(for: "capture", in: reloaded) == custom, "Recording a replacement shortcut re-enables a cleared action")
        reloaded.resetShortcut(for: "capture")
        require(reloaded.shortcuts["capture"] == nil && !reloaded.disabledShortcuts.contains("capture") && GlobalShortcuts.effectiveShortcut(for: "capture", in: reloaded) == capture, "Restoring a customized action removes its override and uses the default")
        reloaded.resetShortcut(for: "history")
        require(!reloaded.disabledShortcuts.contains("history") && GlobalShortcuts.effectiveShortcut(for: "history", in: reloaded) == GlobalShortcuts.defaults["history"], "Restoring a cleared action re-enables its default shortcut")
        reloaded.resetShortcut(for: "pinClipboard")
        require(!reloaded.disabledShortcuts.contains("pinClipboard") && GlobalShortcuts.effectiveShortcut(for: "pinClipboard", in: reloaded) == nil, "Restoring an optional action returns it to the unassigned default state")
        reloaded.setShortcut(custom, for: "pinClipboard")
        reloaded.resetShortcut(for: "pinClipboard")
        require(reloaded.shortcuts["pinClipboard"] == nil && GlobalShortcuts.effectiveShortcut(for: "pinClipboard", in: reloaded) == nil, "Restoring a customized optional action removes its binding")

        let legacy = try JSONDecoder().decode(WorkflowDocument.self, from: Data("{}".utf8))
        require(legacy.disabledShortcuts.isEmpty, "Older workflows without disabled shortcuts decode with no disabled actions")
        for (action, spec) in GlobalShortcuts.defaults {
            require(GlobalShortcuts.effectiveShortcut(for: action, in: legacy) == spec, "Older workflows retain the default shortcut for \(action)")
        }
        let legacyCustomJSON = """
        {"shortcuts":{"capture":{"keyCode":17,"modifiers":\(custom.modifiers),"label":"⌃⌥T"}}}
        """
        let legacyCustom = try JSONDecoder().decode(WorkflowDocument.self, from: Data(legacyCustomJSON.utf8))
        require(GlobalShortcuts.effectiveShortcut(for: "capture", in: legacyCustom) == custom, "Older workflows retain custom shortcuts when the disabled field is absent")
    }

    static func localizedSettingsLabels() {
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        let expected = [
            ("captureLong", "长截图", "Scrolling capture"),
            ("captureOCR", "截图识别文字", "Capture and recognize text"),
            ("captureRecord", "录屏 / 动图", "Record / GIF"),
            ("pinClipboard", "剪贴板贴图", "Pin clipboard"),
            ("resetPinPassthrough", "恢复贴图鼠标交互", "Restore pin mouse interaction"),
            ("restorePin", "恢复上次贴图", "Restore last pin"),
            ("togglePins", "隐藏 / 显示全部贴图", "Hide / show all pins"),
        ]
        for language in ["en", "zh", "en"] {
            var arguments = original
            arguments[AppLanguage.preferenceKey] = language
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            for (key, chinese, english) in expected {
                require(shortcutTitle(key) == (language == "zh" ? chinese : english), "\(language): settings show a localized name for \(key)")
                require(shortcutTitle(key) == GlobalShortcuts.title(for: key), "\(language): settings and shortcut conflict messages use the same action name")
                let description = shortcutDescription(key) ?? ""
                let containsChinese = description.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
                require(!description.isEmpty && !description.contains(key) && containsChinese == (language == "zh"), "\(language): \(key) includes a readable description in the selected language")
            }
            require(GlobalShortcuts.allActions.allSatisfy { shortcutTitle($0) != $0 }, "\(language): no supported settings action falls back to an internal key")
            require(shortcutDescription("capture") != nil, "\(language): the original screenshot action retains its help text")
            var document = WorkflowDocument()
            let binding = GlobalShortcuts.defaults["history"]!
            document.shortcuts["history"] = GlobalShortcuts.defaults["capture"]!
            document.shortcuts["pinClipboard"] = binding
            let conflict = GlobalShortcuts.conflictDescription(for: binding, excluding: "captureLong", in: document) ?? ""
            require(conflict.contains(shortcutTitle("pinClipboard")) && !conflict.contains("pinClipboard"), "\(language): a conflicting optional shortcut is identified by its visible localized name")
        }
    }
}
