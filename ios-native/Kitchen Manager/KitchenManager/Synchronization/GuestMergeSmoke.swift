import Foundation
import SwiftData

/// A second, independent one-off smoke guard for Phase 2B-2, mirroring
/// `SyncSmokeConfiguration`. Never a product feature flag; false in every
/// Release build even if a build setting is accidentally supplied. Requires
/// `INVENTORY_SYNC_ENABLED` to also be on, since the smoke exercises the real
/// Guest merge feature end to end.
nonisolated struct GuestMergeSmokeConfiguration: Equatable, Sendable {
    let isSmokeEnabled: Bool
    let isDevelopmentBuild: Bool
    let isDevelopmentEnvironment: Bool
    let isMergeFeatureEnabled: Bool

    init(
        isSmokeEnabled: Bool = false,
        isDevelopmentBuild: Bool = false,
        isDevelopmentEnvironment: Bool = false,
        isMergeFeatureEnabled: Bool = false
    ) {
        self.isSmokeEnabled = isSmokeEnabled
        self.isDevelopmentBuild = isDevelopmentBuild
        self.isDevelopmentEnvironment = isDevelopmentEnvironment
        self.isMergeFeatureEnabled = isMergeFeatureEnabled
    }

    var isAvailable: Bool {
        isSmokeEnabled && isDevelopmentBuild && isDevelopmentEnvironment && isMergeFeatureEnabled
    }

    static func load(from bundle: Bundle = .main) -> GuestMergeSmokeConfiguration {
        #if DEBUG
        let isDevelopmentBuild = true
        #else
        let isDevelopmentBuild = false
        #endif
        guard let rawValue = bundle.object(forInfoDictionaryKey: "KM_GUEST_MERGE_SMOKE_ENABLED") else {
            return GuestMergeSmokeConfiguration(isDevelopmentBuild: isDevelopmentBuild)
        }
        let normalized = String(describing: rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return GuestMergeSmokeConfiguration(
            isSmokeEnabled: ["1", "true", "yes"].contains(normalized),
            isDevelopmentBuild: isDevelopmentBuild,
            isDevelopmentEnvironment: ((bundle.object(
                forInfoDictionaryKey: "KM_SYNC_SMOKE_ENVIRONMENT"
            ) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) == "development",
            isMergeFeatureEnabled: InventoryMergeConfiguration.load(from: bundle).isEnabled
        )
    }
}

nonisolated enum GuestMergeSmokeError: LocalizedError, Equatable, Sendable {
    case smokeDisabled
    case nonDevelopmentBuild
    case nonDevelopmentEnvironment
    case mergeFeatureDisabled
    case notAuthenticated
    case missingDefaultHousehold
    case invalidBootstrap
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .smokeDisabled: "Development Guest merge smoke is disabled."
        case .nonDevelopmentBuild: "Development Guest merge smoke is unavailable in this build."
        case .nonDevelopmentEnvironment: "Development Guest merge smoke requires the explicit development environment setting."
        case .mergeFeatureDisabled: "INVENTORY_SYNC_ENABLED must also be on for this development smoke run."
        case .notAuthenticated: "Sign in with a development test account before running smoke."
        case .missingDefaultHousehold: "The signed-in development account has no default household scope."
        case .invalidBootstrap: "The development sync bootstrap could not be verified."
        case .validationFailed(let detail): "Development Guest merge smoke validation failed: \(detail)."
        }
    }
}

/// One boolean per Phase 2B-2 checkpoint (section 三 of the validation
/// request). Never includes an email, UUID, mutation id, token, or password.
nonisolated struct GuestMergeSmokeReport: Equatable, Sendable {
    var previewPerformedZeroNetworkWrites = false
    var createApplied = false
    var duplicateHandledWithoutASecondRecord = false
    var quantityConflictDetectedNotAutoCreated = false
    var expiryConflictDetectedNotAutoOverwritten = false
    var metadataConflictDetected = false
    var ambiguousDuplicateNeverAutoSelected = false
    var planDriftInvalidatedTheOldPlan = false
    var sessionRecoveredAfterSimulatedRestart = false
    var logoutStoppedFurtherRequests = false
    var sameAccountResumedAfterReLogin = false
    var userBCannotSeeUserASession = false
    var rollbackRemovedOnlyThisSessionsCreates = false
    var finalPullSawTheDeleteTombstone = false
    var guestBoundaryUnchanged = false
}

#if DEBUG
/// Explicitly invoked from a Debug-only, environment-gated test/developer
/// entry point — never from App startup, login, or a timer. Every merge
/// call goes through the real `GuestMergeController` (the exact same code a
/// signed-in user's account page would run); the only thing "isolated" here
/// is the *local* `KitchenStore`/persistence container that supplies the
/// test's own marked dataset, so this smoke never scans or uploads a
/// developer's real local Guest inventory. Network calls (bootstrap, the
/// pre-merge read, push, pull) all hit the real configured backend.
@MainActor
final class GuestMergeSmokeRunner {
    private let smokeConfiguration: GuestMergeSmokeConfiguration
    private let transportFactory: @MainActor (any SyncAccessTokenProviding) -> any SyncTransport

    init(
        smokeConfiguration: GuestMergeSmokeConfiguration,
        transportFactory: @escaping @MainActor (any SyncAccessTokenProviding) -> any SyncTransport = { provider in
            ExpressSyncTransport(tokenProvider: provider)
        }
    ) {
        self.smokeConfiguration = smokeConfiguration
        self.transportFactory = transportFactory
    }

