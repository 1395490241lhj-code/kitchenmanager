import Foundation

@MainActor
enum ConsumptionMigration {
    static let legacyRecordsKey = "native_km_consumption_records_v1"
    static let completionKey = "native_km_consumption_swiftdata_migration_v1"

    static func migrateIfNeeded(
        userDefaults: UserDefaults,
        persistence: ConsumptionPersistenceProtocol
    ) throws -> [InventoryConsumptionRecord] {
        if userDefaults.bool(forKey: completionKey) {
            let stored = try persistence.loadRecords()
            guard stored.isEmpty else { return stored }
            let legacy = try loadLegacyRecords(from: userDefaults)
            guard !legacy.isEmpty else { return [] }
            try persistence.replaceRecords(with: legacy)
            return try persistence.loadRecords()
        }

        let persistedRecords = try persistence.loadRecords()
        let legacyRecords = try loadLegacyRecords(from: userDefaults)
        let persistedIDs = Set(persistedRecords.map(\.id))
        let mergedRecords = persistedRecords + legacyRecords.filter { !persistedIDs.contains($0.id) }
        let expectedIDs = Set(mergedRecords.map(\.id))

        if mergedRecords.count != persistedRecords.count {
            try persistence.replaceRecords(with: mergedRecords)
        }

        let verifiedRecords = try persistence.loadRecords()
        guard verifiedRecords.count == expectedIDs.count,
              Set(verifiedRecords.map(\.id)) == expectedIDs else {
            throw ConsumptionMigrationError.verificationFailed
        }

        userDefaults.set(true, forKey: completionKey)
        return verifiedRecords
    }

    static func loadLegacyRecords(from userDefaults: UserDefaults) throws -> [InventoryConsumptionRecord] {
        guard let data = userDefaults.data(forKey: legacyRecordsKey) else { return [] }
        do {
            return try JSONDecoder().decode([InventoryConsumptionRecord].self, from: data)
        } catch {
            throw ConsumptionMigrationError.invalidLegacyData(error)
        }
    }
}

enum ConsumptionMigrationError: LocalizedError {
    case invalidLegacyData(Error)
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .invalidLegacyData:
            return "旧消耗记录无法读取，已保留原始数据。"
        case .verificationFailed:
            return "消耗记录迁移验证失败，已保留旧数据。"
        }
    }
}
