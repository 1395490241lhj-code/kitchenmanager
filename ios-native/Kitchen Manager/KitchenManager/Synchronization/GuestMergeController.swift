import Foundation
import Combine

/// Bridges `AuthStore`'s live session to `SyncTransport` — a SwiftUI `View`
/// never sees a token value at all; it only ever passes the already-injected
/// `AuthStore` reference it already holds for sign-out. This re-queries
/// `AuthStore` fresh on every single call rather than freezing a token value
/// at construction time, so a sign-out that happens while a multi-request
/// upload/pull is still in flight immediately and permanently starves any
/// further request in that same run (the very next `accessToken()` call
/// returns `nil`, and `ExpressSyncTransport` then throws
/// `.notAuthenticated` instead of sending anything). Holds only a `weak`
/// reference, so it cannot itself extend `AuthStore`'s lifetime or be
/// mistaken for an owner of session state.
@MainActor
private final class AuthStoreCredentialProvider: SyncAccessTokenProviding {
    private weak var authStore: AuthStore?

    init(authStore: AuthStore) {
        self.authStore = authStore
    }

    func accessToken() async -> String? {
        await authStore?.currentAccessToken()
    }
}

/// Orchestrates Guest Inventory detection → preview → explicit confirmation →
/// controlled upload → limited rollback, entirely through the existing
/// `SyncCoordinator` / `InventorySyncAdapter` / `ExpressSyncTransport` — no
/// second upload client. Gated end-to-end by `INVENTORY_SYNC_ENABLED`
/// (`InventoryMergeConfiguration`), which is independent of and does not
/// modify the global `SYNC_ENABLED` flag.
@MainActor
final class GuestMergeController: ObservableObject {
    @Published private(set) var summary: GuestDatasetSummary?
    @Published private(set) var session: GuestMergeSession?
    @Published private(set) var isBusy = false
    @Published private(set) var lastErrorMessage: String?

    private let persistence: any SyncPersistenceProtocol
    private let transportFactory: @MainActor (any SyncAccessTokenProviding) -> any SyncTransport
    private let configuration: InventoryMergeConfiguration
    /// How long a completed session's own newly-created records may still be
    /// rolled back.
    private let rollbackWindow: TimeInterval

    init(
        persistence: any SyncPersistenceProtocol,
        configuration: InventoryMergeConfiguration = .load(),
        transportFactory: @escaping @MainActor (any SyncAccessTokenProviding) -> any SyncTransport = { provider in
            ExpressSyncTransport(tokenProvider: provider)
        },
        rollbackWindow: TimeInterval = 24 * 60 * 60
    ) {
        self.persistence = persistence
        self.configuration = configuration
        self.transportFactory = transportFactory
        self.rollbackWindow = rollbackWindow
    }

    var isFeatureEnabled: Bool { configuration.isEnabled }
    var plan: InventoryMergePlan? { session?.plan }

    // MARK: Detection (read-only, in-memory, no network)

    func detect(kitchenStore: KitchenStore, recipeStore: RecipeStore) {
        summary = GuestDatasetDetector.summary(kitchenStore: kitchenStore, recipeStore: recipeStore)
    }

    // MARK: Preview (local-only; never writes network or creates a mutation)

    /// Resumes an existing active session for this (user, household), or
    /// starts a fresh preview when none exists. Regenerates the plan when the
    /// current local inventory no longer matches the session's stored plan
    /// hash (i.e. the user edited inventory since the last preview).
    ///
    /// `remoteTransport`, when supplied, is used for exactly one read-only
    /// pre-merge fetch (`SyncTransport.fetchChanges`, a GET) so matching can
    /// see what already exists remotely — this never writes a mutation,
    /// never advances the persisted pull cursor, and is never called by the
    /// ordinary in-app preview flow (which always passes `nil`, preserving
    /// its existing zero-network-call behavior exactly). Omitted, it defaults
    /// to `nil` and `knownRemoteItems` stays empty, matching prior behavior.
    func preparePreview(
        userId: UUID,
        householdId: UUID,
        kitchenStore: KitchenStore,
        remoteTransport: (any SyncTransport)? = nil
    ) async {
        guard isFeatureEnabled else { return }
        isBusy = true
        lastErrorMessage = nil
        defer { isBusy = false }
        do {
            let localItems = kitchenStore.inventory
            let knownRemoteItems = try await fetchKnownRemoteItems(householdId: householdId, transport: remoteTransport)
            if var existing = try await persistence.activeGuestMergeSession(
                userId: userId, householdId: householdId, entityType: .inventoryItem
            ) {
                if let existingPlan = existing.plan,
                   !InventoryMergePlanner.isPlanStillValid(existingPlan, against: localItems),
                   existing.status == .detected || existing.status == .previewReady || existing.status == .awaitingConfirmation {
                    // Local data changed since this plan was generated and no
                    // upload has started yet — regenerate rather than upload
                    // a stale plan.
                    existing = regeneratedPreview(session: existing, localItems: localItems, knownRemoteItems: knownRemoteItems)
                    try await persistence.saveGuestMergeSession(existing)
                }
                session = existing
                return
            }

            guard !localItems.isEmpty else { return }
            let newSession = freshPreview(userId: userId, householdId: householdId, localItems: localItems, knownRemoteItems: knownRemoteItems)
            try await persistence.saveGuestMergeSession(newSession)
            session = newSession
        } catch {
            lastErrorMessage = "无法生成合并预览，请稍后重试。"
        }
    }

