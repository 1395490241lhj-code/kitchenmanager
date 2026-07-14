import Foundation
import Combine

@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var status: AuthenticationStatus = .guest
    @Published private(set) var activity: AuthenticationActivity = .idle
    @Published private(set) var account: CurrentAccount?
    @Published private(set) var errorMessage: String?
    @Published private(set) var accountMessage: String?
    @Published private(set) var confirmationEmail: String?

    private let authService: AuthService
    private let accountService: AccountService
    private var session: AuthSession?
    private var observationTask: Task<Void, Never>?
    private var hasStarted = false

    init(
        authService: AuthService,
        accountService: AccountService,
        configurationMessage: String? = nil
    ) {
        self.authService = authService
        self.accountService = accountService
        errorMessage = configurationMessage
    }

    deinit { observationTask?.cancel() }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        observeAuthChanges()
        activity = .restoring
        do {
            if let restored = try await authService.restoreSession() {
                await apply(restored)
            } else {
                clearSession()
            }
        } catch {
            clearSession()
            errorMessage = AuthenticationError.unavailable.localizedDescription
        }
        activity = .idle
    }

    @discardableResult
    func signIn(email: String, password: String) async -> Bool {
        guard activity != .submitting else { return false }
        activity = .submitting
        errorMessage = nil
        confirmationEmail = nil
        defer { activity = .idle }
        do {
            await apply(try await authService.signIn(email: email, password: password))
            return true
        } catch {
            errorMessage = safeMessage(for: error)
            return false
        }
    }

    @discardableResult
    func signUp(email: String, password: String) async -> Bool {
        guard activity != .submitting else { return false }
        activity = .submitting
        errorMessage = nil
        confirmationEmail = nil
        defer { activity = .idle }
        do {
            switch try await authService.signUp(email: email, password: password) {
            case .signedIn(let session):
                await apply(session)
                return true
            case .confirmationRequired(let email):
                confirmationEmail = email
                return false
            }
        } catch {
            errorMessage = safeMessage(for: error)
            return false
        }
    }

    func signOut() async {
        guard activity != .submitting else { return }
        activity = .submitting
        errorMessage = nil
        defer { activity = .idle }
        do {
            try await authService.signOut()
            clearSession()
        } catch {
            errorMessage = safeMessage(for: error)
        }
    }

    func refreshAccount() async {
        guard let session else { return }
        do {
            account = try await accountService.currentAccount(accessToken: session.accessToken)
            accountMessage = nil
        } catch {
            account = nil
            accountMessage = (error as? LocalizedError)?.errorDescription
                ?? AccountServiceError.temporarilyUnavailable.localizedDescription
        }
    }

    private func observeAuthChanges() {
        observationTask = Task { [weak self, authService] in
            for await change in authService.authStateChanges {
                guard let self else { return }
                switch change {
                case .sessionUpdated(let session): await self.apply(session)
                case .signedOut: self.clearSession()
                }
            }
        }
    }

    private func apply(_ newSession: AuthSession) async {
        session = newSession
        status = .signedIn(newSession.user)
        errorMessage = nil
        confirmationEmail = nil
        await refreshAccount()
    }

    private func clearSession() {
        session = nil
        status = .guest
        account = nil
        accountMessage = nil
    }

    private func safeMessage(for error: Error) -> String {
        (error as? AuthenticationError)?.localizedDescription
            ?? AuthenticationError.unavailable.localizedDescription
    }

    #if DEBUG
    /// Read only by the explicitly confirmed development sync smoke. The
    /// session remains in Keychain-owned auth storage; this does not persist,
    /// refresh, or log its access token.
    func developmentSyncSmokeSession() -> AuthSession? { session }
    #endif

    /// Read only by the Guest inventory merge flow (Phase 2B), itself gated
    /// off by default via `INVENTORY_SYNC_ENABLED`. The session remains in
    /// Keychain-owned auth storage; this does not persist, refresh, or log
    /// the token.
    var currentUserID: UUID? {
        if case .signedIn(let user) = status { return user.id }
        return nil
    }

    func currentAccessToken() -> String? { session?.accessToken }
}

extension AuthStore {
    static func guestPreview() -> AuthStore {
        AuthStore(authService: UnavailableAuthService(), accountService: UnavailableAccountService())
    }
}
