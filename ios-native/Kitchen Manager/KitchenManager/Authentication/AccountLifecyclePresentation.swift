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
        if let summary = AccountLifecycleSummaryFixture.active { return summary.householdID }
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

/// UI-5B2B-B2A: deterministic *preview* states for the corrected summary, the
/// read-only resolved review, and the confirmation copy.
///
/// Distinct from `AccountLifecycleConflictFixture`: these sessions are
/// `.previewReady`, because everything this phase changes lives on the preview
/// screen. Candidates arrive with `userChoice` already recorded where the
/// scenario needs a resolved outcome — set directly on the fixture value, never
/// by calling `resolveConflict`, which this phase must not invoke.
///
/// Same safety envelope as the B1 fixtures: local, fake, inert. No account, no
/// token, no network, no `SyncCoordinator`, no staged mutation.
enum AccountLifecycleSummaryFixture: String, CaseIterable {
    /// creates + updates + keepRemote + skip + unresolved, all at once.
    case mixed = "UITEST_MERGE_SUMMARY_MIXED"
    /// Every conflict decided; some will upload.
    case resolvedOnly = "UITEST_MERGE_SUMMARY_RESOLVED_ONLY"
    /// Every conflict skipped — nothing to upload, nothing outstanding.
    case allSkip = "UITEST_MERGE_SUMMARY_ALL_SKIP"
    /// Every conflict kept-remote — nothing to upload, nothing outstanding.
    case keepRemoteOnly = "UITEST_MERGE_SUMMARY_KEEP_REMOTE_ONLY"
    /// keepRemote and skip mixed, still zero uploadable.
    case keepRemoteAndSkip = "UITEST_MERGE_SUMMARY_KEEP_REMOTE_AND_SKIP"
    /// Unresolved conflicts alongside uploadable entries.
    case unresolvedWithUploadable = "UITEST_MERGE_SUMMARY_UNRESOLVED_UPLOADABLE"
    /// Unresolved conflicts with nothing uploadable — must never read "先合并其余 0 条".
    case unresolvedZeroUpload = "UITEST_MERGE_SUMMARY_UNRESOLVED_ZERO_UPLOAD"
    /// 20 resolved conflicts, for scroll and grouping behavior.
    case longResolved = "UITEST_MERGE_SUMMARY_LONG_RESOLVED"
    /// No conflicts at all — the ordinary merge, to prove no copy regression.
    case noConflict = "UITEST_MERGE_SUMMARY_NO_CONFLICT"
    /// Resumed after a *partial* confirm: this session already uploaded part of
    /// the plan, hit leftover conflicts, and returned to `.previewReady` once the
    /// last one was resolved. Its plan therefore mixes already-uploaded choices
    /// with newly-decided ones, and no copy may claim either that nothing has
    /// been uploaded or that the whole plan is still upcoming.
    case postPartialConfirmResumed = "UITEST_MERGE_SUMMARY_POST_PARTIAL_CONFIRM"

    static var active: AccountLifecycleSummaryFixture? {
        let arguments = ProcessInfo.processInfo.arguments
        return allCases.first { arguments.contains($0.rawValue) }
    }

