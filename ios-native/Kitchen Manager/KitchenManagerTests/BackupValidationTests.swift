import XCTest
@testable import KitchenManager

/// Feature 005, Phase 2: a decoded JSON object must not become a restore
/// candidate until it has been proven to be a supported Kitchen Manager backup.
///
/// The zero-mutation assertions do not infer from the final arrays alone. They
/// count writes at the persistence boundary, because inventory is the first
/// domain `restoreBackupData` replaces: a call count of zero proves the
/// destructive phase never began, not merely that it happened to end where it
/// started.
@MainActor
final class BackupValidationTests: XCTestCase {

    /// Counts whole-table writes and forwards everything else to a real
    /// in-memory persistence, so the store under test behaves normally.
    private final class InventoryWriteSpy: InventoryPersistenceProtocol {
        private let wrapped: InventoryPersistenceProtocol
        private(set) var replaceCallCount = 0

        init(wrapping wrapped: InventoryPersistenceProtocol) { self.wrapped = wrapped }

        func loadInventory() throws -> [InventoryItem] { try wrapped.loadInventory() }
        func replaceInventory(with items: [InventoryItem]) throws {
            replaceCallCount += 1
            try wrapped.replaceInventory(with: items)
        }
        func upsert(_ item: InventoryItem) throws { try wrapped.upsert(item) }
        func delete(id: UUID) throws { try wrapped.delete(id: id) }
        func deleteAll() throws { try wrapped.deleteAll() }
        func applyChanges(upserting items: [InventoryItem], deleting ids: [UUID]) throws {
            try wrapped.applyChanges(upserting: items, deleting: ids)
        }
    }

    private var spy: InventoryWriteSpy!
    private var store: KitchenStore!

