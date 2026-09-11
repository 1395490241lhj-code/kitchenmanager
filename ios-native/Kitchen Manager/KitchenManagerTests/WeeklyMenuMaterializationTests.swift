import XCTest
@testable import KitchenManager

/// Turning a generated menu into real Planner meals: the order the writes
/// happen in, what each failure leaves behind, and how a half-finished attempt
/// is picked up again.
@MainActor
final class WeeklyMenuMaterializationTests: XCTestCase {
    /// Records which store was written, so a test can prove the receipt is
    /// durable *before* the meals are.
    private final class WriteLog {
        var entries: [String] = []
    }

    private final class TestTodayPlanPersistence: TodayPlanPersistenceProtocol {
        struct ExpectedFailure: Error {}
        var plans: [MealPlanItem] = []
        var shouldFail = false
        var replaceCallCount = 0
        /// Runs right after a successful write, so a test can fail the *next*
        /// store and land on the window between the meals and the receipt.
        var onWrite: (() -> Void)?
        let log: WriteLog?

        init(log: WriteLog? = nil) { self.log = log }

        func loadPlans() throws -> [MealPlanItem] { plans }
        func replacePlans(with items: [MealPlanItem]) throws {
            replaceCallCount += 1
            if shouldFail { throw ExpectedFailure() }
            log?.entries.append("plans")
            plans = items
            onWrite?()
        }
        func upsert(_ item: MealPlanItem) throws {}
        func delete(id: UUID) throws {}
        func deleteAll() throws { plans = [] }
    }

    private final class TestWeeklyPlanPersistence: WeeklyPlanPersistenceProtocol {
        struct ExpectedFailure: Error {}
        var plan: WeeklyMealPlan?
        var shouldFail = false
        var replaceCallCount = 0
        let log: WriteLog?

        init(log: WriteLog? = nil) { self.log = log }

        func loadPlan() throws -> WeeklyMealPlan? { plan }
        func replacePlan(with plan: WeeklyMealPlan?) throws {
            replaceCallCount += 1
            if shouldFail { throw ExpectedFailure() }
            log?.entries.append("weekly")
            self.plan = plan
        }
        func deleteAll() throws { plan = nil }
    }

    private final class TestUserRecipePersistence: UserRecipePersistenceProtocol {
        struct ExpectedFailure: Error {}
        var recipes: [Recipe] = []
        var shouldFail = false
        var replaceCallCount = 0

        func loadRecipes() throws -> [Recipe] { recipes }
        func storedRecordCount() throws -> Int { recipes.count }
        func replaceRecipes(with recipes: [Recipe]) throws {
            replaceCallCount += 1
            if shouldFail { throw ExpectedFailure() }
            self.recipes = recipes
        }
        func deleteAll() throws { recipes = [] }
    }

