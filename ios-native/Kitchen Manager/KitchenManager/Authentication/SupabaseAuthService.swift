import Foundation
import Supabase
import UIKit

@MainActor
final class SupabaseAuthService: CoordinatedAuthService {
    private let coordinator: ProviderSessionCoordinator

    init(configuration: AuthConfiguration) {
        let storage = KeychainLocalStorage(service: "com.lianghongjing.kitchenmanager.auth")
        coordinator = ProviderSessionCoordinator(
            url: configuration.supabaseURL.appendingPathComponent("auth/v1"),
            headers: ["apikey": configuration.publishableKey,
                      "Authorization": "Bearer \(configuration.publishableKey)"],
            storageKey: "kitchenmanager.auth.session", storage: storage,
            fetch: { try await URLSession.shared.data(for: $0) },
            initiallyActive: UIApplication.shared.applicationState == .active)
    }

    init(coordinator: ProviderSessionCoordinator) { self.coordinator = coordinator }

    // AuthStore uses the acknowledged consumer, never a second AsyncStream reducer.
    var authStateChanges: AsyncStream<AuthStateChange> { AsyncStream { $0.finish() } }

    func installConsumer(_ consumer: @escaping @MainActor (AuthProviderUpdate) async -> Void) {
        coordinator.setConsumer { snapshot in
            let phase: AuthProviderUpdate.Phase
            switch snapshot.phase {
            case .transition: phase = .transition
            case .settled: phase = .settled
            case .unavailable: phase = .unavailable
            }
            await consumer(AuthProviderUpdate(phase: phase, session: snapshot.session.map(Self.map),
                context: snapshot.context, operationID: snapshot.operationID,
                endingContext: snapshot.endingContext, isSignOut: snapshot.operation == .signOut))
        }
    }

    func restoreSession() async throws -> AuthSession? {
        do { return try await coordinator.perform(.restore).session.map(Self.map) }
        catch { throw Self.map(error) }
    }
    func signUp(email: String, password: String) async throws -> SignUpOutcome {
        do {
            let result = try await coordinator.perform(.signUp, email: email, password: password)
            if let email = result.confirmationEmail { return .confirmationRequired(email: email) }
            guard let session = result.session else { throw AuthenticationError.unavailable }
            return .signedIn(Self.map(session))
        } catch { throw Self.map(error) }
    }
    func signIn(email: String, password: String) async throws -> AuthSession {
        do {
            guard let session = try await coordinator.perform(.signIn, email: email, password: password).session else {
                throw AuthenticationError.unavailable
            }
            return Self.map(session)
        } catch { throw Self.map(error) }
    }
    func reauthenticate(email: String, password: String) async throws -> AuthSession {
        try await reauthenticate(email: email, password: password, expectedContext: coordinator.context)
    }
    func reauthenticate(email: String, password: String, expectedContext: UUID?) async throws -> AuthSession {
        do {
            guard let session = try await coordinator.perform(.reauthenticate, email: email,
                password: password, expectedContext: expectedContext).session else { throw AuthenticationError.unavailable }
            return Self.map(session)
        } catch { throw Self.map(error) }
    }
    func signOut() async throws { try await signOut(expectedContext: coordinator.context, operationID: UUID()) }
    func signOut(expectedContext: UUID?, operationID: UUID) async throws {
        do { _ = try await coordinator.perform(.signOut, expectedContext: expectedContext, operationID: operationID) }
        catch { throw Self.map(error) }
    }

    private static func map(_ session: Session) -> AuthSession {
        AuthSession(
            user: AuthUser(id: session.user.id, email: session.user.email),
            accessToken: session.accessToken
        )
    }

    private static func map(_ error: Error) -> AuthenticationError {
        guard let error = error as? AuthError else { return .unavailable }
        switch error.errorCode {
        case .invalidCredentials: return AuthenticationError.invalidCredentials
        case .emailNotConfirmed: return AuthenticationError.emailNotConfirmed
        case .emailExists, .userAlreadyExists: return AuthenticationError.emailAlreadyRegistered
        case .weakPassword: return AuthenticationError.weakPassword
        case .overRequestRateLimit, .overEmailSendRateLimit: return AuthenticationError.rateLimited
        default: return AuthenticationError.unavailable
        }
    }
}
