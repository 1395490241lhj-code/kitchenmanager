import Foundation

@MainActor
enum TodayPlanMigration {
    static let legacyPlansKey = "native_km_plans_v1"
    static let completionKey = "native_km_today_plan_swiftdata_migration_v1"

    static func migrateIfNeeded(
        userDefaults: UserDefaults,
        persistence: TodayPlanPersistenceProtocol
    ) throws -> [MealPlanItem] {
        if userDefaults.bool(forKey: completionKey) {
            // One-shot: once the migration has been verified, an empty table is
            // the member's own state (a cleared list, the last plan removed), not
            // a lost store. Re-reading the legacy JSON here brought long-gone
            // data back on every relaunch. The JSON itself stays untouched.
            return try persistence.loadPlans()
        }

        let persistedItems = try persistence.loadPlans()
        let legacyItems = try loadLegacyPlans(from: userDefaults)
        let persistedIDs = Set(persistedItems.map(\.id))
        let mergedItems = persistedItems + legacyItems.filter { !persistedIDs.contains($0.id) }
        let expectedIDs = Set(mergedItems.map(\.id))

        if mergedItems.count != persistedItems.count {
            try persistence.replacePlans(with: mergedItems)
        }

        let verifiedItems = try persistence.loadPlans()
        guard verifiedItems.count == expectedIDs.count,
              Set(verifiedItems.map(\.id)) == expectedIDs else {
            throw TodayPlanMigrationError.verificationFailed
        }

        userDefaults.set(true, forKey: completionKey)
        return verifiedItems
    }

    static func loadLegacyPlans(from userDefaults: UserDefaults) throws -> [MealPlanItem] {
        guard let data = userDefaults.data(forKey: legacyPlansKey) else { return [] }
        do {
            return try JSONDecoder().decode([MealPlanItem].self, from: data)
        } catch {
            throw TodayPlanMigrationError.invalidLegacyData(error)
        }
    }
}

enum TodayPlanMigrationError: LocalizedError {
    case invalidLegacyData(Error)
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .invalidLegacyData:
            return "旧今日计划无法读取，已保留原始数据。"
        case .verificationFailed:
            return "今日计划迁移验证失败，已保留旧数据。"
        }
    }
}
