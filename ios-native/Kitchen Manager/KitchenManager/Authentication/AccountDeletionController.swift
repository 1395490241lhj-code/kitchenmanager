import Foundation
import Combine

/// Bridges `AuthStore`'s live session the same way
/// `Synchronization/GuestMergeController.swift`'s own private
/// `AuthStoreCredentialProvider` does — a `View` never sees a token value;
/// it only ever passes its already-injected `AuthStore` reference into this
/// controller's methods, matching the existing, established pattern for
/// every other authenticated network call in this app.
@MainActor
final class AccountDeletionController: ObservableObject {
    enum CompletionState: Equatable {
        case notConfirmed
        case localCleanupPending(userID: UUID)
        case completed(userID: UUID)
    }
    @Published private(set) var preview: AccountDeletionPreview?
    @Published private(set) var isLoadingPreview = false
    @Published private(set) var transferCandidates: [TransferCandidate] = []
    @Published private(set) var isLoadingCandidates = false
    @Published private(set) var isTransferring = false
    @Published private(set) var isReauthenticating = false
    @Published private(set) var isConfirming = false
    @Published private(set) var errorMessage: String?
    /// App-lifetime operation state, not another persisted account/session model.
    /// Once confirmed remotely, every retry is local and consumes no credentials.
    @Published private(set) var completionState: CompletionState = .notConfirmed
    var didComplete: Bool {
        if case .completed = completionState { return true }
        return false
    }
    var needsLocalCleanup: Bool {
        if case .localCleanupPending = completionState { return true }
        return false
    }

    @Published private(set) var localCleanupBlockedReason: String?
    private struct CleanupOwnership {
        let userID: UUID
        let authID: ObjectIdentifier
        let kitchenID: ObjectIdentifier
        let authorization: AccountDeletionCleanupAuthorization
        let context: UUID?
    }
    private var cleanupOwnership: CleanupOwnership?
    private var authObservation: AnyCancellable?
    private var localDataCleared = false
    private var isSigningOut = false
    private var sawExpectedSignOutGuest = false
    private var expectedSignOutOperationID: UUID?

    private let service: AccountDeletionService
    private let persistence: SyncPersistenceProtocol
    /// Stable across retries of the same deletion intent (see the design
    /// note in `docs/ACCOUNT_DELETION_DESIGN.md`); only regenerated when the
    /// user starts a genuinely new attempt after a full success/failure.
    private var idempotencyKey = UUID()
    private var reauthenticationProof: String?

    init(persistence: SyncPersistenceProtocol, service: AccountDeletionService? = nil) {
        self.persistence = persistence
        self.service = service ?? APIAccountDeletionService()
    }

    func loadPreview(authStore: AuthStore) async {
        resetCompletedIntentForAnotherAccount(authStore)
        guard completionState == .notConfirmed else { return }
        guard let accessToken = authStore.currentAccessToken() else {
            errorMessage = AccountDeletionError.unavailable.localizedDescription
            return
        }
        isLoadingPreview = true
        errorMessage = nil
        defer { isLoadingPreview = false }
        do {
            let loaded = try await service.preview(accessToken: accessToken)
            guard completionState == .notConfirmed else { return }
            preview = loaded
            self.reauthenticationProof = nil
        } catch {
            guard completionState == .notConfirmed else { return }
            preview = nil
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? AccountDeletionError.unavailable.localizedDescription
        }
    }

    func loadTransferCandidates(householdId: UUID, authStore: AuthStore) async {
        guard let accessToken = authStore.currentAccessToken() else { return }
        isLoadingCandidates = true
        defer { isLoadingCandidates = false }
        do {
            transferCandidates = try await service.transferCandidates(accessToken: accessToken, householdId: householdId)
        } catch {
            transferCandidates = []
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? AccountDeletionError.unavailable.localizedDescription
        }
    }

