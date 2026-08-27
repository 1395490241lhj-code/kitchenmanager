import XCTest
@testable import KitchenManager

@MainActor
final class QuickMealCandidateTests: XCTestCase {
    private func item(_ name: String, expiringInDays days: Int? = nil, quantity: Double = 1) -> InventoryItem {
        InventoryItem(
            name: name,
            quantity: quantity,
            unit: "份",
            expiryDate: days.map { Calendar.current.date(byAdding: .day, value: $0, to: Date())! },
            createdAt: Date()
        )
    }

    private func batch(
        _ name: String,
        _ state: PreparedComponentState,
        portions: Int = 3,
        expiringInDays days: Int = 3
    ) -> PreparedComponent {
        PreparedComponent(
            name: name,
            portionsRemaining: portions,
            state: state,
            storage: .refrigerated,
            preparedAt: Date(),
            expiryDate: Calendar.current.date(byAdding: .day, value: days, to: Date())!
        )
    }

    // MARK: - Provenance

    func testEachDomainKeepsItsOwnIdentityThroughTheCandidate() {
        let stock = item("米饭")
        let prepared = batch("卤牛肉", .cooked)

        let fromInventory = QuickMealCandidate(inventoryItem: stock)
        let fromPrepared = QuickMealCandidate(preparedComponent: prepared)

        XCTAssertEqual(fromInventory.source, .inventory(stock.id))
        XCTAssertEqual(fromPrepared.source, .preparedComponent(prepared.id))
        XCTAssertNotEqual(fromInventory.source, fromPrepared.source)
    }

    func testTheSameUUIDInBothDomainsIsStillTwoDifferentCandidates() {
        // Sources are keyed by domain as well as id, so identity can never
        // collide even if two records somehow shared a UUID.
        let id = UUID()
        XCTAssertNotEqual(
            QuickMealCandidateSource.inventory(id),
            QuickMealCandidateSource.preparedComponent(id)
        )
    }

    // MARK: - Profile derivation

    func testAnInventoryItemIsClassifiedExactlyAsBefore() {
        for name in ["米饭", "大米", "挂面", "米粉", "冷冻饺子", "卤牛肉", "腌鸡肉", "上海青", "盐"] {
            XCTAssertEqual(
                QuickMealCandidate(inventoryItem: item(name)).profile,
                QuickFoodProfileClassifier.profile(for: name),
                "\(name) must classify identically to P0-3C"
            )
        }
    }

    func testAPreparedBatchTakesItsPreparationStateFromTheStoredFactNotTheName() {
        // The name carries no 腌 / 卤 hint at all.
        let prepped = QuickMealCandidate(preparedComponent: batch("鸡肉", .prepped))
        XCTAssertEqual(prepped.profile.preparationState, .prepped)
        XCTAssertNotEqual(
            prepped.profile.preparationState,
            QuickFoodProfileClassifier.profile(for: "鸡肉").preparationState,
            "name inference would call plain 鸡肉 raw; the stored state must win"
        )

        let cooked = QuickMealCandidate(preparedComponent: batch("鸡肉", .cooked))
        XCTAssertEqual(cooked.profile.preparationState, .cooked)
    }

    func testAPreparedBatchStillTakesItsRolesAndFormFromTheName() {
        let beef = QuickMealCandidate(preparedComponent: batch("卤牛肉", .cooked))
        XCTAssertTrue(beef.profile.has(.protein))
        XCTAssertNil(beef.profile.form)

        let rice = QuickMealCandidate(preparedComponent: batch("米饭", .cooked))
        XCTAssertTrue(rice.profile.has(.carb))
        XCTAssertEqual(rice.profile.form, .rice)
    }

    func testTheStoredStateWinsEvenWhereNameInferenceWouldDisagree() {
        // If name inference ever changed its mind about 卤, the structured fact
        // must still decide. Asserting the override rather than the coincidence.
        let component = batch("卤牛肉", .prepped)
        let candidate = QuickMealCandidate(preparedComponent: component)
        XCTAssertEqual(candidate.profile.preparationState, .prepped)
        XCTAssertEqual(QuickFoodProfileClassifier.profile(for: "卤牛肉").preparationState, .cooked)
    }

    func testTheStateMappingIsExplicitAndTotal() {
        XCTAssertEqual(PreparedComponentState.prepped.quickMealPreparationState, .prepped)
        XCTAssertEqual(PreparedComponentState.cooked.quickMealPreparationState, .cooked)
        for state in PreparedComponentState.allCases {
            let mapped = state.quickMealPreparationState
            XCTAssertTrue(
                mapped == .prepped || mapped == .cooked,
                "a batch can never be raw, convenience or unknown"
            )
        }
    }

    func testTheClassifierStaysASinglePathWhenNoStateIsSupplied() {
        for name in ["卤牛肉", "腌鸡肉", "米饭", "神秘食材"] {
            XCTAssertEqual(
                QuickFoodProfileClassifier.profile(for: name, preparationState: nil),
                QuickFoodProfileClassifier.profile(for: name)
            )
        }
    }

    // MARK: - Availability

    func testInventoryKeepsItsQuantityRuleAndPreparedBatchesNeedNone() {
        var empty = item("挂面")
        empty.quantity = 0
        let pool = QuickMealCandidate.pool(
            inventory: [empty, item("米饭")],
            preparedComponents: [batch("卤牛肉", .cooked)]
        )

        XCTAssertFalse(pool.contains { $0.name == "挂面" }, "a depleted inventory row is out")
        XCTAssertTrue(pool.contains { $0.name == "米饭" })
        // P1-B guarantees a stored batch always has at least one portion.
        XCTAssertTrue(pool.contains { $0.name == "卤牛肉" })
    }

    func testSeasoningsAndUnclassifiedItemsAreStillExcluded() {
        let pool = QuickMealCandidate.pool(
            inventory: [item("盐"), item("神秘食材")],
            preparedComponents: []
        )
        XCTAssertTrue(pool.isEmpty)
    }

    // MARK: - Expiry rule parity

    func testTheCandidateExpiryWindowMatchesTheInventoryOne() {
        // Ranking must not shift because a second threshold crept in.
        for days in [-5, -1, 0, 1, 2, 3, 4, 7, 30] {
            let stock = item("上海青", expiringInDays: days)
            XCTAssertEqual(
                QuickMealCandidate(inventoryItem: stock).isExpiringSoon,
                stock.isExpiringSoon,
                "day offset \(days) must be judged the same way by both"
            )
        }
        XCTAssertFalse(QuickMealCandidate(inventoryItem: item("大米")).isExpiringSoon, "no date, no urgency")
    }

    func testAPreparedBatchNearItsDateCountsAsUrgent() {
        XCTAssertTrue(QuickMealCandidate(preparedComponent: batch("卤牛肉", .cooked, expiringInDays: 1)).isExpiringSoon)
        XCTAssertFalse(QuickMealCandidate(preparedComponent: batch("卤牛肉", .cooked, expiringInDays: 20)).isExpiringSoon)
    }
}
