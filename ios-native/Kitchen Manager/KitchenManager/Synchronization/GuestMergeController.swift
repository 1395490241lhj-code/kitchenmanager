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
    #if DEBUG
    /// UI-test-only record of which branch `preparePreview` actually took.
    ///
    /// Set inside the real branches, never inferred from session id (which
    /// `regeneratedPreview` preserves), candidate counts, or launch arguments.
    enum UITestPreviewOrigin: String {
        case createdNew = "created-new"
        case resumedExisting = "resumed-existing"
        case regeneratedInvalidPlan = "regenerated-invalid-plan"
    }
    @Published private(set) var uiTestPreviewOrigin: UITestPreviewOrigin?
    #endif

    /// UI-5B2B-B2B: transient, edit-scoped error for conflict-choice actions.
    ///
    /// Deliberately separate from `lastErrorMessage`: a successful choice edit
    /// must not silently discard an unrelated preview/confirm/sync/rollback
    /// error the user still needs to see, and the editing surfaces must not have
    /// to rely on clearing a global field to display their own failure.
    @Published private(set) var conflictChoiceErrorMessage: String?
    /// Which candidate the message above belongs to, so opening a different
    /// candidate never shows another candidate's stale rejection.
    @Published private(set) var conflictChoiceErrorCandidateId: UUID?

    /// The edit error for `candidateId`, or `nil` when the current error belongs
    /// to a different candidate.
    func conflictChoiceError(for candidateId: UUID) -> String? {
        guard conflictChoiceErrorCandidateId == candidateId else { return nil }
        return conflictChoiceErrorMessage
    }

    /// Drops an error that belongs to some other candidate. Called when an
    /// editing surface opens, never on every render — a rejection produced by
    /// the surface's own stale action must stay on screen.
    func clearConflictChoiceError(unless candidateId: UUID) {
        guard conflictChoiceErrorCandidateId != candidateId else { return }
        conflictChoiceErrorMessage = nil
        conflictChoiceErrorCandidateId = nil
    }
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
    /// Phase 2C-1: set whenever any sync call returns 426 (this app build is
    /// below the server's configured minimum). Never cleared automatically —
    /// only a fresh call that itself succeeds (or fails for a different
    /// reason) resets it, so the UI can render a persistent "需要更新" state
    /// rather than a one-shot popup. A View drives its confirm/rollback
    /// button visibility from this flag; local-only (Guest) usage is
    /// entirely unaffected, since this only ever gets set from inside a
    /// network call these buttons themselves would have triggered.
    @Published private(set) var clientUpgradeRequired = false
    /// Phase 2C-1: set whenever any sync call returns 429; the value is the
    /// server's own `Retry-After` translated into an absolute deadline (or a
    /// conservative fallback if the server didn't include one), so a View
    /// can show "请在 X 秒后重试" without re-deriving the interval itself.
    @Published private(set) var rateLimitedRetryAfter: Date?

    private let persistence: any SyncPersistenceProtocol
    private let transportFactory: @MainActor (any SyncAccessTokenProviding) -> any SyncTransport
    private let configuration: InventoryMergeConfiguration
    private let uiConfiguration: InventoryMergeUIConfiguration
    private let dogfoodConfiguration: InventorySyncDogfoodConfiguration
    /// How long a completed session's own newly-created records may still be
    /// rolled back.
    private let rollbackWindow: TimeInterval
    /// Phase 2C-2: operational breadcrumbs only (see
    /// docs/CRASH_REPORTING.md) — never business content. Defaults to the
    /// safe no-op provider; tests inject a fake to assert on emitted events.
    private let crashReporter: any CrashReporting
    /// True only after the current controller instance prepared a preview
    /// with the production remote transport. Offline/no-transport callers
    /// retain their existing local-only semantics; production callers must
    /// never confirm a plan that lacks a remote fingerprint.
    private var previewRequiresRemoteFingerprint = false

    init(
        persistence: any SyncPersistenceProtocol,
        configuration: InventoryMergeConfiguration = .load(),
        uiConfiguration: InventoryMergeUIConfiguration = .load(),
        dogfoodConfiguration: InventorySyncDogfoodConfiguration = .load(),
        transportFactory: @escaping @MainActor (any SyncAccessTokenProviding) -> any SyncTransport = { provider in
            ExpressSyncTransport(tokenProvider: provider)
        },
        rollbackWindow: TimeInterval = 24 * 60 * 60,
        crashReporter: (any CrashReporting)? = nil
    ) {
        self.persistence = persistence
        self.configuration = configuration
        self.uiConfiguration = uiConfiguration
        self.dogfoodConfiguration = dogfoodConfiguration
        self.transportFactory = transportFactory
        self.rollbackWindow = rollbackWindow
        self.crashReporter = crashReporter ?? CrashReportingFactory.makeProvider()
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
        clientUpgradeRequired = false
        rateLimitedRetryAfter = nil
        previewRequiresRemoteFingerprint = remoteTransport != nil
        // A persisted plan is not trusted for presentation until this
        // explicit, user-initiated remote read completes. The in-memory and
        // persisted record remains available for recovery, while
        // `InventoryMergeFlowView` gates its body on this request completing
        // so a stale preview can never flash or become confirmable.
        crashReporter.addBreadcrumb(.mergePreviewStarted, metadata: [:])
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
            noteSyncOutcomeForVersionAndRateLimitDisplay(syncError)
            crashReporter.addBreadcrumb(.mergePreviewFailed, metadata: ["errorCode": syncError.crashReportingCode])
            return
        }

        do {
            if var existing = try await persistence.activeGuestMergeSession(
                userId: userId, householdId: householdId, entityType: .inventoryItem
            ) {
                if let existingPlan = existing.plan,
                   (remoteTransport != nil && existingPlan.remoteSnapshotHash == nil
                    || !InventoryMergePlanner.isPlanStillValid(existingPlan, against: localItems, currentRemoteItems: knownRemoteItems)),
                   existing.status == .detected || existing.status == .previewReady || existing.status == .awaitingConfirmation {
                    #if DEBUG
                    uiTestPreviewOrigin = .regeneratedInvalidPlan
                    #endif
                    // Local data changed since this plan was generated and no
                    // upload has started yet — regenerate rather than upload
                    // a stale plan.
                    existing = regeneratedPreview(
                        session: existing, localItems: localItems, knownRemoteItems: knownRemoteItems,
                        remoteSnapshotFetchedAt: remoteSnapshotFetchedAt
                    )
                    try await persistence.saveGuestMergeSession(existing)
                }
                #if DEBUG
                // Only when the regenerate branch above did not run.
                if uiTestPreviewOrigin != .regeneratedInvalidPlan {
                    uiTestPreviewOrigin = .resumedExisting
                }
                #endif
                session = existing
                return
            }

            guard !localItems.isEmpty else { return }
            #if DEBUG
            uiTestPreviewOrigin = .createdNew
            #endif
            let newSession = freshPreview(
                userId: userId, householdId: householdId, localItems: localItems, knownRemoteItems: knownRemoteItems,
                remoteSnapshotFetchedAt: remoteSnapshotFetchedAt
            )
            try await persistence.saveGuestMergeSession(newSession)
            session = newSession
        } catch {
            lastErrorMessage = "无法生成合并预览，请稍后重试。"
            crashReporter.addBreadcrumb(.mergePreviewFailed, metadata: ["errorCode": "persistence_failure"])
        }
    }

    /// Production entry point — called only after the user opens the preview
    /// sheet. Account-page rendering and the inline prompt never construct a
    /// credential provider or transport.
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

    /// Records — or, before the first confirm, changes — one candidate's choice.
    ///
    /// The controller is the final safety boundary here, not the UI: a stale
    /// screen, a queued tap, or any future caller must fail closed rather than
    /// rewrite a decision this session may already have executed remotely.
    /// Nothing in this app can undo a completed remote create or update.
    func resolveConflict(candidateId: UUID, choice: InventoryMergeConflictChoice) async {
        guard var current = session, var plan = current.plan else {
            conflictChoiceErrorMessage = "无法找到这条冲突记录，请返回合并预览后重试。"
            conflictChoiceErrorCandidateId = candidateId
            return
        }
        guard let index = plan.candidates.firstIndex(where: { $0.localItemId == candidateId }) else {
            conflictChoiceErrorMessage = "无法找到这条冲突记录，请返回合并预览后重试。"
            conflictChoiceErrorCandidateId = candidateId
            return
        }

        let candidate = plan.candidates[index]
        if candidate.userChoice == nil {
            // First-time resolution of an outstanding conflict. `.conflict` is
            // included because that is exactly where `confirmMerge` parks a
            // session whose leftover conflicts still need deciding.
            guard current.status == .previewReady
                    || current.status == .awaitingConfirmation
                    || current.status == .conflict else {
                conflictChoiceErrorMessage = "当前状态无法处理冲突，请重新查看合并预览。"
                conflictChoiceErrorCandidateId = candidateId
                return
            }
        } else {
            // Re-editing an already-recorded choice. Allowed only while this
            // session has provably never attempted a write: a confirm may have
            // uploaded this very candidate, and `InventoryMergeCandidate` keeps
            // no per-item upload state to tell which. Note `.conflict` is
            // absent — reaching it means a confirm already ran.
            guard current.status == .previewReady || current.status == .awaitingConfirmation,
                  current.confirmedAt == nil,
                  current.uploadedItemCount == 0,
                  current.createdEntityIds.isEmpty else {
                conflictChoiceErrorMessage = "同步已经开始，已记录的处理方式不能再修改。"
                conflictChoiceErrorCandidateId = candidateId
                return
            }
        }

        // Past both guards. Only the edit-scoped error is cleared — an
        // unrelated preview/confirm/sync failure in `lastErrorMessage` stays
        // visible, because this edit did not resolve it.
        conflictChoiceErrorMessage = nil
        conflictChoiceErrorCandidateId = nil
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
            // Both: the dedicated field drives the editor, while the existing
            // global message is preserved for callers that already relied on it.
            conflictChoiceErrorMessage = "无法保存处理方式，请重试。"
            conflictChoiceErrorCandidateId = candidateId
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

    // MARK: - R1: whole-operation inventory consistency boundary

    /// R1: the inbound half of the composition-root wiring `ContentView`
    /// already does for the outbound half (`KitchenStore.onInventoryChanged`).
    /// `KitchenStore` still imports nothing about Auth/Sync; this controller
    /// only ever asks it to open/close a consistency window.
    ///
    /// Weak so the controller never keeps the app's store alive, but a `nil`
    /// store is emphatically **not** "skip reconciliation" — see
    /// `withInventoryConsistencyBoundary`.
    weak var kitchenStore: KitchenStore?

    static let inventoryConsistencyUnavailableMessage = "库存同步暂不可用：缺少本地库存状态绑定。"

    /// Wraps a whole operation that may write `InventoryRecord` through
    /// `SwiftDataSyncPersistence`.
    ///
    /// The window must open before the operation's *first* durable inventory
    /// write, not merely around the coordinator run: `confirmMerge` writes
    /// `InventoryRecord` while staging (`InventorySyncAdapter.stageUpsert` →
    /// `commitInventoryAndSync`), which happens before `runOnce` is reached
    /// and can fail partway. Since R3, `rollback`'s own staging is remote-only
    /// — but it still needs the same window, because the coordinator run it
    /// performs can write durable inventory through the pull path. Closing it in a `defer`-equivalent position — on
    /// every exit, including an early `return` from `body` and any partial
    /// staging failure — is what makes "durable write happened, memory never
    /// caught up" unreachable.
    ///
    /// Fails closed: without a reconciliation target the operation does not
    /// start at all. Running a coordinator that can write durable inventory
    /// with nowhere to reconcile to is precisely the R1 state this boundary
    /// exists to prevent, so degrading to "sync anyway" would be worse than
    /// not syncing.
    private func withInventoryConsistencyBoundary(_ body: () async -> Void) async {
        guard let kitchenStore else {
            lastErrorMessage = Self.inventoryConsistencyUnavailableMessage
            lastSyncErrorMessage = Self.inventoryConsistencyUnavailableMessage
            return
        }
        kitchenStore.beginInventorySyncConsistencyWindow()
        await body()
        if !kitchenStore.endInventorySyncConsistencyWindow() {
            lastSyncErrorMessage = KitchenStore.inventoryReconciliationFailedNotice
            lastErrorMessage = KitchenStore.inventoryReconciliationFailedNotice
        }
    }

    func confirmMerge(authStore: AuthStore) async {
        await withInventoryConsistencyBoundary { [self] in
            await performConfirmMerge(authStore: authStore)
        }
    }

    func rollback(authStore: AuthStore) async {
        await withInventoryConsistencyBoundary { [self] in
            await performRollback(authStore: authStore)
        }
    }

    func syncNow(authStore: AuthStore, householdId: UUID) async {
        await withInventoryConsistencyBoundary { [self] in
            await performSyncNow(authStore: authStore, householdId: householdId)
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
    private func performConfirmMerge(authStore: AuthStore) async {
        guard isFeatureEnabled else { return }
        guard var current = session, let plan = current.plan else { return }
        guard current.status == .previewReady || current.status == .awaitingConfirmation || current.status == .conflict else { return }
        // Captured before any network attempt: if this attempt fails purely
        // because of client-version/rate-limit (not a genuine upload
        // failure), the session is restored to exactly this status rather
        // than `.failed` — `confirmMerge`'s own guard above only ever
        // accepts these three statuses, so landing on `.failed` would make
        // the very next retry (after the user updates the app, or once the
        // rate-limit window passes) a permanent no-op.
        let statusBeforeAttempt = current.status
        guard let userId = authStore.currentUserID else {
            lastErrorMessage = "请先登录后再确认合并。"
            return
        }

        isBusy = true
        lastErrorMessage = nil
        clientUpgradeRequired = false
        rateLimitedRetryAfter = nil
        crashReporter.addBreadcrumb(.mergeConfirmStarted, metadata: [:])
        defer { isBusy = false }

        // Session-owner / identity guard — never let one account confirm a
        // session that was generated under a different identity.
        guard current.userId == userId else {
            lastErrorMessage = "会话与当前账号不匹配，请重新查看合并预览。"
            return
        }

        let provider = AuthStoreCredentialProvider(authStore: authStore)
        let transport = transportFactory(provider)

        // A legacy/offline plan has no trustworthy remote fingerprint. The
        // production path must fail closed before stageUpsert or
        // SyncCoordinator, even if a caller bypasses the preview UI.
        //
        // Depends on the plan alone, never on `previewRequiresRemoteFingerprint`:
        // that flag is cleared by the no-transport `preparePreview` overload, which
        // also persists a plan carrying no fingerprint. Consulting it let
        // controller state disarm the guard — the hash-less plan passed here, then
        // skipped the re-verification below (itself conditional on a non-nil
        // hash), and reached stageUpsert and SyncCoordinator with no remote check
        // at all. The no-transport overload stays available for local preview and
        // tests; its plans simply can never be confirmed in production.
        guard plan.remoteSnapshotHash != nil else {
            lastErrorMessage = "请重新查看合并预览后再确认。"
            return
        }

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
                // `activeForkedLocalItemId`, never `forkedLocalItemId`: since
                // UI-5B2B-B2B a reserved fork id is retained after the user
                // moves the choice away from `keepBoth`, so a non-nil raw value
                // no longer means "this candidate forks". Reading the raw field
                // here would route a `keepLocal`/`keepRemote`/`skip` candidate
                // down the fork-create path and create a record the user never
                // asked for.
                if let forkedId = candidate.activeForkedLocalItemId {
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
                var recognizedSyncError: SyncError?
                if case .failed(let syncError) = outcome { recognizedSyncError = syncError }
                if case .paused(let syncError) = outcome { recognizedSyncError = syncError }
                if let recognizedSyncError {
                    noteSyncOutcomeForVersionAndRateLimitDisplay(recognizedSyncError)
                    lastErrorMessage = Self.userFacingSyncError(recognizedSyncError)
                    crashReporter.captureNonFatal(recognizedSyncError, context: ["routeCategory": "merge_confirm"])
                }
                crashReporter.addBreadcrumb(.mergeConfirmFailed, metadata: ["errorCode": recognizedSyncError?.crashReportingCode ?? String(describing: outcome)])
                switch recognizedSyncError {
                case .clientUpgradeRequired, .clientSchemaUnsupported, .rateLimited:
                    // Never a genuine upload failure — restore the
                    // pre-attempt status so the next retry's own guard
                    // still accepts it.
                    current.status = statusBeforeAttempt
                default:
                    current.status = .failed
                }
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
                // A same-id `keepBoth` fork's outcome lives under its *active*
                // forked id, not `localItemId` — the original entity id is
                // never staged for this candidate at all. An inactive retained
                // reservation must fall through to `localItemId`, or the
                // outcome of an edited-away choice would be read from an entity
                // that was never staged.
                let entityIdToCheck = candidate.activeForkedLocalItemId ?? candidate.localItemId
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
                crashReporter.addBreadcrumb(.mergeConfirmCompleted, metadata: ["mutationCountBucket": CrashReportingMetadata.countBucket(uploaded)])
            } else if failed > 0 {
                current.status = .failed
                crashReporter.addBreadcrumb(.mergeConfirmFailed, metadata: ["errorCode": "partial_failure"])
            } else {
                current.status = .conflict
            }
            try await persistence.saveGuestMergeSession(current)
            session = current
        } catch {
            if let syncError = error as? SyncError { noteSyncOutcomeForVersionAndRateLimitDisplay(syncError) }
            current.status = .failed
            current.lastErrorCode = "transport"
            current.updatedAt = Date()
            try? await persistence.saveGuestMergeSession(current)
            session = current
            lastErrorMessage = (error as? SyncError).map(Self.userFacingSyncError) ?? "合并上传失败，可稍后重试。"
            crashReporter.captureNonFatal(error, context: ["routeCategory": "merge_confirm"])
            crashReporter.addBreadcrumb(.mergeConfirmFailed, metadata: ["errorCode": (error as? SyncError)?.crashReportingCode ?? "unknown_error"])
        }
    }

    #if DEBUG
    /// UI-test-only seam: marks the in-memory and persisted session as having
    /// started syncing, so a UI test can prove the review/editor turn read-only
    /// *while still open*. Sets nothing else — no upload, no coordinator, no
    /// network, no staged mutation — and exists only in DEBUG.
    func markSyncStartedForUITesting() async {
        guard var current = session else { return }
        current.confirmedAt = current.confirmedAt ?? Date()
        current.updatedAt = Date()
        try? await persistence.saveGuestMergeSession(current)
        session = current
    }
    #endif

    // MARK: Rollback (limited — only this session's own newly-created records)

    /// Soft-deletes only the remote records this session itself created.
    /// Never touches pre-existing remote records or conflicts the user chose
    /// to keep-remote. Idempotent: safe to call again if a prior attempt
    /// partially failed. Takes the live `AuthStore` reference (never a raw
    /// token), same as `confirmMerge`.
    ///
    /// R3 — the invariant this method must never break: **rollback withdraws
    /// what the merge published to the household, and never removes a local
    /// durable `InventoryRecord` from the store.** `createdEntityIds` names *remote*
    /// entities; for a plain `.create` candidate the same UUID is also the id
    /// of a local row the user owned before the merge ever ran, and for a
    /// same-id `keepBoth` fork it is a local row the merge created but that the
    /// user can already see and edit. Both are preserved. Staging therefore
    /// goes through `stageRemoteDeletePreservingLocal`, never the destructive
    /// `stageDeleteRemovingLocalRecord`.
    private func performRollback(authStore: AuthStore) async {
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
        clientUpgradeRequired = false
        rateLimitedRetryAfter = nil
        crashReporter.addBreadcrumb(.rollbackStarted, metadata: [:])
        defer { isBusy = false }

        current.status = .rollbackPending
        current.updatedAt = Date()
        try? await persistence.saveGuestMergeSession(current)

        let scope = SyncScope(type: .household, id: current.householdId)
        let adapter = InventorySyncAdapter(persistence: persistence)
        do {
            // A prior rollback attempt on this same session can have already
            // soft-deleted some entities while others failed (conflict,
            // rejected, transport error) — re-staging an already-deleted
            // entity is never a correctness problem server-side (the RPC
            // rejects it as `already_deleted`), but it would overwrite this
            // entity's own local `SyncMetadata` back to `.pendingDelete`,
            // making it indistinguishable from a genuine failure by any
            // check that runs afterward. Skip entities this session has
            // already confirmed deleted, so only genuinely outstanding
            // entities are staged and verified on a retry.
            var entityIdsToVerify: [UUID] = []
            for entityId in current.createdEntityIds {
                let existing = try await persistence.metadata(entityType: .inventoryItem, entityId: entityId)
                if existing?.state == .synced, existing?.deletedAt != nil { continue }
                // An earlier attempt's delete mutation may still be queued with
                // its attempt budget spent. `stageInventoryMutation`'s
                // `(.delete, .delete)` branch deliberately reuses an
                // already-queued delete rather than adding a second one — right
                // for ordinary CRUD — but the reused record keeps its
                // `attemptCount`, and `pendingMutations(scope:maxAttempts:)`
                // stops handing an exhausted mutation to the coordinator. Left
                // alone, the attempt after the budget ran out would push
                // nothing, report `rollback_delete_not_applied`, and go on doing
                // so until the rollback window expired — the merge permanently
                // published with no way to withdraw it.
                //
                // An explicit user retry earns a fresh attempt budget, but it
                // must be the **same mutation**, not a replacement. A failed
                // push is ambiguous: the delete may have reached the server,
                // tombstoned the entity and had only its *response* lost. The
                // server's idempotency ledger is keyed on `mutationId`, so
                // re-sending the original id is answered `duplicate` with the
                // original version — which `resolvePending` converges exactly
                // like an `applied`. A fresh id is invisible to that ledger and
                // is judged on its `baseVersion` alone, which is stale precisely
                // because the version bump was in the lost response: the server
                // answers `conflict`, the entity's metadata sticks at
                // `.conflicted`, and the session can never reach `.rolledBack`
                // no matter how often the user retries.
                //
                // Requeueing in place is not expressible through the persistence
                // protocol, so this discards and re-saves the identical
                // mutation, carrying `mutationId`, `baseVersion` and payload
                // over verbatim and resetting only the attempt bookkeeping.
                // Only a `.failed` record is requeued; a `pending`/`inFlight`
                // one is still the coordinator's to finish.
                if let spent = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: entityId),
                   spent.status == .failed {
                    try await persistence.discardPendingMutation(id: spent.mutationId)
                    try await persistence.savePending(PendingMutation(
                        mutationId: spent.mutationId,
                        entityType: spent.entityType,
                        entityId: spent.entityId,
                        scope: spent.scope,
                        operation: spent.operation,
                        baseVersion: spent.baseVersion,
                        payloadData: spent.payloadData,
                        clientUpdatedAt: spent.clientUpdatedAt,
                        createdAt: spent.createdAt,
                        attemptCount: 0,
                        lastAttemptAt: nil,
                        lastErrorCode: nil,
                        status: .pending
                    ))
                    entityIdsToVerify.append(entityId)
                    continue
                }
                let staging = try await adapter.stageRemoteDeletePreservingLocal(entityId: entityId, scope: scope)
                guard case .staged = staging else {
                    // `.cancelled` is the create+delete collapse: staging
                    // removed this entity's pending record *and* its
                    // `SyncMetadata` instead of queueing anything. Nothing will
                    // be pushed, and the retained-tombstone shield that keeps a
                    // later tombstone pull from removing the preserved local row
                    // is gone with it. Fail loudly and stay retryable rather
                    // than verify an entity nothing was staged for.
                    current.status = .completed
                    current.lastErrorCode = "rollback_staging_cancelled"
                    current.updatedAt = Date()
                    try await persistence.saveGuestMergeSession(current)
                    session = current
                    lastErrorMessage = "回滚未完全生效，请重试。"
                    crashReporter.addBreadcrumb(.rollbackFailed, metadata: ["errorCode": "rollback_staging_cancelled"])
                    return
                }
                entityIdsToVerify.append(entityId)
            }
            let configuration = SyncConfiguration(isEnabled: true)
            let provider = AuthStoreCredentialProvider(authStore: authStore)
            let transport = transportFactory(provider)
            let coordinator = SyncCoordinator(configuration: configuration, persistence: persistence, transport: transport)
            let authentication = SyncAuthenticationContext(userID: userId, isAuthenticated: true)
            let outcome = await coordinator.runOnce(authentication: authentication, scopes: [scope])
            guard outcome == .completed else {
                if case .failed(let syncError) = outcome {
                    noteSyncOutcomeForVersionAndRateLimitDisplay(syncError)
                    lastErrorMessage = Self.userFacingSyncError(syncError)
                } else if case .paused(let syncError) = outcome {
                    noteSyncOutcomeForVersionAndRateLimitDisplay(syncError)
                    lastErrorMessage = Self.userFacingSyncError(syncError)
                }
                current.status = .completed // remains rollback-eligible; retry later
                current.lastErrorCode = String(describing: outcome)
                try await persistence.saveGuestMergeSession(current)
                session = current
                crashReporter.addBreadcrumb(.rollbackFailed, metadata: ["errorCode": String(describing: outcome)])
                return
            }
            // `runOnce`'s `.completed` outcome only means the push/pull round
            // trip finished without a transport error — an individual delete
            // can still have come back `conflict`/`rejected` and been
            // resolved without throwing (SyncCoordinator.push ->
            // resolvePending). `pendingMutationForEntity` is the wrong tool
            // here: its underlying query only matches a `pending`/`failed`
            // status record, so a `conflict`/`rejected` result (which
            // `resolvePending` leaves in place with exactly one of those two
            // statuses, never deleting it) would silently read back as "no
            // pending mutation left" — a false success. Only a genuinely
            // *applied* delete moves this entity's own `SyncMetadata` to
            // `.synced` with `deletedAt` set (`resolvePending`'s `.applied`
            // case); `.conflict` leaves it `.conflicted`, `.rejected` leaves
            // it in whatever pre-push state staging produced (`.pendingDelete`,
            // or `.failed` if an earlier attempt had already exhausted its
            // budget) — neither is ever `.synced` with a `deletedAt`. Confirm
            // every entity staged this attempt reached that state before ever
            // reporting `.rolledBack`.
            for entityId in entityIdsToVerify {
                let resultingMetadata = try await persistence.metadata(entityType: .inventoryItem, entityId: entityId)
                let deleteApplied = resultingMetadata?.state == .synced && resultingMetadata?.deletedAt != nil
                if !deleteApplied {
                    current.status = .completed // remains rollback-eligible; retry later
                    current.lastErrorCode = "rollback_delete_not_applied"
                    try await persistence.saveGuestMergeSession(current)
                    session = current
                    lastErrorMessage = "回滚未完全生效，请重试。"
                    return
                }
            }
            current.status = .rolledBack
            current.updatedAt = Date()
            try await persistence.saveGuestMergeSession(current)
            session = current
            crashReporter.addBreadcrumb(.rollbackCompleted, metadata: [:])
        } catch {
            if let syncError = error as? SyncError { noteSyncOutcomeForVersionAndRateLimitDisplay(syncError) }
            current.status = .completed
            current.lastErrorCode = "transport"
            try? await persistence.saveGuestMergeSession(current)
            session = current
            lastErrorMessage = (error as? SyncError).map(Self.userFacingSyncError) ?? "回滚失败，可稍后重试。"
            crashReporter.captureNonFatal(error, context: ["routeCategory": "rollback"])
            crashReporter.addBreadcrumb(.rollbackFailed, metadata: ["errorCode": (error as? SyncError)?.crashReportingCode ?? "unknown_error"])
        }
    }

    // MARK: Manual sync (explicit, user-initiated only — never automatic)

    /// The only way `SyncCoordinator.runOnce` is ever invoked outside of
    /// `confirmMerge`/`rollback` — always in direct response to the user
    /// tapping "立即同步库存". Never called from App startup, sign-in, a
    /// timer, or a background task. Scoped to `.inventoryItem` only, exactly
    /// like every other entry point in this file.
    private func performSyncNow(authStore: AuthStore, householdId: UUID) async {
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
        clientUpgradeRequired = false
        rateLimitedRetryAfter = nil
        lastSyncStartedAt = Date()
        crashReporter.addBreadcrumb(.syncStarted, metadata: [:])
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
            noteSyncOutcomeForVersionAndRateLimitDisplay(error)
            crashReporter.addBreadcrumb(.syncFailed, metadata: ["errorCode": error.crashReportingCode])
        } else if case .paused(let error) = outcome {
            lastSyncErrorMessage = Self.userFacingSyncError(error)
            noteSyncOutcomeForVersionAndRateLimitDisplay(error)
            crashReporter.addBreadcrumb(.syncFailed, metadata: ["errorCode": error.crashReportingCode])
        } else if outcome == .completed {
            crashReporter.addBreadcrumb(.syncCompleted, metadata: [:])
        }
    }

    /// How many inventory mutations are currently staged and not yet
    /// resolved for this household — used only for the status label ("待同步
    /// X 项"), never to decide whether to sync automatically.
    func pendingInventoryCount(householdId: UUID) async -> Int {
        let scope = SyncScope(type: .household, id: householdId)
        return (try? await persistence.pendingMutations(scope: scope, maxAttempts: .max).count) ?? 0
    }

    /// Updates the two Phase 2C-1 display flags from whatever error a sync
    /// call just threw/returned — called in addition to (never instead of)
    /// each call site's existing session-state handling, so this never
    /// changes what a session's own status/pending-mutation state does.
    /// Never touches `session`, `createdEntityIds`, or any SwiftData record;
    /// purely a display-state update.
    private func noteSyncOutcomeForVersionAndRateLimitDisplay(_ error: SyncError) {
        switch error {
        case .clientUpgradeRequired, .clientSchemaUnsupported:
            clientUpgradeRequired = true
            crashReporter.addBreadcrumb(.syncUpgradeRequired, metadata: ["errorCode": "CLIENT_UPGRADE_REQUIRED"])
        case .rateLimited(let retryAfterSeconds):
            rateLimitedRetryAfter = Date().addingTimeInterval(retryAfterSeconds ?? 30)
            crashReporter.addBreadcrumb(.syncRateLimited, metadata: ["errorCode": "SYNC_RATE_LIMITED"])
        default:
            break
        }
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
        case .clientUpgradeRequired, .clientSchemaUnsupported: "当前版本过旧，更新后才能继续使用家庭同步。"
        case .rateLimited: "同步请求过于频繁，请稍后再试。"
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
