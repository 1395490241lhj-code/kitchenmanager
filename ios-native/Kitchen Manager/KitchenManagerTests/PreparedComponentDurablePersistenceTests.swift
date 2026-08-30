import XCTest
import SwiftData
@testable import KitchenManager

/// Restart-style durable persistence for prepared components.
///
/// Every other prepared-component test injects `bundle.preparedComponents`
/// explicitly, so all of them pass even when the *production* composition root
/// forgets that dependency — which is exactly the bug this file exists to
/// catch. Two things therefore have to hold at once here:
///
/// 1. the store is opened on a real on-disk `ModelConfiguration(url:)`, never
///    `isStoredInMemoryOnly: true`, so a pass actually means bytes on disk;
/// 2. the `KitchenStore` under test is built through the *same* seam
///    `KitchenManagerApp.init` uses, so a persistence dropped from that seam
///    fails here rather than silently degrading to an in-memory container.
///
/// "Restart" is modelled the only way a unit test can: instance A writes, A and
/// its `ModelContext` are released, and a brand-new container + persistence +
/// store are opened over the same store URL — and the same `UserDefaults`
/// suite — as instance B. It does not exercise app-process launch, `@main`, or
/// SwiftUI `StateObject` lifetime; those stay covered by the source-level
/// composition guard in `test/ios-native-kitchen-store-composition.test.mjs`
/// and by manual simulator checks.
@MainActor
final class PreparedComponentDurablePersistenceTests: XCTestCase {
    private var storeURL: URL!
    /// One suite for the whole test, not one per instance: a real relaunch
    /// keeps its `UserDefaults`, and `KitchenStore.init` runs five
    /// UserDefaults-driven migrations against it before anything else.
    private var defaultsSuiteName: String!

    override func setUpWithError() throws {
        storeURL = FileManager.default.temporaryDirectory
            .appending(path: "prepared-durable-\(UUID().uuidString).store")
        defaultsSuiteName = "prepared-durable-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
        UserDefaults().removePersistentDomain(forName: defaultsSuiteName)
        storeURL = nil
        defaultsSuiteName = nil
    }

    // MARK: - Composition under test

    /// A durable bundle over `storeURL`, built through the same factory the
    /// application uses — only the store location differs.
    private func makeBundle() throws -> KitchenPersistenceBundle {
        try KitchenPersistenceFactory.bundle(
            container: KitchenPersistenceFactory.makeContainer(
                configuration: ModelConfiguration(url: storeURL)
            )
        )
    }

    /// Runs `body` in its own scope so instance A's store, persistences and
    /// `ModelContext`s are released before instance B opens the same file.
    /// Plain ARC scope exit is what releases them — deliberately not
    /// `autoreleasepool`, which does nothing for Swift-native objects.
    private func instanceScope<T>(_ body: () throws -> T) rethrows -> T {
        try body()
    }

    /// The production composition seam: `KitchenManagerApp.init` builds its
    /// `KitchenStore` through this same initializer, so every persistence the
    /// bundle carries reaches the store here exactly as it does in the app.
    ///
    /// What this cannot see is the app *choosing* that initializer — a test
    /// target cannot instantiate `@main struct KitchenManagerApp`. That half is
    /// guarded at source level by `test/ios-native-kitchen-store-composition.test.mjs`.
    private func makeStore() throws -> KitchenStore {
        KitchenStore(
            userDefaults: UserDefaults(suiteName: defaultsSuiteName)!,
            persistence: try makeBundle()
        )
    }

    private func component(
        _ name: String,
        portions: Int = 5,
        offset: TimeInterval = 0
    ) -> PreparedComponent {
        PreparedComponent(
            name: name,
            portionsRemaining: portions,
            state: .cooked,
            storage: .refrigerated,
            preparedAt: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            expiryDate: Date(timeIntervalSince1970: 1_700_300_000 + offset)
        )
    }

    // MARK: - Restart

    func testAPreparedComponentSurvivesAStoreRestart() throws {
        let batch = component("卤鸡腿")

        try instanceScope {
            let instanceA = try makeStore()
            instanceA.addPreparedComponent(batch)
            XCTAssertEqual(instanceA.preparedComponents, [batch])
        }

        let instanceB = try makeStore()
        XCTAssertEqual(
            instanceB.preparedComponents, [batch],
            "a prepared component written by one store instance must still be there when the same on-disk store is reopened"
        )
    }

