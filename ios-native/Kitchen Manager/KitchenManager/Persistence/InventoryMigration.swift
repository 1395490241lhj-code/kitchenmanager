import Foundation

@MainActor
enum InventoryMigration {
    static let legacyInventoryKey = "native_km_inventory_v1"
    static let completionKey = "native_km_inventory_swiftdata_migration_v1"

    static func migrateIfNeeded(
        userDefaults: UserDefaults,
        persistence: InventoryPersistenceProtocol
    ) throws -> [InventoryItem] {
        if userDefaults.bool(forKey: completionKey) {
            let stored = try persistence.loadInventory()
            guard stored.isEmpty else { return stored }
            let legacy = try loadLegacyInventory(from: userDefaults)
            guard !legacy.isEmpty else { return [] }
            try persistence.replaceInventory(with: legacy)
            return try persistence.loadInventory()
        }

        let persistedItems = try persistence.loadInventory()
        let legacyItems = try loadLegacyInventory(from: userDefaults)
        var mergedByID = Dictionary(
            persistedItems.map { ($0.id, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
        for item in legacyItems where mergedByID[item.id] == nil {
            mergedByID[item.id] = item
        }

        let mergedItems = persistedItems + legacyItems.filter { legacy in
            !persistedItems.contains(where: { $0.id == legacy.id })
        }
        if mergedItems.count != persistedItems.count {
            try persistence.replaceInventory(with: mergedItems)
        }

        let verifiedItems = try persistence.loadInventory()
        guard verifiedItems.count == mergedByID.count,
              Set(verifiedItems.map(\.id)) == Set(mergedByID.keys) else {
            throw InventoryMigrationError.verificationFailed
        }

        userDefaults.set(true, forKey: completionKey)
        return verifiedItems
    }

    static func loadLegacyInventory(from userDefaults: UserDefaults) throws -> [InventoryItem] {
        guard let data = userDefaults.data(forKey: legacyInventoryKey) else { return [] }
        do {
            return try JSONDecoder().decode([InventoryItem].self, from: data)
        } catch {
            throw InventoryMigrationError.invalidLegacyData(error)
        }
    }
}

enum InventoryMigrationError: LocalizedError {
    case invalidLegacyData(Error)
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .invalidLegacyData:
            return "旧库存数据无法读取，已保留原始数据。"
        case .verificationFailed:
            return "库存迁移验证失败，已保留旧库存数据。"
        }
    }
}
