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
        let householdID = mergeFixtureHouseholdID
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

    private var mergeFixtureHouseholdID: UUID {
        // A conflict fixture owns its own isolated household, so the account page
        // must point at that one — otherwise the merge link would open a different
        // household than the seeded `.conflict` session belongs to.
        if let conflict = AccountLifecycleConflictFixture.active { return conflict.householdID }
        let arguments = ProcessInfo.processInfo.arguments
        let ids: [(String, String)] = [
            ("UITEST_MERGE_EMPTY", "00000000-0000-0000-0000-000000000011"),
            ("UITEST_MERGE_COUNTS", "00000000-0000-0000-0000-000000000012"),
            ("UITEST_MERGE_UNAUTHORIZED", "00000000-0000-0000-0000-000000000013"),
            ("UITEST_MERGE_OFFLINE", "00000000-0000-0000-0000-000000000014"),
            ("UITEST_MERGE_LOADING", "00000000-0000-0000-0000-000000000015"),
            ("UITEST_MERGE_RETRY_SUCCESS", "00000000-0000-0000-0000-000000000016"),
            ("UITEST_MERGE_LEGACY", "00000000-0000-0000-0000-000000000017")
        ]
        let raw = ids.first(where: { arguments.contains($0.0) })?.1 ?? "00000000-0000-0000-0000-000000000010"
        return UUID(uuidString: raw)!
    }
}

/// UI-5B2B-B1: deterministic conflict-screen states.
///
/// The conflict screen is only reachable when a *persisted* session already has
/// `status == .conflict`, and `GuestMergeController.preparePreview` deliberately
/// never regenerates a `.conflict` session — so seeding one is the whole
/// mechanism. Every scenario is local, fake and inert: no account, no token, no
/// network, no `SyncCoordinator`, and no mutation is ever staged or sent.
enum AccountLifecycleConflictFixture: String, CaseIterable {
    case sameIDQuantity = "UITEST_MERGE_CONFLICT_SAME_ID"
    case differentIDMetadata = "UITEST_MERGE_CONFLICT_DIFFERENT_ID"
    case expiry = "UITEST_MERGE_CONFLICT_EXPIRY"
    case ambiguous = "UITEST_MERGE_CONFLICT_AMBIGUOUS"
    case multiple = "UITEST_MERGE_CONFLICT_MULTIPLE"
    case longList = "UITEST_MERGE_CONFLICT_LONG"

    static var active: AccountLifecycleConflictFixture? {
        let arguments = ProcessInfo.processInfo.arguments
        return allCases.first { arguments.contains($0.rawValue) }
    }

    /// One isolated household per scenario, so no two fixtures can read or
    /// overwrite each other's persisted session.
    var householdID: UUID {
        let suffix: String
        switch self {
        case .sameIDQuantity: suffix = "31"
        case .differentIDMetadata: suffix = "32"
        case .expiry: suffix = "33"
        case .ambiguous: suffix = "34"
        case .multiple: suffix = "35"
        case .longList: suffix = "36"
        }
        return UUID(uuidString: "00000000-0000-0000-0000-0000000000\(suffix)")!
    }

    /// Isolated per scenario for the same reason as `householdID`.
    var sessionID: UUID {
        let suffix: String
        switch self {
        case .sameIDQuantity: suffix = "41"
        case .differentIDMetadata: suffix = "42"
        case .expiry: suffix = "43"
        case .ambiguous: suffix = "44"
        case .multiple: suffix = "45"
        case .longList: suffix = "46"
        }
        return UUID(uuidString: "00000000-0000-0000-0000-0000000000\(suffix)")!
    }

