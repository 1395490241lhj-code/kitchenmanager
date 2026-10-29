import XCTest
@testable import KitchenManager

@MainActor
final class PreparedPortionGroupingRecommendationTests: XCTestCase {
    private func rows(_ name: String, mass: Int64 = 8000, count: Int = 4,
                      state: PreparedComponentState = .cooked) throws -> [PreparedComponent] {
        let source = try PreparedSourceSnapshot(id: UUID(), name: name, initialMassDecigrams: mass, initialPortionCount: count)
        let ids = (0..<(mass % Int64(count) == 0 ? 1 : 2)).map { _ in UUID() }
        return try PreparedPortionAllocator.allocate(source: source, groupIDs: ids).groups.map { group in
            PreparedComponent(id: group.id, name: name, portionsRemaining: group.count, state: state, storage: .refrigerated,
                preparedAt: Date(timeIntervalSince1970: 100), expiryDate: Date(timeIntervalSince1970: 200),
                grouping: try PreparedPortionGrouping(source: source, massPerPortionDecigrams: group.massPerPortionDecigrams))
        }
    }
    private func split(_ row: PreparedComponent) -> [PreparedComponent] {
        var remainder = row; remainder.portionsRemaining -= 1
        var sibling = row; sibling.id = UUID(); sibling.portionsRemaining = 1
        return [remainder, sibling]
    }
    private func item(_ name: String, id: UUID = UUID()) -> InventoryItem {
        InventoryItem(id: id, name: name, quantity: 2, unit: "份", expiryDate: nil)
    }
    func testLinkedRoundingCandidatesKeepBothActionUUIDsButShareOneSelectionIdentity() throws {
        let rows = try rows("红薯", mass: 1000, count: 3)
        let candidates = QuickMealCandidate.pool(inventory: [], preparedComponents: rows)
        XCTAssertEqual(candidates.count, 2, "do not collapse expiry/profile facts globally")
        XCTAssertEqual(candidates.map(\.source), rows.map { .preparedComponent($0.id) })
        XCTAssertEqual(Set(candidates.map(\.selectionIdentity)), [.preparedSource(rows[0].grouping!.source.id)])
    }
    func testLegacyInventoryAndLinkedSourceNamespacesRemainIndependentEvenForSameUUID() throws {
        let linked = try XCTUnwrap(rows("红薯").first)
        let id = linked.grouping!.source.id
        var legacy = linked; legacy.id = id; legacy.grouping = nil
        let stock = item("红薯", id: id)
        let candidates = QuickMealCandidate.pool(inventory: [stock], preparedComponents: [legacy, linked])
        XCTAssertEqual(candidates.map(\.selectionIdentity), [.inventory(id), .legacyPreparedComponent(id), .preparedSource(id)])
        XCTAssertEqual(Set(candidates.map(\.selectionIdentity)).count, 3)
    }
    func testSplitSweetPotatoOrCornCannotCreateACompleteComponentMeal() throws {
        for name in ["红薯", "玉米"] {
            let carb = try XCTUnwrap(rows(name).first)
            let protein = try rows("鸡肉")
            let before = ComponentMealPolicy.assemble(inventory: [], preparedComponents: [carb] + protein)
            let after = ComponentMealPolicy.assemble(inventory: [], preparedComponents: split(carb) + protein)
            XCTAssertNil(before.suggestion); XCTAssertNil(after.suggestion)
            XCTAssertEqual(after.gaps, before.gaps)
        }
    }
    func testRoundingBucketsCannotFillBothComponentMealRoles() throws {
        for name in ["红薯", "玉米"] {
            let result = ComponentMealPolicy.assemble(inventory: [], preparedComponents: try rows(name, mass: 1000, count: 3) + rows("鸡肉"))
            XCTAssertNil(result.suggestion); XCTAssertEqual(result.gaps, [.missingVegetable])
        }
    }
    func testSplitDoesNotAddQuickMealComponentsAlternativesOrChangeRankingAndEffort() throws {
        for name in ["红薯", "玉米"] {
            let carb = try XCTUnwrap(rows(name).first); let chicken = try rows("鸡肉", state: .prepped)
            let before = QuickMealAssemblyEngine.assemble(inventory: [], preparedComponents: [carb] + chicken)
            let after = QuickMealAssemblyEngine.assemble(inventory: [], preparedComponents: split(carb) + chicken)
            XCTAssertFalse(before.suggestions.isEmpty)
            XCTAssertEqual(after.suggestions.map(\.template), before.suggestions.map(\.template))
            XCTAssertEqual(after.suggestions.map(\.effort), before.suggestions.map(\.effort))
            XCTAssertEqual(after.suggestions.map { $0.components.map(\.name) }, before.suggestions.map { $0.components.map(\.name) })
            XCTAssertEqual(after.suggestions.map(\.selectionIdentities), before.suggestions.map(\.selectionIdentities))
        }
    }
    func testRoundingQuickMealUsesEachSourceOnceAndHasNoDuplicateSelectionSets() throws {
        let grouped = try rows("红薯", mass: 1000, count: 3) + rows("鸡肉", state: .prepped)
        let result = QuickMealAssemblyEngine.assemble(inventory: [], preparedComponents: grouped)
        XCTAssertFalse(result.suggestions.isEmpty)
        for suggestion in result.suggestions {
            XCTAssertEqual(suggestion.selectionIdentities.count, suggestion.components.count)
        }
        XCTAssertEqual(Set(result.suggestions.map(\.selectionIdentities)).count, result.suggestions.count)
    }
    func testQuickMealDeduplicationAndSubsetComparisonUseSelectionInsteadOfActionIDs() throws {
        // Name corrections may change role/form facts without changing linkage.
        // Keep both candidates so each template can still evaluate those facts.
        var carbs = split(try XCTUnwrap(rows("米饭").first))
        carbs[1].name = "面条"
        let protein = try rows("鸡肉")
        let plain = QuickMealAssemblyEngine.assemble(inventory: [], preparedComponents: carbs + protein)
        XCTAssertEqual(plain.suggestions.count, 1)
        XCTAssertEqual(plain.suggestions.first?.template, .preparedWithCarb)
        XCTAssertEqual(plain.suggestions.first?.components.count, 2)
        // Equal-effort subset removal must also see the common carb source,
        // although the noodle template uses a different live group UUID.
        let full = QuickMealAssemblyEngine.assemble(inventory: [], preparedComponents: try carbs + protein + rows("西兰花"))
        XCTAssertEqual(full.suggestions.count, 1)
        XCTAssertEqual(full.suggestions.first?.template, .riceBowl)
        XCTAssertEqual(full.suggestions.first?.components.count, 3)
    }

