import Foundation
import Supabase

@MainActor
final class SupabaseAuthService: AuthService {
    private let client: SupabaseClient

    init(configuration: AuthConfiguration) {
        let storage = KeychainLocalStorage(service: "com.lianghongjing.kitchenmanager.auth")
        let options = SupabaseClientOptions(
            auth: .init(
                storage: storage,
                storageKey: "kitchenmanager.auth.session",
                emitLocalSessionAsInitialSession: true
            )
        )
        client = SupabaseClient(
            supabaseURL: configuration.supabaseURL,
            supabaseKey: configuration.publishableKey,
            options: options
        )
    }

    var authStateChanges: AsyncStream<AuthStateChange> {
        AsyncStream { continuation in
            let task = Task { [client] in
                for await (event, session) in client.auth.authStateChanges {
                    switch (event, session) {
                    case (.signedOut, _), (.userDeleted, _):
                        continuation.yield(.signedOut)
                    case (_, let session?):
                        continuation.yield(.sessionUpdated(Self.map(session)))
                    default:
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func restoreSession() async throws -> AuthSession? {
        do {
            return Self.map(try await client.auth.session)
        } catch let error as AuthError where error.errorCode == .sessionNotFound {
            return nil
        } catch {
            throw Self.map(error)
        }
    }

    func signUp(email: String, password: String) async throws -> SignUpOutcome {
        do {
            let response = try await client.auth.signUp(email: email, password: password)
            if let session = response.session { return .signedIn(Self.map(session)) }
            return .confirmationRequired(email: response.user.email ?? email)
        } catch {
            throw Self.map(error)
        }
    }

    func signIn(email: String, password: String) async throws -> AuthSession {
        do {
            return Self.map(try await client.auth.signIn(email: email, password: password))
        } catch {
            throw Self.map(error)
        }
    }

    func signOut() async throws {
        do { try await client.auth.signOut() } catch { throw Self.map(error) }
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