    @discardableResult
    func transferOwnership(householdId: UUID, newOwnerUserId: UUID, authStore: AuthStore) async -> Bool {
        guard let accessToken = authStore.currentAccessToken() else { return false }
        isTransferring = true
        errorMessage = nil
        defer { isTransferring = false }
        do {
            try await service.transferOwnership(accessToken: accessToken, householdId: householdId, newOwnerUserId: newOwnerUserId)
            // A stale preview must never be acted on after the underlying
            // blocking state changed — re-fetch rather than assume success
            // resolved every blocker (there could be more than one household).
            await loadPreview(authStore: authStore)
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? AccountDeletionError.unavailable.localizedDescription
            return false
        }
    }

    /// iOS sends the password only to Supabase through `AuthStore`; our
    /// backend receives only the new Supabase-issued JWT and returns a short,
    /// one-use proof bound to this preview fingerprint.
    @discardableResult
    func reauthenticateForDeletion(password: String, authStore: AuthStore) async -> Bool {
        guard completionState == .notConfirmed, !isConfirming else { return false }
        guard let preview, preview.canDelete else {
            errorMessage = AccountDeletionError.stalePreview.localizedDescription
            return false
        }
        isReauthenticating = true
        errorMessage = nil
        defer { isReauthenticating = false }

        guard await authStore.reauthenticateForAccountDeletion(password: password),
              let accessToken = authStore.currentAccessToken() else {
            errorMessage = AccountDeletionError.reauthenticationFailed.localizedDescription
            return false
        }

        do {
            reauthenticationProof = try await service.createReauthenticationProof(
                accessToken: accessToken,
                confirmationVersion: preview.confirmationVersion
            ).reauthenticationProof
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? AccountDeletionError.reauthenticationFailed.localizedDescription
            return false
        }
    }

    /// Returns `true` only on a genuine `completed` result. `false` (with
    /// `errorMessage` set) covers every blocked/rejected/failed case,
    /// including the recoverable `auth_deletion_pending` state — the caller
    /// must not clear local data or sign out except on a real `true`.
    @discardableResult
    func confirmDeletion(
        authStore: AuthStore,
        kitchenStore: KitchenStore
    ) async -> Bool {
        resetCompletedIntentForAnotherAccount(authStore)
        if needsLocalCleanup {
            return await retryLocalCleanup(authStore: authStore, kitchenStore: kitchenStore)
        }
        if didComplete { return true }
        guard !isConfirming else { return false }
        guard let preview else {
            errorMessage = AccountDeletionError.stalePreview.localizedDescription
            return false
        }
        guard let reauthenticationProof else {
            errorMessage = AccountDeletionError.reauthenticationRequired.localizedDescription
            return false
        }
        guard let accessToken = authStore.currentAccessToken() else {
            errorMessage = AccountDeletionError.unavailable.localizedDescription
            return false
        }
        guard case .signedIn(let user) = authStore.status else {
            errorMessage = AccountDeletionError.unavailable.localizedDescription
            return false
        }
        guard !kitchenStore.isPreparedComponentUnavailable else {
            errorMessage = PreparedComponentMutationError.unavailable.localizedDescription
            return false
        }
        beginCleanupOwnership(authStore: authStore, kitchenStore: kitchenStore, userID: user.id)
        isConfirming = true
        errorMessage = nil
        defer { isConfirming = false }
        do {
            let result = try await service.confirmDeletion(
                accessToken: accessToken,
                idempotencyKey: idempotencyKey,
                confirmationVersion: preview.confirmationVersion,
                reauthenticationProof: reauthenticationProof
            )
            guard result.status == "completed" else {
                // auth_deletion_pending: business data is already gone
                // server-side, but the Auth user deletion step itself needs
                // a retry (same idempotencyKey — this is exactly the
                // recoverable case the saga is designed for). Do not clear
                // local data or sign out yet; the account may still nominally
                // "exist" from this device's perspective until finalize
                // actually succeeds.
                errorMessage = "删除仍在处理中，请稍后重试确认。"
                self.preview = nil
                return false
            }
            // The external result is terminal even if the following local work
            // fails. Never return to preview/password/confirm after this point.
            completionState = .localCleanupPending(userID: user.id)
            self.preview = nil
            self.reauthenticationProof = nil
            return await clearLocalStateAfterSuccessfulDeletion(authStore: authStore, kitchenStore: kitchenStore)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? AccountDeletionError.unavailable.localizedDescription
            // A stale/reauth/in-progress rejection means this exact preview+
            // nonce can never succeed again — force a fresh preview fetch
            // before any further attempt, rather than silently retrying with
            // now-invalid values.
            self.preview = nil
            self.reauthenticationProof = nil
            return false
        }
    }

