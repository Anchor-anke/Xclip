import Foundation
import Combine

/// Favorites use the same records and transaction boundary as history.
class FavoriteManager: ObservableObject {
    static let shared = FavoriteManager()
    @Published var favoriteItems: [ClipboardItem] = []
    private var observer: NSObjectProtocol?
    private init() {
        observer = NotificationCenter.default.addObserver(forName: .init("ClipboardItemsChanged"), object: nil, queue: .main) { [weak self] _ in
            self?.favoriteItems = ClipboardManager.shared.clipboardItems.filter(\.isFavorite)
        }
    }
    func addToFavorites(_ item: ClipboardItem) { var value = item; value.isFavorite = true; ClipboardManager.shared.update(value) }
    func removeFromFavorites(_ item: ClipboardItem) { var value = item; value.isFavorite = false; ClipboardManager.shared.update(value) }
    func toggleFavorite(_ item: ClipboardItem) { var value = item; value.isFavorite.toggle(); ClipboardManager.shared.update(value) }
    func isFavorite(_ item: ClipboardItem) -> Bool { item.isFavorite }
    func getAllFavorites() -> [ClipboardItem] { ClipboardManager.shared.clipboardItems.filter(\.isFavorite) }
    func getFavorites(ofType type: ClipboardItemType) -> [ClipboardItem] { getAllFavorites().filter { $0.type == type } }
    var favoriteCount: Int { getAllFavorites().count }
    func clearAllFavorites() { for item in getAllFavorites() { removeFromFavorites(item) } }
    func syncWithClipboardStore() { favoriteItems = getAllFavorites() }
    func validateDataConsistency() -> Bool { Set(getAllFavorites().map(\.id)).count == getAllFavorites().count }
    func autoFixDataInconsistency() { syncWithClipboardStore() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}
