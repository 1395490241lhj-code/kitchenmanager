import Foundation

@MainActor enum WeeklyPlanMigration {
    static let legacyKey = "native_km_weekly_plan_v1"
    static let completionKey = "native_km_weekly_plan_swiftdata_migration_v1"
    static func migrateIfNeeded(userDefaults: UserDefaults, persistence: WeeklyPlanPersistenceProtocol) throws -> WeeklyMealPlan? {
        if userDefaults.bool(forKey: completionKey) {
            // One-shot: once the migration has been verified, an empty table is
            // the member's own state (a cleared list, the last plan removed), not
            // a lost store. Re-reading the legacy JSON here brought long-gone
            // data back on every relaunch. The JSON itself stays untouched.
            return try persistence.loadPlan()
        }
        let stored = try persistence.loadPlan()
        let legacy = try loadLegacy(from: userDefaults)
        if stored == nil, let legacy { try persistence.replacePlan(with: legacy) }
        let verified = try persistence.loadPlan()
        guard (legacy == nil || verified != nil) else { throw WeeklyPlanMigrationError.verificationFailed }
        userDefaults.set(true, forKey: completionKey)
        return verified
    }
    static func loadLegacy(from defaults: UserDefaults) throws -> WeeklyMealPlan? {
        guard let data = defaults.data(forKey: legacyKey) else { return nil }
        do { return try JSONDecoder().decode(WeeklyMealPlan.self, from: data) } catch { throw WeeklyPlanMigrationError.invalidLegacy(error) }
    }
}
enum WeeklyPlanMigrationError: LocalizedError { case invalidLegacy(Error), verificationFailed
    var errorDescription: String? { "周菜单迁移失败，已保留旧数据。" }
}