    @discardableResult
    func retryLocalCleanup(authStore: AuthStore, kitchenStore: KitchenStore) async -> Bool {
        guard needsLocalCleanup, !isConfirming else { return false }
        isConfirming = true
        errorMessage = nil
        defer { isConfirming = false }
        return await clearLocalStateAfterSuccessfulDeletion(authStore: authStore, kitchenStore: kitchenStore)
    }

    private func clearLocalStateAfterSuccessfulDeletion(
        authStore: AuthStore,
        kitchenStore: KitchenStore
    ) async -> Bool {
        guard case .localCleanupPending(let deletionUserID) = completionState else { return false }
        guard ownsCleanupContext(authStore: authStore, kitchenStore: kitchenStore) else {
            blockLocalCleanup()
            return false
        }
        if !localDataCleared {
            // A failed rollback can require a verified reload, never an erase.
            if kitchenStore.isPreparedComponentUnavailable,
               case .failure = kitchenStore.reloadPreparedComponents() {
                reportLocalCleanupFailure(kitchenStore: kitchenStore)
                return false
            }
            do {
                guard let authorization = cleanupOwnership?.authorization,
                      try await persistence.clearAllSyncState(authorizedBy: authorization) else {
                    blockLocalCleanup()
                    return false
                }
            } catch {
                guard ownsCleanupContext(authStore: authStore, kitchenStore: kitchenStore) else {
                    blockLocalCleanup()
                    return false
                }
                errorMessage = "此前账号的远端删除已完成，但本机同步记录清理失败。请重试本机清理；厨房数据和菜谱库会保留。"
                return false
            }
            guard ownsCleanupContext(authStore: authStore, kitchenStore: kitchenStore) else {
                blockLocalCleanup()
                return false
            }
            guard kitchenStore.clearAllLocalData() else {
                reportLocalCleanupFailure(kitchenStore: kitchenStore)
                return false
            }
            localDataCleared = true
        }
        // A failed/busy sign-out is retried without clearing newly added data.
        isSigningOut = true
        sawExpectedSignOutGuest = false
        let signOutID = UUID()
        expectedSignOutOperationID = signOutID
        // This admitted cleanup owns settlement even if its initiating caller cancels.
        let signOutSettlement = Task { @MainActor in
            await authStore.signOut(ifCurrent: {
                self.ownsCleanupContext(authStore: authStore, kitchenStore: kitchenStore,
                                        allowingExpectedGuest: true)
            }, operationID: signOutID)
        }
        let signedOut = await signOutSettlement.value
        isSigningOut = false
        let localSignOutSettled = sawExpectedSignOutGuest &&
            authStore.sessionOwnership.signOutOperationID == signOutID &&
            !authStore.sessionOwnership.isUnavailable && !authStore.sessionOwnership.isTransitioning
        guard (signedOut || localSignOutSettled), cleanupOwnership?.authorization.isValid == true else {
            if cleanupOwnership?.authorization.isValid != true {
                blockLocalCleanup()
            } else {
                errorMessage = "此前账号的远端删除和本机厨房清理已完成，但退出登录尚未完成。请重试；不会再次清理数据或删除账号。"
            }
            return false
        }
        idempotencyKey = UUID()
        errorMessage = nil
        localCleanupBlockedReason = nil
        authObservation = nil
        completionState = .completed(userID: deletionUserID)
        return true
    }