    /// Never writes anything — a GET-only pull used purely to build in-memory
    /// match candidates. Deliberately does not call `persistence.advanceCursor`,
    /// so it cannot interfere with `SyncCoordinator`'s own persisted pull
    /// cursor bookkeeping used later during the real upload/pull.
    private func fetchKnownRemoteItems(
        householdId: UUID,
        transport: (any SyncTransport)?
    ) async throws -> [RemoteInventorySnapshotItem] {
        guard let transport else { return [] }
        let scope = SyncScope(type: .household, id: householdId)
        let adapter = InventorySyncAdapter(persistence: persistence)
        var cursor = SyncCursorValue.zero
        var results: [UUID: RemoteInventorySnapshotItem] = [:]
        var hasMore = true
        var pagesFetched = 0
        let maxPages = 50
        while hasMore && pagesFetched < maxPages {
            let response = try await transport.fetchChanges(scope: scope, after: cursor, limit: 100)
            guard response.scope == scope else { break }
            for change in response.changes where change.entityType == .inventoryItem {
                if change.operation == .delete {
                    results.removeValue(forKey: change.entityId)
                } else if let snapshot = try await adapter.decodeRemoteInventorySnapshot(change) {
                    results[change.entityId] = snapshot
                }
            }
            cursor = response.cursor
            hasMore = response.hasMore
            pagesFetched += 1
            if hasMore, response.changes.isEmpty { break }
        }
        return Array(results.values)
    }

    private func freshPreview(
        userId: UUID, householdId: UUID, localItems: [InventoryItem], knownRemoteItems: [RemoteInventorySnapshotItem]
    ) -> GuestMergeSession {
        let sessionId = UUID()
        let now = Date()
        let plan = InventoryMergePlanner.makePlan(
            sessionId: sessionId, householdId: householdId, localItems: localItems,
            knownRemoteItems: knownRemoteItems, generatedAt: now
        )
        return GuestMergeSession(
            id: sessionId,
            userId: userId,
            householdId: householdId,
            entityType: .inventoryItem,
            status: .previewReady,
            createdAt: now,
            updatedAt: now,
            confirmedAt: nil,
            completedAt: nil,
            cancelledAt: nil,
            rollbackAvailableUntil: nil,
            localSnapshot: snapshot(of: localItems),
            plan: plan,
            plannedItemCount: plan.creates.count + plan.updates.count,
            uploadedItemCount: 0,
            conflictCount: plan.conflicts.count,
            failedCount: 0,
            lastErrorCode: nil,
            createdEntityIds: [],
            mergeVersion: 1
        )
    }

    private func regeneratedPreview(
        session existing: GuestMergeSession, localItems: [InventoryItem], knownRemoteItems: [RemoteInventorySnapshotItem]
    ) -> GuestMergeSession {
        var updated = existing
        let plan = InventoryMergePlanner.makePlan(
            sessionId: existing.id, householdId: existing.householdId, localItems: localItems,
            knownRemoteItems: knownRemoteItems, generatedAt: Date()
        )
        updated.plan = plan
        updated.localSnapshot = snapshot(of: localItems)
        updated.plannedItemCount = plan.creates.count + plan.updates.count
        updated.conflictCount = plan.conflicts.count
        updated.status = .previewReady
        updated.updatedAt = Date()
        return updated
    }