    private func localID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000005%02d", index))!
    }

    private func remoteID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000006%02d", index))!
    }

    /// Every candidate has `conflictReason != nil` and `userChoice == nil`, so all
    /// start unresolved and nothing appears pre-selected.
    var candidates: [InventoryMergeCandidate] {
        let expiry = Date(timeIntervalSince1970: 1_767_225_600)
        let laterExpiry = Date(timeIntervalSince1970: 1_769_904_000)
        switch self {
        case .sameIDQuantity:
            // Same stable id on both sides: keepLocal updates that family record.
            return [candidate(index: 1, name: "豆腐", unit: "块", localQuantity: 1, remoteQuantity: 3,
                              sameIdentity: true, reason: .quantityMismatch)]
        case .differentIDMetadata:
            // Different ids: keepLocal adds a new family record instead.
            return [candidate(index: 2, name: "大米", unit: "袋", localQuantity: 2, remoteQuantity: 2,
                              sameIdentity: false, reason: .metadataMismatch)]
        case .expiry:
            return [candidate(index: 3, name: "牛奶", unit: "盒", localQuantity: 1, remoteQuantity: 1,
                              sameIdentity: true, reason: .expiryMismatch,
                              localExpiry: expiry, remoteExpiry: laterExpiry)]
        case .ambiguous:
            return [candidate(index: 4, name: "鸡蛋", unit: "个", localQuantity: 6, remoteQuantity: 10,
                              sameIdentity: false, reason: .ambiguousDuplicate)]
        case .multiple:
            return [
                candidate(index: 1, name: "豆腐", unit: "块", localQuantity: 1, remoteQuantity: 3,
                          sameIdentity: true, reason: .quantityMismatch),
                candidate(index: 2, name: "大米", unit: "袋", localQuantity: 2, remoteQuantity: 2,
                          sameIdentity: false, reason: .metadataMismatch),
                candidate(index: 3, name: "牛奶", unit: "盒", localQuantity: 1, remoteQuantity: 1,
                          sameIdentity: true, reason: .expiryMismatch,
                          localExpiry: expiry, remoteExpiry: laterExpiry)
            ]
        case .longList:
            return (1...20).map { index in
                candidate(
                    index: index,
                    name: "冲突食材\(index)",
                    unit: "份",
                    localQuantity: Double(index),
                    remoteQuantity: Double(index + 1),
                    sameIdentity: index.isMultiple(of: 2),
                    reason: index.isMultiple(of: 3) ? .expiryMismatch : .quantityMismatch,
                    localExpiry: index.isMultiple(of: 3) ? expiry : nil,
                    remoteExpiry: index.isMultiple(of: 3) ? laterExpiry : nil
                )
            }
        }
    }

    private func candidate(
        index: Int,
        name: String,
        unit: String,
        localQuantity: Double,
        remoteQuantity: Double,
        sameIdentity: Bool,
        reason: InventoryMergeConflictReason,
        localExpiry: Date? = nil,
        remoteExpiry: Date? = nil
    ) -> InventoryMergeCandidate {
        let local = localID(index)
        return InventoryMergeCandidate(
            localItemId: local,
            name: name,
            unit: unit,
            localQuantity: localQuantity,
            localExpiryDate: localExpiry,
            remoteItemId: sameIdentity ? local : remoteID(index),
            remoteQuantity: remoteQuantity,
            remoteExpiryDate: remoteExpiry,
            remoteVersion: nil,
            action: .create,
            conflictReason: reason,
            userChoice: nil
        )
    }

    /// A `.conflict` session whose every candidate still needs a decision.
    /// `remoteSnapshotHash` is populated so the session resembles one produced by
    /// a real pre-merge read; it is never used to write anything, because these
    /// fixtures never confirm.
    func session(userID: UUID) -> GuestMergeSession {
        let now = Date(timeIntervalSince1970: 1_767_225_600)
        let candidates = self.candidates
        let plan = InventoryMergePlan(
            sessionId: sessionID,
            householdId: householdID,
            generatedAt: now,
            sourceCount: candidates.count,
            candidates: candidates,
            skippedItemIds: [],
            planHash: "fixture-plan-\(rawValue)",
            knownRemoteItemCount: candidates.count,
            remoteSnapshotHash: "fixture-snapshot-\(rawValue)",
            remoteSnapshotFetchedAt: now
        )
        return GuestMergeSession(
            id: sessionID,
            userId: userID,
            householdId: householdID,
            entityType: .inventoryItem,
            status: .conflict,
            createdAt: now,
            updatedAt: now,
            confirmedAt: nil,
            completedAt: nil,
            cancelledAt: nil,
            rollbackAvailableUntil: nil,
            localSnapshot: candidates.map {
                GuestInventorySnapshotItem(
                    id: $0.localItemId, name: $0.name, unit: $0.unit,
                    quantity: $0.localQuantity, expiryDate: $0.localExpiryDate
                )
            },
            plan: plan,
            plannedItemCount: 0,
            uploadedItemCount: 0,
            conflictCount: candidates.count,
            failedCount: 0,
            lastErrorCode: nil,
            createdEntityIds: [],
            mergeVersion: 1
        )
    }

    /// Writes the scenario's session so the merge flow opens straight onto the
    /// conflict screen. A local persistence write only — no network, no
    /// coordinator, no staged mutation.
    ///
    /// Seeds at most once per (user, household). `saveGuestMergeSession` upserts
    /// by session id, so a repeat call could not duplicate the session — but it
    /// *would* rewrite an already-resolved session back to all-unresolved, which
    /// would silently undo a choice the test just made and mask a real regression.
    /// SwiftUI may run `.task` more than once, so the existence check is the
    /// safeguard, not an optimisation.
    ///
    /// - Returns: true once the scenario's session is present, whether this call
    ///   wrote it or found it already there. Tests wait on this rather than
    ///   sleeping.
    @discardableResult
    static func seedIfRequested(persistence: any SyncPersistenceProtocol, userID: UUID) async -> Bool {
        guard let fixture = active else { return false }
        return await fixture.seed(persistence: persistence, userID: userID)
    }

    /// Fixtures already seeded by *this* process.
    ///
    /// The scope matters. Within a process the seed must not repeat, or a second
    /// `.task` run would rewrite an already-resolved session back to unresolved
    /// and silently undo a choice the test just made. Across processes it must
    /// repeat, because the simulator's store outlives the app: without a fresh
    /// write, a scenario a previous test case resolved would be inherited in its
    /// resolved state by the next launch.
    private static var seededThisProcess: Set<String> = []

    /// The launch-argument-independent half of `seedIfRequested`, so both halves
    /// of that scoping can be proven deterministically in a unit test.
    @discardableResult
    func seed(persistence: any SyncPersistenceProtocol, userID: UUID) async -> Bool {
        if Self.seededThisProcess.contains(rawValue) { return true }
        do {
            // Upserts by session id, so this replaces any stale copy left by an
            // earlier launch rather than adding a second one.
            try await persistence.saveGuestMergeSession(session(userID: userID))
            Self.seededThisProcess.insert(rawValue)
            return true
        } catch {
            return false
        }
    }

    /// Unit tests share one process, so each case has to start from a clean
    /// slate to exercise the first-seed path.
    static func resetSeedTrackingForTesting() { seededThisProcess.removeAll() }
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
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("UITEST_MERGE_LOADING") {
            try await Task.sleep(for: .seconds(2))
        }
        if arguments.contains("UITEST_MERGE_UNAUTHORIZED") {
            throw SyncError.unauthorized
        }
        if arguments.contains("UITEST_MERGE_OFFLINE") {
            throw SyncError.transport
        }
        if arguments.contains("UITEST_MERGE_MALFORMED") {
            throw SyncError.decoding
        }

        let changes: [SyncChangeEnvelope]
        if arguments.contains("UITEST_MERGE_COUNTS") || arguments.contains("UITEST_MERGE_RETRY_SUCCESS") || arguments.contains("UITEST_MERGE_LEGACY") {
            let remoteID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
            changes = [SyncChangeEnvelope(
                sequence: .zero,
                entityType: .inventoryItem,
                entityId: remoteID,
                operation: .upsert,
                version: try! SyncCursorValue("1"),
                changedAt: Date(timeIntervalSince1970: 1_735_689_600),
                data: [
                    "name": .string("豆腐"),
                    "quantity": .number(3),
                    "unit": .string("块"),
                    "isStaple": .bool(false)
                ]
            )]
        } else if arguments.contains("UITEST_MERGE_EMPTY") {
            changes = []
        } else if AccountLifecycleConflictFixture.active != nil {
            // The conflict scenarios seed their own `.conflict` session, so this
            // pre-merge read only has to succeed: `preparePreview` resumes the
            // seeded session and never regenerates a `.conflict` plan. Returning
            // no changes keeps this a read that writes nothing.
            changes = []
        } else {
            throw SyncError.transport
        }
        return SyncChangesResponse(
            scopeType: scope.type,
            scopeId: scope.id,
            cursor: cursor,
            hasMore: false,
            changes: changes
        )
    }
    func sendMutations(scope: SyncScope, mutations: [SyncMutation]) async throws -> SyncMutationBatchResponse {
        throw SyncError.transport
    }
}

#endif
