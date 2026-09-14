import XCTest
@testable import KitchenManager

/// Feature 005, Phase 5: a restore reports which of five things actually
/// happened, and never calls an unproven recovery "recovered".
///
/// Failures are injected per call at the persistence boundary, so a restore
/// write and the compensating write that follows it can be failed
/// independently. Nothing here relies on provoking a real SwiftData fault.
@MainActor
final class RestoreOutcomeTests: XCTestCase {
    private struct Injected: Error {}

    // MARK: - Scripted persistences

    /// Shared script: which 1-based replace calls throw, and whether loads
    /// throw. `arm` zeroes the counter so seeding writes never shift the index.
    private final class Script {
        var failReplaceCalls: Set<Int> = []
        var failLoad = false
        var replaceCalls = 0
        func shouldFailReplace() -> Bool {
            replaceCalls += 1
            return failReplaceCalls.contains(replaceCalls)
        }
        func arm(replaceCalls failing: Set<Int> = [], failLoad: Bool = false) {
            self.failReplaceCalls = failing
            self.failLoad = failLoad
            self.replaceCalls = 0
        }
    }

    private final class ScriptedInventory: InventoryPersistenceProtocol {
        let wrapped: InventoryPersistenceProtocol; let script: Script
        init(_ w: InventoryPersistenceProtocol, _ s: Script) { wrapped = w; script = s }
        func loadInventory() throws -> [InventoryItem] {
            if script.failLoad { throw Injected() }
            return try wrapped.loadInventory()
        }
        func replaceInventory(with items: [InventoryItem]) throws {
            if script.shouldFailReplace() { throw Injected() }
            try wrapped.replaceInventory(with: items)
        }
        func upsert(_ item: InventoryItem) throws { try wrapped.upsert(item) }
        func delete(id: UUID) throws { try wrapped.delete(id: id) }
        func deleteAll() throws { try wrapped.deleteAll() }
        func applyChanges(upserting items: [InventoryItem], deleting ids: [UUID]) throws {
            try wrapped.applyChanges(upserting: items, deleting: ids)
        }
    }

    private final class ScriptedShopping: ShoppingListPersistenceProtocol {
        let wrapped: ShoppingListPersistenceProtocol; let script: Script
        init(_ w: ShoppingListPersistenceProtocol, _ s: Script) { wrapped = w; script = s }
        func loadShoppingItems() throws -> [KitchenShoppingItem] {
            if script.failLoad { throw Injected() }
            return try wrapped.loadShoppingItems()
        }
        func replaceShoppingItems(with items: [KitchenShoppingItem]) throws {
            if script.shouldFailReplace() { throw Injected() }
            try wrapped.replaceShoppingItems(with: items)
        }
        func upsert(_ item: KitchenShoppingItem) throws { try wrapped.upsert(item) }
        func delete(id: UUID) throws { try wrapped.delete(id: id) }
        func deleteAll() throws { try wrapped.deleteAll() }
    }

    private final class ScriptedTodayPlan: TodayPlanPersistenceProtocol {
        let wrapped: TodayPlanPersistenceProtocol; let script: Script
        init(_ w: TodayPlanPersistenceProtocol, _ s: Script) { wrapped = w; script = s }
        func loadPlans() throws -> [MealPlanItem] {
            if script.failLoad { throw Injected() }
            return try wrapped.loadPlans()
        }
        func replacePlans(with items: [MealPlanItem]) throws {
            if script.shouldFailReplace() { throw Injected() }
            try wrapped.replacePlans(with: items)
        }
        func upsert(_ item: MealPlanItem) throws { try wrapped.upsert(item) }
        func delete(id: UUID) throws { try wrapped.delete(id: id) }
        func deleteAll() throws { try wrapped.deleteAll() }
    }

    private final class ScriptedConsumption: ConsumptionPersistenceProtocol {
        let wrapped: ConsumptionPersistenceProtocol; let script: Script
        init(_ w: ConsumptionPersistenceProtocol, _ s: Script) { wrapped = w; script = s }
        func loadRecords() throws -> [InventoryConsumptionRecord] {
            if script.failLoad { throw Injected() }
            return try wrapped.loadRecords()
        }
        func replaceRecords(with records: [InventoryConsumptionRecord]) throws {
            if script.shouldFailReplace() { throw Injected() }
            try wrapped.replaceRecords(with: records)
        }
        func upsert(_ record: InventoryConsumptionRecord) throws { try wrapped.upsert(record) }
        func delete(id: UUID) throws { try wrapped.delete(id: id) }
        func deleteAll() throws { try wrapped.deleteAll() }
    }