    func testEveryPreparedComponentSurvivesARestartNotJustTheFirst() throws {
        let first = component("卤鸡腿", portions: 5, offset: 0)
        let second = component("腌鸡胸", portions: 3, offset: 10)
        let third = component("番茄牛腩", portions: 2, offset: 20)

        try instanceScope {
            let instanceA = try makeStore()
            [first, second, third].forEach(instanceA.addPreparedComponent)
            XCTAssertEqual(instanceA.preparedComponents.count, 3)
        }

        let instanceB = try makeStore()
        XCTAssertEqual(Set(instanceB.preparedComponents), Set([first, second, third]))
    }

    // MARK: - Edit

    func testAnEditSurvivesARestart() throws {
        let batch = component("卤鸡腿")
        var edited = batch
        edited.name = "卤鸡翅"
        edited.portionsRemaining = 2

        try instanceScope {
            let instanceA = try makeStore()
            instanceA.addPreparedComponent(batch)
            instanceA.updatePreparedComponent(edited)
        }

        let instanceB = try makeStore()
        XCTAssertEqual(instanceB.preparedComponents, [edited])
    }

    /// Eating a portion is the most common edit there is, so it gets its own
    /// restart rather than riding on the generic update path.
    func testConsumingOnePortionSurvivesARestart() throws {
        let batch = component("卤鸡腿", portions: 3)

        try instanceScope {
            let instanceA = try makeStore()
            instanceA.addPreparedComponent(batch)
            instanceA.consumePreparedPortion(id: batch.id)
        }

        let instanceB = try makeStore()
        XCTAssertEqual(instanceB.preparedComponents.first?.portionsRemaining, 2)
    }

    // MARK: - Delete

    func testADeletedPreparedComponentStaysDeletedAfterARestart() throws {
        let kept = component("腌鸡胸", offset: 10)
        let removed = component("卤鸡腿")

        try instanceScope {
            let instanceA = try makeStore()
            instanceA.addPreparedComponent(kept)
            instanceA.addPreparedComponent(removed)
            instanceA.removePreparedComponent(id: removed.id)
        }

        let instanceB = try makeStore()
        XCTAssertEqual(instanceB.preparedComponents, [kept])
    }

    /// The last portion removes the batch rather than leaving a zero-portion
    /// row — that removal must be durable too.
    func testEatingTheLastPortionRemovesTheBatchDurably() throws {
        let batch = component("卤鸡腿", portions: 1)

        try instanceScope {
            let instanceA = try makeStore()
            instanceA.addPreparedComponent(batch)
            instanceA.consumePreparedPortion(id: batch.id)
        }

        let instanceB = try makeStore()
        XCTAssertTrue(instanceB.preparedComponents.isEmpty)
    }

    // MARK: - Clear / backup / restore

    func testClearAllLocalDataRemovesPreparedComponentsDurably() throws {
        let batch = component("卤鸡腿")

        try instanceScope {
            let instanceA = try makeStore()
            instanceA.addPreparedComponent(batch)
            instanceA.clearAllLocalData()
            XCTAssertTrue(instanceA.preparedComponents.isEmpty)
        }

        let instanceB = try makeStore()
        XCTAssertTrue(
            instanceB.preparedComponents.isEmpty,
            "clearing local data must delete prepared components from the durable store, not just from memory"
        )
    }

    func testARestoredBackupWritesPreparedComponentsToTheDurableStore() throws {
        let batch = component("卤鸡腿")

        let backup: Data = try instanceScope {
            let source = try makeStore()
            source.addPreparedComponent(batch)
            return try source.exportBackupData()
        }

        try instanceScope {
            let target = try makeStore()
            target.clearAllLocalData()
            try target.restoreBackupData(backup)
            XCTAssertEqual(target.preparedComponents, [batch])
        }

        let afterRestart = try makeStore()
        XCTAssertEqual(
            afterRestart.preparedComponents, [batch],
            "a restore must land in the durable store, not only in the in-memory published array"
        )
    }
}
