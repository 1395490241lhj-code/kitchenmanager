import Foundation
import Combine

/// Read-only wrapper around a signed-in user's access token, built once per
/// controller so the transport never touches `AuthStore` internals directly.
private struct AccessTokenReader: SyncAccessTokenProviding {
    let read: @Sendable () -> String?
    func accessToken() async -> String? { read() }
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
    func preparePreview(userId: UUID, householdId: UUID, kitchenStore: KitchenStore) async {
        guard isFeatureEnabled else { return }
        isBusy = true
        lastErrorMessage = nil
        defer { isBusy = false }
        do {
            let localItems = kitchenStore.inventory
            if var existing = try await persistence.activeGuestMergeSession(
                userId: userId, householdId: householdId, entityType: .inventoryItem
            ) {
                if let existingPlan = existing.plan,
                   !InventoryMergePlanner.isPlanStillValid(existingPlan, against: localItems),
                   existing.status == .detected || existing.status == .previewReady || existing.status == .awaitingConfirmation {
                    // Local data changed since this plan was generated and no
                    // upload has started yet — regenerate rather than upload
                    // a stale plan.
                    existing = regeneratedPreview(session: existing, localItems: localItems)
                    try await persistence.saveGuestMergeSession(existing)
                }
                session = existing
                return
            }

            guard !localItems.isEmpty else { return }
            let newSession = freshPreview(userId: userId, householdId: householdId, localItems: localItems)
            try await persistence.saveGuestMergeSession(newSession)
            session = newSession
        } catch {
            lastErrorMessage = "无法生成合并预览，请稍后重试。"
        }
    }

    private func freshPreview(userId: UUID, householdId: UUID, localItems: [InventoryItem]) -> GuestMergeSession {
        let sessionId = UUID()
        let now = Date()
        let plan = InventoryMergePlanner.makePlan(
            sessionId: sessionId, householdId: householdId, localItems: localItems, generatedAt: now
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

    private func regeneratedPreview(session existing: GuestMergeSession, localItems: [InventoryItem]) -> GuestMergeSession {
        var updated = existing
        let plan = InventoryMergePlanner.makePlan(
            sessionId: existing.id, householdId: existing.householdId, localItems: localItems, generatedAt: Date()
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
    /// modified by this path.
    func confirmMerge(userId: UUID, accessToken: String?) async {
        guard isFeatureEnabled else { return }
        guard var current = session, let plan = current.plan else { return }
        guard current.status == .previewReady || current.status == .awaitingConfirmation || current.status == .conflict else { return }
        guard let accessToken, !accessToken.isEmpty else {
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
                _ = try await adapter.stageUpsert(item: localItem, scope: scope)
            }

            let configuration = SyncConfiguration(isEnabled: true)
            let provider = AccessTokenReader { accessToken }
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
    /// partially failed.
    func rollback(userId: UUID, accessToken: String?) async {
        guard var current = session else { return }
        guard current.status == .completed || current.status == .rollbackPending else { return }
        if let deadline = current.rollbackAvailableUntil, Date() > deadline {
            lastErrorMessage = "回滚窗口已过期。"
            return
        }
        guard let accessToken, !accessToken.isEmpty else {
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
            let provider = AccessTokenReader { accessToken }
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
