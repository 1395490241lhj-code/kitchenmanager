import Foundation

nonisolated enum InventoryRemoteApplyOutcome: Equatable, Sendable {
    case applied
    case duplicate
    case conflict
}

/// Phase 2A proof-of-concept boundary for inventory only. Nothing calls these
/// local staging methods from the production inventory UI yet, so enabling the
/// feature flag alone cannot upload existing guest data.
nonisolated struct InventorySyncAdapter: Sendable {
    private let persistence: any SyncPersistenceProtocol

    init(persistence: any SyncPersistenceProtocol) {
        self.persistence = persistence
    }

    func stageUpsert(
        item: InventoryItem,
        scope: SyncScope,
        now: Date = Date(),
        mutationId: UUID = UUID()
    ) async throws -> UUID {
        let existing = try await persistence.metadata(entityType: .inventoryItem, entityId: item.id)
        let state: EntitySyncState = existing?.remoteVersion == nil ? .pendingCreate : .pendingUpdate
        let metadata = SyncMetadata(
            entityType: .inventoryItem,
            entityId: item.id,
            scope: scope,
            remoteVersion: existing?.remoteVersion,
            state: state,
            lastSyncedAt: existing?.lastSyncedAt,
            lastErrorCode: nil,
            lastErrorAt: nil,
            deletedAt: nil,
            updatedAt: now
        )
        let mutation = try pendingMutation(
            id: mutationId,
            item: item,
            scope: scope,
            operation: .upsert,
            baseVersion: existing?.remoteVersion ?? .zero,
            now: now
        )
        try await persistence.commitInventoryAndSync(
            item: item,
            removeInventory: false,
            metadata: metadata,
            mutation: mutation
        )
        return mutationId
    }

    #if DEBUG
    /// Development-smoke-only path for exercising the server's optimistic
    /// conflict response. It is not compiled into Release and has no ordinary
    /// inventory UI caller.
    func stageSmokeUpsert(
        item: InventoryItem,
        scope: SyncScope,
        staleBaseVersion: SyncCursorValue,
        now: Date = Date(),
        mutationId: UUID = UUID()
    ) async throws -> UUID {
        let existing = try await persistence.metadata(entityType: .inventoryItem, entityId: item.id)
        let metadata = SyncMetadata(
            entityType: .inventoryItem,
            entityId: item.id,
            scope: scope,
            remoteVersion: existing?.remoteVersion,
            state: .pendingUpdate,
            lastSyncedAt: existing?.lastSyncedAt,
            lastErrorCode: nil,
            lastErrorAt: nil,
            deletedAt: nil,
            updatedAt: now
        )
        let mutation = try pendingMutation(
            id: mutationId,
            item: item,
            scope: scope,
            operation: .upsert,
            baseVersion: staleBaseVersion,
            now: now
        )
        try await persistence.commitInventoryAndSync(
            item: item,
            removeInventory: false,
            metadata: metadata,
            mutation: mutation
        )
        return mutationId
    }
    #endif

    /// **Destructive — removes the local `InventoryRecord` as well as staging
    /// the remote delete**, both in one transaction.
    ///
    /// This is the smoke/marker-cleanup helper: it exists for a row this
    /// process created purely as a probe and now wants gone from both sides.
    /// Production inventory CRUD and Guest-merge rollback must never call it.
    ///
    /// - Ordinary user deletion does not go through here at all: `KitchenStore`
    ///   removes the durable row itself and `GuestMergeController`'s CRUD hook
    ///   stages the remote delete through
    ///   `SyncPersistenceProtocol.stageInventoryMutation`.
    /// - Rollback must use `stageRemoteDeletePreservingLocal` — an entity id in
    ///   `GuestMergeSession.createdEntityIds` names a *remote* entity this
    ///   session created, and (outside the same-id `keepBoth` fork) the very
    ///   same UUID is the id of a local row the user owned long before the
    ///   merge. Deleting it locally is user data loss, which
    ///   `INVENTORY_MERGE_CONTRACT.md` has always forbidden.
    ///
    /// The naming, not a `preserveLocal:` flag, is what keeps those two
    /// intentions apart: a boolean would leave ownership ambiguous at every
    /// call site and re-open exactly this defect the next time someone
    /// defaults it.
    func stageDeleteRemovingLocalRecord(
        entityId: UUID,
        scope: SyncScope,
        now: Date = Date(),
        mutationId: UUID = UUID()
    ) async throws -> UUID {
        let existing = try await persistence.metadata(entityType: .inventoryItem, entityId: entityId)
        let metadata = SyncMetadata(
            entityType: .inventoryItem,
            entityId: entityId,
            scope: scope,
            remoteVersion: existing?.remoteVersion,
            state: .pendingDelete,
            lastSyncedAt: existing?.lastSyncedAt,
            lastErrorCode: nil,
            lastErrorAt: nil,
            deletedAt: now,
            updatedAt: now
        )
        let mutation = PendingMutation(
            mutationId: mutationId,
            entityType: .inventoryItem,
            entityId: entityId,
            scope: scope,
            operation: .delete,
            baseVersion: existing?.remoteVersion ?? .zero,
            payloadData: Data("{}".utf8),
            clientUpdatedAt: now,
            createdAt: now,
            attemptCount: 0,
            lastAttemptAt: nil,
            lastErrorCode: nil,
            status: .pending
        )
        try await persistence.commitInventoryAndSync(
            item: nil,
            removeInventory: true,
            metadata: metadata,
            mutation: mutation
        )
        return mutationId
    }

    /// Stages a **remote-only** delete: the server is told the entity is gone,
    /// and the local `InventoryRecord` is left exactly as it is.
    ///
    /// R3: this is what Guest-merge rollback needs. `createdEntityIds` records
    /// the entities this session created *remotely*; for a plain `.create`
    /// candidate that id is also the primary key of a local row the user
    /// already owned, so undoing the merge must never touch it. Rollback's
    /// invariant is therefore: it may withdraw what the merge published to the
    /// household, but it never removes a local durable inventory row from the
    /// store — not the user's original, and not a `keepBoth` fork either.
    /// Restoring the exact pre-merge local state is a separate feature that
    /// would need its own provenance model and product semantics.
    ///
    /// Deliberately reuses `stageInventoryMutation`, the same primitive
    /// ordinary CRUD deletions already use, rather than adding a second
    /// staging implementation: it writes only `SyncMetadata` and a
    /// `PendingMutation`, never `InventoryRecord`, and its coalescing rules
    /// make a repeated delete for the same entity reuse the already-queued
    /// mutation id instead of queueing a second one.
    func stageRemoteDeletePreservingLocal(
        entityId: UUID,
        scope: SyncScope,
        now: Date = Date()
    ) async throws -> InventoryMutationStagingOutcome {
        try await persistence.stageInventoryMutation(
            entityId: entityId,
            scope: scope,
            operation: .delete,
            payloadData: Data("{}".utf8),
            now: now
        )
    }

    /// Pure, read-only decode of a pulled change into a
    /// `RemoteInventorySnapshotItem` — never writes local persistence. Used by
    /// the Guest merge pre-merge read (`GuestMergeController`) to learn what
    /// already exists remotely before generating a plan, without touching
    /// local `SyncMetadata`/`InventoryRecord` at all. Returns `nil` for a
    /// tombstone (delete), since a deleted remote record is not a match
    /// candidate.
    @MainActor
    func decodeRemoteInventorySnapshot(_ change: SyncChangeEnvelope) throws -> RemoteInventorySnapshotItem? {
        guard change.entityType == .inventoryItem else { throw SyncError.unsupportedEntity }
        guard change.operation != .delete else { return nil }
        let item = try decodeInventory(change)
        return RemoteInventorySnapshotItem(
            id: item.id,
            name: item.name,
            unit: item.unit,
            quantity: item.quantity,
            expiryDate: item.expiryDate,
            // `decodeInventory` has already resolved the wire's two
            // classification axes through `classification(_:)`; carrying the
            // resolved `kind` (rather than re-deriving anything here) keeps
            // the precedence rule implemented in exactly one place.
            kind: item.kind,
            stapleCategory: item.stapleCategory,
            lowStockThreshold: item.lowStockThreshold,
            defaultRestockQuantity: item.defaultRestockQuantity,
            autoSuggestRestock: item.autoSuggestRestock,
            stapleTrackingMode: item.stapleTrackingMode,
            stapleAvailabilityStatus: item.stapleAvailabilityStatus,
            remoteVersion: change.version
        )
    }

    func applyRemote(_ change: SyncChangeEnvelope, scope: SyncScope) async throws -> InventoryRemoteApplyOutcome {
        guard change.entityType == .inventoryItem else { throw SyncError.unsupportedEntity }
        let existing = try await persistence.metadata(entityType: .inventoryItem, entityId: change.entityId)
        if let existing,
           [.pendingCreate, .pendingUpdate, .pendingDelete, .conflicted].contains(existing.state) {
            let conflicted = SyncMetadata(
                entityType: .inventoryItem,
                entityId: change.entityId,
                scope: scope,
                remoteVersion: max(existing.remoteVersion ?? .zero, change.version),
                state: .conflicted,
                lastSyncedAt: existing.lastSyncedAt,
                lastErrorCode: "remote_change_while_pending",
                lastErrorAt: change.changedAt,
                deletedAt: existing.deletedAt,
                updatedAt: change.changedAt
            )
            try await persistence.saveMetadata(conflicted)
            return .conflict
        }
        if let remoteVersion = existing?.remoteVersion, remoteVersion >= change.version {
            return .duplicate
        }

        let isDelete = change.operation == .delete
        let item = isDelete ? nil : try await decodeInventory(change)
        let metadata = SyncMetadata(
            entityType: .inventoryItem,
            entityId: change.entityId,
            scope: scope,
            remoteVersion: change.version,
            state: .synced,
            lastSyncedAt: change.changedAt,
            lastErrorCode: nil,
            lastErrorAt: nil,
            deletedAt: isDelete ? date(change.data["deletedAt"]) ?? change.changedAt : nil,
            updatedAt: change.changedAt
        )
        try await persistence.applyRemoteInventory(
            item: item,
            removeInventory: isDelete,
            metadata: metadata
        )
        return .applied
    }

    private func pendingMutation(
        id: UUID,
        item: InventoryItem,
        scope: SyncScope,
        operation: SyncOperation,
        baseVersion: SyncCursorValue,
        now: Date
    ) throws -> PendingMutation {
        let data = payload(for: item)
        return PendingMutation(
            mutationId: id,
            entityType: .inventoryItem,
            entityId: item.id,
            scope: scope,
            operation: operation,
            baseVersion: baseVersion,
            payloadData: try JSONEncoder().encode(data),
            clientUpdatedAt: now,
            createdAt: now,
            attemptCount: 0,
            lastAttemptAt: nil,
            lastErrorCode: nil,
            status: .pending
        )
    }

    /// Phase 2B-4: reused by `GuestMergeController`'s CRUD-originated staging
    /// so both paths encode the exact same fields the same way — never a
    /// second, drifting payload-building implementation.
    func encodedPayload(for item: InventoryItem) throws -> Data {
        try JSONEncoder().encode(payload(for: item))
    }

    private func payload(for item: InventoryItem) -> [String: SyncJSONValue] {
        var value: [String: SyncJSONValue] = [
            "name": .string(item.name),
            "normalizedName": .string(item.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
            "quantity": .number(item.quantity),
            "unit": .string(item.unit),
            "isStaple": .bool(item.isStaple),
            // The preparation axis (`SYNC_API_CONTRACT.md` §4.2), orthogonal
            // to `isStaple` and written from the *same* `item` snapshot, so
            // the pair can never drift: `isStaple` is itself a projection of
            // `item.kind`, and this line reads the same property.
            //
            // Three things this must never be:
            // - `.null` — the column is NOT NULL and an explicit null is
            //   rejected; `"none"` is the only "no preparation" value.
            // - `item.kind.rawValue` — that sends the out-of-vocabulary
            //   `"staple"` for a staple row, which the Express enum and the
            //   database CHECK both reject.
            // - written under the key `"kind"` — that is a *different*,
            //   PWA-owned column (`raw`/`dry`/`staple` semantics) which this
            //   client neither reads nor writes.
            "preparationKind": .string(item.kind == .readyToCook ? "readyToCook" : "none"),
            "autoSuggestRestock": .bool(item.autoSuggestRestock),
            "stapleTrackingMode": .string(item.stapleTrackingMode.rawValue),
            "stapleAvailabilityStatus": .string(item.stapleAvailabilityStatus.rawValue),
            "sortOrder": .number(0)
        ]
        value["expiryDate"] = item.expiryDate.map { .string(dayString($0)) } ?? .null
        value["lowStockThreshold"] = item.lowStockThreshold.map(SyncJSONValue.number) ?? .null
        value["defaultRestockQuantity"] = item.defaultRestockQuantity.map(SyncJSONValue.number) ?? .null
        value["stapleNote"] = item.stapleNote.map(SyncJSONValue.string) ?? .null
        value["stapleCategory"] = item.stapleCategory.map(SyncJSONValue.string) ?? .null
        return value
    }

    @MainActor
    private func decodeInventory(_ change: SyncChangeEnvelope) throws -> InventoryItem {
        guard let name = string(change.data["name"]) else { throw SyncError.decoding }
        return InventoryItem(
            id: change.entityId,
            name: name,
            quantity: number(change.data["quantity"]) ?? 0,
            unit: string(change.data["unit"]) ?? "",
            expiryDate: date(change.data["expiryDate"]),
            kind: classification(change.data),
            createdAt: date(change.data["createdAt"]),
            updatedAt: date(change.data["updatedAt"]) ?? change.changedAt,
            lowStockThreshold: number(change.data["lowStockThreshold"]),
            defaultRestockQuantity: number(change.data["defaultRestockQuantity"]),
            autoSuggestRestock: bool(change.data["autoSuggestRestock"]) ?? false,
            stapleNote: string(change.data["stapleNote"]),
            stapleCategory: string(change.data["stapleCategory"]),
            stapleTrackingMode: StapleTrackingMode(rawValue: string(change.data["stapleTrackingMode"]) ?? "") ?? .quantity,
            stapleAvailabilityStatus: StapleAvailabilityStatus(rawValue: string(change.data["stapleAvailabilityStatus"]) ?? "")
                ?? ((number(change.data["quantity"]) ?? 0) <= 0 ? .missing : .available)
        )
    }

    /// Resolves the wire's two orthogonal classification axes — `isStaple`
    /// and `preparationKind` — into the one local `InventoryItemKind`. This
    /// is the single place that precedence is implemented; every other read
    /// path takes the already-resolved `kind`.
    ///
    /// Precedence is fixed by `docs/contracts/SYNC_API_CONTRACT.md` §4.2 as
    /// `staple > readyToCook > ordinary`. It has to be an explicit order
    /// rather than an either/or, because `isStaple = true` together with
    /// `preparationKind = "readyToCook"` is a *legal* stored combination:
    /// the database deliberately carries no cross-axis CHECK so that a
    /// sparse PATCH can move one axis at a time without the other axis's
    /// unseen stored value turning a valid request into an undiagnosable
    /// rejection.
    ///
    /// Everything that is not exactly `"readyToCook"` resolves to
    /// `.ordinary`, and nothing here throws. A missing key (a change record
    /// written before the P2 preparation column existed), `"none"`, an
    /// out-of-vocabulary future value, a wrong JSON type and an explicit
    /// null all take the same fallback. Throwing would be far more damaging
    /// than falling back: `SyncCoordinator.pull` aborts the whole page and
    /// leaves the cursor unadvanced when `applyRemote` throws, so a single
    /// unparseable record would poison the entire change feed permanently
    /// with no way to self-heal. Falling back also matches how every other
    /// field in `decodeInventory` already behaves — `name` is the only field
    /// whose absence is fatal.
    ///
    /// The wire vocabulary is matched literally rather than handed to the
    /// local enum's own raw-value initialiser: the enum's vocabulary
    /// (`ordinary`/`staple`/`readyToCook`) is not the preparation column's
    /// vocabulary (`none`/`readyToCook`), so reusing it would silently accept
    /// a `"staple"` preparation value that no server would ever send.
    ///
    /// The accepted cost of that fallback, stated precisely: every inventory
    /// upsert this client sends is a *full snapshot* (`payload(for:)` always
    /// writes the whole known field set, and the staging queue replaces a
    /// coalesced payload wholesale rather than merging field by field). So
    /// once an unknown future preparation value has been read as `.ordinary`,
    /// **any** subsequent local upsert for that row normalises it to `"none"`
    /// server-side — an unrelated quantity, expiry or note edit just as much
    /// as a deliberate classification change. That is a real forward-
    /// compatibility loss, traded knowingly against a decode failure wedging
    /// the whole change feed. An out-of-vocabulary value is not reachable
    /// under the current protocol at all — the P2 Express enum and the
    /// database CHECK both reject one — so no hosted row can be in that state
    /// today.
    ///
    /// The same full-snapshot mechanism collapses the *legal*
    /// `isStaple=true` + `preparationKind="readyToCook"` combination too, and
    /// that needs no unknown value to happen. Such a row decodes to `.staple`
    /// by precedence, and this client's next upsert of it — again, an
    /// unrelated quantity edit is enough — writes back
    /// `isStaple=true, preparationKind="none"`, erasing the preparation half
    /// it never represented locally. The collapse is what the contract's
    /// normalisation map asks a single-axis client to do, not a bug; it is
    /// recorded here because a second sync client writing that combination
    /// would see this client quietly flatten it.
    private func classification(_ data: [String: SyncJSONValue]) -> InventoryItemKind {
        if bool(data["isStaple"]) == true { return .staple }
        return string(data["preparationKind"]) == "readyToCook" ? .readyToCook : .ordinary
    }

    private func string(_ value: SyncJSONValue?) -> String? {
        guard case .string(let result) = value else { return nil }
        return result
    }

    private func number(_ value: SyncJSONValue?) -> Double? {
        guard case .number(let result) = value else { return nil }
        return result
    }

    private func bool(_ value: SyncJSONValue?) -> Bool? {
        guard case .bool(let result) = value else { return nil }
        return result
    }

    private func date(_ value: SyncJSONValue?) -> Date? {
        guard let raw = string(value) else { return nil }
        if let day = parseDay(raw) { return day }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = fractional.date(from: raw) { return result }
        return ISO8601DateFormatter().date(from: raw)
    }

    private func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private func dayString(_ date: Date) -> String { dayFormatter().string(from: date) }

    private func parseDay(_ value: String) -> Date? {
        guard value.count == 10 else { return nil }
        return dayFormatter().date(from: value)
    }
}
