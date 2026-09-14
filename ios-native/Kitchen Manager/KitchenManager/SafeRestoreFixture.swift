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
    }

    static var state: State {
        let raw = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("SAFE_RESTORE_") }
        return State(rawValue: String(raw?.dropFirst("SAFE_RESTORE_".count) ?? "")) ?? .dated
    }

    /// Known, deliberately uneven domain counts, so a test can tell the preview
    /// is reporting the candidate rather than the current kitchen.
    static func candidateData() throws -> Data {
        switch state {
        case .dated:
            return try JSONEncoder().encode(KitchenBackupPayload(
                inventory: [
                    InventoryItem(name: "备份番茄", quantity: 3, unit: "个", expiryDate: nil),
                    InventoryItem(name: "备份鸡蛋", quantity: 6, unit: "个", expiryDate: nil)
                ],
                plans: [],
                shoppingItems: [KitchenShoppingItem(name: "备份牛奶", quantity: 1, unit: "盒")],
                weeklyPlan: nil,
                consumptionRecords: [],
                preparedComponents: [],
                specialPlans: []
            ))
        case .legacy:
            // The shape of the oldest real v1 files: identity, the four keys
            // that have always been present, and no exportedAt.
            return try JSONSerialization.data(withJSONObject: [
                "format": KitchenBackupValidator.supportedFormat,
                "version": KitchenBackupValidator.supportedVersion,
                "inventory": [],
                "plans": [],
                "shoppingItems": [],
                "consumptionRecords": []
            ])
        }
    }
}
#endif