    override func setUp() {
        super.setUp()
        let base = KitchenPersistenceFactory.isolatedInMemory()
        spy = InventoryWriteSpy(wrapping: base.inventory)
        let bundle = KitchenPersistenceBundle(
            inventory: spy,
            shoppingList: base.shoppingList,
            todayPlan: base.todayPlan,
            consumption: base.consumption,
            weeklyPlan: base.weeklyPlan,
            userRecipes: base.userRecipes,
            recipePreferences: base.recipePreferences,
            preparedComponents: base.preparedComponents,
            specialPlans: base.specialPlans,
            conversations: base.conversations,
            sync: base.sync
        )
        // Isolated recovery slot: this suite must not touch, or be blocked by,
        // the app's single production one.
        store = KitchenStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            persistence: bundle,
            recoverySnapshot: .isolated()
        )
    }

    override func tearDown() {
        store = nil
        spy = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// `KitchenBackupError` is not `Equatable`, and making it so from the test
    /// target would be a cross-module conformance on an internal type. Matching
    /// the two cases this slice introduces is smaller and just as strict.
    private static func matches(_ error: Error, _ expected: KitchenBackupError) -> Bool {
        guard let error = error as? KitchenBackupError else { return false }
        switch (error, expected) {
        case (.invalidFile, .invalidFile), (.unrecognizedBackup, .unrecognizedBackup):
            return true
        case (.unsupportedVersion(let actual), .unsupportedVersion(let wanted)):
            return actual == wanted
        default:
            return false
        }
    }

    private func seedKitchen() {
        store.addInventory(name: "番茄", quantity: 5, unit: "个", expiryDate: nil)
        store.addShopping(name: "牛奶", quantity: 1, unit: "盒")
    }

    /// Asserts the file was refused for `expected`, that the kitchen is exactly
    /// as it was, and that no whole-table inventory write was ever attempted.
    private func assertRefused(
        _ data: Data,
        _ expected: KitchenBackupError,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let inventoryBefore = store.inventory
        let shoppingBefore = store.shoppingItems
        let writesBefore = spy.replaceCallCount

        XCTAssertThrowsError(try store.restoreBackupData(data), what, file: file, line: line) { error in
            XCTAssertTrue(
                Self.matches(error, expected),
                "\(what) 的拒绝原因不符，实际为 \(error)", file: file, line: line
            )
        }

        XCTAssertEqual(
            spy.replaceCallCount, writesBefore,
            "\(what) 必须零持久化写入，实际尝试了 \(spy.replaceCallCount - writesBefore) 次",
            file: file, line: line
        )
        XCTAssertEqual(store.inventory, inventoryBefore, "\(what) 改动了库存", file: file, line: line)
        XCTAssertEqual(store.shoppingItems, shoppingBefore, "\(what) 改动了购物清单", file: file, line: line)
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    /// The four keys every v1 file carries, with nothing in them.
    private var minimalV1Object: [String: Any] {
        [
            "format": KitchenBackupValidator.supportedFormat,
            "version": KitchenBackupValidator.supportedVersion,
            "inventory": [],
            "plans": [],
            "shoppingItems": [],
            "consumptionRecords": []
        ]
    }

    // MARK: - 1. Rejected inputs, each with zero persistence writes

    func testMalformedBytesAreRefused() {
        seedKitchen()
        assertRefused(Data("not json at all {".utf8), .invalidFile, "畸形字节")
    }

    func testTopLevelJSONArrayIsRefused() throws {
        seedKitchen()
        assertRefused(try JSONSerialization.data(withJSONObject: [1, 2, 3]), .invalidFile, "顶层数组")
    }

    func testEmptyObjectIsRefused() throws {
        seedKitchen()
        // The headline regression: `{}` decodes cleanly into seven empty
        // domains and used to replace the whole kitchen with nothing.
        assertRefused(try json([:]), .unrecognizedBackup, "空对象 {}")
    }

    func testUnrelatedJSONObjectIsRefused() throws {
        seedKitchen()
        let unrelated: [String: Any] = ["title": "某个别的导出", "items": [["id": 1]], "schema": 7]
        assertRefused(try json(unrelated), .unrecognizedBackup, "其他应用的 JSON")
    }

    func testWrongFormatIsRefused() throws {
        seedKitchen()
        var object = minimalV1Object
        object["format"] = "some-other-product-backup"
        assertRefused(try json(object), .unrecognizedBackup, "format 不匹配")
    }

    func testMissingFormatIsRefused() throws {
        seedKitchen()
        var object = minimalV1Object
        object.removeValue(forKey: "format")
        assertRefused(try json(object), .unrecognizedBackup, "缺少 format")
    }

    func testMissingVersionIsRefused() throws {
        seedKitchen()
        var object = minimalV1Object
        object.removeValue(forKey: "version")
        assertRefused(try json(object), .unrecognizedBackup, "缺少 version")
    }

    func testFutureVersionIsRefused() throws {
        seedKitchen()
        var object = minimalV1Object
        object["version"] = 2
        assertRefused(try json(object), .unsupportedVersion(2), "未来版本")
    }

    func testObjectCarryingIdentityButNoRecognizedStructureIsRefused() throws {
        seedKitchen()
        // Identity alone is not enough: a file claiming to be a backup while
        // carrying none of the domain keys is not one.
        let object: [String: Any] = [
            "format": KitchenBackupValidator.supportedFormat,
            "version": KitchenBackupValidator.supportedVersion
        ]
        assertRefused(try json(object), .unrecognizedBackup, "有身份但无结构")
    }

    func testDomainKeyOfTheWrongShapeIsRefused() throws {
        seedKitchen()
        var object = minimalV1Object
        object["inventory"] = "not-an-array"
        assertRefused(try json(object), .unrecognizedBackup, "域键类型错误")
    }

    // MARK: - 2. Accepted inputs

    func testValidBackupRoundTripIsAccepted() throws {
        seedKitchen()
        let exported = try store.exportBackupData()
        store.addInventory(name: "黄瓜", quantity: 2, unit: "根", expiryDate: nil)
        XCTAssertEqual(store.inventory.count, 2)

        try store.restoreBackupData(exported)

        XCTAssertEqual(store.inventory.map(\.name), ["番茄"], "有效备份必须照常恢复")
        XCTAssertEqual(store.shoppingItems.map(\.name), ["牛奶"])
    }

    /// A kitchen that was empty when it was exported is a legitimate backup.
    /// It is told apart from `{}` by identity and structure, never by counting
    /// items -- otherwise restoring a deliberate empty state would be blocked.
    func testGenuineEmptyV1BackupIsAcceptedAndIsNotConfusedWithAnEmptyObject() throws {
        let emptyStore = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let emptyBackup = try emptyStore.exportBackupData()

        seedKitchen()
        XCTAssertFalse(store.inventory.isEmpty)

        try store.restoreBackupData(emptyBackup)

        XCTAssertTrue(store.inventory.isEmpty, "真实的空备份必须可以恢复")
        XCTAssertTrue(store.shoppingItems.isEmpty)
        XCTAssertGreaterThan(spy.replaceCallCount, 0, "这一条确实走到了写入阶段")
    }

    func testMinimalLegacyV1ObjectIsAccepted() throws {
        seedKitchen()
        // No `exportedAt`, no `weeklyPlan`, no `preparedComponents`, no
        // `specialPlans` — the shape of the oldest real v1 files, and the same
        // shape the repository already pins in SwiftDataConsistencyTests and
        // SpecialPlanPersistenceTests.
        try store.restoreBackupData(try json(minimalV1Object))
        XCTAssertTrue(store.inventory.isEmpty)
        XCTAssertTrue(store.preparedComponents.isEmpty)
        XCTAssertTrue(store.specialPlans.isEmpty)
    }

    func testV1BackupOmittingLaterDomainsStillRestoresTheDomainsItHas() throws {
        var object = minimalV1Object
        object["inventory"] = [
            [
                "id": UUID().uuidString,
                "name": "鸡蛋",
                "quantity": 6,
                "unit": "个",
                "isStaple": false,
                "autoSuggestRestock": false,
                "stapleTrackingMode": "quantity",
                "stapleAvailabilityStatus": "available"
            ]
        ]

        try store.restoreBackupData(try json(object))

        XCTAssertEqual(store.inventory.map(\.name), ["鸡蛋"])
        XCTAssertTrue(store.preparedComponents.isEmpty, "缺失的后加域恢复为空，而不是让整个文件失败")
        XCTAssertTrue(store.specialPlans.isEmpty)
    }

    // MARK: - 3. The validator itself

    func testValidatorSeparatesDecodingFromValidation() throws {
        // `{}` decodes perfectly well; that is exactly why decoding cannot be
        // the gate.
        XCTAssertNoThrow(
            try JSONDecoder().decode(KitchenBackupPayload.self, from: try json([:])),
            "前提：宽容解码仍然接受空对象"
        )
        XCTAssertThrowsError(try KitchenBackupValidator.validate(try json([:]))) { error in
            XCTAssertTrue(Self.matches(error, .unrecognizedBackup))
        }
    }
}
