import XCTest
import SwiftData
@testable import KitchenManager

@MainActor
final class PreparedPortionGroupingBackupTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "pr2-backup-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "pr2-backup-\(UUID())"; defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }
    private func bundle() throws -> KitchenPersistenceBundle {
        KitchenPersistenceFactory.bundle(container: try KitchenPersistenceFactory.makeContainer(
            configuration: ModelConfiguration(url: directory.appending(path: "test.store"))))
    }
    private func store(_ b: KitchenPersistenceBundle) -> KitchenStore {
        KitchenStore(userDefaults: defaults, persistence: b,
            recoverySnapshot: KitchenRecoverySnapshotStore(directoryURL: directory.appending(path: "recovery")))
    }
    private func rows() throws -> [PreparedComponent] {
        let source = try PreparedSourceSnapshot(id: UUID(), name: "鸡肉", initialMassDecigrams: 1000, initialPortionCount: 3)
        let allocation = try PreparedPortionAllocator.allocate(source: source, groupIDs: [UUID(), UUID()])
        return try allocation.groups.map { group in
            PreparedComponent(id: group.id, name: "显示名", portionsRemaining: group.count, state: .prepped,
                storage: .frozen, preparedAt: Date(timeIntervalSince1970: 100), expiryDate: Date(timeIntervalSince1970: 200),
                grouping: try PreparedPortionGrouping(source: source, massPerPortionDecigrams: group.massPerPortionDecigrams))
        }
    }
    private func payload() throws -> KitchenBackupPayload {
        let plan = MealPlanItem(recipeID: "sample-mapotofu", recipeName: "麻婆豆腐")
        var legacy = try rows()[0]; legacy.id = UUID(); legacy.grouping = nil; legacy.name = "旧备餐"
        return KitchenBackupPayload(inventory: [InventoryItem(name: "米饭", quantity: 3, unit: "份", expiryDate: nil)],
            plans: [plan], shoppingItems: [KitchenShoppingItem(name: "牛奶", quantity: 1, unit: "盒")],
            weeklyPlan: WeeklyMealPlan(startDate: Date(timeIntervalSince1970: 100),
                days: [WeeklyMealPlanDay(dayIndex: 0, meals: [])], shoppingItems: [], servings: 2,
                summary: "完整备份", createdAt: Date(timeIntervalSince1970: 101)),
            consumptionRecords: [InventoryConsumptionRecord(id: UUID(), date: Date(timeIntervalSince1970: 102),
                recipeID: plan.recipeID, recipeName: plan.recipeName, planIDs: [plan.id], items: [])],
            preparedComponents: try rows() + [legacy], specialPlans: [SpecialPlan(title: "聚餐",
                scheduledAt: Date(timeIntervalSince1970: 200), peopleCount: 4, constraintNotes: [], notes: "保留",
                dishes: [SpecialPlanDish(recipeID: "sample-mapotofu", recipeName: "麻婆豆腐")])])
    }
    private func object(_ payload: KitchenBackupPayload) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
    }
    private func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    func testV3ExportPreviewRestoreAndDiskRestartKeepAllSevenDomainsAndEveryGroupedField() throws {
        let original = try payload(); let b = try bundle(); let s = store(b)
        // This setup also exercises all seven production restore writers.
        try s.restoreBackupData(JSONEncoder().encode(original))
        let exported = try s.exportBackupData()
        XCTAssertEqual(try object(JSONDecoder().decode(KitchenBackupPayload.self, from: exported))["version"] as? Int, 3)
        let preview = try KitchenBackupValidator.validateCandidate(exported)
        XCTAssertEqual(preview.version, 3)
        XCTAssertTrue(preview.payload.matchesBackupScope(of: original))
        let confirmed = try KitchenBackupValidator.encodeV3(preview.payload) // exact preview path
        XCTAssertTrue(s.clearAllLocalData())
        try s.restoreBackupData(confirmed)
        let reopened = store(try bundle())
        let restored = try KitchenBackupValidator.validate(reopened.exportBackupData())
        XCTAssertTrue(restored.matchesBackupScope(of: original))
        XCTAssertEqual(restored.preparedComponents, original.preparedComponents)
        XCTAssertFalse(s.recoverySnapshot.hasOutstandingSnapshot)
    }
    func testV2RequiresExplicitPreparedArrayInOriginalBytesBeforePreviewCanNormalizeIt() throws {
        var valid = try XCTUnwrap(JSONSerialization.jsonObject(with: PreparedLifecycleBackupFixtures.historical(payload(), version: 2)) as? [String: Any])
        let invalidValues: [Any?] = [nil, NSNull(), "not-array", [:], 1]
        for invalid in invalidValues {
            var malformed = valid; malformed["preparedComponents"] = invalid
            XCTAssertThrowsError(try KitchenBackupValidator.validateCandidate(data(malformed)), "\(String(describing: invalid))")
        }
        valid["preparedComponents"] = []
        XCTAssertEqual(try KitchenBackupValidator.validateCandidate(data(valid)).payload.preparedComponents, [])
    }
    func testV1MissingNullAndLegacyPreparedRemainReadableWithoutInventedMass() throws {
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: PreparedLifecycleBackupFixtures.historical(payload(), version: 2)) as? [String: Any]); old["version"] = 1
        var legacy = try rows()[0]; legacy.grouping = nil
        let legacyJSON = [try PreparedLifecycleBackupFixtures.originalRow(legacy, version: 1)]
        let cases: [(Any?, [PreparedComponent])] = [(nil, []), (NSNull(), []), ([], []), (legacyJSON, [legacy])]
        for (historical, expected) in cases {
            old["preparedComponents"] = historical
            let candidate = try KitchenBackupValidator.validateCandidate(data(old))
            XCTAssertEqual(candidate.version, 1)
            XCTAssertTrue(candidate.payload.preparedComponents.allSatisfy { $0.grouping == nil })
            XCTAssertEqual(candidate.payload.preparedComponents, expected)
        }
    }
    func testDeclaredV1CannotCarryNonnullGroupingEvenWhenOtherwiseValid() throws {
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: PreparedLifecycleBackupFixtures.historical(payload(), version: 2)) as? [String: Any]); old["version"] = 1
        XCTAssertThrowsError(try KitchenBackupValidator.validateCandidate(data(old)))
        var rows = try XCTUnwrap(old["preparedComponents"] as? [[String: Any]])
        rows = [rows[0]]; rows[0]["grouping"] = NSNull(); old["preparedComponents"] = rows
        XCTAssertNil(try KitchenBackupValidator.validate(data(old)).preparedComponents[0].grouping)
    }
    func testUnsupportedMetadataMalformedSourceDuplicateAndImpossibleOriginalBucketsAreRefused() throws {
        var valid = try XCTUnwrap(JSONSerialization.jsonObject(with: PreparedLifecycleBackupFixtures.historical(payload(), version: 2)) as? [String: Any])
        let originalRows = try XCTUnwrap(valid["preparedComponents"] as? [[String: Any]])
        var variants = [[[String: Any]]]()
        variants.append([originalRows[0], originalRows[0]])
        var modified = originalRows
        var metadata = try XCTUnwrap(modified[0]["grouping"] as? [String: Any]); metadata["version"] = 99
        modified[0]["grouping"] = metadata; variants.append(modified)
        modified = originalRows; modified[0]["grouping"] = "broken"; variants.append(modified)
        modified = originalRows; metadata = try XCTUnwrap(modified[0]["grouping"] as? [String: Any])
        var source = try XCTUnwrap(metadata["source"] as? [String: Any]); source["name"] = "conflicting"
        metadata["source"] = source; modified[0]["grouping"] = metadata; variants.append(modified)
        modified = originalRows; modified[0]["portionsRemaining"] = 2; variants.append(modified) // 334 bucket capacity = 1
        modified = originalRows; modified[0]["portionsRemaining"] = 0; variants.append(modified)
        modified = originalRows; metadata = try XCTUnwrap(modified[0]["grouping"] as? [String: Any])
        metadata["massPerPortionDecigrams"] = Int64.max; modified[0]["grouping"] = metadata; variants.append(modified)
        for rows in variants {
            var invalid = valid; invalid["preparedComponents"] = rows
            XCTAssertThrowsError(try KitchenBackupValidator.validateCandidate(data(invalid)))
        }
    }
    func testDuplicateIDsInEveryArrayDomainAreRejectedBeforeIdentityNormalization() throws {
        let valid = try object(payload())
        for key in ["inventory", "shoppingItems", "plans", "consumptionRecords", "preparedComponents", "specialPlans"] {
            var bad = valid; let rows = try XCTUnwrap(valid[key] as? [Any]); bad[key] = rows + rows
            XCTAssertThrowsError(try KitchenBackupValidator.validateCandidate(data(bad)), key)
        }
    }
    func testV1RecoveryCopySurvivesReopenAndExplicitRecoveryWithOriginalUUIDs() throws {
        var old = try payload(); old.version = 1
        old.preparedComponents = old.preparedComponents.filter { $0.grouping == nil }
        let s = store(try bundle())
        try s.recoverySnapshot.prepare(PreparedLifecycleBackupFixtures.historical(old, version: 1))
        let reopened = store(try bundle())
        XCTAssertTrue(reopened.recoverySnapshot.hasOutstandingSnapshot)
        try reopened.restoreFromRecoverySnapshot()
        XCTAssertTrue(try KitchenBackupValidator.validate(reopened.exportBackupData()).matchesBackupScope(of: old))
        XCTAssertEqual(reopened.preparedComponents, old.preparedComponents)
        XCTAssertFalse(reopened.recoverySnapshot.hasOutstandingSnapshot)
    }
    func testFrozenPR1GateAcceptsV1AndRejectsV2BeforeTolerantDecodeCanStripGrouping() throws {
        var candidate = try payload(); candidate.version = 1; candidate.preparedComponents = []
        XCTAssertNoThrow(try FrozenPR1BackupValidator.validate(PreparedLifecycleBackupFixtures.historical(candidate, version: candidate.version)))
        candidate.version = 2; candidate.preparedComponents = try rows()
        XCTAssertThrowsError(try FrozenPR1BackupValidator.validate(PreparedLifecycleBackupFixtures.historical(candidate, version: candidate.version))) { error in
            guard case KitchenBackupError.unsupportedVersion(2) = error else { return XCTFail("\(error)") }
        }
        candidate.version = 3
        XCTAssertNoThrow(try KitchenBackupValidator.validate(JSONEncoder().encode(candidate)))
        candidate.version = 4
        XCTAssertThrowsError(try KitchenBackupValidator.validate(JSONEncoder().encode(candidate)))
    }
}
