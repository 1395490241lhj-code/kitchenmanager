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
    /// Set only when the production preview's read-only remote fetch itself
    /// fails (network/auth/decode/scope/pagination) — kept separate from
    /// `lastErrorMessage` so an unrelated sync error elsewhere can never
    /// bleed into (or be masked by) this specific state, and so the View can
    /// render an explicit "could not read household inventory" state that
    /// takes precedence over both the empty-state and any stale session.
    /// Cleared at the start of every `preparePreview` call.
    @Published private(set) var previewFetchFailureMessage: String?
    /// Manual-sync-only state (section 十二/十三) — entirely separate from
    /// the merge session's own `isBusy`/`lastErrorMessage`, since a manual
    /// sync can run independently of any merge session (e.g. after a merge
    /// has already completed).
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncOutcome: SyncRunOutcome?
    @Published private(set) var lastSyncStartedAt: Date?
    @Published private(set) var lastSyncCompletedAt: Date?
    @Published private(set) var lastSyncErrorMessage: String?
    /// Phase 2B-4: set when an ordinary CRUD edit was blocked from staging
    /// (conflict or pending-delete) — display-only, never blocks the local
    /// edit itself (which has already happened by the time this is set).
    @Published private(set) var inventoryMutationBlockedMessage: String?

    private let persistence: any SyncPersistenceProtocol
    private let transportFactory: @MainActor (any SyncAccessTokenProviding) -> any SyncTransport
    private let configuration: InventoryMergeConfiguration
    private let uiConfiguration: InventoryMergeUIConfiguration
    private let dogfoodConfiguration: InventorySyncDogfoodConfiguration
    /// How long a completed session's own newly-created records may still be
    /// rolled back.
    private let rollbackWindow: TimeInterval

    init(
        persistence: any SyncPersistenceProtocol,
        configuration: InventoryMergeConfiguration = .load(),
        uiConfiguration: InventoryMergeUIConfiguration = .load(),
        dogfoodConfiguration: InventorySyncDogfoodConfiguration = .load(),
        transportFactory: @escaping @MainActor (any SyncAccessTokenProviding) -> any SyncTransport = { provider in
            ExpressSyncTransport(tokenProvider: provider)
        },
        rollbackWindow: TimeInterval = 24 * 60 * 60
    ) {
        self.persistence = persistence
        self.configuration = configuration
        self.uiConfiguration = uiConfiguration
        self.dogfoodConfiguration = dogfoodConfiguration
        self.transportFactory = transportFactory
        self.rollbackWindow = rollbackWindow
    }

    /// Whether the dogfood diagnostics screen should be reachable at all.
    var showsDiagnosticsScreen: Bool { dogfoodConfiguration.showsDiagnosticsScreen }

    var isFeatureEnabled: Bool { configuration.isEnabled }
    /// Whether the merge/sync UI should be shown at all — independent of
    /// `isFeatureEnabled` (the network capability). Both default `NO`.
    var isUIEnabled: Bool { uiConfiguration.isEnabled }
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
        previewFetchFailureMessage = nil
        defer { isBusy = false }

        let localItems = kitchenStore.inventory
        let knownRemoteItems: [RemoteInventorySnapshotItem]
        let remoteSnapshotFetchedAt: Date?
        do {
            knownRemoteItems = try await fetchKnownRemoteItems(householdId: householdId, transport: remoteTransport)
            // Only a real transport performed a real remote read — a `nil`
            // transport (the offline/no-network-call path) must keep
            // producing a plan with no remote fingerprint at all, exactly as
            // before, rather than fabricating a fetch timestamp for a fetch
            // that never happened.
            remoteSnapshotFetchedAt = remoteTransport != nil ? Date() : nil
        } catch {
            // A failed remote read must never be indistinguishable from "the
            // household has nothing yet" — surface a dedicated failure state
            // and stop here without touching `session` at all, so neither a
            // stale existing session nor a fresh empty-cloud plan is ever
            // shown in its place.
            let syncError = (error as? SyncError) ?? .transport
            previewFetchFailureMessage = Self.userFacingSyncError(syncError)
            return
        }

        do {
            if var existing = try await persistence.activeGuestMergeSession(
                userId: userId, householdId: householdId, entityType: .inventoryItem
            ) {
                if let existingPlan = existing.plan,
                   !InventoryMergePlanner.isPlanStillValid(existingPlan, against: localItems, currentRemoteItems: knownRemoteItems),
                   existing.status == .detected || existing.status == .previewReady || existing.status == .awaitingConfirmation {
                    // Local data changed since this plan was generated and no
                    // upload has started yet — regenerate rather than upload
                    // a stale plan.
                    existing = regeneratedPreview(
                        session: existing, localItems: localItems, knownRemoteItems: knownRemoteItems,
                        remoteSnapshotFetchedAt: remoteSnapshotFetchedAt
                    )
                    try await persistence.saveGuestMergeSession(existing)
                }
                session = existing
                return
            }

            guard !localItems.isEmpty else { return }
            let newSession = freshPreview(
                userId: userId, householdId: householdId, localItems: localItems, knownRemoteItems: knownRemoteItems,
                remoteSnapshotFetchedAt: remoteSnapshotFetchedAt
            )
            try await persistence.saveGuestMergeSession(newSession)
            session = newSession
        } catch {
            lastErrorMessage = "无法生成合并预览，请稍后重试。"
        }
    }

    /// Production entry point — the sole call site is `GuestMergePromptView`.
    /// The View passes its already-injected `AuthStore` reference (never a
    /// token); this constructs the same credential-provider/transport
    /// pattern `confirmMerge`/`syncNow` already use, so the pre-merge read
    /// this phase wires in is authenticated exactly like every other network
    /// call in this file, and the View gains no new token-handling path.
    func preparePreview(
        userId: UUID,
        householdId: UUID,
        kitchenStore: KitchenStore,
        authStore: AuthStore
    ) async {
        let provider = AuthStoreCredentialProvider(authStore: authStore)
        let transport = transportFactory(provider)
        await preparePreview(userId: userId, householdId: householdId, kitchenStore: kitchenStore, remoteTransport: transport)
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
            // A scope mismatch means the response cannot be trusted at all —
            // silently `break`ing here previously let the fetch return
            // whatever partial results had already accumulated as if they
            // were a complete, valid snapshot. Preview must never mistake
            // "cannot trust this response" for "household has nothing yet".
            guard response.scope == scope else { throw SyncError.decoding }
            for change in response.changes where change.entityType == .inventoryItem {
                if change.operation == .delete {
                    results.removeValue(forKey: change.entityId)
                } else if let snapshot = try adapter.decodeRemoteInventorySnapshot(change) {
                    results[change.entityId] = snapshot
                }
            }
            cursor = response.cursor
            hasMore = response.hasMore
            pagesFetched += 1
            if hasMore, response.changes.isEmpty { break }
        }
        // Exiting the loop with `hasMore` still true means the household has
        // more remote data than `maxPages` could cover — the accumulated
        // `results` is a truncated, incomplete snapshot and must never be
        // returned as if it were the full remote state.
        guard !hasMore else { throw SyncError.invalidCursor }
        return Array(results.values)
    }

    private func freshPreview(
        userId: UUID, householdId: UUID, localItems: [InventoryItem], knownRemoteItems: [RemoteInventorySnapshotItem],
        remoteSnapshotFetchedAt: Date? = nil
    ) -> GuestMergeSession {
        let sessionId = UUID()
        let now = Date()
        let plan = InventoryMergePlanner.makePlan(
            sessionId: sessionId, householdId: householdId, localItems: localItems,
            knownRemoteItems: knownRemoteItems, remoteSnapshotFetchedAt: remoteSnapshotFetchedAt, generatedAt: now
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
        session existing: GuestMergeSession, localItems: [InventoryItem], knownRemoteItems: [RemoteInventorySnapshotItem],
        remoteSnapshotFetchedAt: Date? = nil
    ) -> GuestMergeSession {
        var updated = existing
        let plan = InventoryMergePlanner.makePlan(
            sessionId: existing.id, householdId: existing.householdId, localItems: localItems,
            knownRemoteItems: knownRemoteItems, remoteSnapshotFetchedAt: remoteSnapshotFetchedAt, generatedAt: Date()
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
        // A session only ever reaches `.conflict` after a real confirm left
        // some candidates unresolved (see `confirmMerge`'s post-upload
        // branch) — and nothing else ever moves it back out of `.conflict`.
        // `InventoryMergeConflictView` has no confirm/continue action of its
        // own, and `InventoryMergeFlowView` only ever routes to the preview
        // screen (which does have the confirm button) for a different set of
        // statuses — so without this, resolving every remaining conflict
        // (via any of the four choices, including `.skip`) left the user
        // permanently stuck on an now-empty conflict form with no way back
        // to confirm. Once nothing here still needs a decision, hand control
        // back to the ordinary preview flow so the user can finish through
        // its existing confirm button (and everything it already validates:
        // stale-fingerprint revalidation, zero-write guarantees, etc.).
        if current.status == .conflict, plan.conflicts.isEmpty {
            current.status = .previewReady
        }
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

        // Session-owner / identity guard — never let one account confirm a
        // session that was generated under a different identity.
        guard current.userId == userId else {
            lastErrorMessage = "会话与当前账号不匹配，请重新查看合并预览。"
            return
        }

        let provider = AuthStoreCredentialProvider(authStore: authStore)
        let transport = transportFactory(provider)

        // Re-verify the remote state right before writing anything — a plan
        // built minutes or hours earlier may no longer reflect reality.
        // Reject rather than silently recompute-and-continue: the whole
        // point of this gate is that stale-remote-data must never reach
        // `stageUpsert`.
        if let previewHash = plan.remoteSnapshotHash {
            let currentRemoteItems: [RemoteInventorySnapshotItem]
            do {
                currentRemoteItems = try await fetchKnownRemoteItems(householdId: current.householdId, transport: transport)
            } catch {
                lastErrorMessage = "无法确认家庭库存最新状态，请重试。"
                return
            }
            let currentHash = InventoryMergePlanner.remoteSnapshotHash(currentRemoteItems)
            guard currentHash == previewHash else {
                current.status = .previewReady
                current.updatedAt = Date()
                try? await persistence.saveGuestMergeSession(current)
                session = current
                lastErrorMessage = "家庭库存已变化，请重新预览。"
                return
            }
        }

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
                if let forkedId = candidate.forkedLocalItemId {
                    // Same-id `keepBoth`: the existing remote entity
                    // (`candidate.localItemId`) is certain and is never
                    // touched here (a true no-op for it, like `keepRemote`).
                    // Instead, stage a genuinely new local record — a copy
                    // of the local values under the fresh, stable forked id
                    // — and create *that* remotely. Guarded so a retry/
                    // re-confirm never re-stages (and never re-mints a
                    // mutationId for) an already-in-flight or already-synced
                    // fork; the coordinator's own pending-mutation retry
                    // logic handles anything still unresolved.
                    guard try await persistence.metadata(entityType: .inventoryItem, entityId: forkedId) == nil else { continue }
                    guard let originalItem = try await persistence.inventoryItem(id: candidate.localItemId) else { continue }
                    var forkedItem = originalItem
                    forkedItem.id = forkedId
                    forkedItem.createdAt = Date()
                    forkedItem.updatedAt = Date()
                    _ = try await adapter.stageUpsert(item: forkedItem, scope: scope)
                    continue
                }
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
                // A same-id `keepBoth` fork's outcome lives under
                // `forkedLocalItemId`, not `localItemId` — the original
                // entity id is never staged for this candidate at all.
                let entityIdToCheck = candidate.forkedLocalItemId ?? candidate.localItemId
                guard let metadata = try await persistence.metadata(entityType: .inventoryItem, entityId: entityIdToCheck) else { continue }
                switch metadata.state {
                case .synced:
                    uploaded += 1
                    if candidate.action == .create, !newCreatedIds.contains(entityIdToCheck) {
                        newCreatedIds.append(entityIdToCheck)
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
                // Phase 2B-4: a completed merge is exactly what moves this
                // (user, household) workspace from notEnrolled/mergeRequired
                // into enrolled — ordinary CRUD may now stage mutations for
                // items with their own household-scoped SyncMetadata.
                try? await persistence.saveEnrollment(InventorySyncEnrollment(
                    userId: userId, householdId: current.householdId, status: .enrolled,
                    enrolledAt: Date(), mergeSessionId: current.id,
                    schemaVersion: InventorySyncEnrollment.currentSchemaVersion, updatedAt: Date()
                ))
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

    // MARK: Manual sync (explicit, user-initiated only — never automatic)

    /// The only way `SyncCoordinator.runOnce` is ever invoked outside of
    /// `confirmMerge`/`rollback` — always in direct response to the user
    /// tapping "立即同步库存". Never called from App startup, sign-in, a
    /// timer, or a background task. Scoped to `.inventoryItem` only, exactly
    /// like every other entry point in this file.
    func syncNow(authStore: AuthStore, householdId: UUID) async {
        guard isFeatureEnabled else {
            lastSyncErrorMessage = "库存同步尚未开启。"
            return
        }
        guard let userId = authStore.currentUserID else {
            lastSyncErrorMessage = "请先登录后再同步。"
            return
        }
        guard !isSyncing else { return }

        isSyncing = true
        lastSyncErrorMessage = nil
        lastSyncStartedAt = Date()
        defer { isSyncing = false }

        let scope = SyncScope(type: .household, id: householdId)
        let provider = AuthStoreCredentialProvider(authStore: authStore)
        let transport = transportFactory(provider)
        let coordinator = SyncCoordinator(configuration: SyncConfiguration(isEnabled: true), persistence: persistence, transport: transport)
        let authentication = SyncAuthenticationContext(userID: userId, isAuthenticated: true)
        let outcome = await coordinator.runOnce(authentication: authentication, scopes: [scope])
        lastSyncOutcome = outcome
        lastSyncCompletedAt = Date()
        if case .failed(let error) = outcome {
            lastSyncErrorMessage = Self.userFacingSyncError(error)
        } else if case .paused(let error) = outcome {
            lastSyncErrorMessage = Self.userFacingSyncError(error)
        }
    }

    /// How many inventory mutations are currently staged and not yet
    /// resolved for this household — used only for the status label ("待同步
    /// X 项"), never to decide whether to sync automatically.
    func pendingInventoryCount(householdId: UUID) async -> Int {
        let scope = SyncScope(type: .household, id: householdId)
        return (try? await persistence.pendingMutations(scope: scope, maxAttempts: .max).count) ?? 0
    }

    /// Maps a technical `SyncError` to plain, user-facing copy — never the
    /// raw error description, an HTTP status, or any transport detail.
    private static func userFacingSyncError(_ error: SyncError) -> String {
        switch error {
        case .notAuthenticated: "需要重新登录。"
        case .forbidden, .unauthorized: "需要重新登录。"
        case .payloadTooLarge: "本次同步内容过大，请稍后重试。"
        case .conflict: "有冲突条目待处理。"
        case .backendUnavailable: "服务暂时不可用，请稍后重试。"
        case .decoding, .invalidCursor, .invalidConfiguration, .unsupportedEntity, .persistence: "同步失败，可稍后重试。"
        case .disabled: "库存同步尚未开启。"
        case .transport: "当前网络不可用，请稍后重试。"
        }
    }

    // MARK: Phase 2B-4: synced-scope CRUD mutation staging (local-only; never touches the network)

    /// Current enrollment status for this (user, household) — `.notEnrolled`
    /// whenever `userId`/`householdId` is nil or no enrollment row exists
    /// yet. Used only for UI status text; never itself decides eligibility
    /// (that's `InventorySyncEligibility`, evaluated fresh per item).
    func enrollmentStatus(userId: UUID?, householdId: UUID?) async -> InventorySyncEnrollmentStatus {
        guard let userId, let householdId else { return .notEnrolled }
        let enrollment = try? await persistence.enrollment(userId: userId, householdId: householdId)
        return (enrollment.flatMap { $0 })?.status ?? .notEnrolled
    }

    // MARK: Phase 2B-5: read-only, redacted diagnostics + consistency checking

    /// Builds the fully redacted diagnostics snapshot — never includes a
    /// name, token, full UUID, household id, or payload. See
    /// `docs/INVENTORY_SYNC_DIAGNOSTICS.md`.
    func diagnosticsSnapshot(
        kitchenStore: KitchenStore, userId: UUID?, householdId: UUID?, environmentName: String, appBuild: String
    ) async -> InventorySyncDiagnosticsSnapshot {
        var enrollment: InventorySyncEnrollment?
        var pendingCount = 0
        var conflictCount = 0
        var failedCount = 0
        var oldestPendingAge: TimeInterval?
        var syncedCount = 0
        var tombstoneCount = 0
        var cursorValue: String?

        if let userId, let householdId {
            enrollment = (try? await persistence.enrollment(userId: userId, householdId: householdId)).flatMap { $0 }
            let scope = SyncScope(type: .household, id: householdId)
            let allMutations = (try? await persistence.allPendingMutations(scope: scope)) ?? []
            let active = allMutations.filter { $0.status == .pending || $0.status == .inFlight || $0.status == .failed }
            pendingCount = active.count
            failedCount = active.filter { $0.status == .failed }.count
            if let oldest = active.map(\.createdAt).min() {
                oldestPendingAge = Date().timeIntervalSince(oldest)
            }
            let allMeta = (try? await persistence.allMetadata(scope: scope)) ?? []
            conflictCount = allMeta.filter { $0.state == .conflicted }.count
            syncedCount = allMeta.filter { $0.state == .synced }.count
            tombstoneCount = allMeta.filter { $0.state == .pendingDelete || $0.deletedAt != nil }.count
            if let cursor = try? await persistence.cursor(for: scope) { cursorValue = cursor.value.rawValue }
        }

        let localIds = Set(kitchenStore.inventory.map(\.id))
        let guestOnlyCount = max(0, localIds.count - syncedCount)

        return InventorySyncDiagnosticsSnapshot(
            environment: environmentName,
            isFeatureEnabled: isFeatureEnabled,
            isDogfoodEnabled: dogfoodConfiguration.isDogfoodEnabled,
            isEnrolled: enrollment?.status.allowsMutationStaging ?? false,
            currentUserPresent: userId != nil,
            householdPresent: householdId != nil,
            pendingCount: pendingCount,
            conflictCount: conflictCount,
            failedCount: failedCount,
            oldestPendingAge: oldestPendingAge,
            lastSyncStartedAt: lastSyncStartedAt,
            lastSyncCompletedAt: lastSyncCompletedAt,
            lastSyncResult: Self.shortOutcomeLabel(lastSyncOutcome),
            lastSuccessfulCursor: cursorValue,
            activeMergeSessionState: session?.status.rawValue,
            enrollmentState: (enrollment?.status ?? .notEnrolled).rawValue,
            localSyncedItemCount: syncedCount,
            localGuestOnlyItemCount: guestOnlyCount,
            localTombstoneCount: tombstoneCount,
            appBuild: appBuild,
            schemaVersion: InventorySyncEnrollment.currentSchemaVersion
        )
    }

    /// Read-only — never fixes anything. Returns every issue found; the
    /// caller (dogfood diagnostics screen, or a test) decides what to do
    /// with them, which today is always just "display", never "auto-repair".
    func consistencyCheck(kitchenStore: KitchenStore, userId: UUID?, householdId: UUID?) async -> [InventorySyncConsistencyIssue] {
        guard let householdId else { return [] }
        let scope = SyncScope(type: .household, id: householdId)
        let enrollment = (try? await persistence.enrollment(userId: userId ?? UUID(), householdId: householdId)).flatMap { $0 }
        let allMeta = (try? await persistence.allMetadata(scope: scope)) ?? []
        let allMutations = (try? await persistence.allPendingMutations(scope: scope)) ?? []
        let activeSession = try? await persistence.activeGuestMergeSession(userId: userId ?? UUID(), householdId: householdId, entityType: .inventoryItem)
        return InventorySyncConsistencyChecker.check(
            localInventoryIds: Set(kitchenStore.inventory.map(\.id)),
            allMetadata: allMeta,
            allPendingMutations: allMutations,
            enrollment: enrollment,
            expectedUserId: userId,
            expectedHouseholdId: householdId,
            activeMergeSession: activeSession.flatMap { $0 },
            previousCursorValue: nil,
            currentCursorValue: nil
        )
    }

    private static func shortOutcomeLabel(_ outcome: SyncRunOutcome?) -> String? {
        guard let outcome else { return nil }
        switch outcome {
        case .disabled: return "disabled"
        case .paused: return "paused"
        case .completed: return "completed"
        case .alreadyRunning: return "alreadyRunning"
        case .failed: return "failed"
        }
    }

    /// The single hook point for "ordinary inventory content changed" —
    /// wired once, in the app's composition root, from
    /// `KitchenStore.onInventoryChanged`. Diffs `old` vs `new` by id and
    /// stages a mutation for each added/changed/removed item that is
    /// currently eligible (see `InventorySyncEligibility`); Guest-only or
    /// not-yet-enrolled items are silently skipped, exactly as before Phase
    /// 2B-4 — this never fails loudly and never touches the network itself.
    func handleInventoryDidChange(old: [InventoryItem], new: [InventoryItem], userId: UUID?, householdId: UUID?) async {
        guard isFeatureEnabled, let userId, let householdId else { return }
        let oldById = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let newById = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
        guard oldById != newById else { return }

        let enrollment = try? await persistence.enrollment(userId: userId, householdId: householdId)
        let flatEnrollment = enrollment.flatMap { $0 }
        let scope = SyncScope(type: .household, id: householdId)
        let adapter = InventorySyncAdapter(persistence: persistence)

        for (id, newItem) in newById {
            let intent: InventoryMutationIntent = oldById[id] == nil ? .create : .update
            if intent == .update, oldById[id] == newItem { continue }
            await stageMutationIfEligible(
                entityId: id, item: newItem, operation: .upsert, intent: intent,
                userId: userId, householdId: householdId, enrollment: flatEnrollment, scope: scope, adapter: adapter
            )
        }
        for id in oldById.keys where newById[id] == nil {
            await stageMutationIfEligible(
                entityId: id, item: nil, operation: .delete, intent: .delete,
                userId: userId, householdId: householdId, enrollment: flatEnrollment, scope: scope, adapter: adapter
            )
        }
    }

    private func stageMutationIfEligible(
        entityId: UUID,
        item: InventoryItem?,
        operation: SyncOperation,
        intent: InventoryMutationIntent,
        userId: UUID,
        householdId: UUID,
        enrollment: InventorySyncEnrollment?,
        scope: SyncScope,
        adapter: InventorySyncAdapter
    ) async {
        let existingMetadata = try? await persistence.metadata(entityType: .inventoryItem, entityId: entityId)
        let flatMetadata = existingMetadata.flatMap { $0 }
        let existingPending = try? await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: entityId)
        let hasExistingPending = (existingPending.flatMap { $0 }) != nil
        let pendingCount = (try? await persistence.pendingMutations(scope: scope, maxAttempts: .max).count) ?? 0
        let result = InventorySyncEligibility.evaluate(
            isFeatureEnabled: isFeatureEnabled, userId: userId, householdId: householdId,
            enrollment: enrollment, existingMetadata: flatMetadata, intent: intent,
            hasExistingPendingMutationForEntity: hasExistingPending,
            currentPendingCount: pendingCount, maxPendingMutations: dogfoodConfiguration.maxPendingMutations
        )
        switch result {
        case .eligible:
            let payloadData: Data
            if let item {
                guard let encoded = try? adapter.encodedPayload(for: item) else { return }
                payloadData = encoded
            } else {
                payloadData = Data("{}".utf8)
            }
            _ = try? await persistence.stageInventoryMutation(
                entityId: entityId, scope: scope, operation: operation, payloadData: payloadData, now: Date()
            )
        case .blockedByConflict:
            inventoryMutationBlockedMessage = "该库存存在同步冲突，请先在同步状态中处理后再修改。"
        case .blockedByPendingDelete:
            inventoryMutationBlockedMessage = "该库存正在等待删除同步，暂不支持编辑。"
        case .blockedByQueueFull:
            inventoryMutationBlockedMessage = "同步队列已满，请先手动同步后再继续编辑。"
        case .localOnly:
            break
        }
    }
}
