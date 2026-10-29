import XCTest
@testable import KitchenManager

@MainActor
final class PreparedLifecycleRecommendationTests: XCTestCase {
    private func inventory(_ name: String) -> InventoryItem {
        InventoryItem(name: name, quantity: 2, unit: "份", expiryDate: nil)
    }
    func testEligibilityMatrixAndExistingPolicies() throws {
        for state in PreparedComponentState.allCases {
            for storage in PreparedStorage.allCases {
                let row = PreparedLifecycleBackupFixtures.row(state: state, storage: storage)
                let pool = QuickMealCandidate.pool(inventory: [], preparedComponents: [row])
                XCTAssertEqual(pool.count, storage == .refrigerated ? 1 : 0)
                let quick = QuickMealAssemblyEngine.assemble(inventory: [inventory("米饭"), inventory("西兰花")], preparedComponents: [row])
                let plate = ComponentMealPolicy.assemble(inventory: [inventory("米饭"), inventory("西兰花")], preparedComponents: [row])
                XCTAssertEqual(quick.suggestions.isEmpty, storage == .frozen)
                XCTAssertEqual(plate.suggestion == nil, storage == .frozen)
                if storage == .refrigerated {
                    var tracked = row
                    tracked.lifecycle = PreparedLifecycle(version: 1, thawPhase: .inactive,
                        thawStartedAt: row.preparedAt, thawCompletedAt: row.preparedAt,
                        cookedAt: state == .cooked ? row.preparedAt : nil)
                    XCTAssertEqual(QuickMealCandidate.pool(inventory: [], preparedComponents: [tracked]).count, 1)
                    XCTAssertNotNil(ComponentMealPolicy.assemble(inventory: [inventory("米饭"), inventory("西兰花")], preparedComponents: [tracked]).suggestion)
                }
            }
            var thaw = PreparedLifecycleBackupFixtures.row(state: state, storage: .refrigerated)
            thaw.lifecycle = PreparedLifecycle(version: 1, thawPhase: .thawing,
                thawStartedAt: PreparedLifecycleBackupFixtures.at, thawCompletedAt: nil,
                cookedAt: state == .cooked ? PreparedLifecycleBackupFixtures.at : nil)
            XCTAssertTrue(QuickMealCandidate.pool(inventory: [], preparedComponents: [thaw]).isEmpty)
            XCTAssertNil(ComponentMealPolicy.assemble(inventory: [inventory("米饭"), inventory("西兰花")], preparedComponents: [thaw]).suggestion)
        }
        let frozenConvenience = inventory("速冻饺子")
        XCTAssertEqual(QuickMealCandidate.pool(inventory: [frozenConvenience], preparedComponents: []).map(\.source), [.inventory(frozenConvenience.id)])
    }

    func testEligibleSiblingSurvivesPerGroupFilter() throws {
        let source = try PreparedSourceSnapshot(id: UUID(), name: "鸡肉", initialMassDecigrams: 8000, initialPortionCount: 4)
        let grouping = try PreparedPortionGrouping(source: source, massPerPortionDecigrams: 2000)
        var frozen = PreparedLifecycleBackupFixtures.row(state: .cooked, count: 2); frozen.grouping = grouping
        var thaw = frozen; thaw.id = UUID(); thaw.portionsRemaining = 1; thaw.storage = .refrigerated
        thaw.lifecycle = PreparedLifecycle(version: 1, thawPhase: .thawing,
            thawStartedAt: frozen.preparedAt, thawCompletedAt: nil, cookedAt: nil)
        var usable = frozen; usable.id = UUID(); usable.portionsRemaining = 1; usable.storage = .refrigerated
        let rows = [frozen, thaw, usable]
        let sides = [inventory("米饭"), inventory("西兰花")]
        let quick = QuickMealAssemblyEngine.assemble(inventory: sides, preparedComponents: rows)
        let plate = try XCTUnwrap(ComponentMealPolicy.assemble(inventory: sides, preparedComponents: rows).suggestion)
        XCTAssertFalse(quick.suggestions.isEmpty)
        XCTAssertEqual(Set(quick.suggestions.flatMap(\.componentSources).filter { if case .preparedComponent = $0 { true } else { false } }), [.preparedComponent(usable.id)])
        XCTAssertTrue(plate.componentSources.contains(.preparedComponent(usable.id)))
        XCTAssertEqual(try PreparedSourceSection.make(rows).first?.remainingPortionCount, 4)
        XCTAssertEqual(try KitchenBackupValidator.validate(KitchenBackupValidator.encodeV3(PreparedLifecycleBackupFixtures.payload(rows))).preparedComponents, rows)
    }

    func testDisplayedExpectedRowIsNotReplacedAtTapTime() throws {
        for field in ["lifecycle", "storage", "expiry", "quantity", "missing"] {
            let bundle = KitchenPersistenceFactory.isolatedInMemory()
            let store = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!, persistence: bundle)
            let row = PreparedLifecycleBackupFixtures.row(storage: .refrigerated)
            try store.addPreparedComponent(row).get()
            let usage = try XCTUnwrap(PreparedPortionUsage.resolve(sources: [.preparedComponent(row.id)], among: store.preparedComponents).first)
            XCTAssertEqual(usage.expected, row)
            var changed = row
            switch field {
            case "lifecycle": changed.lifecycle = PreparedLifecycleBackupFixtures.thaw
            case "storage": changed.storage = .frozen
            case "expiry": changed.expiryDate.addTimeInterval(1)
            case "quantity": changed.portionsRemaining -= 1
            default: break
            }
            try bundle.preparedComponents.replaceComponents(with: field == "missing" ? [] : [changed])
            try store.reloadPreparedComponents().get()
            let before = store.preparedComponents
            XCTAssertEqual(store.consumePreparedPortion(id: usage.id, expected: usage.expected, context: .immediateMeal),
                .failure(field == "missing" ? .missingRecord : .staleRecord))
            XCTAssertEqual(store.preparedComponents, before)
            XCTAssertEqual(try bundle.preparedComponents.loadComponents(), before)
        }
        let store = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let first = PreparedLifecycleBackupFixtures.row(storage: .refrigerated)
        var sibling = first; sibling.id = UUID()
        try store.addPreparedComponent(first).get(); try store.addPreparedComponent(sibling).get()
        let captured = PreparedPortionUsage.resolve(sources: [.preparedComponent(first.id)], among: store.preparedComponents)[0]
        _ = try store.consumePreparedPortion(id: captured.id, expected: captured.expected, context: .immediateMeal).get()
        XCTAssertEqual(store.consumePreparedPortion(id: captured.id, expected: captured.expected, context: .immediateMeal), .failure(.staleRecord))
        let next = PreparedPortionUsage.resolve(sources: [.preparedComponent(sibling.id)], among: store.preparedComponents)[0]
        _ = try store.consumePreparedPortion(id: next.id, expected: next.expected, context: .immediateMeal).get()
        XCTAssertEqual(store.preparedComponents.map(\.portionsRemaining), [3, 3])
    }
}