    private func snapshot(of items: [InventoryItem]) -> [GuestInventorySnapshotItem] {
        items.prefix(GuestMergeSession.maxSnapshotItems).map {
            GuestInventorySnapshotItem(id: $0.id, name: $0.name, unit: $0.unit, quantity: $0.quantity, expiryDate: $0.expiryDate)
        }
    }

    // MARK: Conflict resolution (persisted; App-restart safe; no upload here)

    func resolveConflict(candidateId: UUID, choice: InventoryMergeConflictChoice) async {
        guard var current = session, var plan = current.plan else { return }
        guard let index = plan.candidates.firstIndex(where: { $0.localItemId == candidateId }) else { return }
        plan.candidates[index] = plan.candidates[index].applyingChoice(choice)
        current.plan = plan
        current.conflictCount = plan.conflicts.count
        current.updatedAt = Date()
        do {
            try await persistence.saveGuestMergeSession(current)
            session = current
        } catch {
            lastErrorMessage = "无法保存冲突处理结果，请重试。"
        }
    }

    // MARK: Cancel (before or during upload — never writes network)

    func cancel() async {
        guard var current = session, !current.status.isTerminal else { return }
        current.status = .cancelled
        current.cancelledAt = Date()
        current.updatedAt = Date()
        do {
            try await persistence.saveGuestMergeSession(current)
            session = current
        } catch {
            lastErrorMessage = "取消失败，请重试。"
        }
    }

    // MARK: Confirm + controlled upload (existing SyncCoordinator/adapter only)

    /// Explicit user confirmation. Uploads only `plan.readyToUpload`
    /// candidates (unresolved conflicts are left pending — partial commit is
    /// supported by design). Constructs its own `SyncConfiguration(isEnabled:
    /// true)` scoped to this call only, mirroring the Phase 2A-4 smoke
    /// runner's pattern; the global `SYNC_ENABLED` flag file is never read or
    /// modified by this path. Takes the live `AuthStore` reference (never a
    /// raw token) so the caller — always a View — never needs to see or hold
    /// a token value.
    func confirmMerge(authStore: AuthStore) async {
        guard isFeatureEnabled else { return }
        guard var current = session, let plan = current.plan else { return }
        guard current.status == .previewReady || current.status == .awaitingConfirmation || current.status == .conflict else { return }
        guard let userId = authStore.currentUserID else {
            lastErrorMessage = "请先登录后再确认合并。"
            return
        }

        isBusy = true
        lastErrorMessage = nil
        defer { isBusy = false }

        current.status = .preparing
        current.confirmedAt = current.confirmedAt ?? Date()
        current.updatedAt = Date()
        do { try await persistence.saveGuestMergeSession(current) } catch { }

        let scope = SyncScope(type: .household, id: current.householdId)
        let adapter = InventorySyncAdapter(persistence: persistence)
        let toUpload = plan.readyToUpload

        do {
            current.status = .uploading
            try await persistence.saveGuestMergeSession(current)

            for candidate in toUpload {
                guard let localItem = try await persistence.inventoryItem(id: candidate.localItemId) else { continue }
                // An `.update` candidate matched a remote record this device
                // never uploaded itself (learned about only via the
                // pre-merge read) — there is no local SyncMetadata for it
                // yet, so InventorySyncAdapter.stageUpsert would otherwise
                // compute baseVersion as 0 and the server would correctly
                // reject it as a stale-version conflict. Seed the known
                // remote version first, but only when this device doesn't
                // already have its own (possibly more current) local record
                // of it — never overwrite an existing local sync state.
                if candidate.action == .update, let remoteVersion = candidate.remoteVersion {
                    let existingMetadata = try await persistence.metadata(entityType: .inventoryItem, entityId: candidate.localItemId)
                    if existingMetadata == nil {
                        try await persistence.saveMetadata(SyncMetadata(
                            entityType: .inventoryItem,
                            entityId: candidate.localItemId,
                            scope: scope,
                            remoteVersion: remoteVersion,
                            state: .synced,
                            lastSyncedAt: nil,
                            lastErrorCode: nil,
                            lastErrorAt: nil,
                            deletedAt: nil,
                            updatedAt: Date()
                        ))
                    }
                }
                _ = try await adapter.stageUpsert(item: localItem, scope: scope)
            }

            let configuration = SyncConfiguration(isEnabled: true)
            let provider = AuthStoreCredentialProvider(authStore: authStore)
            let transport = transportFactory(provider)
            let coordinator = SyncCoordinator(configuration: configuration, persistence: persistence, transport: transport)
            let authentication = SyncAuthenticationContext(userID: userId, isAuthenticated: true)
            let outcome = await coordinator.runOnce(authentication: authentication, scopes: [scope])

            guard outcome == .completed else {
                current.status = .failed
                current.lastErrorCode = String(describing: outcome)
                current.updatedAt = Date()
                try await persistence.saveGuestMergeSession(current)
                session = current
                return
            }

            var uploaded = 0
            var conflicted = 0
            var failed = 0
            var newCreatedIds = current.createdEntityIds
            for index in plan.candidates.indices {
                let candidate = plan.candidates[index]
                guard toUpload.contains(where: { $0.localItemId == candidate.localItemId }) else { continue }
                guard let metadata = try await persistence.metadata(entityType: .inventoryItem, entityId: candidate.localItemId) else { continue }
                switch metadata.state {
                case .synced:
                    uploaded += 1
                    if candidate.action == .create, !newCreatedIds.contains(candidate.localItemId) {
                        newCreatedIds.append(candidate.localItemId)
                    }
                case .conflicted:
                    conflicted += 1
                case .failed:
                    failed += 1
                default:
                    break
                }
            }

            current.uploadedItemCount = uploaded
            current.conflictCount = plan.conflicts.count + conflicted
            current.failedCount = failed
            current.createdEntityIds = newCreatedIds
            current.updatedAt = Date()

            if plan.conflicts.isEmpty && conflicted == 0 && failed == 0 {
                current.status = .completed
                current.completedAt = Date()
                current.rollbackAvailableUntil = Date().addingTimeInterval(rollbackWindow)
            } else if failed > 0 {
                current.status = .failed
            } else {
                current.status = .conflict
            }
            try await persistence.saveGuestMergeSession(current)
            session = current
        } catch {
            current.status = .failed
            current.lastErrorCode = "transport"
            current.updatedAt = Date()
            try? await persistence.saveGuestMergeSession(current)
            session = current
            lastErrorMessage = "合并上传失败，可稍后重试。"
        }
    }

