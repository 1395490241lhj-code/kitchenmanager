import XCTest
@testable import KitchenManager

@MainActor
final class PreparedPortionGroupingUsageTests: XCTestCase {
    func testGroupedConsumptionFeedbackScopesCountsAndExhaustionToTheGroup() throws {
        let source = try PreparedSourceSnapshot(id: UUID(), name: "鸡肉", initialMassDecigrams: 1000, initialPortionCount: 3)
        var row = PreparedComponent(name: "鸡肉", portionsRemaining: 2, state: .cooked, storage: .frozen,
            preparedAt: Date(), expiryDate: Date(),
            grouping: try PreparedPortionGrouping(source: source, massPerPortionDecigrams: 333))
        for context in [PreparedPortionConsumptionFeedback.Context.preparedList, .meal] {
            XCTAssertEqual(PreparedPortionConsumptionFeedback.message(for: row, context: context),
                "这组还剩 1 份")
        }
        row.portionsRemaining = 1
        for context in [PreparedPortionConsumptionFeedback.Context.preparedList, .meal] {
            XCTAssertEqual(PreparedPortionConsumptionFeedback.message(for: row, context: context),
                "这组已用完")
        }
        row.grouping = nil
        XCTAssertEqual(PreparedPortionConsumptionFeedback.message(for: row, context: .preparedList), "「鸡肉」已吃完，记录已移除")
        XCTAssertEqual(PreparedPortionConsumptionFeedback.message(for: row, context: .meal), "鸡肉已用完")
        row.portionsRemaining = 2
        XCTAssertEqual(PreparedPortionConsumptionFeedback.message(for: row, context: .preparedList), "已吃掉一份，还剩 1 份")
        XCTAssertEqual(PreparedPortionConsumptionFeedback.message(for: row, context: .meal), "已使用 1 份鸡肉，还剩 1 份")
    }
    func testGroupedUsageDisclosesRoundingMassAndDistinctLiveGroupContext() throws {
        let suite = "grouped-usage-\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KitchenStore(userDefaults: defaults)
        var draft = PreparedComponentFormDraft(); draft.name = "鸡肉"; draft.massText = "100"; draft.portions = 3
        let rows = try draft.save(in: store).get()
        let sources = rows.map { QuickMealCandidateSource.preparedComponent($0.id) }
        let usages = PreparedPortionUsage.resolve(sources: sources, among: rows)
        XCTAssertEqual(usages.map(\.id), rows.map(\.id))
        XCTAssertTrue(usages[0].detailText?.contains("33.4g") == true)
        XCTAssertTrue(usages[1].detailText?.contains("33.3g") == true)
        XCTAssertTrue(usages[0].buttonLabel.contains("33.4克"))
        XCTAssertTrue(usages[1].buttonLabel.contains("33.3克"))
        XCTAssertTrue(usages[0].detailText?.contains("第1组") == true)
        XCTAssertTrue(usages[1].detailText?.contains("第2组") == true)
        XCTAssertTrue(usages[0].detailText?.contains("已做熟") == true)
        XCTAssertTrue(usages[0].detailText?.contains("冷藏") == true)
        _ = try store.consumePreparedPortion(id: usages[0].id).get()
        let after = PreparedPortionUsage.resolve(sources: sources, among: store.preparedComponents)
        XCTAssertEqual(after.map(\.id), [rows[1].id])
        XCTAssertTrue(after[0].buttonLabel.contains("33.3克"))
        XCTAssertTrue(PreparedPortionUsage.resolve(sources: [.preparedComponent(draft.sourceID)], among: rows).isEmpty)
    }
    func testLegacyUsageKeepsExistingLabelAndDoesNotInventMass() throws {
        let row = PreparedComponent(name: "卤鸡腿", portionsRemaining: 3, state: .cooked, storage: .refrigerated,
            preparedAt: Date(), expiryDate: Date())
        let usage = try XCTUnwrap(PreparedPortionUsage.resolve(sources: [.preparedComponent(row.id)], among: [row]).first)
        XCTAssertNil(usage.detailText); XCTAssertNil(usage.spokenDetail)
        XCTAssertEqual(usage.remainingText, "备餐剩 3 份")
        XCTAssertEqual(usage.buttonLabel, "使用 1 份卤鸡腿")
        var frozen = row; frozen.storage = .frozen
        XCTAssertTrue(PreparedPortionUsage.resolve(sources: [.preparedComponent(frozen.id)], among: [frozen]).isEmpty)
    }
}