    private final class ScriptedWeekly: WeeklyPlanPersistenceProtocol {
        let wrapped: WeeklyPlanPersistenceProtocol; let script: Script
        init(_ w: WeeklyPlanPersistenceProtocol, _ s: Script) { wrapped = w; script = s }
        func loadPlan() throws -> WeeklyMealPlan? {
            if script.failLoad { throw Injected() }
            return try wrapped.loadPlan()
        }
        func replacePlan(with plan: WeeklyMealPlan?) throws {
            if script.shouldFailReplace() { throw Injected() }
            try wrapped.replacePlan(with: plan)
        }
        func deleteAll() throws { try wrapped.deleteAll() }
    }

    private final class ScriptedComponents: PreparedComponentPersistenceProtocol {
        let wrapped: PreparedComponentPersistenceProtocol; let script: Script
        init(_ w: PreparedComponentPersistenceProtocol, _ s: Script) { wrapped = w; script = s }
        func loadComponents() throws -> [PreparedComponent] {
            if script.failLoad { throw Injected() }
            return try wrapped.loadComponents()
        }
        func replaceComponents(with components: [PreparedComponent]) throws {
            if script.shouldFailReplace() { throw Injected() }
            try wrapped.replaceComponents(with: components)
        }
        func upsert(_ component: PreparedComponent) throws { try wrapped.upsert(component) }
        func delete(id: UUID) throws { try wrapped.delete(id: id) }
        func deleteAll() throws { try wrapped.deleteAll() }
    }

    private final class ScriptedSpecial: SpecialPlanPersistenceProtocol {
        let wrapped: SpecialPlanPersistenceProtocol; let script: Script
        init(_ w: SpecialPlanPersistenceProtocol, _ s: Script) { wrapped = w; script = s }
        func loadPlans() throws -> [SpecialPlan] {
            if script.failLoad { throw Injected() }
            return try wrapped.loadPlans()
        }
        func replacePlans(with plans: [SpecialPlan]) throws {
            if script.shouldFailReplace() { throw Injected() }
            try wrapped.replacePlans(with: plans)
        }
        func upsert(_ plan: SpecialPlan) throws { try wrapped.upsert(plan) }
        func delete(id: UUID) throws { try wrapped.delete(id: id) }
        func deleteAll() throws { try wrapped.deleteAll() }
    }

    // MARK: - Harness

    private var base: KitchenPersistenceBundle!
    private var scripts: [KitchenBackupDomain: Script]!
    private var snapshot: KitchenRecoverySnapshotStore!
    private var store: KitchenStore!