    func testNoProteinNoodleFallbackExcludesReadyMadeSourceFromVegetableAndKeepsIndependentVegetable() throws {
        let suite = "pr2-noodle-\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KitchenStore(userDefaults: defaults)
        store.addInventory(name: "挂面", quantity: 1, unit: "份", expiryDate: nil)
        let later = Calendar.current.date(byAdding: .day, value: 20, to: Date())!
        let draft = PreparedSourceDraft(sourceID: UUID(), groupIDs: [UUID()], name: "剩菜", massDecigrams: 8000,
            portionCount: 4, state: .cooked, storage: .refrigerated, preparedAt: Date(), expiryDate: later)
        let original = try XCTUnwrap(store.addPreparedSource(draft: draft).get().first)
        let pair = try store.splitPreparedComponent(id: original.id, taking: 1, newGroupID: UUID(), expected: original).get()
        var readyMade = pair[0]; readyMade.expiryDate = Date()
        _ = try store.updatePreparedComponent(readyMade, expected: pair[0]).get()
        var sibling = pair[1]; sibling.name = "西兰花"
        _ = try store.updatePreparedComponent(sibling, expected: pair[1]).get()
        let result = QuickMealAssemblyEngine.assemble(inventory: store.inventory, preparedComponents: store.preparedComponents)
        let noodle = try XCTUnwrap(result.suggestions.first { $0.template == .noodleBowl })
        XCTAssertEqual(noodle.selectionIdentities.count, noodle.components.count)
        XCTAssertEqual(noodle.components.map(\.slot), [.carb, .readyMade])
        XCTAssertTrue(noodle.componentSources.contains(.preparedComponent(readyMade.id)))
        XCTAssertFalse(noodle.componentSources.contains(.preparedComponent(sibling.id)))
        XCTAssertEqual(PreparedPortionUsage.resolve(sources: Array(noodle.componentSources), among: store.preparedComponents).map(\.id), [readyMade.id])
        var independent = try XCTUnwrap(rows("西兰花").first); independent.expiryDate = later
        let full = try XCTUnwrap(QuickMealAssemblyEngine.assemble(inventory: store.inventory,
            preparedComponents: store.preparedComponents + [independent]).suggestions.first { $0.template == .noodleBowl })
        XCTAssertEqual(full.selectionIdentities.count, 3)
        XCTAssertEqual(full.components.first { $0.slot == .vegetable }?.source, .preparedComponent(independent.id))
        XCTAssertEqual(full.effort, noodle.effort, "existing cooked-vegetable effort policy stays intact")
    }

