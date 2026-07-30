import Foundation

#if DEBUG

/// Credential-free, local-only account presentation state used by UI tests.
/// This type is intentionally compiled only for Debug and never creates a
/// Supabase session or performs a network request.
enum AccountLifecycleFixture: Equatable {
    case owner
    case member
    case loading
    case accountError
    case syncIdle
    case syncNotEnrolled
    case syncCompleted
    case syncPending
    case syncRunning
    case syncOffline
    case syncError
    case syncRateLimited
    case syncUpgradeRequired
    case syncNoHousehold
    case signOutFailure

    static var active: AccountLifecycleFixture? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let raw = arguments.first(where: { $0.hasPrefix("UITEST_ACCOUNT_") }) else { return nil }
        switch raw {
        case "UITEST_ACCOUNT_OWNER": return .owner
        case "UITEST_ACCOUNT_MEMBER": return .member
        case "UITEST_ACCOUNT_LOADING": return .loading
        case "UITEST_ACCOUNT_ERROR": return .accountError
        case "UITEST_ACCOUNT_SYNC_IDLE": return .syncIdle
        case "UITEST_ACCOUNT_SYNC_NOT_ENROLLED": return .syncNotEnrolled
        case "UITEST_ACCOUNT_SYNC_COMPLETED": return .syncCompleted
        case "UITEST_ACCOUNT_SYNC_PENDING": return .syncPending
        case "UITEST_ACCOUNT_SYNC_RUNNING": return .syncRunning
        case "UITEST_ACCOUNT_SYNC_OFFLINE": return .syncOffline
        case "UITEST_ACCOUNT_SYNC_ERROR": return .syncError
        case "UITEST_ACCOUNT_SYNC_RATE_LIMITED": return .syncRateLimited
        case "UITEST_ACCOUNT_SYNC_UPGRADE_REQUIRED": return .syncUpgradeRequired
        case "UITEST_ACCOUNT_SYNC_NO_HOUSEHOLD": return .syncNoHousehold
        case "UITEST_ACCOUNT_SIGNOUT_FAILURE": return .signOutFailure
        default: return nil
        }
    }

    var user: AuthUser {
        AuthUser(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, email: "fixture@example.com")
    }

    var session: AuthSession { AuthSession(user: user, accessToken: "fixture-token-never-sent") }

    var account: CurrentAccount {
        let householdID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let role = self == .member ? "member" : "owner"
        return CurrentAccount(
            user: AccountProfile(id: user.id, email: user.email, displayName: self == .member ? "家庭成员" : "厨房主人"),
            households: self == .syncNoHousehold
                ? []
                : [AccountHousehold(id: householdID, name: "家庭厨房", role: role)]
        )
    }

    var syncPresentationState: InventorySyncPresentationState {
        switch self {
        case .syncNotEnrolled: return .notEnrolled
        case .syncCompleted: return .completed
        case .syncPending: return .pending(count: 3)
        case .syncRunning: return .syncing
        case .syncOffline: return .offline
        case .syncError: return .error
        case .syncRateLimited: return .rateLimited(retryAfter: Date().addingTimeInterval(45))
        case .syncUpgradeRequired: return .upgradeRequired
        case .syncNoHousehold: return .noHousehold
        case .syncIdle: return .idle
        default: return .featureDisabled
        }
    }

    var syncTitle: String {
        switch self {
        case .syncCompleted: "已同步"
        case .syncError: "同步遇到问题，可重试"
        case .syncIdle: "已同步"
        default: "尚未开启"
        }
    }

    var syncDetail: String? {
        self == .syncError ? "当前使用本机数据，稍后可重试。" : nil
    }

    var shouldFailSignOut: Bool { self == .signOutFailure }
}

@MainActor
final class AccountLifecycleFixtureAuthService: AuthService {
    let fixture: AccountLifecycleFixture

    init(fixture: AccountLifecycleFixture) { self.fixture = fixture }

    var authStateChanges: AsyncStream<AuthStateChange> { AsyncStream { _ in } }
    func restoreSession() async throws -> AuthSession? { fixture.session }
    func signUp(email: String, password: String) async throws -> SignUpOutcome { .signedIn(fixture.session) }
    func signIn(email: String, password: String) async throws -> AuthSession { fixture.session }
    func reauthenticate(email: String, password: String) async throws -> AuthSession { fixture.session }
    func signOut() async throws {
        if fixture.shouldFailSignOut { throw AuthenticationError.unavailable }
    }
}

@MainActor
final class AccountLifecycleFixtureAccountService: AccountService {
    let fixture: AccountLifecycleFixture

    init(fixture: AccountLifecycleFixture) { self.fixture = fixture }

    func currentAccount(accessToken: String) async throws -> CurrentAccount {
        if fixture == .loading {
            try await Task.sleep(for: .seconds(8))
        }
        if fixture == .accountError {
            throw AccountServiceError.temporarilyUnavailable
        }
        return fixture.account
    }
}

struct AccountLifecycleFixtureTransport: SyncTransport {
    func bootstrap() async throws -> SyncBootstrapResponse { throw SyncError.transport }
    func fetchChanges(scope: SyncScope, after cursor: SyncCursorValue, limit: Int) async throws -> SyncChangesResponse {
        throw SyncError.transport
    }
    func sendMutations(scope: SyncScope, mutations: [SyncMutation]) async throws -> SyncMutationBatchResponse {
        throw SyncError.transport
    }
}

#endif