    // MARK: - Harness

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private var startDate: Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: 18))!
    }

    private struct Harness {
        let kitchen: KitchenStore
        let recipes: RecipeStore
        let planner: WeeklyMenuPlannerStore
        let todayPlan: TestTodayPlanPersistence
        let weekly: TestWeeklyPlanPersistence
        let userRecipes: TestUserRecipePersistence
        let log: WriteLog
    }

    private func makeHarness() -> Harness {
        let log = WriteLog()
        let todayPlan = TestTodayPlanPersistence(log: log)
        let weekly = TestWeeklyPlanPersistence(log: log)
        let userRecipes = TestUserRecipePersistence()
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let kitchen = KitchenStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            inventoryPersistence: bundle.inventory,
            shoppingListPersistence: bundle.shoppingList,
            todayPlanPersistence: todayPlan,
            consumptionPersistence: bundle.consumption,
            weeklyPlanPersistence: weekly,
            preparedComponentPersistence: bundle.preparedComponents,
            specialPlanPersistence: bundle.specialPlans
        )
        let recipes = RecipeStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            userRecipePersistence: userRecipes,
            recipePreferencePersistence: bundle.recipePreferences
        )
        return Harness(
            kitchen: kitchen, recipes: recipes, planner: WeeklyMenuPlannerStore(),
            todayPlan: todayPlan, weekly: weekly, userRecipes: userRecipes, log: log
        )
    }

    /// A fresh planner store reading the durable draft, the way a relaunch does.
    private func reopen(_ harness: Harness) -> WeeklyMenuPlannerStore {
        let planner = WeeklyMenuPlannerStore()
        planner.loadSavedPlanIfNeeded(from: harness.kitchen)
        return planner
    }

    // MARK: - Draft fixtures

    private func aiDish(id: String, title: String, ingredient: String = "番茄 2 个") -> WeeklyMealPlanRecipe {
        WeeklyMealPlanRecipe(
            id: id, title: title, ingredients: [ingredient], steps: ["炒熟"],
            tags: ["家常菜"], cookingTime: 15, difficulty: "简单",
            reason: nil, source: .ai, existingRecipeID: nil
        )
    }

    private func localDish(id: String, title: String) -> WeeklyMealPlanRecipe {
        WeeklyMealPlanRecipe(
            id: id, title: title, ingredients: ["食材 1 个"], steps: ["做好"],
            tags: [], cookingTime: 10, difficulty: "简单",
            reason: nil, source: .local, existingRecipeID: id
        )
    }

    private func draft(
        days: [Int: [WeeklyMealPlanRecipe]],
        receipt: WeeklyMaterializationReceipt? = nil
    ) -> WeeklyMealPlan {
        WeeklyMealPlan(
            startDate: startDate,
            days: days.keys.sorted().map { index in
                WeeklyMealPlanDay(
                    dayIndex: index,
                    meals: [WeeklyMealPlanMeal(mealIndex: 0, title: "晚餐", recipes: days[index] ?? [])]
                )
            },
            shoppingItems: [],
            servings: 4,
            summary: nil,
            createdAt: Date(),
            materialization: receipt
        )
    }

    private func expectedDate(dayIndex: Int) -> Date {
        let calendar = self.calendar
        let raw = calendar.date(byAdding: .day, value: dayIndex, to: calendar.startOfDay(for: startDate))!
        return MealPlanItem.normalizedPlannerDate(for: raw, calendar: calendar)
    }

    private func materialize(
        _ harness: Harness,
        confirmedAppend: Bool = false
    ) -> WeeklyMaterializationOutcome {
        harness.planner.materialize(
            kitchenStore: harness.kitchen,
            recipeStore: harness.recipes,
            confirmedAppend: confirmedAppend,
            calendar: calendar
        )
    }

    private func storedRecipe(id: String, title: String, ingredient: String = "番茄 2 个") -> Recipe {
        WeeklyMenuPlannerStore.domainRecipe(from: aiDish(id: id, title: title, ingredient: ingredient))
    }

    // MARK: - Initial materialization

    func testAWholeMenuBecomesMealsOnItsOwnDays() throws {
        let harness = makeHarness()
        try harness.recipes.saveUserRecipe(storedRecipe(id: "local-1", title: "红烧肉"))
        harness.planner.generatedPlan = draft(days: [
            0: [localDish(id: "local-1", title: "红烧肉"), aiDish(id: "weekly-ai-1", title: "番茄炒蛋")],
            2: [aiDish(id: "weekly-ai-2", title: "青椒肉丝", ingredient: "青椒 3 个")]
        ])

        let outcome = materialize(harness)

        let items = try XCTUnwrap(outcome.materializedItems)
        XCTAssertEqual(outcome, .materialized(items))
        XCTAssertEqual(harness.kitchen.plans.map(\.recipeName), ["红烧肉", "番茄炒蛋", "青椒肉丝"])
        XCTAssertEqual(
            harness.kitchen.plans.map(\.date),
            [expectedDate(dayIndex: 0), expectedDate(dayIndex: 0), expectedDate(dayIndex: 2)],
            "each dish lands on the day it was shown on, and dishes keep their order within a day"
        )
        XCTAssertEqual(
            harness.kitchen.plans.map(\.plannedServings), [nil, nil, nil],
            "the menu's headcount is not a per-dish target"
        )
        XCTAssertEqual(
            harness.kitchen.plans.map(\.recipeID), ["local-1", "weekly-ai-1", "weekly-ai-2"],
            "every meal points at a canonical recipe"
        )
        for item in harness.kitchen.plans {
            XCTAssertNotNil(harness.recipes.recipe(id: item.recipeID), "and that recipe resolves")
        }
    }

    func testTheReceiptRecordsExactlyTheIdsThatLandedOnThePlan() throws {
        let harness = makeHarness()
        harness.planner.generatedPlan = draft(days: [0: [aiDish(id: "weekly-ai-1", title: "番茄炒蛋")]])

        let items = try XCTUnwrap(materialize(harness).materializedItems)

        let receipt = try XCTUnwrap(harness.kitchen.weeklyPlan?.materialization)
        XCTAssertEqual(receipt.state, .materialized)
        XCTAssertEqual(receipt.planIDs, items.map(\.id))
        XCTAssertEqual(receipt.planIDs, harness.kitchen.plans.map(\.id))
        XCTAssertEqual(receipt.recipeIDs, ["weekly-ai-1"], "one canonical recipe per intended meal, in order")
        XCTAssertNotNil(receipt.completedAt)
    }

    func testAMissingLocalRecipeStopsEverythingAndNamesTheDish() {
        let harness = makeHarness()
        harness.planner.generatedPlan = draft(days: [
            0: [aiDish(id: "weekly-ai-1", title: "番茄炒蛋"), localDish(id: "gone", title: "红烧肉")]
        ])

        let outcome = materialize(harness)

        XCTAssertEqual(outcome, .missingLocalRecipe(dishName: "红烧肉"))
        XCTAssertTrue(harness.kitchen.plans.isEmpty)
        XCTAssertTrue(harness.recipes.userRecipes.isEmpty, "not even the healthy dish's recipe is written")
        XCTAssertNil(harness.kitchen.weeklyPlan?.materialization)
        XCTAssertEqual(harness.log.entries, [], "nothing at all reached the disk")
    }

    func testARecipeIdTakenByDifferentContentBlocksBeforeAnyWrite() throws {
        let harness = makeHarness()
        try harness.recipes.saveUserRecipe(storedRecipe(id: "weekly-ai-1", title: "我的红烧肉", ingredient: "五花肉 500g"))
        harness.planner.generatedPlan = draft(days: [0: [aiDish(id: "weekly-ai-1", title: "番茄炒蛋")]])

        let outcome = materialize(harness)

        XCTAssertEqual(outcome, .recipeIdentityConflict(recipeID: "weekly-ai-1"))
        XCTAssertTrue(harness.kitchen.plans.isEmpty)
        XCTAssertEqual(harness.recipes.recipe(id: "weekly-ai-1")?.title, "我的红烧肉", "never overwritten")
    }

    func testAnEmptyDraftWritesNothing() {
        let harness = makeHarness()
        harness.planner.generatedPlan = draft(days: [0: []])

        XCTAssertEqual(materialize(harness), .emptyDraft)
        XCTAssertTrue(harness.kitchen.plans.isEmpty)
        XCTAssertNil(harness.kitchen.weeklyPlan)
        XCTAssertEqual(harness.log.entries, [])
    }

    // MARK: - Collision

    func testAnEmptyWeekNeedsNoConfirmation() {
        let harness = makeHarness()
        harness.planner.generatedPlan = draft(days: [0: [aiDish(id: "weekly-ai-1", title: "番茄炒蛋")]])

        XCTAssertTrue(materialize(harness).didChangeSchedule)
    }

    func testADayThatAlreadyHasMealsAsksFirstAndWritesNothing() throws {
        let harness = makeHarness()
        harness.kitchen.addPlan(
            recipe: storedRecipe(id: "existing", title: "既有"),
            on: expectedDate(dayIndex: 0), calendar: calendar
        )
        let before = harness.kitchen.plans
        harness.planner.generatedPlan = draft(days: [
            0: [aiDish(id: "weekly-ai-1", title: "番茄炒蛋")],
            1: [aiDish(id: "weekly-ai-2", title: "青椒肉丝", ingredient: "青椒 3 个")]
        ])

        let outcome = materialize(harness)

        guard case .confirmationRequired(let collision) = outcome else {
            return XCTFail("expected a confirmation, got \(outcome)")
        }
        XCTAssertEqual(collision.dayCount, 1, "only one of the two target days is occupied")
        XCTAssertEqual(collision.existingMealCount, 1)
        XCTAssertEqual(harness.kitchen.plans, before, "asking is not doing")
        XCTAssertTrue(harness.recipes.userRecipes.isEmpty)
        XCTAssertNil(harness.kitchen.weeklyPlan?.materialization)
    }

    func testASpecialPlanOnTheDayIsNotAClash() {
        let harness = makeHarness()
        harness.kitchen.addSpecialPlan(
            SpecialPlan(title: "家宴", scheduledAt: expectedDate(dayIndex: 0), peopleCount: 6)
        )
        harness.planner.generatedPlan = draft(days: [0: [aiDish(id: "weekly-ai-1", title: "番茄炒蛋")]])

        XCTAssertTrue(materialize(harness).didChangeSchedule, "hosting a dinner is not the same as planning this dish")
    }

    func testConfirmedAppendKeepsWhatWasAlreadyPlanned() throws {
        let harness = makeHarness()
        harness.kitchen.addPlan(
            recipe: storedRecipe(id: "existing", title: "既有"),
            on: expectedDate(dayIndex: 0), calendar: calendar
        )
        let existing = try XCTUnwrap(harness.kitchen.plans.first)
        harness.planner.generatedPlan = draft(days: [0: [aiDish(id: "weekly-ai-1", title: "番茄炒蛋")]])

        let outcome = materialize(harness, confirmedAppend: true)

        XCTAssertTrue(outcome.didChangeSchedule)
        XCTAssertEqual(harness.kitchen.plans.first, existing, "the existing meal is untouched and still first")
        XCTAssertEqual(harness.kitchen.plans.count, 2)
    }

    // MARK: - Write order and failure windows

    func testTheReceiptIsDurableBeforeTheMealsAre() {
        let harness = makeHarness()
        harness.planner.generatedPlan = draft(days: [0: [aiDish(id: "weekly-ai-1", title: "番茄炒蛋")]])

        XCTAssertTrue(materialize(harness).didChangeSchedule)

        XCTAssertEqual(
            harness.log.entries, ["weekly", "plans", "weekly"],
            "pending receipt, then the meals, then the receipt marked done"
        )
        XCTAssertEqual(harness.todayPlan.replaceCallCount, 1, "the whole menu is one write")
    }

    func testAFailedReceiptWriteLeavesNoMealsAndReusableRecipes() {
        let harness = makeHarness()
        harness.planner.generatedPlan = draft(days: [0: [aiDish(id: "weekly-ai-1", title: "番茄炒蛋")]])
        harness.weekly.shouldFail = true

        let outcome = materialize(harness)

        XCTAssertEqual(outcome, .receiptPersistenceFailed)
        XCTAssertTrue(harness.kitchen.plans.isEmpty, "no meal is written without a durable id to name it")
        XCTAssertEqual(
            harness.recipes.userRecipes.map(\.id), ["weekly-ai-1"],
            "the recipe it already stored stays, so a retry reuses it"
        )

        harness.weekly.shouldFail = false
        let retry = materialize(harness)
        XCTAssertTrue(retry.didChangeSchedule)
        XCTAssertEqual(harness.recipes.userRecipes.count, 1, "and is not stored twice")
    }

    func testAFailedPlanWriteLeavesADurablePendingReceiptToRetryFrom() throws {
        let harness = makeHarness()
        harness.planner.generatedPlan = draft(days: [
            0: [aiDish(id: "weekly-ai-1", title: "番茄炒蛋")],
            1: [aiDish(id: "weekly-ai-2", title: "青椒肉丝", ingredient: "青椒 3 个")]
        ])
        harness.todayPlan.shouldFail = true

        XCTAssertEqual(materialize(harness), .planPersistenceFailed)

        XCTAssertTrue(harness.kitchen.plans.isEmpty)
        let receipt = try XCTUnwrap(harness.weekly.plan?.materialization)
        XCTAssertEqual(receipt.state, .pending)
        XCTAssertEqual(receipt.planIDs.count, 2)

        // The relaunch case: a fresh planner store reads the durable draft.
        harness.todayPlan.shouldFail = false
        let reopened = reopen(harness)
        let retry = reopened.materialize(
            kitchenStore: harness.kitchen, recipeStore: harness.recipes, calendar: calendar
        )

        XCTAssertTrue(retry.didChangeSchedule)
        XCTAssertEqual(harness.kitchen.plans.map(\.id), receipt.planIDs, "the retry recreates those exact meals")
        XCTAssertEqual(harness.kitchen.plans.count, 2, "and does not double up")
        XCTAssertEqual(harness.kitchen.weeklyPlan?.materialization?.state, .materialized)
    }

    func testMealsStandEvenWhenTheReceiptCannotBeFinalized() throws {
        let harness = makeHarness()
        harness.planner.generatedPlan = draft(days: [0: [aiDish(id: "weekly-ai-1", title: "番茄炒蛋")]])

        // Let the pending receipt and the meals through, then fail the write
        // that would have marked the receipt done.
        harness.todayPlan.onWrite = { harness.weekly.shouldFail = true }
        let outcome = materialize(harness)
        harness.todayPlan.onWrite = nil

        guard case .materializedNeedsReceiptRepair(let items) = outcome else {
            return XCTFail("expected a repair-needed result, got \(outcome)")
        }
        XCTAssertEqual(harness.kitchen.plans.map(\.id), items.map(\.id), "the member's schedule really did change")
        XCTAssertEqual(harness.weekly.plan?.materialization?.state, .pending, "only the bookkeeping lagged")

        // Reopening sees every id present and finalizes without appending again.
        harness.weekly.shouldFail = false
        let reopened = reopen(harness)
        let repair = reopened.materialize(
            kitchenStore: harness.kitchen, recipeStore: harness.recipes, calendar: calendar
        )

        XCTAssertEqual(repair, .receiptRepaired)
        XCTAssertEqual(harness.kitchen.plans.count, 1, "no second copy of the meal")
        XCTAssertEqual(harness.kitchen.weeklyPlan?.materialization?.state, .materialized)
        XCTAssertEqual(harness.todayPlan.replaceCallCount, 1, "the plan store was written exactly once overall")
    }

    // MARK: - Pending receipt recovery

    func testAMenuAlreadyOnThePlanRefusesToBeAddedAgain() {
        let harness = makeHarness()
        harness.planner.generatedPlan = draft(days: [0: [aiDish(id: "weekly-ai-1", title: "番茄炒蛋")]])
        XCTAssertTrue(materialize(harness).didChangeSchedule)
        let planned = harness.kitchen.plans

        XCTAssertEqual(materialize(harness), .alreadyMaterialized)
        XCTAssertEqual(harness.kitchen.plans, planned)
    }

    func testAFinalizedMenuStaysDoneAfterAMealIsDeletedInThePlanner() throws {
        let harness = makeHarness()
        harness.planner.generatedPlan = draft(days: [
            0: [aiDish(id: "weekly-ai-1", title: "番茄炒蛋"), aiDish(id: "weekly-ai-2", title: "青椒肉丝", ingredient: "青椒 3 个")]
        ])
        XCTAssertTrue(materialize(harness).didChangeSchedule)
        _ = harness.kitchen.removePlan(id: try XCTUnwrap(harness.kitchen.plans.first).id)

        XCTAssertEqual(materialize(harness), .alreadyMaterialized, "a deliberate deletion is not an unfinished menu")
        XCTAssertEqual(harness.kitchen.plans.count, 1, "and the deleted meal is not put back")
    }

    func testAPartlyPresentMenuAsksTheMemberInsteadOfRepairingItself() throws {
        let harness = makeHarness()
        let receipt = try pendingReceiptAfterAFailedPlanWrite(harness)
        // One of the two intended meals exists; the other does not.
        harness.kitchen.appendPlans([
            MealPlanItem(id: receipt.planIDs[0], recipeID: "weekly-ai-1", recipeName: "番茄炒蛋", date: expectedDate(dayIndex: 0))
        ])
        let writesBefore = harness.todayPlan.replaceCallCount

        let outcome = reopen(harness).materialize(
            kitchenStore: harness.kitchen, recipeStore: harness.recipes, calendar: calendar
        )

        XCTAssertEqual(
            outcome,
            .partialRecoveryRequired(present: [receipt.planIDs[0]], missing: [receipt.planIDs[1]])
        )
        XCTAssertEqual(harness.todayPlan.replaceCallCount, writesBefore, "nothing is repaired behind the member's back")
    }

    func testPuttingBackTheMissingMealsUsesTheirOriginalIds() throws {
        let harness = makeHarness()
        let receipt = try pendingReceiptAfterAFailedPlanWrite(harness)
        harness.kitchen.appendPlans([
            MealPlanItem(id: receipt.planIDs[0], recipeID: "weekly-ai-1", recipeName: "番茄炒蛋", date: expectedDate(dayIndex: 0))
        ])

        let reopened = reopen(harness)
        let outcome = reopened.materializeMissingMeals(
            kitchenStore: harness.kitchen, recipeStore: harness.recipes, calendar: calendar
        )

        XCTAssertTrue(outcome.didChangeSchedule)
        XCTAssertEqual(Set(harness.kitchen.plans.map(\.id)), Set(receipt.planIDs))
        XCTAssertEqual(harness.kitchen.plans.count, 2, "only the missing one was added")
        XCTAssertEqual(harness.kitchen.weeklyPlan?.materialization?.state, .materialized)
    }

    func testKeepingTheCurrentScheduleClosesTheMenuWithoutRecreatingAnything() throws {
        let harness = makeHarness()
        let receipt = try pendingReceiptAfterAFailedPlanWrite(harness)
        harness.kitchen.appendPlans([
            MealPlanItem(id: receipt.planIDs[0], recipeID: "weekly-ai-1", recipeName: "番茄炒蛋", date: expectedDate(dayIndex: 0))
        ])

        let reopened = reopen(harness)
        let outcome = reopened.acceptCurrentSchedule(kitchenStore: harness.kitchen)

        XCTAssertEqual(outcome, .receiptRepaired)
        XCTAssertEqual(harness.kitchen.plans.count, 1, "the meal they removed stays removed")
        XCTAssertEqual(harness.kitchen.weeklyPlan?.materialization?.state, .materialized)
        XCTAssertEqual(
            reopened.materialize(kitchenStore: harness.kitchen, recipeStore: harness.recipes, calendar: calendar),
            .alreadyMaterialized,
            "and the menu never offers to add itself again"
        )
    }

    func testARetryDoesNotAskAboutCollisionsTheMemberAlreadyAccepted() throws {
        let harness = makeHarness()
        _ = try pendingReceiptAfterAFailedPlanWrite(harness)
        // Something else lands on a target day between the attempts.
        harness.kitchen.addPlan(
            recipe: storedRecipe(id: "other", title: "别的"),
            on: expectedDate(dayIndex: 0), calendar: calendar
        )

        let outcome = reopen(harness).materialize(
            kitchenStore: harness.kitchen, recipeStore: harness.recipes, calendar: calendar
        )

        XCTAssertTrue(outcome.didChangeSchedule, "the append decision was already made when the receipt was written")
    }

    func testACopiedMenuStartsWithoutTheOriginalsReceipt() throws {
        let harness = makeHarness()
        harness.planner.generatedPlan = draft(days: [0: [aiDish(id: "weekly-ai-1", title: "番茄炒蛋")]])
        XCTAssertTrue(materialize(harness).didChangeSchedule)
        XCTAssertNotNil(harness.kitchen.weeklyPlan?.materialization)

        let copy = try XCTUnwrap(harness.kitchen.duplicateWeeklyPlanForNextWeek())

        XCTAssertNil(copy.materialization, "a copy has never been added to the plan")

        // And it can be added on its own days, without disturbing the original's.
        let planner = reopen(harness)
        let outcome = planner.materialize(
            kitchenStore: harness.kitchen, recipeStore: harness.recipes, calendar: calendar
        )
        XCTAssertTrue(outcome.didChangeSchedule)
        XCTAssertEqual(harness.kitchen.plans.count, 2, "the original meal stands and the copy adds its own")
    }

    // MARK: - Receipt integrity

    func testAnEditedMenuWillNotReuseItsOldReceipt() throws {
        let harness = makeHarness()
        _ = try pendingReceiptAfterAFailedPlanWrite(harness)

        // The member removed a dish before retrying, so the recorded ids can no
        // longer be matched to dishes without guessing.
        let reopened = reopen(harness)
        var edited = try XCTUnwrap(reopened.generatedPlan)
        edited.days[1].meals[0].recipes = []
        reopened.generatedPlan = edited

        let outcome = reopened.materialize(
            kitchenStore: harness.kitchen, recipeStore: harness.recipes, calendar: calendar
        )

        XCTAssertEqual(outcome, .staleReceipt)
        XCTAssertTrue(harness.kitchen.plans.isEmpty, "and nothing is invented to cover the gap")
    }

    // MARK: - Receipt date mapping
    //
    // The receipt has to describe which meal belongs on which day by itself.
    // The same recipe on two days gives an identical id sequence, so without
    // the recorded days an edited menu would still look like a match and a
    // retry would put approved meals on the wrong dates.

    func testTheReceiptRecordsTheDayEachMealBelongsOn() throws {
        let harness = makeHarness()
        // The same recipe on two different days: only the dates tell them apart.
        harness.planner.generatedPlan = draft(days: [
            0: [aiDish(id: "weekly-ai-1", title: "番茄炒蛋")],
            1: [aiDish(id: "weekly-ai-1", title: "番茄炒蛋")]
        ])

        let items = try XCTUnwrap(materialize(harness).materializedItems)

        let receipt = try XCTUnwrap(harness.kitchen.weeklyPlan?.materialization)
        XCTAssertEqual(receipt.recipeIDs, ["weekly-ai-1", "weekly-ai-1"], "one recipe, twice")
        XCTAssertEqual(
            receipt.planDates, [expectedDate(dayIndex: 0), expectedDate(dayIndex: 1)],
            "and two different days, which is the only thing distinguishing them"
        )
        XCTAssertEqual(receipt.planIDs.count, 2)
        XCTAssertEqual(items.map(\.date), receipt.planDates)
        XCTAssertEqual(harness.kitchen.plans.map(\.date), receipt.planDates)
    }

    func testAMenuWhoseDaysMovedWillNotReuseItsReceipt() throws {
        let harness = makeHarness()
        let receipt = try pendingReceiptAfterAFailedPlanWrite(harness)
        XCTAssertEqual(receipt.recipeIDs.count, 2)

        // The dishes and their order are untouched; only the days they sit on
        // change. The recipe sequence still matches, so dates are what catch it.
        let reopened = reopen(harness)
        var moved = try XCTUnwrap(reopened.generatedPlan)
        moved.days[1].dayIndex = 4
        reopened.generatedPlan = moved

        let outcome = reopened.materialize(
            kitchenStore: harness.kitchen, recipeStore: harness.recipes, calendar: calendar
        )

        XCTAssertEqual(outcome, .staleReceipt, "approved meals are never quietly moved to other days")
        XCTAssertTrue(harness.kitchen.plans.isEmpty)
    }

    func testAMenuThatStartsOnADifferentDayWillNotReuseItsReceipt() throws {
        let harness = makeHarness()
        _ = try pendingReceiptAfterAFailedPlanWrite(harness)

        let reopened = reopen(harness)
        var shifted = try XCTUnwrap(reopened.generatedPlan)
        shifted.startDate = calendar.date(byAdding: .day, value: 3, to: shifted.startDate)!
        reopened.generatedPlan = shifted

        let outcome = reopened.materialize(
            kitchenStore: harness.kitchen, recipeStore: harness.recipes, calendar: calendar
        )

        XCTAssertEqual(outcome, .staleReceipt)
        XCTAssertTrue(harness.kitchen.plans.isEmpty)
    }

    func testARetryPutsTheMealsOnTheDaysTheReceiptRecorded() throws {
        let harness = makeHarness()
        let receipt = try pendingReceiptAfterAFailedPlanWrite(harness)

        let retry = reopen(harness).materialize(
            kitchenStore: harness.kitchen, recipeStore: harness.recipes, calendar: calendar
        )

        XCTAssertTrue(retry.didChangeSchedule)
        XCTAssertEqual(harness.kitchen.plans.map(\.id), receipt.planIDs)
        XCTAssertEqual(
            harness.kitchen.plans.map(\.date), receipt.planDates,
            "the days come from the receipt the member's attempt committed to"
        )
    }

    func testPuttingBackAMissingMealUsesTheDayTheReceiptRecorded() throws {
        let harness = makeHarness()
        let receipt = try pendingReceiptAfterAFailedPlanWrite(harness)
        let planDates = try XCTUnwrap(receipt.planDates)
        harness.kitchen.appendPlans([
            MealPlanItem(id: receipt.planIDs[0], recipeID: "weekly-ai-1", recipeName: "番茄炒蛋", date: planDates[0])
        ])

        let outcome = reopen(harness).materializeMissingMeals(
            kitchenStore: harness.kitchen, recipeStore: harness.recipes, calendar: calendar
        )

        XCTAssertTrue(outcome.didChangeSchedule)
        let restored = try XCTUnwrap(harness.kitchen.plans.first { $0.id == receipt.planIDs[1] })
        XCTAssertEqual(restored.date, planDates[1], "restored onto the day it was approved for")
        XCTAssertEqual(restored.recipeID, receipt.recipeIDs[1])
    }

    func testAReceiptWithNoRecordedDaysCannotProveItsMapping() throws {
        let harness = makeHarness()
        let receipt = try pendingReceiptAfterAFailedPlanWrite(harness)

        // A receipt from before days were recorded.
        let reopened = reopen(harness)
        var legacy = try XCTUnwrap(reopened.generatedPlan)
        legacy.materialization = WeeklyMaterializationReceipt(
            state: .pending,
            planIDs: receipt.planIDs,
            recipeIDs: receipt.recipeIDs,
            planDates: nil,
            startedAt: receipt.startedAt
        )
        reopened.generatedPlan = legacy

        let outcome = reopened.materialize(
            kitchenStore: harness.kitchen, recipeStore: harness.recipes, calendar: calendar
        )

        XCTAssertEqual(outcome, .staleReceipt, "an unproven mapping is not treated as proven")
        XCTAssertTrue(harness.kitchen.plans.isEmpty)
    }

    func testAReceiptWhoseParallelArraysDisagreeIsRejected() throws {
        let harness = makeHarness()
        let receipt = try pendingReceiptAfterAFailedPlanWrite(harness)
        let planDates = try XCTUnwrap(receipt.planDates)

        let reopened = reopen(harness)
        var malformed = try XCTUnwrap(reopened.generatedPlan)
        malformed.materialization = WeeklyMaterializationReceipt(
            state: .pending,
            planIDs: receipt.planIDs,
            recipeIDs: receipt.recipeIDs,
            planDates: [planDates[0]],
            startedAt: receipt.startedAt
        )
        reopened.generatedPlan = malformed

        XCTAssertEqual(
            reopened.materialize(kitchenStore: harness.kitchen, recipeStore: harness.recipes, calendar: calendar),
            .staleReceipt
        )
        XCTAssertTrue(harness.kitchen.plans.isEmpty)
    }

    // MARK: - Helpers

    /// Leaves the harness with a durable pending receipt for two dishes and no
    /// meals on the plan — the state a failed canonical write produces.
    @discardableResult
    private func pendingReceiptAfterAFailedPlanWrite(
        _ harness: Harness
    ) throws -> WeeklyMaterializationReceipt {
        harness.planner.generatedPlan = draft(days: [
            0: [aiDish(id: "weekly-ai-1", title: "番茄炒蛋")],
            1: [aiDish(id: "weekly-ai-2", title: "青椒肉丝", ingredient: "青椒 3 个")]
        ])
        harness.todayPlan.shouldFail = true
        XCTAssertEqual(materialize(harness), .planPersistenceFailed)
        harness.todayPlan.shouldFail = false
        return try XCTUnwrap(harness.weekly.plan?.materialization)
    }
}