    override func setUpWithError() throws {
        base = KitchenPersistenceFactory.isolatedInMemory()
        scripts = Dictionary(uniqueKeysWithValues: KitchenBackupDomain.allCases.map { ($0, Script()) })
        snapshot = .isolated()
        store = KitchenStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            inventoryPersistence: ScriptedInventory(base.inventory, scripts[.inventory]!),
            shoppingListPersistence: ScriptedShopping(base.shoppingList, scripts[.shoppingItems]!),
            todayPlanPersistence: ScriptedTodayPlan(base.todayPlan, scripts[.plans]!),
            consumptionPersistence: ScriptedConsumption(base.consumption, scripts[.consumptionRecords]!),
            weeklyPlanPersistence: ScriptedWeekly(base.weeklyPlan, scripts[.weeklyPlan]!),
            preparedComponentPersistence: ScriptedComponents(base.preparedComponents, scripts[.preparedComponents]!),
            specialPlanPersistence: ScriptedSpecial(base.specialPlans, scripts[.specialPlans]!),
            recoverySnapshot: snapshot
        )
    }

    override func tearDown() {
        store = nil; snapshot = nil; scripts = nil; base = nil
        super.tearDown()
    }

    /// Seeds a kitchen with something in every backup-scoped domain, then
    /// returns the candidate payload a restore will try to write over it.
    @discardableResult
    private func seedOriginalAndBuildCandidate() throws -> Data {
        store.addInventory(name: "番茄", quantity: 5, unit: "个", expiryDate: nil)
        store.addShopping(name: "牛奶", quantity: 1, unit: "盒")
        store.addSpecialPlan(specialPlan(title: "原始聚餐"))
        store.addPreparedComponent(component(name: "原始备餐"))

        let other = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        other.addInventory(name: "黄瓜", quantity: 9, unit: "根", expiryDate: nil)
        other.addShopping(name: "面包", quantity: 2, unit: "个")
        other.addSpecialPlan(specialPlan(title: "候选聚餐"))
        return try other.exportBackupData()
    }

    private func armFailure(at domain: KitchenBackupDomain, calls: Set<Int> = [1]) {
        for (key, script) in scripts { script.arm(replaceCalls: key == domain ? calls : []) }
    }

    private func storedScope() throws -> KitchenBackupPayload {
        KitchenBackupPayload(
            inventory: try base.inventory.loadInventory(),
            plans: try base.todayPlan.loadPlans(),
            shoppingItems: try base.shoppingList.loadShoppingItems(),
            weeklyPlan: try base.weeklyPlan.loadPlan(),
            consumptionRecords: try base.consumption.loadRecords(),
            preparedComponents: try base.preparedComponents.loadComponents(),
            specialPlans: try base.specialPlans.loadPlans()
        )
    }

    private func inMemoryScope() -> KitchenBackupPayload {
        KitchenBackupPayload(
            inventory: store.inventory,
            plans: store.plans,
            shoppingItems: store.shoppingItems,
            weeklyPlan: store.weeklyPlan,
            consumptionRecords: store.consumptionRecords,
            preparedComponents: store.preparedComponents,
            specialPlans: store.specialPlans
        )
    }

    private func specialPlan(title: String) -> SpecialPlan {
        SpecialPlan(
            title: title,
            scheduledAt: Date(timeIntervalSince1970: 1_750_000_000),
            peopleCount: 6,
            constraintNotes: ["1 人不吃辣"],
            notes: "",
            dishes: [SpecialPlanDish(recipeID: "sample-mapotofu", recipeName: "麻婆豆腐")]
        )
    }

    private func component(name: String) -> PreparedComponent {
        PreparedComponent(
            name: name, portionsRemaining: 3, state: .cooked, storage: .refrigerated,
            preparedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiryDate: Date(timeIntervalSince1970: 1_700_300_000)
        )
    }

    // MARK: - Success

    func testSuccessReplacesTheScopeAndResolvesTheSnapshot() throws {
        let candidate = try seedOriginalAndBuildCandidate()

        try store.restoreBackupData(candidate)

        XCTAssertEqual(store.lastRestoreOutcome, .success)
        XCTAssertFalse(snapshot.hasOutstandingSnapshot, "成功之后不得留下阻塞下一次恢复的副本")
        XCTAssertTrue(
            inMemoryScope().matchesBackupScope(of: try storedScope()),
            "成功后内存状态必须等于持久化真相"
        )
        XCTAssertEqual(store.inventory.map(\.name), ["黄瓜"])
    }

    // MARK: - Proven recovery, at every failure position

    func testEveryFailurePositionRecoversAndProvesIt() throws {
        for domain in KitchenBackupDomain.restoreOrder {
            try setUpWithError()
            let candidate = try seedOriginalAndBuildCandidate()
            let original = inMemoryScope()
            armFailure(at: domain)

            XCTAssertThrowsError(try store.restoreBackupData(candidate), "\(domain) 失败必须抛出") { error in
                // `KitchenBackupError` is not Equatable; its nine descriptions
                // are distinct, so comparing them identifies the case exactly.
                XCTAssertEqual(
                    (error as? KitchenBackupError)?.errorDescription,
                    domain.persistenceError.errorDescription
                )
            }

            XCTAssertEqual(
                store.lastRestoreOutcome, .failedAndRecovered(domain),
                "\(domain) 位置失败后应为已证实恢复"
            )
            let stored = try storedScope()
            XCTAssertTrue(stored.matchesBackupScope(of: original), "\(domain)：持久化必须回到原始状态")
            XCTAssertTrue(
                inMemoryScope().matchesBackupScope(of: stored),
                "\(domain)：内存状态必须等于已核实的持久化真相"
            )
            XCTAssertFalse(snapshot.hasOutstandingSnapshot, "\(domain)：已证实恢复后副本应被释放")
        }
    }

    /// The failure position with six domains already written before it.
    func testAFailureAfterSixWrittenDomainsStillRecovers() throws {
        let candidate = try seedOriginalAndBuildCandidate()
        let original = inMemoryScope()
        armFailure(at: .specialPlans)

        XCTAssertThrowsError(try store.restoreBackupData(candidate))

        XCTAssertEqual(store.lastRestoreOutcome, .failedAndRecovered(.specialPlans))
        XCTAssertTrue(try storedScope().matchesBackupScope(of: original))
        XCTAssertEqual(store.inventory.map(\.name), ["番茄"], "六个已写入的域都必须被放回")
        XCTAssertEqual(store.shoppingItems.map(\.name), ["牛奶"])
    }

    // MARK: - Unsafe

    func testACompensationFailureIsNeverCalledRecovered() throws {
        let candidate = try seedOriginalAndBuildCandidate()
        armFailure(at: .plans)
        // Inventory's restore write is call 1, its compensating write is call 2.
        scripts[.inventory]!.arm(replaceCalls: [2])

        XCTAssertThrowsError(try store.restoreBackupData(candidate))

        XCTAssertEqual(
            store.lastRestoreOutcome, .failedUnsafe(.compensationFailed([.inventory])),
            "补偿失败必须产生不安全结果，并指明是哪个域"
        )
        XCTAssertTrue(store.lastRestoreOutcome?.isUnsafe == true)
        XCTAssertTrue(snapshot.hasOutstandingSnapshot, "不安全结果必须保留持久副本")
    }

    func testAReconciliationReadFailureIsUnsafeAndPublishesNothing() throws {
        let candidate = try seedOriginalAndBuildCandidate()
        let before = inMemoryScope()
        armFailure(at: .plans)
        scripts[.consumptionRecords]!.arm(failLoad: true)

        XCTAssertThrowsError(try store.restoreBackupData(candidate))

        XCTAssertEqual(
            store.lastRestoreOutcome, .failedUnsafe(.reconciliationFailed(.consumptionRecords))
        )
        XCTAssertTrue(snapshot.hasOutstandingSnapshot, "读不全时必须保留副本")
        XCTAssertTrue(
            inMemoryScope().matchesBackupScope(of: before),
            "读取失败时不得发布半个协调结果"
        )
    }

    func testAnOutstandingUnsafeSnapshotBlocksTheNextRestore() throws {
        let candidate = try seedOriginalAndBuildCandidate()
        armFailure(at: .plans)
        scripts[.inventory]!.arm(replaceCalls: [2])
        XCTAssertThrowsError(try store.restoreBackupData(candidate))
        XCTAssertTrue(snapshot.hasOutstandingSnapshot)

        for (_, script) in scripts { script.arm() }
        XCTAssertThrowsError(try store.restoreBackupData(candidate)) { error in
            XCTAssertEqual(
                error as? KitchenRecoverySnapshotError, .outstandingSnapshotPresent,
                "未处理的恢复资产不得被下一次导入静默覆盖"
            )
        }
        XCTAssertEqual(store.lastRestoreOutcome, .preparationFailed)
    }

    // MARK: - The two zero-mutation outcomes

    func testValidationFailureMutatesNothing() throws {
        try seedOriginalAndBuildCandidate()
        let before = inMemoryScope()
        armFailure(at: .inventory, calls: [])

        XCTAssertThrowsError(try store.restoreBackupData(Data("{}".utf8)))

        XCTAssertEqual(store.lastRestoreOutcome, .validationFailed)
        XCTAssertEqual(store.lastRestoreOutcome?.mutatedNothing, true)
        XCTAssertFalse(store.lastRestoreOutcome?.isUnsafe == true)
        XCTAssertTrue(inMemoryScope().matchesBackupScope(of: before))
        XCTAssertTrue(try storedScope().matchesBackupScope(of: before))
        XCTAssertFalse(snapshot.hasOutstandingSnapshot, "被校验拒绝时不应准备任何副本")
    }

    func testPreparationFailureMutatesNothing() throws {
        let candidate = try seedOriginalAndBuildCandidate()
        let before = inMemoryScope()
        let blocked = KitchenStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            inventoryPersistence: ScriptedInventory(base.inventory, scripts[.inventory]!),
            shoppingListPersistence: ScriptedShopping(base.shoppingList, scripts[.shoppingItems]!),
            todayPlanPersistence: ScriptedTodayPlan(base.todayPlan, scripts[.plans]!),
            consumptionPersistence: ScriptedConsumption(base.consumption, scripts[.consumptionRecords]!),
            weeklyPlanPersistence: ScriptedWeekly(base.weeklyPlan, scripts[.weeklyPlan]!),
            preparedComponentPersistence: ScriptedComponents(base.preparedComponents, scripts[.preparedComponents]!),
            specialPlanPersistence: ScriptedSpecial(base.specialPlans, scripts[.specialPlans]!),
            recoverySnapshot: KitchenRecoverySnapshotStore(directoryURL: nil)
        )
        for (_, script) in scripts { script.arm() }

        XCTAssertThrowsError(try blocked.restoreBackupData(candidate)) { error in
            XCTAssertEqual(error as? KitchenRecoverySnapshotError, .storageUnavailable)
        }

        XCTAssertEqual(blocked.lastRestoreOutcome, .preparationFailed)
        XCTAssertEqual(blocked.lastRestoreOutcome?.mutatedNothing, true)
        XCTAssertTrue(try storedScope().matchesBackupScope(of: before), "准备失败时不得发生破坏性写入")
    }

    // MARK: - RecipeStore stays outside the backup scope

    func testRecipeDomainsAreUntouchedAcrossEveryOutcome() throws {
        // Re-seeded after every harness rebuild: `setUpWithError` makes a fresh
        // isolated container, so seeding once would only prove that a new
        // container starts empty.
        func seedRecipeDomains() throws {
            let recipe = Recipe(
                id: "user-1", title: "自家番茄面", cookingTime: nil, difficulty: nil,
                tags: [], ingredients: ["番茄"], steps: ["炒"]
            )
            try base.userRecipes.replaceRecipes(with: [recipe])
            try base.recipePreferences.replacePreferences(
                with: [RecipePreference(recipeID: "user-1", isFavorite: true, isFrequent: true)]
            )
        }
        try seedRecipeDomains()

        func assertRecipeDomainsUnchanged(_ label: String) throws {
            XCTAssertEqual(try base.userRecipes.loadRecipes().map(\.id), ["user-1"], "\(label)：用户菜谱被改动")
            let loaded = try base.recipePreferences.loadPreferences()
            XCTAssertEqual(loaded.map(\.recipeID), ["user-1"], "\(label)：收藏/常做记录被改动")
            XCTAssertEqual(loaded.first?.isFavorite, true, "\(label)：收藏被改动")
            XCTAssertEqual(loaded.first?.isFrequent, true, "\(label)：常做记录被改动")
        }

        // Success.
        let candidate = try seedOriginalAndBuildCandidate()
        try store.restoreBackupData(candidate)
        XCTAssertEqual(store.lastRestoreOutcome, .success)
        try assertRecipeDomainsUnchanged("成功")

        // Proven recovery.
        try setUpWithError()
        try seedRecipeDomains()
        let second = try seedOriginalAndBuildCandidate()
        armFailure(at: .weeklyPlan)
        XCTAssertThrowsError(try store.restoreBackupData(second))
        XCTAssertEqual(store.lastRestoreOutcome, .failedAndRecovered(.weeklyPlan))
        try assertRecipeDomainsUnchanged("已证实恢复")

        // Unsafe.
        try setUpWithError()
        try seedRecipeDomains()
        let third = try seedOriginalAndBuildCandidate()
        armFailure(at: .plans)
        scripts[.inventory]!.arm(replaceCalls: [2])
        XCTAssertThrowsError(try store.restoreBackupData(third))
        XCTAssertEqual(store.lastRestoreOutcome?.isUnsafe, true)
        try assertRecipeDomainsUnchanged("不安全")
    }
}