    /// One isolated household per scenario, distinct from every B1 conflict
    /// household (…0031–0036) and every legacy merge household (…0010–0017).
    var householdID: UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000000%02d", 51 + index))!
    }

    var sessionID: UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000000%02d", 61 + index))!
    }

    private var index: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    private func localID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000007%02d", n))!
    }

    private func remoteID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000008%02d", n))!
    }

    private static let expiry = Date(timeIntervalSince1970: 1_767_225_600)
    private static let laterExpiry = Date(timeIntervalSince1970: 1_769_904_000)

    /// A plain non-conflict candidate: `conflictReason == nil`, so it can never
    /// appear in the resolved review, and it counts under 将新增/将更新/无需处理.
    private func plain(_ n: Int, _ name: String, action: InventoryMergeAction) -> InventoryMergeCandidate {
        InventoryMergeCandidate(
            localItemId: localID(n), name: name, unit: "份",
            localQuantity: Double(n), localExpiryDate: nil,
            remoteItemId: action == .create ? nil : localID(n),
            remoteQuantity: action == .create ? nil : Double(n),
            remoteExpiryDate: nil, remoteVersion: nil,
            action: action, conflictReason: nil, userChoice: nil
        )
    }

    /// A conflict candidate. `choice == nil` leaves it unresolved; otherwise the
    /// recorded choice is applied through the model's own `applyingChoice`, so
    /// `action` and `forkedLocalItemId` are exactly what the real flow produces.
    private func conflict(
        _ n: Int, _ name: String, sameIdentity: Bool,
        reason: InventoryMergeConflictReason, choice: InventoryMergeConflictChoice?
    ) -> InventoryMergeCandidate {
        let local = localID(n)
        let base = InventoryMergeCandidate(
            localItemId: local, name: name, unit: "份",
            localQuantity: Double(n), localExpiryDate: reason == .expiryMismatch ? Self.expiry : nil,
            remoteItemId: sameIdentity ? local : remoteID(n),
            remoteQuantity: Double(n + 1),
            remoteExpiryDate: reason == .expiryMismatch ? Self.laterExpiry : nil,
            remoteVersion: nil, action: .create, conflictReason: reason, userChoice: nil
        )
        guard let choice else { return base }
        return base.applyingChoice(choice)
    }

    var candidates: [InventoryMergeCandidate] {
        switch self {
        case .mixed:
            return [
                plain(1, "面粉", action: .create),
                plain(2, "白糖", action: .create),
                plain(3, "酱油", action: .update),
                plain(4, "食盐", action: .skip),
                conflict(5, "豆腐", sameIdentity: true, reason: .quantityMismatch, choice: .keepLocal),
                conflict(6, "大米", sameIdentity: false, reason: .metadataMismatch, choice: .keepRemote),
                conflict(7, "牛奶", sameIdentity: true, reason: .expiryMismatch, choice: .skip),
                conflict(8, "鸡蛋", sameIdentity: true, reason: .quantityMismatch, choice: .keepBoth),
                conflict(9, "青椒", sameIdentity: true, reason: .quantityMismatch, choice: nil),
                conflict(10, "土豆", sameIdentity: false, reason: .ambiguousDuplicate, choice: nil)
            ]
        case .resolvedOnly:
            return [
                conflict(11, "豆腐", sameIdentity: true, reason: .quantityMismatch, choice: .keepLocal),
                conflict(12, "大米", sameIdentity: false, reason: .metadataMismatch, choice: .keepRemote),
                conflict(13, "牛奶", sameIdentity: true, reason: .expiryMismatch, choice: .keepBoth),
                conflict(14, "鸡蛋", sameIdentity: true, reason: .quantityMismatch, choice: .skip)
            ]
        case .allSkip:
            return (21...23).map {
                conflict($0, "跳过食材\($0 - 20)", sameIdentity: true, reason: .quantityMismatch, choice: .skip)
            }
        case .keepRemoteOnly:
            return (31...33).map {
                conflict($0, "保留家庭食材\($0 - 30)", sameIdentity: true, reason: .quantityMismatch, choice: .keepRemote)
            }
        case .keepRemoteAndSkip:
            return [
                conflict(41, "保留家庭豆腐", sameIdentity: true, reason: .quantityMismatch, choice: .keepRemote),
                conflict(42, "跳过大米", sameIdentity: false, reason: .metadataMismatch, choice: .skip)
            ]
        case .unresolvedWithUploadable:
            return [
                plain(51, "面粉", action: .create),
                plain(52, "酱油", action: .update),
                conflict(53, "豆腐", sameIdentity: true, reason: .quantityMismatch, choice: .keepLocal),
                conflict(54, "青椒", sameIdentity: true, reason: .quantityMismatch, choice: nil),
                conflict(55, "土豆", sameIdentity: false, reason: .ambiguousDuplicate, choice: nil)
            ]
        case .unresolvedZeroUpload:
            return [
                conflict(61, "保留家庭豆腐", sameIdentity: true, reason: .quantityMismatch, choice: .keepRemote),
                conflict(62, "跳过大米", sameIdentity: true, reason: .expiryMismatch, choice: .skip),
                conflict(63, "青椒", sameIdentity: true, reason: .quantityMismatch, choice: nil),
                conflict(64, "土豆", sameIdentity: false, reason: .ambiguousDuplicate, choice: nil)
            ]
        case .longResolved:
            return (1...20).map { n in
                let choices: [InventoryMergeConflictChoice] = [.keepLocal, .keepRemote, .keepBoth, .skip]
                return conflict(
                    n, "已处理食材\(n)",
                    sameIdentity: n.isMultiple(of: 2),
                    reason: n.isMultiple(of: 3) ? .expiryMismatch : .quantityMismatch,
                    choice: choices[(n - 1) % 4]
                )
            }
        case .noConflict:
            return [
                plain(71, "面粉", action: .create),
                plain(72, "白糖", action: .create),
                plain(73, "酱油", action: .update),
                plain(74, "食盐", action: .skip)
            ]
        case .postPartialConfirmResumed:
            return [
                // Uploaded by the first confirm — still listed in the plan,
                // because nothing removes a confirmed candidate from it.
                plain(81, "面粉", action: .create),
                plain(82, "酱油", action: .update),
                // Decided after that confirm, awaiting the next one.
                conflict(83, "豆腐", sameIdentity: true, reason: .quantityMismatch, choice: .keepLocal),
                conflict(84, "大米", sameIdentity: false, reason: .metadataMismatch, choice: .keepRemote),
                conflict(85, "牛奶", sameIdentity: true, reason: .expiryMismatch, choice: .skip)
            ]
        }
    }

    /// A `.previewReady` session, because every surface this phase changes is on
    /// the preview screen.
    ///
    /// `planHash`/`remoteSnapshotHash` are computed with the real planner against
    /// `localItems` (the live local inventory at seed time) and an empty remote
    /// snapshot — which is exactly what the fixture transport returns. Without
    /// that, `preparePreview` would find the plan stale and regenerate it for a
    /// `.previewReady` session, discarding the recorded choices this phase needs
    /// to display. A literal placeholder hash cannot work here, unlike the B1
    /// `.conflict` fixtures, which `preparePreview` never regenerates.
    func session(userID: UUID, localItems: [InventoryItem]) -> GuestMergeSession {
        let now = Date(timeIntervalSince1970: 1_767_225_600)
        let candidates = self.candidates
        let remoteHash = InventoryMergePlanner.remoteSnapshotHash([])
        let plan = InventoryMergePlan(
            sessionId: sessionID,
            householdId: householdID,
            generatedAt: now,
            sourceCount: candidates.count,
            candidates: candidates,
            skippedItemIds: [],
            planHash: InventoryMergePlanner.planHash(
                sessionId: sessionID, householdId: householdID,
                localItems: localItems, remoteSnapshotHash: remoteHash
            ),
            knownRemoteItemCount: candidates.filter { $0.remoteItemId != nil }.count,
            remoteSnapshotHash: remoteHash,
            remoteSnapshotFetchedAt: now
        )
        return GuestMergeSession(
            id: sessionID,
            userId: userID,
            householdId: householdID,
            entityType: .inventoryItem,
            status: .previewReady,
            createdAt: now,
            updatedAt: now,
            // The post-partial state is the only one that has already confirmed
            // once; every other scenario is a first pass.
            confirmedAt: self == .postPartialConfirmResumed ? now : nil,
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
            uploadedItemCount: self == .postPartialConfirmResumed ? 2 : 0,
            conflictCount: candidates.filter { $0.needsDecision }.count,
            failedCount: 0,
            lastErrorCode: nil,
            createdEntityIds: [],
            mergeVersion: 1
        )
    }

    /// Seeded at most once per process, for exactly the reasons documented on
    /// `AccountLifecycleConflictFixture.seededThisProcess`: within a process a
    /// repeat `.task` must not clobber state a test has changed, while a new
    /// process must re-seed so nothing leaks between UI test cases.
    private static var seededThisProcess: Set<String> = []

    @discardableResult
    static func seedIfRequested(
        persistence: any SyncPersistenceProtocol, userID: UUID, localItems: [InventoryItem]
    ) async -> Bool {
        guard let fixture = active else { return false }
        return await fixture.seed(persistence: persistence, userID: userID, localItems: localItems)
    }

    @discardableResult
    func seed(
        persistence: any SyncPersistenceProtocol, userID: UUID, localItems: [InventoryItem]
    ) async -> Bool {
        if Self.seededThisProcess.contains(rawValue) { return true }
        do {
            try await persistence.saveGuestMergeSession(session(userID: userID, localItems: localItems))
            Self.seededThisProcess.insert(rawValue)
            return true
        } catch {
            return false
        }
    }

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
        } else if AccountLifecycleConflictFixture.active != nil || AccountLifecycleSummaryFixture.active != nil {
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
