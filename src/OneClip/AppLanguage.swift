import Foundation
import Combine

/// One preference and one observable update source for all application-owned text.
/// This file intentionally has no workflow/UI dependency so helpers and tests use the same rules.
final class AppLanguage: ObservableObject {
    static let preferenceKey = "local.cclip.language"
    static let didChange = Notification.Name("XclipLanguageDidChange")
    static let shared = AppLanguage()
    static let supportedCodes = ["zh", "en"]

    @Published private(set) var code: String
    private let defaults: UserDefaults
    var locale: Locale { Locale(identifier: code == "en" ? "en_US" : "zh_CN") }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        code = Self.normalized(defaults.string(forKey: Self.preferenceKey))
    }

    static func normalized(_ code: String?) -> String { code == "en" ? "en" : "zh" }

    static func text(_ chinese: String, _ english: String) -> String {
        // UserDefaults is thread-safe; services can translate errors off the main thread.
        normalized(UserDefaults.standard.string(forKey: preferenceKey)) == "en" ? english : chinese
    }

    func text(_ chinese: String, _ english: String) -> String { code == "en" ? english : chinese }

    func select(_ selectedCode: String) {
        let selectedCode = Self.normalized(selectedCode)
        defaults.set(selectedCode, forKey: Self.preferenceKey)
        guard code != selectedCode else { return }
        code = selectedCode
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Keep injected test/backup stores isolated from the live application's preferences.
    static func synchronize(_ code: String, defaults: UserDefaults) {
        if defaults === UserDefaults.standard {
            if Thread.isMainThread { shared.select(code) }
            else {
                defaults.set(normalized(code), forKey: preferenceKey)
                DispatchQueue.main.async { shared.select(code) }
            }
        } else { defaults.set(normalized(code), forKey: preferenceKey) }
    }
}
