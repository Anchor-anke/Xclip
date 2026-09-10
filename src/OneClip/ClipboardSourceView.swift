import AppKit
import SwiftUI

/// Resolves recorded source metadata against locally installed applications only.
/// The captured name stays authoritative if the application is renamed or removed.
enum ClipboardSourceInfo {
    private final class LocalApplication: NSObject {
        let name: String?
        let icon: NSImage?

        init(name: String?, icon: NSImage?) {
            self.name = name
            self.icon = icon
        }
    }

    private static let applications: NSCache<NSString, LocalApplication> = {
        let cache = NSCache<NSString, LocalApplication>()
        cache.countLimit = 256
        return cache
    }()

    static func name(for item: ClipboardItem) -> String {
        if let recordedName = nonempty(item.sourceAppName) { return recordedName }
        guard let identifier = nonempty(item.sourceApp) else {
            return L("来源未知", "Unknown source")
        }
        return application(for: identifier).name ?? identifier
    }

    static func searchText(for item: ClipboardItem) -> String {
        [name(for: item), nonempty(item.sourceAppName), nonempty(item.sourceApp)]
            .compactMap { $0 }.joined(separator: " ")
    }

    static func detail(for item: ClipboardItem) -> String {
        guard isKnown(item) else { return L("来源未知（未记录来源应用）", "Unknown source (source app was not recorded)") }
        var lines = [L("来源应用：", "Source app: ") + name(for: item)]
        if let identifier = nonempty(item.sourceApp) {
            lines.append(L("应用标识：", "App identifier: ") + identifier)
        }
        return lines.joined(separator: "\n")
    }

    static func icon(for item: ClipboardItem) -> NSImage? {
        guard let identifier = nonempty(item.sourceApp) else { return nil }
        return application(for: identifier).icon
    }

    static func isKnown(_ item: ClipboardItem) -> Bool {
        nonempty(item.sourceAppName) != nil || nonempty(item.sourceApp) != nil
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func application(for identifier: String) -> LocalApplication {
        let key = identifier as NSString
        if let cached = applications.object(forKey: key) { return cached }
        let result: LocalApplication
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            let bundle = Bundle(url: url)
            let displayName = nonempty(bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? nonempty(bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? nonempty((try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName)
                ?? url.deletingPathExtension().lastPathComponent
            result = LocalApplication(name: displayName, icon: NSWorkspace.shared.icon(forFile: url.path))
        } else {
            // Cache missing applications too, so legacy or remote identifiers do not
            // repeatedly trigger Launch Services lookups while scrolling.
            result = LocalApplication(name: nil, icon: nil)
        }
        applications.setObject(result, forKey: key)
        return result
    }
}

struct ClipboardSourceBadge: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    let item: ClipboardItem
    var iconSize: CGFloat = 12
    var showsPrefix = true

    private var label: String {
        let name = ClipboardSourceInfo.name(for: item)
        return showsPrefix && ClipboardSourceInfo.isKnown(item) ? L("来自 ", "From ") + name : name
    }

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if let icon = ClipboardSourceInfo.icon(for: item) {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else {
                    Image(systemName: ClipboardSourceInfo.isKnown(item) ? "app" : "questionmark.app")
                        .resizable().scaledToFit()
                }
            }
            .frame(width: iconSize, height: iconSize)
            .accessibilityHidden(true)
            Text(label).lineLimit(1).truncationMode(.tail)
        }
        .help(ClipboardSourceInfo.detail(for: item))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ClipboardSourceInfo.detail(for: item))
    }
}
