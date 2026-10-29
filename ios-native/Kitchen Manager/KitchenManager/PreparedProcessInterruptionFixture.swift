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
    /// Literal old row vocabulary for a synthetic outstanding v1 copy only.
    static func historicalV1Data(_ payload: KitchenBackupPayload) throws -> Data {
        var root = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as! [String: Any]
        root["version"] = 1
        root["preparedComponents"] = payload.preparedComponents.map { row in
            ["id": row.id.uuidString, "name": row.name, "portionsRemaining": row.portionsRemaining,
             "state": row.state.rawValue, "storage": row.storage.rawValue,
             "preparedAt": row.preparedAt.timeIntervalSinceReferenceDate,
             "expiryDate": row.expiryDate.timeIntervalSinceReferenceDate] as [String: Any]
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
    /// Historical synthetic rows use the original vocabulary; tracked facts may never be stripped.
    static func historicalData(_ payload: KitchenBackupPayload, version: Int) throws -> Data {
        guard [1, 2].contains(version), payload.preparedComponents.allSatisfy({
            $0.lifecycle == nil && (version == 2 || $0.grouping == nil)
        }) else { throw PreparedLifecycleError.invalidMetadata }
        var root = try JSONSerialization.jsonObject(with: historicalV1Data(payload)) as! [String: Any]
        root["version"] = version
        if version == 2 {
            var rows = root["preparedComponents"] as! [[String: Any]]
            for index in rows.indices {
                if let grouping = payload.preparedComponents[index].grouping {
                    rows[index]["grouping"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(grouping))
                }
            }
            root["preparedComponents"] = rows
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
    static func pr3Payload(operation: String, candidate: Bool = false) throws -> KitchenBackupPayload {
        let date: (Double) -> Date = { Date(timeIntervalSince1970: $0) }
        var value = try payload(new: candidate)
        if candidate {
            for index in value.preparedComponents.indices where value.preparedComponents[index].grouping != nil {
                var row = value.preparedComponents[index]
                row.storage = .refrigerated
                row.state = index == 0 ? .prepped : .cooked
                row.lifecycle = PreparedLifecycle(version: 1, thawPhase: index == 0 ? .thawing : .inactive,
                    thawStartedAt: date(110), thawCompletedAt: index == 0 ? nil : date(150), cookedAt: index == 0 ? nil : date(200))
                value.preparedComponents[index] = row
            }
            value.preparedComponents.append(PreparedComponent(id: id(204), name: "已记录完成的旧备餐", portionsRemaining: 2,
                state: .prepped, storage: .refrigerated, preparedAt: date(100), expiryDate: date(100000),
                lifecycle: PreparedLifecycle(version: 1, thawPhase: .inactive, thawStartedAt: date(110),
                    thawCompletedAt: date(150), cookedAt: nil)))
            return value
        }
        let source = try PreparedSourceSnapshot(id: id(100), name: "原鸡肉", initialMassDecigrams: 8000, initialPortionCount: 4)
        let grouping = try PreparedPortionGrouping(source: source, massPerPortionDecigrams: 2000)
        let count = operation == "split-thawing" ? 2 : 1
        let tracked = operation != "begin-thaw"
        let completed = operation == "mark-cooked" || operation == "consume-final"
        let selected = PreparedComponent(id: id(1), name: source.name, portionsRemaining: count,
            state: operation == "consume-final" ? .cooked : .prepped,
            storage: tracked ? .refrigerated : .frozen, preparedAt: date(100), expiryDate: date(100000), grouping: grouping,
            lifecycle: tracked ? PreparedLifecycle(version: 1, thawPhase: completed ? .inactive : .thawing,
                thawStartedAt: date(110), thawCompletedAt: completed ? date(150) : nil,
                cookedAt: operation == "consume-final" ? date(200) : nil) : nil)
        let sibling = PreparedComponent(id: id(4), name: source.name, portionsRemaining: 4 - count,
            state: .prepped, storage: .frozen, preparedAt: date(100), expiryDate: date(100000), grouping: grouping)
        value.preparedComponents = [selected, sibling, value.preparedComponents.last!]
        return value
    }
    private static func performPR3(_ operation: String, in store: KitchenStore) throws {
        guard let row = store.preparedComponents.first(where: { $0.id == id(1) }) else { throw PreparedLifecycleError.invalidMetadata }
        if operation == "split-thawing" {
            _ = try store.splitPreparedComponent(id: row.id, taking: 1, newGroupID: id(2), expected: row).get()
        } else if operation == "consume-final" {
            _ = try store.consumePreparedPortion(id: row.id, expected: row, context: .immediateMeal).get()
        } else {
            let action: PreparedLifecycleAction
            switch operation {
            case "begin-thaw": action = .beginThaw
            case "complete-thaw": action = .completeThaw
            case "mark-cooked": action = .markCooked
            default: throw PreparedLifecycleError.invalidTransition
            }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let event = Date(timeIntervalSince1970: 300)
            let expiry = try PreparedLifecycleTransition.defaultExpiryDate(action: action, state: row.state,
                existingExpiryDate: row.expiryDate, eventAt: event, calendar: calendar)
            _ = try store.transitionPreparedComponent(id: row.id, expected: row, intent: PreparedLifecycleIntent(
                action: action, eventAt: event, calendar: calendar, expiryReview: PreparedExpiryReview(action: action,
                    existingExpiryDate: row.expiryDate, selectedExpiryDate: expiry, explicitlyEdited: false))).get()
        }
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
            if action.hasPrefix("pr3-seed-") {
                let operation = String(action.dropFirst("pr3-seed-".count))
                let isRecovery = operation.hasPrefix("recovery-v")
                let version = isRecovery ? Int(String(operation.suffix(1)))! : 3
                var original = try pr3Payload(operation: operation == "import-v3" || isRecovery ? "mark-cooked" : operation)
                if version < 3 {
                    original = try payload(new: false)
                    if version == 1 { original.preparedComponents = original.preparedComponents.map { var row = $0; row.grouping = nil; return row } }
                }
                let candidate = try pr3Payload(operation: "", candidate: true)
                let originalData = try version == 3 ? KitchenBackupValidator.encodeV3(original) : historicalData(original, version: version)
                let candidateData = try KitchenBackupValidator.encodeV3(candidate)
                try store.restoreBackupData(originalData)
                try write(originalData, "baseline.json"); try write(candidateData, "candidate.json")
                if isRecovery {
                    try store.restoreBackupData(candidateData)
                    try store.recoverySnapshot.prepare(originalData)
                }
            } else if action == "seed" || action == "seed-v1" {
                var original = try payload(new: false)
                if action == "seed-v1" {
                    original.version = 1
                    original.preparedComponents = original.preparedComponents.map { row in
                        var row = row; row.grouping = nil; return row
                    }
                }
                let candidate = try payload(new: true)
                let originalData = try action == "seed-v1" ? historicalV1Data(original) : KitchenBackupValidator.encodeV3(original)
                let candidateData = try KitchenBackupValidator.encodeV3(candidate)
                try store.restoreBackupData(originalData)
                try write(originalData, "baseline.json")
                try write(candidateData, "candidate.json")
                if action == "seed-v1" {
                    try store.restoreBackupData(candidateData)
                    try store.recoverySnapshot.prepare(originalData)
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
                if action == "pr3-restore-after" {
                    try store.restoreBackupData(Data(contentsOf: directory.appending(path: "candidate.json")))
                } else if action == "pr3-recovery-after" {
                    try store.restoreFromRecoverySnapshot()
                } else if action.hasPrefix("pr3-") {
                    let operation = String(action.dropFirst(4).dropLast(action.hasSuffix("-before") ? 7 : 6))
                    try performPR3(operation, in: store)
                } else if action.hasPrefix("create-") {
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