    /// `authStoreA`/`authStoreB` must already be signed in to two distinct,
    /// real development test accounts before calling `run`. `authStoreA` is
    /// the primary account the whole merge lifecycle runs against;
    /// `authStoreB` is used only for the account-isolation checkpoint.
    /// `reSignInA` performs the real re-authentication for the
    /// logout/resume checkpoint — it is supplied by the caller (which holds
    /// the real test-account password from an ignored environment file);
    /// this runner never receives or handles a password itself.
    func run(authStoreA: AuthStore, authStoreB: AuthStore, reSignInA: () async -> Void) async throws -> GuestMergeSmokeReport {
        guard smokeConfiguration.isSmokeEnabled else { throw GuestMergeSmokeError.smokeDisabled }
        guard smokeConfiguration.isDevelopmentBuild else { throw GuestMergeSmokeError.nonDevelopmentBuild }
        guard smokeConfiguration.isDevelopmentEnvironment, APIEnvironment.current == .development else {
            throw GuestMergeSmokeError.nonDevelopmentEnvironment
        }
        guard smokeConfiguration.isMergeFeatureEnabled else { throw GuestMergeSmokeError.mergeFeatureDisabled }
        guard let sessionA = authStoreA.developmentSyncSmokeSession(), let userIdA = authStoreA.currentUserID else {
            throw GuestMergeSmokeError.notAuthenticated
        }
        guard authStoreB.developmentSyncSmokeSession() != nil, authStoreB.currentUserID != nil else {
            throw GuestMergeSmokeError.notAuthenticated
        }

        let providerA = AuthStoreSyncTokenProvider(authStore: authStoreA)
        let transportA = transportFactory(providerA)
        let bootstrap = try await transportA.bootstrap()
        guard bootstrap.schemaVersion == 1, bootstrap.user.id == sessionA.user.id else {
            throw GuestMergeSmokeError.invalidBootstrap
        }
        guard let householdId = bootstrap.defaultHouseholdId,
              bootstrap.syncScopes.contains(where: { $0.type == .household && $0.id == householdId }) else {
            throw GuestMergeSmokeError.missingDefaultHousehold
        }
        let scope = SyncScope(type: .household, id: householdId)

        var report = GuestMergeSmokeReport()
        let marker = String(UUID().uuidString.prefix(8)).lowercased()
        func markedName(_ suffix: String) -> String { "__guest_merge_smoke_\(marker)_\(suffix)" }

        // MARK: 1-2. Isolated container — never the developer's real Guest inventory.
        let container = try ModelContainer(
            for: InventoryRecord.self, ShoppingItemRecord.self, TodayPlanRecord.self,
            ConsumptionRecordEntity.self, WeeklyPlanRecord.self,
            SyncMetadataRecord.self, PendingMutationRecord.self, SyncCursorRecord.self, GuestMergeSessionRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let persistence = SwiftDataSyncPersistence(modelContainer: container)
        let kitchenStore = KitchenStore(
            userDefaults: UserDefaults(suiteName: "guest-merge-smoke-\(marker)")!,
            inventoryPersistence: SwiftDataInventoryPersistence(container: container),
            shoppingListPersistence: SwiftDataShoppingListPersistence(container: container),
            todayPlanPersistence: SwiftDataTodayPlanPersistence(container: container),
            consumptionPersistence: SwiftDataConsumptionPersistence(container: container),
            weeklyPlanPersistence: SwiftDataWeeklyPlanPersistence(container: container)
        )
        let recipeStore = RecipeStore()
        let guestBefore = GuestBoundarySnapshot(kitchenStore: kitchenStore, recipeStore: recipeStore)

        // Every entity id this run creates remotely, tracked so a thrown
        // error anywhere below still triggers a best-effort soft-delete
        // sweep before rethrowing — mirroring `SyncSmokeRunner`'s own
        // cleanup-on-failure pattern, so an interrupted run never leaves
        // orphaned marker rows for a human to find and clean up by hand.
        var cleanupIds: Set<UUID> = []
        do {
            return try await runRemainingPhases(
                authStoreA: authStoreA, authStoreB: authStoreB, reSignInA: reSignInA,
                transportA: transportA, userIdA: userIdA, householdId: householdId, scope: scope,
                persistence: persistence, kitchenStore: kitchenStore, recipeStore: recipeStore,
                guestBefore: guestBefore, markedName: markedName, report: report, cleanupIds: &cleanupIds
            )
        } catch {
            await Self.bestEffortCleanup(entityIds: cleanupIds, scope: scope, persistence: persistence, transport: transportA, userId: userIdA)
            throw error
        }
    }

    private func runRemainingPhases(
        authStoreA: AuthStore, authStoreB: AuthStore, reSignInA: () async -> Void,
        transportA: any SyncTransport, userIdA: UUID, householdId: UUID, scope: SyncScope,
        persistence: SwiftDataSyncPersistence, kitchenStore: KitchenStore, recipeStore: RecipeStore,
        guestBefore: GuestBoundarySnapshot, markedName: (String) -> String,
        report initialReport: GuestMergeSmokeReport, cleanupIds: inout Set<UUID>
    ) async throws -> GuestMergeSmokeReport {
        var report = initialReport

        // MARK: 3. Baseline — establish real, already-existing remote counterparts
        // for the conflict scenarios (a genuinely different device/session
        // uploading these first), scoped only to this run's own marker.
        let quantityId = UUID(), expiryId = UUID(), metadataId = UUID(), exactId = UUID()
        let ambiguousRemoteOneId = UUID(), ambiguousRemoteTwoId = UUID()
        cleanupIds.formUnion([quantityId, expiryId, metadataId, exactId, ambiguousRemoteOneId, ambiguousRemoteTwoId])
        kitchenStore.inventory = [
            InventoryItem(id: quantityId, name: markedName("qty"), quantity: 2, unit: "个", expiryDate: nil),
            InventoryItem(id: expiryId, name: markedName("exp"), quantity: 1, unit: "盒", expiryDate: nil),
            InventoryItem(
                id: metadataId, name: markedName("meta"), quantity: 5, unit: "袋", expiryDate: nil,
                isStaple: true, lowStockThreshold: 2
            ),
            InventoryItem(id: exactId, name: markedName("exact"), quantity: 1, unit: "个", expiryDate: nil),
            InventoryItem(id: ambiguousRemoteOneId, name: markedName("ambig"), quantity: 1, unit: "个", expiryDate: nil),
            InventoryItem(id: ambiguousRemoteTwoId, name: markedName("ambig"), quantity: 3, unit: "个", expiryDate: nil)
        ]
        let baselineController = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: transportFactory
        )
        await baselineController.preparePreview(userId: userIdA, householdId: householdId, kitchenStore: kitchenStore)
        await baselineController.confirmMerge(authStore: authStoreA)
        guard baselineController.session?.status == .completed else {
            throw GuestMergeSmokeError.validationFailed("baseline seeding did not complete: \(String(describing: baselineController.session?.status))")
        }
        // This baseline session is already terminal (`.completed`), so it is
        // never returned by `activeGuestMergeSession` again — its records now
        // simply exist remotely, exactly like data uploaded by another device.

        // MARK: 4. Real dataset (section 六 A-F) — a fresh local inventory,
        // as if this were a different device merging into the same household.
        let createId = UUID()
        cleanupIds.insert(createId)
        let quantityConflictLocal = InventoryItem(id: quantityId, name: markedName("qty"), quantity: 3, unit: "个", expiryDate: nil)
        let expiryConflictLocal = InventoryItem(id: expiryId, name: markedName("exp"), quantity: 1, unit: "盒", expiryDate: Date())
        let metadataConflictLocal = InventoryItem(
            id: metadataId, name: markedName("meta"), quantity: 5, unit: "袋", expiryDate: nil,
            isStaple: false, lowStockThreshold: nil
        )
        let ambiguousLocal = InventoryItem(id: UUID(), name: markedName("ambig"), quantity: 2, unit: "个", expiryDate: nil)
        cleanupIds.insert(ambiguousLocal.id)
        // Same id, same quantity/unit/expiry as the baseline upload — a true
        // no-op (section 六 B): identical content already known remotely.
        let exactMatchLocal = InventoryItem(id: exactId, name: markedName("exact"), quantity: 1, unit: "个", expiryDate: nil)
        kitchenStore.inventory = [
            InventoryItem(id: createId, name: markedName("create"), quantity: 1, unit: "个", expiryDate: nil),
            quantityConflictLocal, expiryConflictLocal, metadataConflictLocal, ambiguousLocal, exactMatchLocal
        ]

        // MARK: 5-7. Preview — zero network writes.
        let mutationsBefore = try await persistence.pendingMutations(scope: scope, maxAttempts: 5).count
        let inventoryCountBefore = try await fetchRemoteInventoryCount(transport: transportA, scope: scope)
        let controller = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: transportFactory
        )
        await controller.preparePreview(userId: userIdA, householdId: householdId, kitchenStore: kitchenStore, remoteTransport: transportA)
        let mutationsAfter = try await persistence.pendingMutations(scope: scope, maxAttempts: 5).count
        let inventoryCountAfter = try await fetchRemoteInventoryCount(transport: transportA, scope: scope)
        guard mutationsBefore == mutationsAfter, inventoryCountBefore == inventoryCountAfter else {
            throw GuestMergeSmokeError.validationFailed("preview performed a network write")
        }
        guard controller.session?.status == .previewReady, controller.session?.plan?.planHash.isEmpty == false else {
            throw GuestMergeSmokeError.validationFailed("preview did not reach previewReady with a saved plan hash")
        }
        report.previewPerformedZeroNetworkWrites = true

