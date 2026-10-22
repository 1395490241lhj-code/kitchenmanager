import XCTest
@testable import KitchenManager

/// After the special-plan table failed to load, `specialPlans` is an empty
/// stand-in. The table is written whole, so the next ordinary edit used to
/// replace it — deleting every record nobody could read.
@MainActor
final class SpecialPlanUnreadableTableTests: XCTestCase {
    private final class UnreadablePersistence: SpecialPlanPersistenceProtocol {
        struct Unreadable: Error {}
        var replaceCount = 0
        var deleteAllCount = 0
        func loadPlans() throws -> [SpecialPlan] { throw Unreadable() }
        func replacePlans(with plans: [SpecialPlan]) throws { replaceCount += 1 }
        func upsert(_ plan: SpecialPlan) throws {}
        func delete(id: UUID) throws {}
        func deleteAll() throws { deleteAllCount += 1 }
    }

    private func makeStore() -> (KitchenStore, UnreadablePersistence) {
        let persistence = UnreadablePersistence()
        let store = KitchenStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            specialPlanPersistence: persistence
        )
        return (store, persistence)
    }

    func testAFailedLoadIsShownOnHome() {
        let (store, _) = makeStore()
        XCTAssertNotNil(store.specialPlanNotice)
        XCTAssertEqual(
            HomeDashboardModuleIssue.issues(
                inventoryNotice: store.inventoryNotice,
                shoppingNotice: store.shoppingNotice,
                specialPlanNotice: store.specialPlanNotice
            ),
            [.specialPlans]
        )
    }

    func testEditsAfterAFailedLoadNeverReplaceTheUnreadableTable() {
        let (store, persistence) = makeStore()

        store.addSpecialPlan(SpecialPlan(title: "周末聚会", scheduledAt: Date()))
        XCTAssertEqual(persistence.replaceCount, 0, "整表覆盖会删掉读不出来的记录")
        XCTAssertTrue(store.specialPlans.isEmpty, "a refused edit does not survive in memory")
        XCTAssertEqual(store.specialPlanNotice, KitchenStore.specialPlansUnreadableWriteRefusedNotice)
    }

    func testAnExplicitClearMakesTheTableWritableAgain() {
        let (store, persistence) = makeStore()
        store.clearAllLocalData()
        XCTAssertEqual(persistence.deleteAllCount, 1)
        XCTAssertNil(store.specialPlanNotice)

        store.addSpecialPlan(SpecialPlan(title: "周末聚会", scheduledAt: Date()))
        XCTAssertEqual(persistence.replaceCount, 1)
        XCTAssertEqual(store.specialPlans.count, 1)
    }

    /// Save failures for meals and the weekly menu were set and never shown.
    func testPlanAndWeeklySaveFailuresAreHomeIssues() {
        XCTAssertEqual(
            HomeDashboardModuleIssue.issues(
                inventoryNotice: nil, shoppingNotice: nil,
                planNotice: "今日计划保存失败，请稍后重试。",
                weeklyPlanNotice: "周菜单保存失败，请稍后重试。"
            ),
            [.plans, .weeklyPlan]
        )
        XCTAssertEqual(HomeDashboardModuleIssue.plans.actionTitle, "查看计划")
    }
}