    func testIndependentSameNameSourcesAndInventoryCanStillFillDifferentSlots() throws {
        let first = try rows("红薯"); let second = try rows("红薯"); let chicken = try rows("鸡肉")
        let separate = ComponentMealPolicy.assemble(inventory: [], preparedComponents: first + second + chicken)
        let suggestion = try XCTUnwrap(separate.suggestion)
        XCTAssertEqual(Set(suggestion.components.map(\.candidate.selectionIdentity)).count, 3)
        let stock = item("红薯", id: first[0].grouping!.source.id)
        XCTAssertNotNil(ComponentMealPolicy.assemble(inventory: [stock], preparedComponents: first + chicken).suggestion)
    }
    func testGroupFactsRemainEligibleAfterSiblingIsExcludedAndExpiryStillPicksLiveGroup() throws {
        var groups = split(try XCTUnwrap(rows("鸡肉").first))
        groups[0].expiryDate = Calendar.current.date(byAdding: .day, value: 20, to: Date())!
        groups[1].expiryDate = Date()
        let candidates = QuickMealCandidate.pool(inventory: [item("米饭"), item("西兰花")], preparedComponents: groups)
        XCTAssertEqual(candidates.filter { if case .preparedComponent = $0.source { return true }; return false }.count, 2)
        let component = try XCTUnwrap(ComponentMealPolicy.assemble(inventory: [item("米饭"), item("西兰花")], preparedComponents: groups).suggestion)
        XCTAssertEqual(component.protein.source, .preparedComponent(groups[1].id))
        let quick = QuickMealAssemblyEngine.assemble(inventory: [item("米饭")], preparedComponents: groups)
        XCTAssertTrue(quick.suggestions.allSatisfy { $0.componentSources.contains(.preparedComponent(groups[1].id)) })
    }
    func testSuggestionsConsumeLiveGroupUUIDAndReassembleFromSiblingAfterDepletion() throws {
        let suite = "pr2-recommendation-\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KitchenStore(userDefaults: defaults)
        store.addInventory(name: "米饭", quantity: 2, unit: "份", expiryDate: nil)
        store.addInventory(name: "西兰花", quantity: 2, unit: "份", expiryDate: nil)
        let draft = PreparedSourceDraft(sourceID: UUID(), groupIDs: [UUID()], name: "鸡肉", massDecigrams: 8000,
            portionCount: 4, state: .cooked, storage: .refrigerated, preparedAt: Date(),
            expiryDate: Calendar.current.date(byAdding: .day, value: 20, to: Date())!)
        let row = try XCTUnwrap(store.addPreparedSource(draft: draft).get().first)
        let pair = try store.splitPreparedComponent(id: row.id, taking: 1, newGroupID: UUID(), expected: row).get()
        var soon = pair[1]; soon.expiryDate = Date()
        _ = try store.updatePreparedComponent(soon, expected: pair[1]).get()
        let quick = try XCTUnwrap(QuickMealAssemblyEngine.assemble(inventory: store.inventory, preparedComponents: store.preparedComponents).suggestions.first)
        let component = try XCTUnwrap(ComponentMealPolicy.assemble(inventory: store.inventory, preparedComponents: store.preparedComponents).suggestion)
        let sources = component.componentSources + Array(quick.componentSources)
        let usages = PreparedPortionUsage.resolve(sources: sources, among: store.preparedComponents)
        XCTAssertEqual(usages.map(\.id), [soon.id])
        XCTAssertEqual(store.consumePreparedPortion(id: draft.sourceID), .failure(.missingRecord))
        _ = try store.consumePreparedPortion(id: usages[0].id).get()
        XCTAssertTrue(PreparedPortionUsage.resolve(sources: sources, among: store.preparedComponents).isEmpty)
        let next = try XCTUnwrap(ComponentMealPolicy.assemble(inventory: store.inventory, preparedComponents: store.preparedComponents).suggestion)
        XCTAssertEqual(next.protein.source, .preparedComponent(row.id))
        XCTAssertEqual(next.protein.candidate.selectionIdentity, .preparedSource(draft.sourceID))
        XCTAssertEqual(store.preparedComponents, [pair[0]])
    }
}