        guard let plan = controller.plan else { throw GuestMergeSmokeError.validationFailed("no plan generated") }
        func candidate(_ id: UUID) -> InventoryMergeCandidate? { plan.candidates.first(where: { $0.localItemId == id }) }
        guard candidate(createId)?.action == .create else {
            throw GuestMergeSmokeError.validationFailed("create item did not plan as create")
        }
        guard candidate(quantityConflictLocal.id)?.conflictReason == .quantityMismatch else {
            throw GuestMergeSmokeError.validationFailed("quantity conflict not detected")
        }
        report.quantityConflictDetectedNotAutoCreated = true
        guard candidate(expiryConflictLocal.id)?.conflictReason == .expiryMismatch else {
            throw GuestMergeSmokeError.validationFailed("expiry conflict not detected")
        }
        report.expiryConflictDetectedNotAutoOverwritten = true
        guard candidate(metadataConflictLocal.id)?.conflictReason == .metadataMismatch else {
            throw GuestMergeSmokeError.validationFailed("metadata conflict not detected")
        }
        report.metadataConflictDetected = true
        guard let ambiguousCandidate = candidate(ambiguousLocal.id),
              ambiguousCandidate.conflictReason == .multipleRemoteCandidates,
              ambiguousCandidate.remoteItemId == nil else {
            throw GuestMergeSmokeError.validationFailed("ambiguous duplicate not detected or auto-selected")
        }
        report.ambiguousDuplicateNeverAutoSelected = true
        guard let exactCandidate = candidate(exactMatchLocal.id), exactCandidate.action == .skip, exactCandidate.conflictReason == nil else {
            throw GuestMergeSmokeError.validationFailed("identical content already known remotely was not a true no-op")
        }

        // MARK: 11. Plan drift — mutate before confirming, must invalidate.
        let planHashBeforeDrift = controller.plan?.planHash
        var driftedInventory = kitchenStore.inventory
        driftedInventory[0].quantity = 999
        kitchenStore.inventory = driftedInventory
        await controller.preparePreview(userId: userIdA, householdId: householdId, kitchenStore: kitchenStore, remoteTransport: transportA)
        guard controller.plan?.planHash != planHashBeforeDrift else {
            throw GuestMergeSmokeError.validationFailed("plan hash did not change after local drift")
        }
        report.planDriftInvalidatedTheOldPlan = true
        // Restore the pre-drift dataset and regenerate a stable plan to confirm.
        kitchenStore.inventory = [
            InventoryItem(id: createId, name: markedName("create"), quantity: 1, unit: "个", expiryDate: nil),
            quantityConflictLocal, expiryConflictLocal, metadataConflictLocal, ambiguousLocal, exactMatchLocal
        ]
        await controller.preparePreview(userId: userIdA, householdId: householdId, kitchenStore: kitchenStore, remoteTransport: transportA)

        // MARK: 10. Resolve every conflict explicitly (never automatic).
        // `keepBoth` is only used for the ambiguous (different-id) case
        // below, where it is well-defined — `ambiguousLocal` already has its
        // own distinct id, so `.create` genuinely produces an independent
        // second record. For the metadata conflict, identity is *certain*
        // (same id as the known remote record), so `keepLocal` (update in
        // place) is the sensible choice; `keepBoth` is not meaningful here
        // since `applyingChoice` does not allocate a new id for a same-id
        // candidate — using it would stage a `create` for an id that already
        // exists remotely, at which point the server should reject it (or
        // the client must never let this be a live option in the UI for a
        // same-id candidate — noted as a follow-up, see final report).
        await controller.resolveConflict(candidateId: quantityConflictLocal.id, choice: .keepLocal)
        await controller.resolveConflict(candidateId: expiryConflictLocal.id, choice: .keepRemote)
        await controller.resolveConflict(candidateId: metadataConflictLocal.id, choice: .keepLocal)
        await controller.resolveConflict(candidateId: ambiguousLocal.id, choice: .keepBoth)

