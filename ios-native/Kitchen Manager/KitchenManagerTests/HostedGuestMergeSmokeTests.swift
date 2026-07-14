import XCTest
@testable import KitchenManager

/// A deliberately opt-in integration test, mirroring `HostedSyncSmokeUITests`.
/// It compiles into every ordinary `xcodebuild test` run (visible and
/// explicitly skipped, never silently absent), but its body only runs when
/// `GUEST_MERGE_SMOKE_ENABLED` + `INVENTORY_SYNC_ENABLED` + development
/// environment are all set in Local.xcconfig and two distinct real
/// development test accounts are supplied via environment variables —
/// otherwise it safely `XCTSkip`s. Credentials are read only inside this
/// test process; they are never logged, embedded in a launch environment,
/// or written to any file this session produces.
@MainActor
final class HostedGuestMergeSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard !environment("TEST_USER_A_EMAIL").isEmpty, !environment("TEST_USER_A_PASSWORD").isEmpty,
              !environment("TEST_USER_B_EMAIL").isEmpty, !environment("TEST_USER_B_PASSWORD").isEmpty else {
            throw XCTSkip("Hosted Guest merge smoke credentials were not supplied.")
        }
        guard GuestMergeSmokeConfiguration.load().isAvailable else {
            throw XCTSkip("GUEST_MERGE_SMOKE_ENABLED, INVENTORY_SYNC_ENABLED, and the development environment marker must all be set in Local.xcconfig for this explicit hosted run.")
        }
    }

    func testControlledDevelopmentGuestMergeSmoke() async throws {
        let emailA = environment("TEST_USER_A_EMAIL")
        let passwordA = environment("TEST_USER_A_PASSWORD")
        let emailB = environment("TEST_USER_B_EMAIL")
        let passwordB = environment("TEST_USER_B_PASSWORD")

        let authStoreA = AuthStore(
            authService: SupabaseAuthService(configuration: try AuthConfiguration.load()),
            accountService: UnavailableAccountService()
        )
        let authStoreB = AuthStore(
            authService: SupabaseAuthService(configuration: try AuthConfiguration.load()),
            accountService: UnavailableAccountService()
        )

        let signedInA = await authStoreA.signIn(email: emailA, password: passwordA)
        XCTAssertTrue(signedInA, "development test account A sign-in failed")
        let signedInB = await authStoreB.signIn(email: emailB, password: passwordB)
        XCTAssertTrue(signedInB, "development test account B sign-in failed")

        let runner = GuestMergeSmokeRunner(smokeConfiguration: .load())
        let report = try await runner.run(
            authStoreA: authStoreA,
            authStoreB: authStoreB,
            reSignInA: {
                _ = await authStoreA.signIn(email: emailA, password: passwordA)
            }
        )

        XCTAssertTrue(report.previewPerformedZeroNetworkWrites)
        XCTAssertTrue(report.createApplied)
        XCTAssertTrue(report.duplicateHandledWithoutASecondRecord)
        XCTAssertTrue(report.quantityConflictDetectedNotAutoCreated)
        XCTAssertTrue(report.expiryConflictDetectedNotAutoOverwritten)
        XCTAssertTrue(report.metadataConflictDetected)
        XCTAssertTrue(report.ambiguousDuplicateNeverAutoSelected)
        XCTAssertTrue(report.planDriftInvalidatedTheOldPlan)
        XCTAssertTrue(report.sessionRecoveredAfterSimulatedRestart)
        XCTAssertTrue(report.logoutStoppedFurtherRequests)
        XCTAssertTrue(report.sameAccountResumedAfterReLogin)
        XCTAssertTrue(report.userBCannotSeeUserASession)
        XCTAssertTrue(report.rollbackRemovedOnlyThisSessionsCreates)
        XCTAssertTrue(report.finalPullSawTheDeleteTombstone)
        XCTAssertTrue(report.guestBoundaryUnchanged)

        await authStoreA.signOut()
    }

    /// Phase 2B-2.5: a minimal, dedicated hosted check for the same-id
    /// `keepBoth` identity-fork fix only — does not repeat the full Phase
    /// 2B-2 18-point matrix (that is `testControlledDevelopmentGuestMergeSmoke`
    /// above). Gated by the exact same flags/credentials.
    func testControlledDevelopmentSameIdKeepBothIdentityFork() async throws {
        let emailA = environment("TEST_USER_A_EMAIL")
        let passwordA = environment("TEST_USER_A_PASSWORD")
        let authStoreA = AuthStore(
            authService: SupabaseAuthService(configuration: try AuthConfiguration.load()),
            accountService: UnavailableAccountService()
        )
        let signedInA = await authStoreA.signIn(email: emailA, password: passwordA)
        XCTAssertTrue(signedInA, "development test account A sign-in failed")

        let runner = GuestMergeSmokeRunner(smokeConfiguration: .load())
        let passed = try await runner.runIdentityForkMinimalSmoke(authStoreA: authStoreA)
        XCTAssertTrue(passed)

        await authStoreA.signOut()
    }

    /// Phase 2B-4: a minimal, dedicated hosted check for the synced-scope
    /// CRUD mutation-staging path only — does not repeat the full Phase
    /// 2B-2 matrix or the Phase 2B-2.5 fork check. Gated by the exact same
    /// flags/credentials.
    func testControlledDevelopmentInventoryCrudSync() async throws {
        let emailA = environment("TEST_USER_A_EMAIL")
        let passwordA = environment("TEST_USER_A_PASSWORD")
        let authStoreA = AuthStore(
            authService: SupabaseAuthService(configuration: try AuthConfiguration.load()),
            accountService: UnavailableAccountService()
        )
        let signedInA = await authStoreA.signIn(email: emailA, password: passwordA)
        XCTAssertTrue(signedInA, "development test account A sign-in failed")

        let runner = GuestMergeSmokeRunner(smokeConfiguration: .load())
        let passed = try await runner.runInventoryCrudSyncMinimalSmoke(authStoreA: authStoreA)
        XCTAssertTrue(passed)

        await authStoreA.signOut()
    }

    /// Phase 2B-6: a minimal, dedicated hosted development dogfood check —
    /// create/sync/update/sync/offline-stage/reconnect+sync/simulated
    /// restart/duplicate-safe retry/delete/sync/tombstone/diagnostics/
    /// consistency-checker-clean. Does not repeat the Phase 2B-2/2B-3 merge
    /// preview matrix or the Phase 2B-4 CRUD matrix. Gated by the exact same
    /// flags/credentials as the other hosted tests in this file.
    func testControlledDevelopmentInventoryDogfoodSmoke() async throws {
        let emailA = environment("TEST_USER_A_EMAIL")
        let passwordA = environment("TEST_USER_A_PASSWORD")
        let authStoreA = AuthStore(
            authService: SupabaseAuthService(configuration: try AuthConfiguration.load()),
            accountService: UnavailableAccountService()
        )
        let signedInA = await authStoreA.signIn(email: emailA, password: passwordA)
        XCTAssertTrue(signedInA, "development test account A sign-in failed")

        let runner = GuestMergeSmokeRunner(smokeConfiguration: .load())
        let passed = try await runner.runInventoryDogfoodMinimalSmoke(authStoreA: authStoreA)
        XCTAssertTrue(passed)

        await authStoreA.signOut()
    }

    private func environment(_ name: String) -> String {
        ProcessInfo.processInfo.environment[name] ?? ""
    }
}
