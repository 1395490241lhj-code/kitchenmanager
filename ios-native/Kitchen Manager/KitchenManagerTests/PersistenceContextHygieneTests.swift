import SwiftData
import XCTest
@testable import KitchenManager

/// Feature 005, Phase 3: after a replace save fails, the *same* persistence
/// object must be safe for an immediate compensating replace.
///
/// Every test shapes the failed attempt so that it leaves pending deletes and
/// inserts behind, then asserts two things on the unrepaired implementations
/// would both be wrong: that the failed write never becomes readable, and that
/// an immediate compensating write on the same instance succeeds and lands.
///
/// The first assertion is what actually fails without the cleanup, and it was
/// verified by temporarily removing the rollback: the next `load` returns the
/// failed attempt's pending state as though it had been saved. The unique-id
/// collision described by `SwiftDataTodayPlanPersistence` did *not* reproduce
/// on this SwiftData version — a compensating replace over a dirty context
/// still succeeded — so these tests pin the hazard that is real here rather
/// than asserting one that is not.
///
/// No test constructs a new persistence object between the failure and the
/// compensation. That is the whole point: the failed context itself has to be
/// reusable.
@MainActor
final class PersistenceContextHygieneTests: XCTestCase {
    private struct InjectedFailure: Error {}

    private var container: ModelContainer!

