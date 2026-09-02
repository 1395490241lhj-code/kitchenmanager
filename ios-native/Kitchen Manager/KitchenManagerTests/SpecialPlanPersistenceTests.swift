import XCTest
import SwiftData
@testable import KitchenManager

/// Persistence for special plans: CRUD, restart durability, and the SwiftData
/// schema upgrade (13 -> 14 models) — the same pattern the PreparedComponent
/// tests use. The production composition seam (`KitchenPersistenceFactory.bundle`)
/// is used so a dropped dependency fails here rather than silently degrading.
@MainActor
final class SpecialPlanPersistenceTests: XCTestCase {
    private var storeURL: URL!
    private var defaultsSuiteName: String!

    override func setUpWithError() throws {
        storeURL = FileManager.default.temporaryDirectory
            .appending(path: "specialplan-durable-\(UUID().uuidString).store")
        defaultsSuiteName = "specialplan-durable-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
        UserDefaults().removePersistentDomain(forName: defaultsSuiteName)
        storeURL = nil
        defaultsSuiteName = nil
    }

    private func makeBundle() throws -> KitchenPersistenceBundle {
        try KitchenPersistenceFactory.bundle(
            container: KitchenPersistenceFactory.makeContainer(
                configuration: ModelConfiguration(url: storeURL)
            )
        )
    }

    private func makeStore() throws -> KitchenStore {
        KitchenStore(
            userDefaults: UserDefaults(suiteName: defaultsSuiteName)!,
            persistence: try makeBundle()
        )
    }

