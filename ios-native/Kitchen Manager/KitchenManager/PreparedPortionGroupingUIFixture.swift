#if DEBUG
import Foundation
import SwiftData

/// Isolated synthetic disk stores, opt-in per UI-test session. Never normal app data.
@MainActor
enum PreparedPortionGroupingUIFixture {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("UITEST_PREPARED_GROUPING") }
    static var simulateStaleEdit: Bool { isEnabled && ProcessInfo.processInfo.arguments.contains("UITEST_GROUPED_STALE_EDIT") }
    static var directory: URL {
        precondition(isEnabled)
        guard let text = ProcessInfo.processInfo.environment["PREPARED_GROUPING_SESSION"], let id = UUID(uuidString: text) else {
            preconditionFailure("Prepared UI fixture requires an isolated session UUID")
        }
        return FileManager.default.temporaryDirectory.appending(path: "PreparedGroupingUI-\(id.uuidString)")
    }
    static var recovery: KitchenRecoverySnapshotStore {
        KitchenRecoverySnapshotStore(directoryURL: directory.appending(path: "recovery"))
    }
    static func configure() -> KitchenPersistenceBundle {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let marker = directory.appending(path: "seeded")
            let bundle = KitchenPersistenceFactory.bundle(container: try KitchenPersistenceFactory.makeContainer(
                configuration: ModelConfiguration(url: directory.appending(path: "kitchen.store"))))
            if !FileManager.default.fileExists(atPath: marker.path) {
                if ProcessInfo.processInfo.arguments.contains("UITEST_GROUPED_SEED_LIFECYCLE") {
                    try seedLifecycle(bundle)
                } else if ProcessInfo.processInfo.arguments.contains("UITEST_GROUPED_SEED_RECOMMENDATION") {
                    try seedRecommendation(bundle)
                } else if ProcessInfo.processInfo.arguments.contains("UITEST_GROUPED_SEED_LINKED") { try seed(bundle) }
                try Data().write(to: marker, options: .atomic)
            }
            let args = ProcessInfo.processInfo.arguments
            let failingWrite = args.first(where: { $0.hasPrefix("UITEST_GROUPED_FAIL_WRITE=") })
                .flatMap { Int($0.split(separator: "=").last ?? "") }
            let unreadable = args.contains("UITEST_GROUPED_UNREADABLE")
            guard failingWrite != nil || unreadable else { return bundle }
            return KitchenPersistenceBundle(
                inventory: bundle.inventory, shoppingList: bundle.shoppingList, todayPlan: bundle.todayPlan,
                consumption: bundle.consumption, weeklyPlan: bundle.weeklyPlan,
                userRecipes: bundle.userRecipes, recipePreferences: bundle.recipePreferences,
                preparedComponents: Boundary(wrapped: bundle.preparedComponents, failingWrite: failingWrite,
                    failingReads: unreadable ? 2 : 0),
                specialPlans: bundle.specialPlans, conversations: bundle.conversations, sync: bundle.sync)

        } catch { preconditionFailure("Prepared grouping fixture could not open its synthetic store") }
    }
    private static func seedRecommendation(_ bundle: KitchenPersistenceBundle) throws {
        let source = try PreparedSourceSnapshot(id: UUID(uuidString: "88000000-0000-0000-0000-000000000100")!,
            name: "鸡肉", initialMassDecigrams: 1000, initialPortionCount: 3)
        let plan = try PreparedPortionAllocator.allocate(source: source, groupIDs: [
            UUID(uuidString: "88000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "88000000-0000-0000-0000-000000000002")!])
        let now = Date()
        try bundle.preparedComponents.replaceComponents(with: plan.groups.map { group in
            PreparedComponent(id: group.id, name: "鸡肉", portionsRemaining: group.count,
                state: .cooked, storage: .refrigerated, preparedAt: now,
                expiryDate: now.addingTimeInterval(86400),
                grouping: try PreparedPortionGrouping(source: source, massPerPortionDecigrams: group.massPerPortionDecigrams))
        })
        try bundle.inventory.replaceInventory(with: [
            InventoryItem(name: "米饭", quantity: 2, unit: "份", expiryDate: now.addingTimeInterval(432_000)),
            InventoryItem(name: "西兰花", quantity: 2, unit: "份", expiryDate: now.addingTimeInterval(432_000))])
    }
    private static func seedLifecycle(_ bundle: KitchenPersistenceBundle) throws {
        let source = try PreparedSourceSnapshot(id: UUID(uuidString: "88000000-0000-0000-0000-000000000100")!,
            name: "鸡肉", initialMassDecigrams: 8000, initialPortionCount: 4)
        let now = Date()
        let row = PreparedComponent(id: UUID(uuidString: "88000000-0000-0000-0000-000000000001")!,
            name: "鸡肉", portionsRemaining: 4, state: .prepped, storage: .frozen,
            preparedAt: now, expiryDate: now.addingTimeInterval(30 * 86400),
            grouping: try PreparedPortionGrouping(source: source, massPerPortionDecigrams: 2000))
        let legacy = PreparedComponent(id: UUID(uuidString: "88000000-0000-0000-0000-000000000003")!,
            name: "香菇鸡肉配彩椒与西兰花的家庭备餐", portionsRemaining: 3, state: .prepped, storage: .refrigerated,
            preparedAt: now, expiryDate: now.addingTimeInterval(30 * 86400))
        try bundle.preparedComponents.replaceComponents(with: [row, legacy])
    }
    private static func seed(_ bundle: KitchenPersistenceBundle) throws {
        let source = try PreparedSourceSnapshot(id: UUID(uuidString: "88000000-0000-0000-0000-000000000100")!,
            name: "鸡肉", initialMassDecigrams: 8000, initialPortionCount: 4)
        let now = Date()
        let groups = try [1, 2].map { index in
            PreparedComponent(id: UUID(uuidString: "88000000-0000-0000-0000-00000000000\(index)")!,
                name: "鸡肉", portionsRemaining: 2, state: .cooked, storage: .frozen,
                preparedAt: now, expiryDate: now.addingTimeInterval(86400),
                grouping: try PreparedPortionGrouping(source: source, massPerPortionDecigrams: 2000))
        }
        let legacy = PreparedComponent(id: UUID(uuidString: "88000000-0000-0000-0000-000000000003")!,
            name: "卤鸡腿", portionsRemaining: 3, state: .cooked, storage: .refrigerated,
            preparedAt: now, expiryDate: now.addingTimeInterval(86400))
        // A leading legacy row exposes any incorrect global/section index deletion.
        try bundle.preparedComponents.replaceComponents(with: [legacy, groups[0], groups[1]])
    }
    static func stageRecoveryIfRequested(in store: KitchenStore) {
        guard isEnabled else { return }
        if ProcessInfo.processInfo.arguments.contains("UITEST_GROUPED_CAPTURE_REOPEN") {
            do {
                let data = try store.exportBackupData()
                let pid = ProcessInfo.processInfo.processIdentifier
                let filename = "ui-reopen-\(pid).json"
                try data.write(to: directory.appending(path: filename), options: .atomic)
                try data.write(to: directory.appending(path: "ui-reopen.json"), options: .atomic)
                let historyURL = directory.appending(path: "ui-launches.json")
                var history = (try? JSONSerialization.jsonObject(with: Data(contentsOf: historyURL))) as? [[String: Any]] ?? []
                history.append(["pid": pid, "snapshot": filename])
                try JSONSerialization.data(withJSONObject: history, options: [.sortedKeys]).write(to: historyURL, options: .atomic)
            } catch { preconditionFailure("Synthetic UI reopen evidence could not be captured") }
        }
        let state = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("UITEST_GROUPED_RECOVERY_STATE=") }
            .flatMap { SafeRestoreFixture.State(rawValue: String($0.split(separator: "=").last ?? "")) }
        let staged = directory.appending(path: "recovery-staged")
        guard isEnabled, ProcessInfo.processInfo.arguments.contains("UITEST_GROUPED_STAGE_RECOVERY") || state != nil,
              !FileManager.default.fileExists(atPath: staged.path),
              !store.recoverySnapshot.hasOutstandingSnapshot else { return }
        do {
            let data = try state.map { try SafeRestoreFixture.candidateData(state: $0) } ?? store.exportBackupData()
            try store.recoverySnapshot.prepare(data)
            try data.write(to: directory.appending(path: "ui-original-recovery.json"), options: .atomic)
            try Data().write(to: staged, options: .atomic)
        } catch { preconditionFailure("Prepared grouping fixture could not stage qualified recovery bytes") }
    }
    private struct Fault: Error {}
    private final class Boundary: PreparedComponentPersistenceProtocol {
        let wrapped: PreparedComponentPersistenceProtocol
        let failingWrite: Int?
        var failingReads: Int
        var writes = 0
        init(wrapped: PreparedComponentPersistenceProtocol, failingWrite: Int?, failingReads: Int) {
            self.wrapped = wrapped; self.failingWrite = failingWrite; self.failingReads = failingReads
        }
        func loadComponents() throws -> [PreparedComponent] {
            if failingReads > 0 { failingReads -= 1; throw Fault() }
            return try wrapped.loadComponents()
        }
        func replaceComponents(with rows: [PreparedComponent]) throws {
            writes += 1
            if writes == failingWrite {
                guard let base = wrapped as? SwiftDataPreparedComponentPersistence else { throw Fault() }
                base.failNextReplaceSaveForTesting = Fault()
            }
            try wrapped.replaceComponents(with: rows)
        }
        func upsert(_ row: PreparedComponent) throws { try wrapped.upsert(row) }
        func delete(id: UUID) throws { try wrapped.delete(id: id) }
        func deleteAll() throws { try wrapped.deleteAll() }
    }
}
#endif