    // MARK: Rollback (limited — only this session's own newly-created records)

    /// Soft-deletes only the remote records this session itself created.
    /// Never touches pre-existing remote records or conflicts the user chose
    /// to keep-remote. Idempotent: safe to call again if a prior attempt
    /// partially failed. Takes the live `AuthStore` reference (never a raw
    /// token), same as `confirmMerge`.
    func rollback(authStore: AuthStore) async {
        guard var current = session else { return }
        guard current.status == .completed || current.status == .rollbackPending else { return }
        if let deadline = current.rollbackAvailableUntil, Date() > deadline {
            lastErrorMessage = "回滚窗口已过期。"
            return
        }
        guard let userId = authStore.currentUserID else {
            lastErrorMessage = "请先登录后再回滚。"
            return
        }

        isBusy = true
        lastErrorMessage = nil
        defer { isBusy = false }

        current.status = .rollbackPending
        current.updatedAt = Date()
        try? await persistence.saveGuestMergeSession(current)

        let scope = SyncScope(type: .household, id: current.householdId)
        let adapter = InventorySyncAdapter(persistence: persistence)
        do {
            for entityId in current.createdEntityIds {
                _ = try await adapter.stageDelete(entityId: entityId, scope: scope)
            }
            let configuration = SyncConfiguration(isEnabled: true)
            let provider = AuthStoreCredentialProvider(authStore: authStore)
            let transport = transportFactory(provider)
            let coordinator = SyncCoordinator(configuration: configuration, persistence: persistence, transport: transport)
            let authentication = SyncAuthenticationContext(userID: userId, isAuthenticated: true)
            let outcome = await coordinator.runOnce(authentication: authentication, scopes: [scope])
            guard outcome == .completed else {
                current.status = .completed // remains rollback-eligible; retry later
                current.lastErrorCode = String(describing: outcome)
                try await persistence.saveGuestMergeSession(current)
                session = current
                return
            }
            current.status = .rolledBack
            current.updatedAt = Date()
            try await persistence.saveGuestMergeSession(current)
            session = current
        } catch {
            current.status = .completed
            current.lastErrorCode = "transport"
            try? await persistence.saveGuestMergeSession(current)
            session = current
            lastErrorMessage = "回滚失败，可稍后重试。"
        }
    }
}
