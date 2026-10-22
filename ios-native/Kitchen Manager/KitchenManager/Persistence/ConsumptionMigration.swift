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
            // One-shot: once the migration has been verified, an empty table is
            // the member's own state (a cleared list, the last plan removed), not
            // a lost store. Re-reading the legacy JSON here brought long-gone
            // data back on every relaunch. The JSON itself stays untouched.
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