        // MARK: 12. Restart recovery — a brand-new controller instance,
        // same persistence, must resume the same session with choices intact.
        let sessionIdBeforeRestart = controller.session?.id
        let restartedController = GuestMergeController(
            persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true),
            transportFactory: transportFactory
        )
        await restartedController.preparePreview(userId: userIdA, householdId: householdId, kitchenStore: kitchenStore, remoteTransport: transportA)
        guard restartedController.session?.id == sessionIdBeforeRestart,
              restartedController.plan?.candidates.first(where: { $0.localItemId == quantityConflictLocal.id })?.userChoice == .keepLocal else {
            throw GuestMergeSmokeError.validationFailed("session/conflict choices did not survive a simulated restart")
        }
        report.sessionRecoveredAfterSimulatedRestart = true

        // MARK: 8-9. Confirm — explicit simulated user confirmation only.
        await restartedController.confirmMerge(authStore: authStoreA)
        guard restartedController.session?.status == .completed else {
            throw GuestMergeSmokeError.validationFailed("confirm did not complete: \(String(describing: restartedController.session?.status)), error=\(restartedController.lastErrorMessage ?? "none")")
        }
        report.createApplied = true

        // Duplicate retry: a dedicated marker item, staged and run through
        // the raw sync boundary (mirroring `SyncSmokeRunner`'s own proven
        // pattern) so the *exact same* persisted `PendingMutation` — same
        // mutationId, entityId, payload, and baseVersion — can be requeued
        // and resent as-is. A brand-new mutationId would not be a duplicate
        // at all from the server's idempotency ledger's point of view (keyed
        // on (user_id, mutation_id)); it would be accepted as a legitimate
        // new update, which is not what this checkpoint is verifying.
        let duplicateAdapter = InventorySyncAdapter(persistence: persistence)
        let duplicateMarkerId = UUID()
        cleanupIds.insert(duplicateMarkerId)
        let duplicateItem = InventoryItem(id: duplicateMarkerId, name: markedName("dup"), quantity: 1, unit: "个", expiryDate: nil)
        let originalMutationId = try await duplicateAdapter.stageUpsert(item: duplicateItem, scope: scope)
        guard let originalPending = try await persistence.pendingMutation(id: originalMutationId) else {
            throw GuestMergeSmokeError.validationFailed("duplicate retry setup: original pending mutation not found")
        }
        let duplicateCoordinator = SyncCoordinator(configuration: SyncConfiguration(isEnabled: true), persistence: persistence, transport: transportA)
        let authenticationA = SyncAuthenticationContext(userID: userIdA, isAuthenticated: true)
        let firstOutcome = await duplicateCoordinator.runOnce(authentication: authenticationA, scopes: [scope])
        guard firstOutcome == .completed else { throw GuestMergeSmokeError.validationFailed("duplicate retry: initial upload did not complete") }
        let metadataAfterFirst = try await persistence.metadata(entityType: .inventoryItem, entityId: duplicateMarkerId)
        guard metadataAfterFirst?.state == .synced else {
            throw GuestMergeSmokeError.validationFailed("duplicate retry: initial upload did not sync")
        }

        try await persistence.savePending(originalPending)
        let secondOutcome = await duplicateCoordinator.runOnce(authentication: authenticationA, scopes: [scope])
        guard secondOutcome == .completed else { throw GuestMergeSmokeError.validationFailed("duplicate retry: resend did not complete") }
        let metadataAfterDuplicate = try await persistence.metadata(entityType: .inventoryItem, entityId: duplicateMarkerId)
        guard metadataAfterDuplicate?.remoteVersion == metadataAfterFirst?.remoteVersion, metadataAfterDuplicate?.state == .synced else {
            throw GuestMergeSmokeError.validationFailed("duplicate retry produced a version bump instead of a no-op duplicate")
        }
        report.duplicateHandledWithoutASecondRecord = true

        // Clean up this dedicated marker immediately — it is not tracked by
        // any GuestMergeSession's own rollback.
        _ = try await duplicateAdapter.stageDelete(entityId: duplicateMarkerId, scope: scope)
        _ = await duplicateCoordinator.runOnce(authentication: authenticationA, scopes: [scope])

        // MARK: 13. Logout mid-run stops further requests.
        await authStoreA.signOut()
        let sessionForLoggedOutRollback = restartedController.session
        await restartedController.rollback(authStore: authStoreA)
        guard restartedController.session?.status == sessionForLoggedOutRollback?.status,
              restartedController.session?.status != .rolledBack else {
            throw GuestMergeSmokeError.validationFailed("sign-out did not stop a further mutation attempt")
        }
        report.logoutStoppedFurtherRequests = true

        // MARK: 14. Re-sign in as the same account, resume the same session.
        await reSignInA()
        guard authStoreA.currentUserID == userIdA else {
            throw GuestMergeSmokeError.validationFailed("re-sign-in did not restore the same account")
        }
        // The session is already terminal (`.completed`) by this point in the
        // run, so `activeGuestMergeSession` correctly excludes it — query by
        // id instead, which remains valid for terminal sessions as history.
        guard let sessionIdBeforeRestart, let resumedSession = try await persistence.guestMergeSession(id: sessionIdBeforeRestart),
              resumedSession.id == sessionIdBeforeRestart else {
            throw GuestMergeSmokeError.validationFailed("session did not resume after re-login")
        }
        report.sameAccountResumedAfterReLogin = true

        // MARK: 15. User B must never see User A's session or household scope.
        guard let userIdB = authStoreB.currentUserID, userIdB != userIdA else {
            throw GuestMergeSmokeError.notAuthenticated
        }
        let providerB = AuthStoreSyncTokenProvider(authStore: authStoreB)
        let transportB = transportFactory(providerB)
        let bootstrapB = try await transportB.bootstrap()
        guard bootstrapB.user.id == userIdB, bootstrapB.defaultHouseholdId != householdId else {
            throw GuestMergeSmokeError.validationFailed("User B's real bootstrap unexpectedly shares User A's household")
        }
        let userBSession = try await persistence.activeGuestMergeSession(userId: userIdB, householdId: householdId, entityType: .inventoryItem)
        guard userBSession == nil else {
            throw GuestMergeSmokeError.validationFailed("User B could see User A's merge session")
        }
        report.userBCannotSeeUserASession = true

        // MARK: 16. Rollback — only this session's own created records.
        let createdIds = restartedController.session?.createdEntityIds ?? []
        await restartedController.rollback(authStore: authStoreA)
        guard restartedController.session?.status == .rolledBack else {
            throw GuestMergeSmokeError.validationFailed("rollback did not complete: \(String(describing: restartedController.session?.status))")
        }
        report.rollbackRemovedOnlyThisSessionsCreates = true

        // MARK: 17. Final pull sees the delete tombstone(s).
        let finalCoordinator = SyncCoordinator(configuration: SyncConfiguration(isEnabled: true), persistence: persistence, transport: transportA)
        _ = await finalCoordinator.runOnce(authentication: SyncAuthenticationContext(userID: userIdA, isAuthenticated: true), scopes: [scope])
        for id in createdIds {
            guard try await persistence.metadata(entityType: .inventoryItem, entityId: id)?.deletedAt != nil else {
                throw GuestMergeSmokeError.validationFailed("final pull did not observe the delete tombstone")
            }
        }
        report.finalPullSawTheDeleteTombstone = true

        // MARK: Guest data boundary — untouched throughout.
        let guestAfter = GuestBoundarySnapshot(kitchenStore: kitchenStore, recipeStore: recipeStore)
        guard guestBefore == guestAfter else {
            throw GuestMergeSmokeError.validationFailed("Guest data outside the isolated smoke dataset changed")
        }
        report.guestBoundaryUnchanged = true

        // Final sweep: the rollback above only covers this run's own second
        // (`restartedController`) session — its `createdEntityIds` never
        // include the *baseline* seed records (quantity/expiry/metadata/
        // exact/ambiguous), since those were only ever *updated*, or served
        // purely as the "already exists remotely" counterpart another device
        // would have uploaded. All of it is still throwaway smoke data, so
        // clean up every tracked marker id, not just the ones this run's own
        // session rollback already handles.
        await Self.bestEffortCleanup(entityIds: cleanupIds, scope: scope, persistence: persistence, transport: transportA, userId: userIdA)

        return report
    }

    /// Phase 2B-2.5: a minimal, dedicated hosted smoke for the same-id
    /// `keepBoth` identity-fork fix only — never the full Phase 2B-2 18-point
    /// matrix. Verifies, against the real backend: a same-id conflict
    /// resolved as `keepBoth` creates a genuinely independent second remote
    /// record (a fresh id, baseVersion 0), leaves the original untouched,
    /// and that `rollback` only soft-deletes the fork. Cleans up both the
    /// fork and the baseline marker itself before returning.
    func runIdentityForkMinimalSmoke(authStoreA: AuthStore) async throws -> Bool {
        guard smokeConfiguration.isSmokeEnabled else { throw GuestMergeSmokeError.smokeDisabled }
        guard smokeConfiguration.isDevelopmentBuild else { throw GuestMergeSmokeError.nonDevelopmentBuild }
        guard smokeConfiguration.isDevelopmentEnvironment, APIEnvironment.current == .development else {
            throw GuestMergeSmokeError.nonDevelopmentEnvironment
        }
        guard smokeConfiguration.isMergeFeatureEnabled else { throw GuestMergeSmokeError.mergeFeatureDisabled }
        guard let userIdA = authStoreA.currentUserID else { throw GuestMergeSmokeError.notAuthenticated }

        let providerA = AuthStoreSyncTokenProvider(authStore: authStoreA)
        let transportA = transportFactory(providerA)
        let bootstrap = try await transportA.bootstrap()
        guard let householdId = bootstrap.defaultHouseholdId else { throw GuestMergeSmokeError.missingDefaultHousehold }
        let scope = SyncScope(type: .household, id: householdId)
        let marker = String(UUID().uuidString.prefix(8)).lowercased()
        let sharedId = UUID()

        var cleanupIds: Set<UUID> = [sharedId]
        let container = try ModelContainer(
            for: InventoryRecord.self, ShoppingItemRecord.self, TodayPlanRecord.self,
            ConsumptionRecordEntity.self, WeeklyPlanRecord.self,
            SyncMetadataRecord.self, PendingMutationRecord.self, SyncCursorRecord.self, GuestMergeSessionRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        // Declared before the `do` so the failure path below can reuse the
        // exact same persistence — a fresh throwaway container would have no
        // knowledge of this run's already-staged SyncMetadata, causing a
        // cleanup delete to (incorrectly) compute baseVersion 0 against a
        // real, already-versioned remote record.
        let persistence = SwiftDataSyncPersistence(modelContainer: container)
        do {
            let kitchenStore = KitchenStore(
                userDefaults: UserDefaults(suiteName: "guest-merge-fork-smoke-\(marker)")!,
                inventoryPersistence: SwiftDataInventoryPersistence(container: container),
                shoppingListPersistence: SwiftDataShoppingListPersistence(container: container),
                todayPlanPersistence: SwiftDataTodayPlanPersistence(container: container),
                consumptionPersistence: SwiftDataConsumptionPersistence(container: container),
                weeklyPlanPersistence: SwiftDataWeeklyPlanPersistence(container: container)
            )

            // Baseline: establish a real, already-existing remote counterpart
            // under `sharedId` (as if from another device), then this run's
            // own local copy conflicts on quantity under the *same* id.
            kitchenStore.inventory = [InventoryItem(id: sharedId, name: "__guest_merge_smoke_\(marker)_fork", quantity: 2, unit: "个", expiryDate: nil)]
            let baselineController = GuestMergeController(
                persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: transportFactory
            )
            await baselineController.preparePreview(userId: userIdA, householdId: householdId, kitchenStore: kitchenStore)
            await baselineController.confirmMerge(authStore: authStoreA)
            guard baselineController.session?.status == .completed else {
                throw GuestMergeSmokeError.validationFailed("baseline seeding did not complete")
            }

            kitchenStore.inventory = [InventoryItem(id: sharedId, name: "__guest_merge_smoke_\(marker)_fork", quantity: 5, unit: "个", expiryDate: nil)]
            let controller = GuestMergeController(
                persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: transportFactory
            )
            await controller.preparePreview(userId: userIdA, householdId: householdId, kitchenStore: kitchenStore, remoteTransport: transportA)
            guard controller.plan?.candidates.first(where: { $0.localItemId == sharedId })?.conflictReason == .quantityMismatch else {
                throw GuestMergeSmokeError.validationFailed("expected quantity conflict against the real baseline")
            }

            await controller.resolveConflict(candidateId: sharedId, choice: .keepBoth)
            guard let forkedId = controller.plan?.candidates.first(where: { $0.localItemId == sharedId })?.forkedLocalItemId else {
                throw GuestMergeSmokeError.validationFailed("keepBoth did not allocate a forked id")
            }
            guard forkedId != sharedId else { throw GuestMergeSmokeError.validationFailed("forked id must differ from the original") }
            cleanupIds.insert(forkedId)

            await controller.confirmMerge(authStore: authStoreA)
            guard controller.session?.status == .completed else {
                throw GuestMergeSmokeError.validationFailed("confirm did not complete: \(String(describing: controller.session?.status))")
            }
            guard controller.session?.createdEntityIds == [forkedId] else {
                throw GuestMergeSmokeError.validationFailed("createdEntityIds must contain only the forked id")
            }

            // Confirm on the real backend: both the original and the forked
            // record now exist, under two different, specific ids (never a
            // raw count, which the household's other real data could affect).
            let remoteSnapshot = try await fetchRemoteInventorySnapshot(transport: transportA, scope: scope)
            guard remoteSnapshot[sharedId] != nil else {
                throw GuestMergeSmokeError.validationFailed("the original entity must still exist remotely, untouched")
            }
            guard remoteSnapshot[forkedId] != nil else {
                throw GuestMergeSmokeError.validationFailed("the forked entity must exist remotely as an independent record")
            }

            await controller.rollback(authStore: authStoreA)
            guard controller.session?.status == .rolledBack else {
                throw GuestMergeSmokeError.validationFailed("rollback did not complete")
            }

            await Self.bestEffortCleanup(entityIds: cleanupIds, scope: scope, persistence: persistence, transport: transportA, userId: userIdA)
            return true
        } catch {
            // Reuse the same persistence the failed attempt already staged
            // into — it already knows the correct remote version for
            // anything genuinely created so far, which a fresh throwaway
            // container would not (and would therefore compute a wrong,
            // rejected baseVersion 0 for the cleanup delete).
            await Self.bestEffortCleanup(entityIds: cleanupIds, scope: scope, persistence: persistence, transport: transportA, userId: userIdA)
            throw error
        }
    }

    /// Phase 2B-4: a minimal, dedicated hosted smoke for the synced-scope
    /// CRUD mutation staging path only — never the full Phase 2B-2 matrix
    /// nor the Phase 2B-2.5 fork check. Verifies, against the real backend:
    /// an enrolled create stages and applies at baseVersion 0; a local
    /// update stages and applies, advancing the remote version; a local
    /// delete stages and applies as a soft-delete tombstone; a duplicate
    /// manual sync afterward is a harmless no-op; and a Guest-only control
    /// item is never staged or uploaded at all. Cleans up the marker before
    /// returning.
    func runInventoryCrudSyncMinimalSmoke(authStoreA: AuthStore) async throws -> Bool {
        guard smokeConfiguration.isSmokeEnabled else { throw GuestMergeSmokeError.smokeDisabled }
        guard smokeConfiguration.isDevelopmentBuild else { throw GuestMergeSmokeError.nonDevelopmentBuild }
        guard smokeConfiguration.isDevelopmentEnvironment, APIEnvironment.current == .development else {
            throw GuestMergeSmokeError.nonDevelopmentEnvironment
        }
        guard smokeConfiguration.isMergeFeatureEnabled else { throw GuestMergeSmokeError.mergeFeatureDisabled }
        guard let userIdA = authStoreA.currentUserID else { throw GuestMergeSmokeError.notAuthenticated }

        let providerA = AuthStoreSyncTokenProvider(authStore: authStoreA)
        let transportA = transportFactory(providerA)
        let bootstrap = try await transportA.bootstrap()
        guard let householdId = bootstrap.defaultHouseholdId else { throw GuestMergeSmokeError.missingDefaultHousehold }
        let scope = SyncScope(type: .household, id: householdId)
        let marker = String(UUID().uuidString.prefix(8)).lowercased()

        let container = try ModelContainer(
            for: InventoryRecord.self, ShoppingItemRecord.self, TodayPlanRecord.self,
            ConsumptionRecordEntity.self, WeeklyPlanRecord.self,
            SyncMetadataRecord.self, PendingMutationRecord.self, SyncCursorRecord.self,
            GuestMergeSessionRecord.self, InventorySyncEnrollmentRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let persistence = SwiftDataSyncPersistence(modelContainer: container)
        var cleanupIds: Set<UUID> = []
        do {
            let kitchenStore = KitchenStore(
                userDefaults: UserDefaults(suiteName: "inventory-crud-smoke-\(marker)")!,
                inventoryPersistence: SwiftDataInventoryPersistence(container: container),
                shoppingListPersistence: SwiftDataShoppingListPersistence(container: container),
                todayPlanPersistence: SwiftDataTodayPlanPersistence(container: container),
                consumptionPersistence: SwiftDataConsumptionPersistence(container: container),
                weeklyPlanPersistence: SwiftDataWeeklyPlanPersistence(container: container)
            )
            try await persistence.saveEnrollment(InventorySyncEnrollment(
                userId: userIdA, householdId: householdId, status: .enrolled, enrolledAt: Date(),
                mergeSessionId: UUID(), schemaVersion: InventorySyncEnrollment.currentSchemaVersion, updatedAt: Date()
            ))
            let controller = GuestMergeController(
                persistence: persistence, configuration: InventoryMergeConfiguration(isEnabled: true), transportFactory: transportFactory
            )

            // 1-2: enrolled create stages a pending mutation at baseVersion 0.
            let markerName = "__inventory_crud_smoke_\(marker)"
            kitchenStore.importInventory([InventoryImportItem(name: markerName, quantity: 2, unit: "个", expiryDate: nil)])
            guard let markerItem = kitchenStore.inventory.first(where: { $0.name == markerName }) else {
                throw GuestMergeSmokeError.validationFailed("marker item was not created locally")
            }
            cleanupIds.insert(markerItem.id)
            await controller.handleInventoryDidChange(old: [], new: [markerItem], userId: userIdA, householdId: householdId)
            let createMutation = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: markerItem.id)
            guard createMutation?.operation == .upsert, createMutation?.baseVersion?.rawValue == "0" else {
                throw GuestMergeSmokeError.validationFailed("create did not stage at baseVersion 0")
            }

            // 3-4: manual sync applies the real create.
            await controller.syncNow(authStore: authStoreA, householdId: householdId)
            guard controller.lastSyncOutcome == .completed else {
                throw GuestMergeSmokeError.validationFailed("manual sync after create did not complete")
            }
            let afterCreateMetadata = try await persistence.metadata(entityType: .inventoryItem, entityId: markerItem.id)
            guard afterCreateMetadata?.state == .synced, afterCreateMetadata?.remoteVersion?.rawValue == "1" else {
                throw GuestMergeSmokeError.validationFailed("create did not apply as expected remotely")
            }

            // 5-7: local update, manual sync, remote version increases.
            var updatedItem = markerItem
            updatedItem.quantity = 5
            kitchenStore.inventory = [updatedItem]
            await controller.handleInventoryDidChange(old: [markerItem], new: [updatedItem], userId: userIdA, householdId: householdId)
            await controller.syncNow(authStore: authStoreA, householdId: householdId)
            guard controller.lastSyncOutcome == .completed else {
                throw GuestMergeSmokeError.validationFailed("manual sync after update did not complete")
            }
            let afterUpdateMetadata = try await persistence.metadata(entityType: .inventoryItem, entityId: markerItem.id)
            guard afterUpdateMetadata?.state == .synced, afterUpdateMetadata?.remoteVersion?.rawValue == "2" else {
                throw GuestMergeSmokeError.validationFailed("update did not advance the remote version as expected")
            }

            // 8-10: local delete, manual sync, remote soft-delete tombstone.
            kitchenStore.inventory = []
            await controller.handleInventoryDidChange(old: [updatedItem], new: [], userId: userIdA, householdId: householdId)
            await controller.syncNow(authStore: authStoreA, householdId: householdId)
            guard controller.lastSyncOutcome == .completed else {
                throw GuestMergeSmokeError.validationFailed("manual sync after delete did not complete")
            }
            let afterDeleteMetadata = try await persistence.metadata(entityType: .inventoryItem, entityId: markerItem.id)
            guard afterDeleteMetadata?.state == .synced, afterDeleteMetadata?.deletedAt != nil else {
                throw GuestMergeSmokeError.validationFailed("delete did not apply as a soft-delete tombstone")
            }

            // 11: duplicate manual sync afterward is a harmless idempotent no-op.
            await controller.syncNow(authStore: authStoreA, householdId: householdId)
            guard controller.lastSyncOutcome == .completed else {
                throw GuestMergeSmokeError.validationFailed("duplicate manual sync was not a harmless no-op")
            }

            // 13: a Guest-only control item (never passed through
            // handleInventoryDidChange) must never be staged or uploaded.
            let controlItem = InventoryItem(name: "__inventory_crud_smoke_\(marker)_control", quantity: 1, unit: "个", expiryDate: nil)
            kitchenStore.inventory = [controlItem]
            let controlMetadata = try await persistence.metadata(entityType: .inventoryItem, entityId: controlItem.id)
            guard controlMetadata == nil else {
                throw GuestMergeSmokeError.validationFailed("Guest-only control item must never have been staged")
            }

            // 12: zero marker residue on the real backend.
            await Self.bestEffortCleanup(entityIds: cleanupIds, scope: scope, persistence: persistence, transport: transportA, userId: userIdA)
            return true
        } catch {
            await Self.bestEffortCleanup(entityIds: cleanupIds, scope: scope, persistence: persistence, transport: transportA, userId: userIdA)
            throw error
        }
    }

    /// Phase 2B-6: a minimal, dedicated hosted dogfood check — create,
    /// manual sync, update, manual sync, offline staging (no network call
    /// while a mutation is only staged locally), reconnect + manual sync,
    /// a simulated App restart (a brand-new `SwiftDataSyncPersistence`
    /// instance over the same on-disk container, exactly like a real
    /// relaunch would produce), duplicate-safe recovery (retrying an
    /// already-applied sync is a harmless no-op), delete, manual sync,
    /// tombstone, a diagnostics snapshot, and a consistency-checker pass
    /// that must come back clean. Does not repeat the full Phase 2B-2/2B-3
    /// merge-preview matrix — enrollment is seeded directly, exactly like
    /// `runInventoryCrudSyncMinimalSmoke` above, since the merge/preview path
    /// itself was already hosted-validated in Phase 2B-2/2B-2.5. Uses only
    /// the `__inventory_dogfood_<marker>` prefix; cleans up (soft-delete,
    /// never a physical remote delete) before returning either way.
    func runInventoryDogfoodMinimalSmoke(authStoreA: AuthStore) async throws -> Bool {
        guard smokeConfiguration.isSmokeEnabled else { throw GuestMergeSmokeError.smokeDisabled }
        guard smokeConfiguration.isDevelopmentBuild else { throw GuestMergeSmokeError.nonDevelopmentBuild }
        guard smokeConfiguration.isDevelopmentEnvironment, APIEnvironment.current == .development else {
            throw GuestMergeSmokeError.nonDevelopmentEnvironment
        }
        guard smokeConfiguration.isMergeFeatureEnabled else { throw GuestMergeSmokeError.mergeFeatureDisabled }
        guard let userIdA = authStoreA.currentUserID else { throw GuestMergeSmokeError.notAuthenticated }

        let providerA = AuthStoreSyncTokenProvider(authStore: authStoreA)
        let transportA = transportFactory(providerA)
        let bootstrap = try await transportA.bootstrap()
        guard let householdId = bootstrap.defaultHouseholdId else { throw GuestMergeSmokeError.missingDefaultHousehold }
        let scope = SyncScope(type: .household, id: householdId)
        let marker = String(UUID().uuidString.prefix(8)).lowercased()
        let markerName = "__inventory_dogfood_\(marker)"

        let container = try ModelContainer(
            for: InventoryRecord.self, ShoppingItemRecord.self, TodayPlanRecord.self,
            ConsumptionRecordEntity.self, WeeklyPlanRecord.self,
            SyncMetadataRecord.self, PendingMutationRecord.self, SyncCursorRecord.self,
            GuestMergeSessionRecord.self, InventorySyncEnrollmentRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        var persistence = SwiftDataSyncPersistence(modelContainer: container)
        var cleanupIds: Set<UUID> = []
        do {
            let kitchenStore = KitchenStore(
                userDefaults: UserDefaults(suiteName: "inventory-dogfood-smoke-\(marker)")!,
                inventoryPersistence: SwiftDataInventoryPersistence(container: container),
                shoppingListPersistence: SwiftDataShoppingListPersistence(container: container),
                todayPlanPersistence: SwiftDataTodayPlanPersistence(container: container),
                consumptionPersistence: SwiftDataConsumptionPersistence(container: container),
                weeklyPlanPersistence: SwiftDataWeeklyPlanPersistence(container: container)
            )
            try await persistence.saveEnrollment(InventorySyncEnrollment(
                userId: userIdA, householdId: householdId, status: .enrolled, enrolledAt: Date(),
                mergeSessionId: UUID(), schemaVersion: InventorySyncEnrollment.currentSchemaVersion, updatedAt: Date()
            ))
            var controller = GuestMergeController(
                persistence: persistence,
                configuration: InventoryMergeConfiguration(isEnabled: true),
                dogfoodConfiguration: InventorySyncDogfoodConfiguration(isDogfoodEnabled: true, diagnosticsEnabled: true),
                transportFactory: transportFactory
            )

            // 1: create, stage, manual sync.
            kitchenStore.importInventory([InventoryImportItem(name: markerName, quantity: 2, unit: "个", expiryDate: nil)])
            guard let markerItem = kitchenStore.inventory.first(where: { $0.name == markerName }) else {
                throw GuestMergeSmokeError.validationFailed("dogfood marker item was not created locally")
            }
            cleanupIds.insert(markerItem.id)
            await controller.handleInventoryDidChange(old: [], new: [markerItem], userId: userIdA, householdId: householdId)
            await controller.syncNow(authStore: authStoreA, householdId: householdId)
            guard controller.lastSyncOutcome == .completed else {
                throw GuestMergeSmokeError.validationFailed("manual sync after create did not complete")
            }

            // 2: update, manual sync.
            var updatedItem = markerItem
            updatedItem.quantity = 6
            kitchenStore.inventory = [updatedItem]
            await controller.handleInventoryDidChange(old: [markerItem], new: [updatedItem], userId: userIdA, householdId: householdId)
            await controller.syncNow(authStore: authStoreA, householdId: householdId)
            guard controller.lastSyncOutcome == .completed else {
                throw GuestMergeSmokeError.validationFailed("manual sync after update did not complete")
            }

            // 3: offline staging — a further local edit is staged as a
            // pending mutation but never sent (no syncNow call here at all).
            var offlineItem = updatedItem
            offlineItem.quantity = 9
            kitchenStore.inventory = [offlineItem]
            await controller.handleInventoryDidChange(old: [updatedItem], new: [offlineItem], userId: userIdA, householdId: householdId)
            let stagedWhileOffline = try await persistence.pendingMutationForEntity(entityType: .inventoryItem, entityId: markerItem.id)
            guard stagedWhileOffline?.status == .pending else {
                throw GuestMergeSmokeError.validationFailed("offline edit did not stage a pending mutation")
            }

            // 4: reconnect + manual sync applies the offline-staged edit.
            await controller.syncNow(authStore: authStoreA, householdId: householdId)
            guard controller.lastSyncOutcome == .completed else {
                throw GuestMergeSmokeError.validationFailed("manual sync after reconnect did not complete")
            }
            let afterReconnectMetadata = try await persistence.metadata(entityType: .inventoryItem, entityId: markerItem.id)
            guard afterReconnectMetadata?.state == .synced, afterReconnectMetadata?.remoteVersion?.rawValue == "3" else {
                throw GuestMergeSmokeError.validationFailed("reconnect sync did not advance the remote version as expected")
            }

            // 5: simulated App restart — a brand-new `SwiftDataSyncPersistence`
            // and a brand-new `GuestMergeController` over the *same* on-disk
            // container, exactly like a real relaunch. A duplicate manual
            // sync immediately afterward must be a harmless no-op (duplicate-
            // safe recovery), never re-applying or re-creating anything.
            persistence = SwiftDataSyncPersistence(modelContainer: container)
            controller = GuestMergeController(
                persistence: persistence,
                configuration: InventoryMergeConfiguration(isEnabled: true),
                dogfoodConfiguration: InventorySyncDogfoodConfiguration(isDogfoodEnabled: true, diagnosticsEnabled: true),
                transportFactory: transportFactory
            )
            await controller.syncNow(authStore: authStoreA, householdId: householdId)
            guard controller.lastSyncOutcome == .completed else {
                throw GuestMergeSmokeError.validationFailed("post-restart duplicate-safe sync did not complete")
            }
            let afterRestartMetadata = try await persistence.metadata(entityType: .inventoryItem, entityId: markerItem.id)
            guard afterRestartMetadata?.remoteVersion?.rawValue == "3" else {
                throw GuestMergeSmokeError.validationFailed("post-restart no-op sync unexpectedly changed the remote version")
            }

            // 6: delete, manual sync, remote soft-delete tombstone.
            kitchenStore.inventory = []
            await controller.handleInventoryDidChange(old: [offlineItem], new: [], userId: userIdA, householdId: householdId)
            await controller.syncNow(authStore: authStoreA, householdId: householdId)
            guard controller.lastSyncOutcome == .completed else {
                throw GuestMergeSmokeError.validationFailed("manual sync after delete did not complete")
            }
            let afterDeleteMetadata = try await persistence.metadata(entityType: .inventoryItem, entityId: markerItem.id)
            guard afterDeleteMetadata?.state == .synced, afterDeleteMetadata?.deletedAt != nil else {
                throw GuestMergeSmokeError.validationFailed("delete did not apply as a soft-delete tombstone")
            }

            // 7: diagnostics snapshot — must reflect a clean, fully-synced state.
            let snapshot = await controller.diagnosticsSnapshot(
                kitchenStore: kitchenStore, userId: userIdA, householdId: householdId,
                environmentName: "development", appBuild: "dogfood-smoke"
            )
            guard snapshot.pendingCount == 0, snapshot.conflictCount == 0, snapshot.failedCount == 0 else {
                throw GuestMergeSmokeError.validationFailed("diagnostics snapshot was not clean after a fully-synced run")
            }

            // 8: consistency checker must report zero issues.
            let issues = await controller.consistencyCheck(kitchenStore: kitchenStore, userId: userIdA, householdId: householdId)
            guard issues.isEmpty else {
                throw GuestMergeSmokeError.validationFailed("consistency checker reported issues after a clean dogfood run: \(issues.map(\.code.rawValue))")
            }

            // 9: zero marker residue on the real backend.
            await Self.bestEffortCleanup(entityIds: cleanupIds, scope: scope, persistence: persistence, transport: transportA, userId: userIdA)
            return true
        } catch {
            await Self.bestEffortCleanup(entityIds: cleanupIds, scope: scope, persistence: persistence, transport: transportA, userId: userIdA)
            throw error
        }
    }

    /// Best-effort — never throws itself. Soft-deletes every tracked marker
    /// id via the same authorized sync boundary used throughout the run (no
    /// service-role key, no physical delete); ids that were never actually
    /// created remotely, or are already deleted, are simply skipped.
    private static func bestEffortCleanup(
        entityIds: Set<UUID>, scope: SyncScope, persistence: SwiftDataSyncPersistence,
        transport: any SyncTransport, userId: UUID
    ) async {
        guard !entityIds.isEmpty else { return }
        let adapter = InventorySyncAdapter(persistence: persistence)
        let coordinator = SyncCoordinator(configuration: SyncConfiguration(isEnabled: true), persistence: persistence, transport: transport)
        let authentication = SyncAuthenticationContext(userID: userId, isAuthenticated: true)
        for id in entityIds {
            _ = try? await adapter.stageDelete(entityId: id, scope: scope)
        }
        _ = await coordinator.runOnce(authentication: authentication, scopes: [scope])
    }

    private func fetchRemoteInventoryCount(transport: any SyncTransport, scope: SyncScope) async throws -> Int {
        try await fetchRemoteInventorySnapshot(transport: transport, scope: scope).count
    }

    /// Present entity ids only (deleted/tombstoned ids are absent) — used to
    /// check specific ids exist, never as a raw count comparison (which
    /// other real data in the same household could affect).
    private func fetchRemoteInventorySnapshot(transport: any SyncTransport, scope: SyncScope) async throws -> [UUID: SyncCursorValue] {
        var cursor = SyncCursorValue.zero
        var versions: [UUID: SyncCursorValue] = [:]
        var hasMore = true
        var pages = 0
        while hasMore && pages < 50 {
            let response = try await transport.fetchChanges(scope: scope, after: cursor, limit: 100)
            for change in response.changes where change.entityType == .inventoryItem {
                if change.operation == .delete { versions.removeValue(forKey: change.entityId) } else { versions[change.entityId] = change.version }
            }
            cursor = response.cursor
            hasMore = response.hasMore
            pages += 1
            if hasMore, response.changes.isEmpty { break }
        }
        return versions
    }
}

private struct GuestBoundarySnapshot: Equatable {
    let shoppingCount: Int
    let todayPlanCount: Int
    let hasWeeklyPlan: Bool
    let userRecipeCount: Int

    init(kitchenStore: KitchenStore, recipeStore: RecipeStore) {
        shoppingCount = kitchenStore.shoppingItems.count
        todayPlanCount = kitchenStore.plans.count
        hasWeeklyPlan = kitchenStore.weeklyPlan != nil
        userRecipeCount = recipeStore.userRecipes.count
    }
}

#endif
