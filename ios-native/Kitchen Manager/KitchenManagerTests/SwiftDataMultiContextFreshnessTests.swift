import SwiftData
import XCTest
@testable import KitchenManager

/// R1 / T10a-d — the one fact the R1 design must not assume.
///
/// `SwiftDataInventoryPersistence` (UI side, `@MainActor`) and
/// `SwiftDataSyncPersistence` (`@ModelActor`) share one `ModelContainer`
/// (`KitchenPersistenceFactory.makeBundle`) but hold two different
/// `ModelContext`s. Whether the UI context observes a row the sync context
/// just committed — after the UI context has already *materialised* that row
/// — decides whether reconciliation can trust `loadInventory()` at all.
///
/// These tests deliberately materialise rows through the UI persistence
/// first (every public method there fetches, which registers the managed
/// objects in that context), then commit a change through the sync context,
/// then re-read through the UI persistence. A failure here is not a bug in
/// the app — it is the SDK behaviour this design has to be built around.
@MainActor
final class SwiftDataMultiContextFreshnessTests: XCTestCase {
    private let scope = SyncScope(type: .household, id: UUID())

    // MARK: - T10a: remote update visible to a subsequent UI load

    func testT10aRemoteUpdateIsVisibleToSubsequentUILoad() async throws {
        let (container, ui, sync) = try makeSharedStores()
        let item = InventoryItem(name: "番茄", quantity: 1, unit: "个", expiryDate: nil)

        // Materialise the row in the UI context.
        try ui.replaceInventory(with: [item])
        XCTAssertEqual(try ui.loadInventory().first?.quantity, 1)

        var remote = item
        remote.quantity = 5
        remote.stapleNote = "remote"
        try await sync.applyRemoteInventory(
            item: remote,
            removeInventory: false,
            metadata: metadata(id: item.id, version: "2")
        )

        let reloaded = try ui.loadInventory()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.quantity, 5, "T10a: UI context must observe the sync context's committed update")
        XCTAssertEqual(reloaded.first?.stapleNote, "remote")
        withExtendedLifetime(container) {}
    }

    // MARK: - T10b: remote insert visible to a subsequent UI operation

    func testT10bRemoteInsertIsVisibleToSubsequentUIOperation() async throws {
        let (container, ui, sync) = try makeSharedStores()
        let seeded = InventoryItem(name: "番茄", quantity: 1, unit: "个", expiryDate: nil)
        try ui.replaceInventory(with: [seeded])

        let inserted = InventoryItem(name: "远端新增", quantity: 3, unit: "袋", expiryDate: nil)
        try await sync.applyRemoteInventory(
            item: inserted,
            removeInventory: false,
            metadata: metadata(id: inserted.id, version: "2")
        )

        let reloaded = try ui.loadInventory()
        XCTAssertEqual(
            Set(reloaded.map(\.id)), Set([seeded.id, inserted.id]),
            "T10b: a row inserted by the sync context must be visible to the UI context"
        )
        withExtendedLifetime(container) {}
    }

    // MARK: - T10c: remote delete visible to a subsequent UI operation

    func testT10cRemoteDeleteIsVisibleToSubsequentUIOperation() async throws {
        let (container, ui, sync) = try makeSharedStores()
        let kept = InventoryItem(name: "番茄", quantity: 1, unit: "个", expiryDate: nil)
        let doomed = InventoryItem(name: "会被远端删除", quantity: 2, unit: "个", expiryDate: nil)
        try ui.replaceInventory(with: [kept, doomed])
        XCTAssertEqual(try ui.loadInventory().count, 2)

        try await sync.applyRemoteInventory(
            item: nil,
            removeInventory: true,
            metadata: metadata(id: doomed.id, version: "2", deletedAt: Date())
        )

        let reloaded = try ui.loadInventory()
        XCTAssertEqual(
            reloaded.map(\.id), [kept.id],
            "T10c: the UI context must not keep serving a row the sync context deleted"
        )
        withExtendedLifetime(container) {}
    }

    // MARK: - T10d: a subsequent UI write is based on the latest durable object

    func testT10dSubsequentUIUpsertIsBasedOnLatestDurableObject() async throws {
        let (container, ui, sync) = try makeSharedStores()
        let rowA = InventoryItem(name: "A", quantity: 1, unit: "个", expiryDate: nil)
        let rowB = InventoryItem(name: "B", quantity: 1, unit: "个", expiryDate: nil)
        try ui.replaceInventory(with: [rowA, rowB])

        var remoteA = rowA
        remoteA.quantity = 9
        try await sync.applyRemoteInventory(
            item: remoteA,
            removeInventory: false,
            metadata: metadata(id: rowA.id, version: "2")
        )

        // A row-scoped local write to a *different* row must leave A's
        // remote value alone, which is only true if the UI context's write
        // is layered on the latest durable state rather than a cached one.
        var editedB = rowB
        editedB.quantity = 7
        try ui.upsert(editedB)

        let afterUpsert = try ui.loadInventory()
        XCTAssertEqual(afterUpsert.first(where: { $0.id == rowA.id })?.quantity, 9, "T10d/upsert: row A must keep its remote value")
        XCTAssertEqual(afterUpsert.first(where: { $0.id == rowB.id })?.quantity, 7)

        // Same question for a row-scoped delete.
        try ui.delete(id: rowB.id)
        let afterDelete = try ui.loadInventory()
        XCTAssertEqual(afterDelete.map(\.id), [rowA.id])
        XCTAssertEqual(afterDelete.first?.quantity, 9, "T10d/delete: row A must still hold its remote value")
        withExtendedLifetime(container) {}
    }

    /// The negative control the whole R1 fix exists for: a *whole-table*
    /// write from a stale in-memory snapshot destroys remote state even when
    /// the contexts are perfectly fresh. Documents that freshness alone is
    /// not sufficient — reconciliation is still required.
    func testT10dWholeTableReplaceFromAStaleSnapshotStillDestroysRemoteState() async throws {
        let (container, ui, sync) = try makeSharedStores()
        let rowA = InventoryItem(name: "A", quantity: 1, unit: "个", expiryDate: nil)
        let rowB = InventoryItem(name: "B", quantity: 1, unit: "个", expiryDate: nil)
        try ui.replaceInventory(with: [rowA, rowB])
        let staleSnapshot = try ui.loadInventory()

        var remoteA = rowA
        remoteA.quantity = 9
        try await sync.applyRemoteInventory(
            item: remoteA,
            removeInventory: false,
            metadata: metadata(id: rowA.id, version: "2")
        )

        try ui.replaceInventory(with: staleSnapshot)
        XCTAssertEqual(
            try ui.loadInventory().first(where: { $0.id == rowA.id })?.quantity, 1,
            "control: a whole-table replace from a stale snapshot overwrites remote state regardless of context freshness"
        )
        withExtendedLifetime(container) {}
    }

    // MARK: - Fixtures

    private func makeSharedStores() throws -> (ModelContainer, SwiftDataInventoryPersistence, SwiftDataSyncPersistence) {
        let container = try ModelContainer(
            for: InventoryRecord.self, ShoppingItemRecord.self, TodayPlanRecord.self,
            ConsumptionRecordEntity.self, WeeklyPlanRecord.self,
            SyncMetadataRecord.self, PendingMutationRecord.self, SyncCursorRecord.self,
            GuestMergeSessionRecord.self, InventorySyncEnrollmentRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return (
            container,
            SwiftDataInventoryPersistence(container: container),
            SwiftDataSyncPersistence(modelContainer: container)
        )
    }

    private func metadata(id: UUID, version: String, deletedAt: Date? = nil) -> SyncMetadata {
        SyncMetadata(
            entityType: .inventoryItem,
            entityId: id,
            scope: scope,
            remoteVersion: try! SyncCursorValue(version),
            state: .synced,
            lastSyncedAt: Date(),
            lastErrorCode: nil,
            lastErrorAt: nil,
            deletedAt: deletedAt,
            updatedAt: Date()
        )
    }
}