    override func setUpWithError() throws {
        container = try KitchenPersistenceFactory.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    /// Asserts the injected failure surfaced unchanged: it is the caller's
    /// error, not something the cleanup swallowed or rewrote.
    private func assertInjected(_ error: Error, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(error is InjectedFailure, "\(what) 的错误映射被改变了，实际为 \(error)", file: file, line: line)
    }

    // MARK: - Shopping list

    func testShoppingListSurvivesAFailedReplaceAndCompensatesOnTheSameInstance() throws {
        let persistence = SwiftDataShoppingListPersistence(container: container)
        let milk = KitchenShoppingItem(name: "牛奶", quantity: 1, unit: "盒", source: "来自常备货架", isDone: false, remark: nil)
        let eggs = KitchenShoppingItem(name: "鸡蛋", quantity: 6, unit: "个", source: "手动添加", isDone: true, remark: "买散养的")
        let original = [milk, eggs]
        try persistence.replaceShoppingItems(with: original)
        XCTAssertEqual(try persistence.loadShoppingItems(), original)

        // Drops `milk` and adds a new row: pending delete plus pending insert.
        let bread = KitchenShoppingItem(name: "面包", quantity: 2, unit: "个")
        persistence.failNextReplaceSaveForTesting = InjectedFailure()
        XCTAssertThrowsError(try persistence.replaceShoppingItems(with: [eggs, bread])) {
            assertInjected($0, "购物清单")
        }

        // The failed attempt must not be readable as though it had been saved.
        // This is the assertion that goes red without the cleanup.
        XCTAssertEqual(
            try persistence.loadShoppingItems(), original,
            "失败的写入不得变成可读的真相"
        )

        // Same instance, same context, immediately.
        XCTAssertNoThrow(try persistence.replaceShoppingItems(with: original), "失败后的立即补偿写入必须成功")

        let restored = try persistence.loadShoppingItems()
        XCTAssertEqual(restored, original, "补偿后的持久化真相必须与原始状态完全一致")
        XCTAssertEqual(restored.map(\.name), ["牛奶", "鸡蛋"], "排序语义必须保持不变")
        XCTAssertEqual(restored.map(\.isDone), [false, true])
        XCTAssertEqual(restored.first?.source, "来自常备货架")
        XCTAssertEqual(restored.last?.remark, "买散养的")
    }

    // MARK: - Consumption records

    func testConsumptionSurvivesAFailedReplaceAndCompensatesOnTheSameInstance() throws {
        let persistence = SwiftDataConsumptionPersistence(container: container)
        let first = consumptionRecord(name: "番茄炒蛋")
        let second = consumptionRecord(name: "麻婆豆腐")
        let original = [first, second]
        try persistence.replaceRecords(with: original)
        XCTAssertEqual(try persistence.loadRecords(), original)

        persistence.failNextReplaceSaveForTesting = InjectedFailure()
        XCTAssertThrowsError(try persistence.replaceRecords(with: [second, consumptionRecord(name: "青椒肉丝")])) {
            assertInjected($0, "消耗记录")
        }

        // The failed attempt must not be readable as though it had been saved.
        // This is the assertion that goes red without the cleanup.
        XCTAssertEqual(
            try persistence.loadRecords(), original,
            "失败的写入不得变成可读的真相"
        )

        XCTAssertNoThrow(try persistence.replaceRecords(with: original), "失败后的立即补偿写入必须成功")

        let restored = try persistence.loadRecords()
        XCTAssertEqual(restored, original, "记录的身份与内容都必须原样回到失败之前")
        XCTAssertEqual(restored.map(\.recipeName), ["番茄炒蛋", "麻婆豆腐"])
        XCTAssertEqual(restored.first?.items, first.items, "嵌套的消耗明细必须保留")
    }

    // MARK: - Prepared components

    func testPreparedComponentsSurviveAFailedReplaceAndCompensateOnTheSameInstance() throws {
        let persistence = SwiftDataPreparedComponentPersistence(container: container)
        let braised = preparedComponent(name: "卤鸡腿", portions: 5, offset: 0)
        let rice = preparedComponent(name: "糙米饭", portions: 3, offset: 100)
        let original = [braised, rice]
        try persistence.replaceComponents(with: original)
        XCTAssertEqual(try persistence.loadComponents(), original)

        persistence.failNextReplaceSaveForTesting = InjectedFailure()
        XCTAssertThrowsError(
            try persistence.replaceComponents(with: [rice, preparedComponent(name: "炒时蔬", portions: 2, offset: 200)])
        ) {
            assertInjected($0, "备餐组件")
        }

        // The failed attempt must not be readable as though it had been saved.
        // This is the assertion that goes red without the cleanup.
        XCTAssertEqual(
            try persistence.loadComponents(), original,
            "失败的写入不得变成可读的真相"
        )

        XCTAssertNoThrow(try persistence.replaceComponents(with: original), "失败后的立即补偿写入必须成功")

        let restored = try persistence.loadComponents()
        XCTAssertEqual(restored, original, "组件身份与持久化字段都必须保留")
        XCTAssertEqual(restored.map(\.name), ["卤鸡腿", "糙米饭"])
        XCTAssertEqual(restored.map(\.portionsRemaining), [5, 3])
        XCTAssertEqual(restored.first?.storage, braised.storage)
        XCTAssertEqual(restored.first?.state, braised.state)
    }

    // MARK: - Special plans

    func testSpecialPlansSurviveAFailedReplaceAndCompensateOnTheSameInstance() throws {
        let persistence = SwiftDataSpecialPlanPersistence(container: container)
        let dinner = specialPlan(title: "朋友聚餐", offsetHours: 18)
        let lunch = specialPlan(title: "家庭午餐", offsetHours: 12)
        let original = [lunch, dinner]
        try persistence.replacePlans(with: original)
        XCTAssertEqual(try persistence.loadPlans(), original)

        persistence.failNextReplaceSaveForTesting = InjectedFailure()
        XCTAssertThrowsError(
            try persistence.replacePlans(with: [dinner, specialPlan(title: "周末烧烤", offsetHours: 20)])
        ) {
            assertInjected($0, "聚餐计划")
        }

        // The failed attempt must not be readable as though it had been saved.
        // This is the assertion that goes red without the cleanup.
        XCTAssertEqual(
            try persistence.loadPlans(), original,
            "失败的写入不得变成可读的真相"
        )

        XCTAssertNoThrow(try persistence.replacePlans(with: original), "失败后的立即补偿写入必须成功")

        let restored = try persistence.loadPlans()
        XCTAssertEqual(restored, original, "计划身份与嵌套菜品都必须保留")
        XCTAssertEqual(restored.map(\.title), ["家庭午餐", "朋友聚餐"])
        XCTAssertEqual(restored.last?.dishes.map(\.recipeID), dinner.dishes.map(\.recipeID))
        XCTAssertEqual(restored.last?.constraintNotes, dinner.constraintNotes)
        XCTAssertEqual(restored.last?.peopleCount, dinner.peopleCount)
    }

    // MARK: - The seam itself

    /// The seam must be one-shot. If it were not, the compensating write in
    /// every test above would be failing for the injected reason rather than
    /// succeeding, and the suite would prove nothing about cleanup.
    func testInjectedFailureIsConsumedSoTheNextWriteIsReal() throws {
        let persistence = SwiftDataShoppingListPersistence(container: container)
        let item = KitchenShoppingItem(name: "盐", quantity: 1, unit: "袋")

        persistence.failNextReplaceSaveForTesting = InjectedFailure()
        XCTAssertThrowsError(try persistence.replaceShoppingItems(with: [item]))
        XCTAssertNil(persistence.failNextReplaceSaveForTesting, "注入必须被消费，而不是持续生效")

        XCTAssertNoThrow(try persistence.replaceShoppingItems(with: [item]))
        XCTAssertEqual(try persistence.loadShoppingItems(), [item])
    }

    /// A failed replace must not report success by leaving its payload readable
    /// from the same context.
    func testAFailedReplaceLeavesTheStoredTruthUnchanged() throws {
        let persistence = SwiftDataShoppingListPersistence(container: container)
        let original = [KitchenShoppingItem(name: "牛奶", quantity: 1, unit: "盒")]
        try persistence.replaceShoppingItems(with: original)

        persistence.failNextReplaceSaveForTesting = InjectedFailure()
        XCTAssertThrowsError(try persistence.replaceShoppingItems(with: []))

        XCTAssertEqual(
            try persistence.loadShoppingItems(), original,
            "失败的写入不得让未保存的内容看起来像已保存"
        )
    }

    // MARK: - Fixtures

    private func consumptionRecord(name: String) -> InventoryConsumptionRecord {
        InventoryConsumptionRecord(
            id: UUID(),
            date: Date(timeIntervalSince1970: 1_700_000_000),
            recipeID: "recipe-\(name)",
            recipeName: name,
            planIDs: [UUID()],
            items: [
                InventoryConsumptionRecordItem(
                    inventoryItemID: UUID(),
                    ingredientName: "番茄",
                    consumedQuantity: 2,
                    unit: "个",
                    previousQuantity: 5,
                    resultingQuantity: 3
                )
            ],
            isUndone: false
        )
    }

    private func preparedComponent(name: String, portions: Int, offset: TimeInterval) -> PreparedComponent {
        PreparedComponent(
            name: name,
            portionsRemaining: portions,
            state: .cooked,
            storage: .refrigerated,
            preparedAt: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            expiryDate: Date(timeIntervalSince1970: 1_700_300_000 + offset)
        )
    }

    private func specialPlan(title: String, offsetHours: Int) -> SpecialPlan {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_750_000_000))
        let scheduled = Calendar.current.date(byAdding: .hour, value: offsetHours, to: day) ?? day
        return SpecialPlan(
            title: title,
            scheduledAt: scheduled,
            peopleCount: 7,
            constraintNotes: ["1 人不吃辣"],
            notes: "测试",
            dishes: [
                SpecialPlanDish(recipeID: "sample-mapotofu", recipeName: "麻婆豆腐"),
                SpecialPlanDish(recipeID: "sample-tomato-eggs", recipeName: "番茄炒鸡蛋")
            ]
        )
    }
}
