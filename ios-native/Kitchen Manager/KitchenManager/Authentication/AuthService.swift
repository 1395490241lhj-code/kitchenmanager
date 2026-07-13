import Foundation

@MainActor
protocol AuthService: AnyObject {
    var authStateChanges: AsyncStream<AuthStateChange> { get }
    func restoreSession() async throws -> AuthSession?
    func signUp(email: String, password: String) async throws -> SignUpOutcome
    func signIn(email: String, password: String) async throws -> AuthSession
    func signOut() async throws
}

@MainActor
protocol AccountService: AnyObject {
    func currentAccount(accessToken: String) async throws -> CurrentAccount
}

@MainActor
final class UnavailableAuthService: AuthService {
    var authStateChanges: AsyncStream<AuthStateChange> { AsyncStream { $0.finish() } }
    func restoreSession() async throws -> AuthSession? { nil }
    func signUp(email: String, password: String) async throws -> SignUpOutcome { throw AuthenticationError.unavailable }
    func signIn(email: String, password: String) async throws -> AuthSession { throw AuthenticationError.unavailable }
    func signOut() async throws {}
}

@MainActor
final class UnavailableAccountService: AccountService {
    func currentAccount(accessToken: String) async throws -> CurrentAccount {
        throw AccountServiceError.temporarilyUnavailable
    }
}