    /// The app retains this controller after sign-out. Only a different signed-
    /// in account starts a new intent; a pending cleanup is never reset here.
    private func resetCompletedIntentForAnotherAccount(_ authStore: AuthStore) {
        guard case .completed(let deletedUserID) = completionState,
              case .signedIn(let user) = authStore.status,
              user.id != deletedUserID else { return }
        completionState = .notConfirmed
        authObservation = nil
        cleanupOwnership = nil
        localDataCleared = false
        localCleanupBlockedReason = nil
        preview = nil
        reauthenticationProof = nil
        errorMessage = nil
    }

    private func beginCleanupOwnership(authStore: AuthStore, kitchenStore: KitchenStore, userID: UUID) {
        let authorization = AccountDeletionCleanupAuthorization()
        cleanupOwnership = CleanupOwnership(userID: userID, authID: ObjectIdentifier(authStore),
                                            kitchenID: ObjectIdentifier(kitchenStore), authorization: authorization,
                                            context: authStore.sessionOwnership.context)
        localDataCleared = false
        isSigningOut = false
        sawExpectedSignOutGuest = false
        localCleanupBlockedReason = nil
        let context = authStore.sessionOwnership.context
        authObservation = authStore.$status.combineLatest(authStore.$sessionOwnership).sink { [weak self] status, ownership in
            guard let self else { return }
            if context != nil, ownership.context == context, !ownership.isUnavailable,
               case .signedIn(let user) = status, user.id == userID,
               !self.sawExpectedSignOutGuest { return }
            if self.isSigningOut, ownership.context == nil,
               ownership.endingContext == context,
               ownership.signOutOperationID == self.expectedSignOutOperationID,
               self.expectedSignOutOperationID != nil, !ownership.isUnavailable {
                if status == .guest && !ownership.isTransitioning { self.sawExpectedSignOutGuest = true }
                return
            }
            authorization.revoke()
            if self.needsLocalCleanup { self.blockLocalCleanup() }
        }
    }

    private func ownsCleanupContext(authStore: AuthStore, kitchenStore: KitchenStore,
                                    allowingExpectedGuest: Bool = false) -> Bool {
        guard let ownership = cleanupOwnership, ownership.authorization.isValid,
              ownership.authID == ObjectIdentifier(authStore),
              ownership.kitchenID == ObjectIdentifier(kitchenStore) else { return false }
        let current = authStore.sessionOwnership
        if current.context != nil, current.context == ownership.context, !current.isUnavailable,
           authStore.currentUserID == ownership.userID { return true }
        return allowingExpectedGuest && isSigningOut && current.context == nil &&
            current.endingContext == ownership.context && !current.isUnavailable &&
            current.signOutOperationID == expectedSignOutOperationID && expectedSignOutOperationID != nil &&
            (current.isTransitioning || (sawExpectedSignOutGuest && authStore.status == .guest))
    }

    func refreshLocalCleanupOwnership(authStore: AuthStore, kitchenStore: KitchenStore) {
        guard needsLocalCleanup else { return }
        if !ownsCleanupContext(authStore: authStore, kitchenStore: kitchenStore) { blockLocalCleanup() }
    }

    private func blockLocalCleanup() {
        cleanupOwnership?.authorization.revoke()
        localCleanupBlockedReason = "此前账号的远端删除已完成，但登录状态或本机数据上下文已变化。本机清理已暂停；此处不会清理当前数据或退出当前账号。不会再次删除账号，也无需重新验证已删除的账号。"
        errorMessage = localCleanupBlockedReason
    }

    private func reportLocalCleanupFailure(kitchenStore: KitchenStore) {
        let cause = kitchenStore.isPreparedComponentUnavailable
            ? "备餐记录暂时无法读取，需成功重新读取后才能继续。"
            : "本机厨房数据清理失败，请稍后重试。"
        errorMessage = "账号已删除，但本机清理尚未完成。\(cause)请重试本机清理；菜谱库、收藏和常做记录会保留。"
    }
}
