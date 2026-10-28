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

    @Published private(set) var sessionOwnership = AuthSessionOwnership()
    var isSessionUnavailable: Bool { sessionOwnership.isUnavailable }
    private var coordinated: (any CoordinatedAuthService)? { authService as? any CoordinatedAuthService }

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
        coordinated?.installConsumer { [weak self] update in await self?.consume(update) }
    }

    deinit { observationTask?.cancel() }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        if coordinated == nil { observeAuthChanges() }
        activity = .restoring
        do {
            if let restored = try await authService.restoreSession() {
                if coordinated == nil { await applyFresh(restored) }
            } else if coordinated == nil {
                clearSession()
            }
        } catch {
            if coordinated == nil { clearSession() }
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
            let session = try await authService.signIn(email: email, password: password)
            if coordinated == nil { await applyFresh(session) }
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
                if coordinated == nil { await applyFresh(session) }
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

    func signOut() async { _ = await signOut(ifCurrent: { true }) }

    /// A deletion can finish after another auth event. Never let its late result
    /// clear a replacement session or write an error onto that account.
    @discardableResult
    func signOut(ifCurrent ownsContext: () -> Bool, operationID: UUID = UUID()) async -> Bool {
        guard ownsContext(), activity != .submitting else { return false }
        activity = .submitting
        errorMessage = nil
        defer { activity = .idle }
        do {
            if let coordinated {
                try await coordinated.signOut(expectedContext: sessionOwnership.context, operationID: operationID)
            } else {
                let ending = sessionOwnership.context
                try await authService.signOut()
                guard ownsContext() else { return false }
                sessionOwnership = AuthSessionOwnership(signOutOperationID: operationID, endingContext: ending)
                clearSession(preservingOwnership: true)
            }
            guard ownsContext() else { return false }
            return true
        } catch {
            guard ownsContext() else { return false }
            errorMessage = safeMessage(for: error)
            return false
        }
    }

    /// Performs a new password authentication for account deletion. This is
    /// intentionally distinct from session restore/refresh: only Supabase's
    /// newly issued, signed authentication-method claim can satisfy the
    /// server-side deletion proof endpoint.
    @discardableResult
    func reauthenticateForAccountDeletion(password: String) async -> Bool {
        guard activity != .submitting,
              case .signedIn(let user) = status,
              let email = user.email,
              !email.isEmpty else {
            errorMessage = AuthenticationError.unavailable.localizedDescription
            return false
        }
        activity = .submitting
        errorMessage = nil
        defer { activity = .idle }
        do {
            let session: AuthSession
            if let coordinated {
                session = try await coordinated.reauthenticate(email: email, password: password,
                                                               expectedContext: sessionOwnership.context)
            } else { session = try await authService.reauthenticate(email: email, password: password) }
            if coordinated == nil { await applyFresh(session) }
            return true
        } catch {
            errorMessage = safeMessage(for: error)
            return false
        }
    }

    func refreshAccount() async {
        guard let session else { return }
        let ownership = sessionOwnership.context
        do {
            let loaded = try await accountService.currentAccount(accessToken: session.accessToken)
            guard sessionOwnership.context == ownership, self.session == session else { return }
            account = loaded
            accountMessage = nil
        } catch {
            guard sessionOwnership.context == ownership, self.session == session else { return }
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
                case .sessionUpdated(let session):
                    if self.currentUserID != session.user.id || self.sessionOwnership.context == nil {
                        await self.applyFresh(session)
                    } else { await self.apply(session) }
                case .signedOut: self.clearSession()
                }
            }
        }
    }

    private func applyFresh(_ newSession: AuthSession) async {
        sessionOwnership = AuthSessionOwnership(context: UUID())
        await apply(newSession)
    }

    private func consume(_ update: AuthProviderUpdate) async {
        sessionOwnership = AuthSessionOwnership(context: update.context,
            signOutOperationID: update.isSignOut ? update.operationID : nil,
            endingContext: update.endingContext, isTransitioning: update.phase == .transition,
            isUnavailable: update.phase == .unavailable)
        switch update.phase {
        case .transition: break
        case .unavailable:
            session = nil; account = nil
            errorMessage = "登录状态暂时无法确认。请重新登录；本机厨房数据会保留。"
        case .settled:
            if let session = update.session {
                if self.session != session { await apply(session) }
            } else { clearSession(preservingOwnership: true) }
        }
    }

    private func apply(_ newSession: AuthSession) async {
        session = newSession
        status = .signedIn(newSession.user)
        errorMessage = nil
        confirmationEmail = nil
        await refreshAccount()
    }

    private func clearSession(preservingOwnership: Bool = false) {
        if !preservingOwnership { sessionOwnership = AuthSessionOwnership() }
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

    /// Safe for any caller, including `View`s — this is the signed-in user's
    /// id, not a credential.
    var currentUserID: UUID? {
        if case .signedIn(let user) = status { return user.id }
        return nil
    }

    /// The signed-in user's current access token. **Must only ever be called
    /// by `AuthStoreCredentialProvider`** (see
    /// `Synchronization/GuestMergeController.swift`) or an equivalent
    /// `SyncAccessTokenProviding` bridge that attaches it directly to one
    /// outgoing request — never by a SwiftUI `View`, never stored on any
    /// `@Published`/`Sendable` model, never persisted, refreshed, or logged.
    /// (`test/ios-native-guest-merge-phase2b1.test.mjs` enforces that no View
    /// file in this target calls this directly.) The session itself remains
    /// in Keychain-owned auth storage.
    func currentAccessToken() -> String? {
        guard !sessionOwnership.isUnavailable, !sessionOwnership.isTransitioning else { return nil }
        return session?.accessToken
    }
}

extension AuthStore {
    static func guestPreview() -> AuthStore {
        AuthStore(authService: UnavailableAuthService(), accountService: UnavailableAccountService())
    }
}
