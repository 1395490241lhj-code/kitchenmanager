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
    @Published private(set) var preview: AccountDeletionPreview?
    @Published private(set) var isLoadingPreview = false
    @Published private(set) var transferCandidates: [TransferCandidate] = []
    @Published private(set) var isLoadingCandidates = false
    @Published private(set) var isTransferring = false
    @Published private(set) var isReauthenticating = false
    @Published private(set) var isConfirming = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var didComplete = false

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
        guard let accessToken = authStore.currentAccessToken() else {
            errorMessage = AccountDeletionError.unavailable.localizedDescription
            return
        }
        isLoadingPreview = true
        errorMessage = nil
        defer { isLoadingPreview = false }
        do {
            preview = try await service.preview(accessToken: accessToken)
            self.reauthenticationProof = nil
        } catch {
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
            await clearLocalStateAfterSuccessfulDeletion(authStore: authStore, kitchenStore: kitchenStore)
            idempotencyKey = UUID()
            self.reauthenticationProof = nil
            didComplete = true
            return true
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

    private func clearLocalStateAfterSuccessfulDeletion(
        authStore: AuthStore,
        kitchenStore: KitchenStore
    ) async {
        // Order matters: clear sync bookkeeping first so nothing can stage a
        // new pending mutation against data that's about to disappear, then
        // clear domain data, then finally drop the Auth session itself (so a
        // window-killed app mid-cleanup still has a valid enough session to
        // resume on next launch rather than being stuck half-signed-in).
        try? await persistence.clearAllSyncState()
        kitchenStore.clearAllLocalData()
        await authStore.signOut()
    }
}
