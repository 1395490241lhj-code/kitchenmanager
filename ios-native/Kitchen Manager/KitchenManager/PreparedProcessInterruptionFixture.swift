#if DEBUG
import Foundation
import Darwin

/// Opt-in synthetic processes stop at a save boundary for the leased host runner to kill.
@MainActor
enum PreparedProcessInterruptionFixture {
    private static func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "99000000-0000-0000-0000-%012d", value))!
    }
    private static func payload(new: Bool) throws -> KitchenBackupPayload {
        let date = Date(timeIntervalSince1970: 100)
        let source = try PreparedSourceSnapshot(id: id(new ? 200 : 100), name: new ? "新鸡肉" : "原鸡肉",
            initialMassDecigrams: new ? 1000 : 8000, initialPortionCount: new ? 3 : 4)
        let plan = try PreparedPortionAllocator.allocate(source: source, groupIDs: new ? [id(201), id(202)] : [id(1)])
        let groups = try plan.groups.map {
            PreparedComponent(id: $0.id, name: source.name, portionsRemaining: $0.count, state: .cooked,
                storage: .frozen, preparedAt: date, expiryDate: date,
                grouping: try PreparedPortionGrouping(source: source, massPerPortionDecigrams: $0.massPerPortionDecigrams))
        }
        let label = new ? "新" : "原"
        let meal = MealPlanItem(recipeID: "sample-mapotofu", recipeName: label + "菜")
        return KitchenBackupPayload(inventory: [InventoryItem(id: id(10), name: label + "米饭", quantity: new ? 2 : 3, unit: "份", expiryDate: date)],
            plans: [meal], shoppingItems: [KitchenShoppingItem(name: label + "牛奶", quantity: 1, unit: "盒")],
            weeklyPlan: WeeklyMealPlan(startDate: date, days: [WeeklyMealPlanDay(dayIndex: 0, meals: [])],
                shoppingItems: [], servings: 2, summary: label + "周计划", createdAt: date),
            consumptionRecords: [InventoryConsumptionRecord(id: id(13), date: date, recipeID: meal.recipeID,
                recipeName: meal.recipeName, planIDs: [meal.id], items: [])],
            preparedComponents: groups + [PreparedComponent(id: id(3), name: label + "旧备餐", portionsRemaining: 2,
                state: .cooked, storage: .refrigerated, preparedAt: date, expiryDate: date)],
            specialPlans: [SpecialPlan(title: label + "聚餐", scheduledAt: date, peopleCount: 4, constraintNotes: [],
                notes: label, dishes: [SpecialPlanDish(recipeID: meal.recipeID, recipeName: meal.recipeName)])])
    }
    static func runIfRequested(in store: KitchenStore, persistence: KitchenPersistenceBundle) {
        guard let action = ProcessInfo.processInfo.environment["PREPARED_PROCESS_ACTION"] else { return }
        precondition(PreparedPortionGroupingUIFixture.isEnabled)
        let directory = PreparedPortionGroupingUIFixture.directory
        func write(_ data: Data, _ name: String) throws { try data.write(to: directory.appending(path: name), options: .atomic) }
        func report(_ name: String, boundary: String? = nil) throws {
            var value: [String: Any] = ["pid": getpid(), "action": action,
                "session": ProcessInfo.processInfo.environment["PREPARED_GROUPING_SESSION"]!,
                "payload": try JSONSerialization.jsonObject(with: store.exportBackupData()),
                "outcome": String(describing: store.lastRestoreOutcome),
                "outstandingRecovery": store.recoverySnapshot.hasOutstandingSnapshot]
            if let boundary { value["boundary"] = boundary }
            try write(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), name)
        }
        func stop(_ boundary: String) {
            do { try report("checkpoint.json", boundary: boundary) }
            catch { _exit(91) }
            raise(SIGSTOP)
            _exit(92) // Resuming instead of killing must never continue the operation.
        }
        do {
            if action == "seed" || action == "seed-v1" {
                var original = try payload(new: false)
                if action == "seed-v1" {
                    original.version = 1
                    original.preparedComponents = original.preparedComponents.map { row in
                        var row = row; row.grouping = nil; return row
                    }
                }
                let candidate = try payload(new: true)
                try store.restoreBackupData(JSONEncoder().encode(original))
                try write(JSONEncoder().encode(original), "baseline.json")
                try write(JSONEncoder().encode(candidate), "candidate.json")
                if action == "seed-v1" {
                    try store.restoreBackupData(JSONEncoder().encode(candidate))
                    try store.recoverySnapshot.prepare(JSONEncoder().encode(original))
                }
            } else if action == "probe" {
                // Read only: no replay or automatic recovery on restart.
            } else if action == "blocked" {
                do {
                    try store.restoreBackupData(Data(contentsOf: directory.appending(path: "candidate.json")))
                    _exit(93)
                } catch KitchenRecoverySnapshotError.outstandingSnapshotPresent { }
            } else if action == "recover" {
                try store.restoreFromRecoverySnapshot()
            } else {
                guard let prepared = persistence.preparedComponents as? SwiftDataPreparedComponentPersistence else { _exit(94) }
                if action.hasSuffix("-before") { prepared.beforeReplaceSaveForTesting = { stop("before-save") } }
                else { prepared.afterReplaceSaveForTesting = { stop("after-commit-before-publication") } }
                if action.hasPrefix("create-") {
                    let candidate = try KitchenBackupValidator.validate(Data(contentsOf: directory.appending(path: "candidate.json")))
                    let row = candidate.preparedComponents[0]
                    let source = row.grouping!.source
                    _ = try store.addPreparedSource(draft: PreparedSourceDraft(sourceID: source.id,
                        groupIDs: candidate.preparedComponents.filter { $0.grouping != nil }.map(\.id), name: source.name,
                        massDecigrams: source.initialMassDecigrams, portionCount: source.initialPortionCount,
                        state: row.state, storage: row.storage, preparedAt: row.preparedAt, expiryDate: row.expiryDate)).get()
                } else if action.hasPrefix("split-") {
                    let row = store.preparedComponents.first { $0.id == id(1) }!
                    _ = try store.splitPreparedComponent(id: row.id, taking: 1, newGroupID: id(2), expected: row).get()
                } else if action.hasPrefix("consume-") {
                    _ = try store.consumePreparedPortion(id: id(1)).get()
                } else if action == "restore-after" {
                    try store.restoreBackupData(Data(contentsOf: directory.appending(path: "candidate.json")))
                } else if action == "recovery-after" {
                    try store.restoreFromRecoverySnapshot()
                } else { _exit(95) }
                _exit(96) // A requested boundary that was not hit is a failed probe.
            }
            try report("result.json")
            _exit(0)
        } catch {
            try? write(Data(String(describing: error).utf8), "error.txt")
            _exit(97)
        }
    }
}
#endif
