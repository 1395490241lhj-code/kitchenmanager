import Foundation

#if DEBUG
/// DEBUG-only deterministic states for the feature 005 safe-restore workflow
/// tests. Launch arguments select data only; everything under test is the
/// production BackupRestoreView, the real validator and the real restore
/// pipeline.
///
/// The system file picker cannot be driven from a UI test, so the fixture
/// delivers its bytes through the one in-app entry that opens the same preview
/// on the same validated candidate: the outstanding recovery copy. Nothing is
/// bypassed - validation, preview and the destructive confirmation are all the
/// real path.
enum SafeRestoreFixture {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("UITEST_SEED_SAFE_RESTORE")
    }

    enum State: String {
        /// A normal v1 backup that carries an export date.
        case dated
        /// A real legacy v1 file with no exportedAt key at all.
        case legacy
        case v2, mixedV3, missingLifecycleV3
    }

    static var state: State {
        let raw = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("SAFE_RESTORE_") }
        return State(rawValue: String(raw?.dropFirst("SAFE_RESTORE_".count) ?? "")) ?? .dated
    }

    /// Explicit malformed inputs are for rejection tests, never positive recovery seeding.
    static func candidateData(state selected: State? = nil) throws -> Data {
        let chosen = selected ?? state
        if selected == nil && chosen == .missingLifecycleV3 { throw KitchenBackupError.invalidFile }
        switch chosen {
        case .legacy:
            return Data(#"{"format":"kitchen-manager-native-backup","version":1,"inventory":[],"plans":[],"shoppingItems":[],"consumptionRecords":[]}"#.utf8)
        case .dated:
            return Data(#"{"format":"kitchen-manager-native-backup","version":1,"exportedAt":700000000,"inventory":[{"id":"70000000-0000-0000-0000-000000000001","name":"备份番茄","quantity":3,"unit":"个"},{"id":"70000000-0000-0000-0000-000000000002","name":"备份鸡蛋","quantity":6,"unit":"个"}],"plans":[],"shoppingItems":[{"id":"70000000-0000-0000-0000-000000000003","name":"备份牛奶","quantity":1,"unit":"盒","source":"手动添加","isDone":false}],"consumptionRecords":[]}"#.utf8)
        case .v2:
            return Data(#"{"format":"kitchen-manager-native-backup","version":2,"exportedAt":700000000,"inventory":[],"plans":[],"shoppingItems":[],"consumptionRecords":[],"preparedComponents":[{"id":"70000000-0000-0000-0000-000000000004","name":"旧备餐","portionsRemaining":2,"state":"cooked","storage":"refrigerated","preparedAt":100,"expiryDate":1000000}]}"#.utf8)
        case .mixedV3, .missingLifecycleV3:
            let date = Date(timeIntervalSinceReferenceDate: 100)
            let source = try PreparedSourceSnapshot(id: UUID(uuidString: "70000000-0000-0000-0000-000000000010")!,
                name: "鸡肉", initialMassDecigrams: 8000, initialPortionCount: 4)
            let grouping = try PreparedPortionGrouping(source: source, massPerPortionDecigrams: 2000)
            let legacy = PreparedComponent(id: UUID(uuidString: "70000000-0000-0000-0000-000000000004")!,
                name: "旧备餐", portionsRemaining: 2, state: .cooked, storage: .refrigerated,
                preparedAt: date, expiryDate: date)
            let thaw = PreparedComponent(id: UUID(uuidString: "70000000-0000-0000-0000-000000000011")!,
                name: "鸡肉", portionsRemaining: 2, state: .prepped, storage: .refrigerated,
                preparedAt: date, expiryDate: date, grouping: grouping,
                lifecycle: PreparedLifecycle(version: 1, thawPhase: .thawing, thawStartedAt: date,
                    thawCompletedAt: nil, cookedAt: nil))
            var cooked = thaw; cooked.id = UUID(uuidString: "70000000-0000-0000-0000-000000000012")!
            cooked.state = .cooked
            cooked.lifecycle = PreparedLifecycle(version: 1, thawPhase: .inactive, thawStartedAt: date,
                thawCompletedAt: date, cookedAt: date)
            var payload = KitchenBackupPayload(inventory: [], plans: [], shoppingItems: [], weeklyPlan: nil,
                consumptionRecords: [], preparedComponents: [legacy, thaw, cooked])
            payload.exportedAt = Date(timeIntervalSinceReferenceDate: 700000000)
            let valid = try KitchenBackupValidator.encodeV3(payload)
            if chosen == .mixedV3 { return valid }
            var root = try JSONSerialization.jsonObject(with: valid) as! [String: Any]
            var rows = root["preparedComponents"] as! [[String: Any]]
            rows[1].removeValue(forKey: "lifecycle"); root["preparedComponents"] = rows
            return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        }
    }
}
#endif
