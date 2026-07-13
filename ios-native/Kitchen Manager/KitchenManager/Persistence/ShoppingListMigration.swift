import Foundation

@MainActor
enum ShoppingListMigration {
    static let legacyShoppingKey = "native_km_shopping_v1"
    static let completionKey = "native_km_shopping_swiftdata_migration_v1"

    static func migrateIfNeeded(
        userDefaults: UserDefaults,
        persistence: ShoppingListPersistenceProtocol
    ) throws -> [KitchenShoppingItem] {
        if userDefaults.bool(forKey: completionKey) {
            let stored = try persistence.loadShoppingItems()
            guard stored.isEmpty else { return stored }
            let legacy = try loadLegacyShoppingItems(from: userDefaults)
            guard !legacy.isEmpty else { return [] }
            try persistence.replaceShoppingItems(with: legacy)
            return try persistence.loadShoppingItems()
        }

        let persistedItems = try persistence.loadShoppingItems()
        let legacyItems = try loadLegacyShoppingItems(from: userDefaults)
        let persistedIDs = Set(persistedItems.map(\.id))
        let mergedItems = persistedItems + legacyItems.filter { !persistedIDs.contains($0.id) }
        let expectedIDs = Set(mergedItems.map(\.id))

        if mergedItems.count != persistedItems.count {
            try persistence.replaceShoppingItems(with: mergedItems)
        }

        let verifiedItems = try persistence.loadShoppingItems()
        guard verifiedItems.count == expectedIDs.count,
              Set(verifiedItems.map(\.id)) == expectedIDs else {
            throw ShoppingListMigrationError.verificationFailed
        }

        userDefaults.set(true, forKey: completionKey)
        return verifiedItems
    }

    static func loadLegacyShoppingItems(from userDefaults: UserDefaults) throws -> [KitchenShoppingItem] {
        guard let data = userDefaults.data(forKey: legacyShoppingKey) else { return [] }
        do {
            return try JSONDecoder().decode([KitchenShoppingItem].self, from: data)
        } catch {
            throw ShoppingListMigrationError.invalidLegacyData(error)
        }
    }
}

enum ShoppingListMigrationError: LocalizedError {
    case invalidLegacyData(Error)
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .invalidLegacyData:
            return "旧购物清单无法读取，已保留原始数据。"
        case .verificationFailed:
            return "购物清单迁移验证失败，已保留旧数据。"
        }
    }
}