    private func plan(
        _ title: String = "朋友聚餐",
        offsetHours: Int = 18,
        people: Int = 7
    ) -> SpecialPlan {
        let day = Calendar.current.startOfDay(
            for: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let scheduled = Calendar.current.date(
            byAdding: .hour, value: offsetHours, to: day
        ) ?? day
        return SpecialPlan(
            title: title,
            scheduledAt: scheduled,
            peopleCount: people,
            constraintNotes: ["1 人不吃辣"],
            notes: "测试",
            dishes: [
                SpecialPlanDish(recipeID: "sample-mapotofu", recipeName: "麻婆豆腐"),
                SpecialPlanDish(recipeID: "sample-tomato-eggs", recipeName: "番茄炒鸡蛋")
            ]
        )
    }

    func testCRUDThroughTheStore() throws {
        let store = try makeStore()
        let p = plan()
        store.addSpecialPlan(p)
        XCTAssertEqual(store.specialPlans, [p])

        var edited = p
        edited.title = "周末火锅"
        edited.peopleCount = 5
        store.updateSpecialPlan(edited)
        XCTAssertEqual(store.specialPlans, [edited])

        XCTAssertNotNil(store.removeSpecialPlan(id: p.id))
        XCTAssertTrue(store.specialPlans.isEmpty)
    }

    func testRestartDurability() throws {
        let p = plan()
        try {
            let instanceA = try makeStore()
            instanceA.addSpecialPlan(p)
            XCTAssertEqual(instanceA.specialPlans, [p])
        }()

        let instanceB = try makeStore()
        XCTAssertEqual(
            instanceB.specialPlans, [p],
            "a special plan written by one store instance must still be there when the same on-disk store is reopened"
        )
    }

    func testMultipleSpecialPlansSurviveARestart() throws {
        let first = plan("朋友聚餐", offsetHours: 18, people: 7)
        let second = plan("火锅局", offsetHours: 12, people: 4)

        try {
            let a = try makeStore()
            a.addSpecialPlan(first)
            a.addSpecialPlan(second)
        }()

        let b = try makeStore()
        XCTAssertEqual(Set(b.specialPlans), Set([first, second]))
    }

    func testMultipleDishesPersistInOnePlan() throws {
        let p = plan()
        try {
            let a = try makeStore()
            a.addSpecialPlan(p)
        }()

        let b = try makeStore()
        XCTAssertEqual(b.specialPlans.first?.dishes.count, 2)
        XCTAssertEqual(
            b.specialPlans.first?.dishes.map(\.recipeID),
            ["sample-mapotofu", "sample-tomato-eggs"]
        )
    }

    func testBackupRestoreRoundTrip() throws {
        let p = plan()
        let store = try makeStore()

        // A backup from a build that predates special plans has no `specialPlans`
        // key. Adding it is the backward-compatibility story.
        var legacyPayload: [String: Any] = [
            "format": "kitchen-manager-native-backup",
            "version": 1,
            "inventory": [],
            "plans": [],
            "shoppingItems": [],
            "consumptionRecords": []
        ]
        legacyPayload["preparedComponents"] = []
        let legacyData = try JSONSerialization.data(withJSONObject: legacyPayload)

        // Restore should succeed with zero special plans.
        try store.restoreBackupData(legacyData)
        XCTAssertTrue(store.specialPlans.isEmpty)

        // A backup that does carry the field round-trips it.
        store.addSpecialPlan(p)
        let exported = try store.exportBackupData()
        let restoreStore = try makeStore()
        try restoreStore.restoreBackupData(exported)
        XCTAssertEqual(restoreStore.specialPlans, [p])
    }

    func testClearAllRemovesSpecialPlans() throws {
        let store = try makeStore()
        store.addSpecialPlan(plan())
        store.clearAllLocalData()
        XCTAssertTrue(store.specialPlans.isEmpty)

        // The restart after clear stays empty.
        let reopened = try makeStore()
        XCTAssertTrue(reopened.specialPlans.isEmpty)
    }

    func testDeletingASpecialPlanDoesNotDeleteRecipes() throws {
        let store = try makeStore()
        let p = plan()
        store.addSpecialPlan(p)
        store.removeSpecialPlan(id: p.id)
        XCTAssertTrue(store.specialPlans.isEmpty)
        // Nothing here even touches RecipeStore — deleting a plan is a pure row
        // removal; the reference is the only thing that connected them.
        XCTAssertTrue(store.plans.isEmpty)
    }

    func testAddRemoveAndReorderDishes() throws {
        let store = try makeStore()
        let p = plan()
        store.addSpecialPlan(p)

        let extra = SpecialPlanDish(recipeID: "user-braised-beef", recipeName: "红烧牛肉")
        XCTAssertTrue(store.addDish(extra, toSpecialPlan: p.id))
        XCTAssertEqual(store.specialPlans.first?.dishes.count, 3)

        XCTAssertTrue(store.moveDish(extra.id, inSpecialPlan: p.id, to: 0))
        XCTAssertEqual(store.specialPlans.first?.dishes.first?.recipeID, "user-braised-beef")

        XCTAssertTrue(store.removeDish(id: extra.id, fromSpecialPlan: p.id))
        XCTAssertEqual(store.specialPlans.first?.dishes.map(\.recipeID), ["sample-mapotofu", "sample-tomato-eggs"])
    }

    func testSetDishCooked() throws {
        let store = try makeStore()
        let p = plan()
        store.addSpecialPlan(p)
        let dishID = try XCTUnwrap(p.dishes.first?.id)

        XCTAssertTrue(store.setDishCooked(dishID, inSpecialPlan: p.id, isCooked: true))
        XCTAssertEqual(store.specialPlans.first?.dishes.first?.isCooked, true)
    }

    /// Dish completion is canonical plan state, not view state: it must survive
    /// a store reopen exactly like the title and the headcount do.
    func testDishCompletionSurvivesARestart() throws {
        let p = plan()
        let dishID = try XCTUnwrap(p.dishes.first?.id)

        try {
            let instanceA = try makeStore()
            instanceA.addSpecialPlan(p)
            XCTAssertTrue(instanceA.setDishCooked(dishID, inSpecialPlan: p.id, isCooked: true))
        }()

        let instanceB = try makeStore()
        let restored = try XCTUnwrap(instanceB.specialPlans.first)
        XCTAssertEqual(restored.dishes.count, 2)
        XCTAssertEqual(
            restored.dishes.first(where: { $0.id == dishID })?.isCooked, true,
            "a completed dish must still read as completed after reopening the store"
        )
        XCTAssertEqual(
            restored.dishes.last?.isCooked, false,
            "only the toggled dish may change"
        )

        // And it can be toggled back off durably.
        XCTAssertTrue(instanceB.setDishCooked(dishID, inSpecialPlan: p.id, isCooked: false))
        let instanceC = try makeStore()
        XCTAssertEqual(instanceC.specialPlans.first?.dishes.first?.isCooked, false)
    }

    // MARK: - Home-inventory switch

    func testNewPlanDefaultsToNotUsingHomeInventory() {
        let fresh = SpecialPlan(title: "去朋友家", scheduledAt: Date())
        XCTAssertFalse(fresh.usesHomeInventory)
        XCTAssertEqual(fresh.requestText, "")
    }

    func testInventorySwitchAndRequestSurviveARestartInBothStates() throws {
        for usesHomeInventory in [false, true] {
            var p = plan("开关 \(usesHomeInventory)")
            p.requestText = "这周六 7 个人吃饭，1 人不吃辣"
            p.usesHomeInventory = usesHomeInventory
            do {
                let store = try makeStore()
                store.addSpecialPlan(p)
            }
            let reopened = try makeStore()
            let loaded = try XCTUnwrap(reopened.specialPlans.first { $0.id == p.id })
            XCTAssertEqual(loaded.usesHomeInventory, usesHomeInventory)
            XCTAssertEqual(loaded.requestText, "这周六 7 个人吃饭，1 人不吃辣")
            XCTAssertEqual(loaded, p)
        }
    }

    /// A row written before the switch existed has no value in its payload.
    /// It keeps the behaviour it always had — reconcile against home
    /// inventory — rather than silently switching to the new default.
    func testLegacyRowWithoutTheSwitchReadsAsUsingHomeInventory() throws {
        let legacy = plan("老计划")
        let record = try SpecialPlanRecord(plan: legacy)
        // Exactly the JSON the previous build wrote: no requestText, no switch.
        record.payloadData = try JSONSerialization.data(withJSONObject: [
            "constraintNotes": ["1 人不吃辣"],
            "notes": "测试",
            "dishes": []
        ])
        let decoded = try record.specialPlan()
        XCTAssertTrue(decoded.usesHomeInventory, "legacy plans keep subtracting home inventory")
        XCTAssertEqual(decoded.requestText, "")
        XCTAssertEqual(decoded.constraintNotes, ["1 人不吃辣"])

        // And a legacy row that goes through the store keeps that value on
        // its next save instead of being rewritten to the new default.
        let bundle = try makeBundle()
        try bundle.specialPlans.upsert(decoded)
        let reloaded = try XCTUnwrap(bundle.specialPlans.loadPlans().first { $0.id == legacy.id })
        XCTAssertTrue(reloaded.usesHomeInventory)
    }

    func testLegacyBackupPlanWithoutTheSwitchRestoresAsUsingHomeInventory() throws {
        let legacyPlan: [String: Any] = [
            "id": UUID().uuidString,
            "title": "旧备份",
            "scheduledAt": 1_750_000_000.0 - 978_307_200,
            "peopleCount": 5,
            "constraintNotes": [],
            "notes": "",
            "dishes": [],
            "createdAt": 0,
            "updatedAt": 0
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyPlan)
        let decoded = try JSONDecoder().decode(SpecialPlan.self, from: data)
        XCTAssertTrue(decoded.usesHomeInventory)
        XCTAssertEqual(decoded.requestText, "")
        XCTAssertEqual(decoded.peopleCount, 5)

        // A current backup round-trips the explicit value, including false.
        var p = plan("新备份")
        p.usesHomeInventory = false
        p.requestText = "去朋友家做饭"
        let roundTripped = try JSONDecoder().decode(SpecialPlan.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(roundTripped, p)
        XCTAssertFalse(roundTripped.usesHomeInventory)
    }

    /// A backup written before special plans existed has no `specialPlans` key
    /// at all; it must restore as empty rather than failing the whole payload.
    func testLegacyBackupWithoutSpecialPlansDecodesAsEmpty() throws {
        let legacy: [String: Any] = [
            "format": "kitchen-manager-native-backup",
            "version": 1,
            "inventory": [],
            "plans": [],
            "shoppingItems": [],
            "consumptionRecords": []
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let payload = try JSONDecoder().decode(KitchenBackupPayload.self, from: data)
        XCTAssertTrue(payload.specialPlans.isEmpty)
    }
}

// MARK: - Seed replication

extension SpecialPlanPersistenceTests {
    /// Mirrors the UI-test seed exactly: clear-all, then add a special plan on
    /// this week's Saturday and a meal. Guards against the seeded plan silently
    /// missing from the store the planner reads.
    func testSeedFlowKeepsBothSources() throws {
        let store = try makeStore()
        store.clearAllLocalData()

        let calendar = Calendar.current
        let monday = PlannerProjection.startOfWeek(
            containing: calendar.startOfDay(for: Date()),
            calendar: calendar
        )
        let eventDate = calendar.date(byAdding: .day, value: 5, to: monday) ?? monday
        let scheduled = calendar.date(byAdding: .hour, value: 18, to: eventDate) ?? eventDate

        var plan = SpecialPlan(
            title: "朋友聚餐",
            scheduledAt: scheduled,
            peopleCount: 7,
            constraintNotes: ["1 人不吃辣"],
            dishes: [SpecialPlanDish(recipeID: "sample-mapotofu", recipeName: "麻婆豆腐")]
        )
        plan.createdAt = Date()
        plan.updatedAt = plan.createdAt
        store.addSpecialPlan(plan)
        store.addPlans([(recipe: Recipe.samples[0], plannedServings: Int?(2))])

        XCTAssertEqual(store.specialPlans.count, 1, "seed special plan must be in the store")
        XCTAssertEqual(store.plans.count, 1)

        let weekStart = PlannerProjection.startOfWeek(containing: Date(), calendar: calendar)
        let entries = PlannerProjection.entries(
            inWeekStarting: weekStart,
            meals: store.plans,
            specialPlans: store.specialPlans,
            calendar: calendar
        )
        XCTAssertTrue(
            entries.contains { entry in
                if case .specialPlan(let p) = entry, p.title == "朋友聚餐" { return true }
                return false
            },
            "the seeded special plan must be inside the current week projection"
        )
    }
}
