import XCTest
import SwiftData
import Combine
import Supabase
@testable import KitchenManager

@MainActor
final class AccountDeletionOwnershipTests: XCTestCase {
    private var directory: URL!
    private var suites: [String] = []
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "deletion-ownership-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
        try FileManager.default.removeItem(at: directory)
    }
    private func defaults() -> UserDefaults {
        let suite = "deletion-ownership-\(UUID())"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    func testPendingDeletionCannotClearAnotherAccountThroughEitherEntryPoint() async throws {
        for useConfirm in [false, true] {
            let f = try await fixture()
            f.fault.failuresRemaining = 1
            let initial = await f.controller.confirmDeletion(authStore: f.auth, kitchenStore: f.kitchen)
            XCTAssertFalse(initial)
            XCTAssertTrue(f.controller.needsLocalCleanup)
            await f.auth.signOut()
            f.authService.userID = UUID()
            _ = await f.auth.signIn(email: "b@example.com", password: "fixture")
            let records = try await seedCurrentContext(f)
            let result = useConfirm
                ? await f.controller.confirmDeletion(authStore: f.auth, kitchenStore: f.kitchen)
                : await f.controller.retryLocalCleanup(authStore: f.auth, kitchenStore: f.kitchen)
            XCTAssertFalse(result, "A's pending outcome must not complete against B")
            try await assertPreserved(f, records: records)
            XCTAssertEqual(f.auth.currentUserID, f.authService.userID)
            XCTAssertEqual(f.authService.signOuts, 1, "only the deliberate account switch may sign out")
            XCTAssertTrue(f.controller.needsLocalCleanup)
            XCTAssertFalse(f.controller.didComplete)
            XCTAssertNotNil(f.controller.localCleanupBlockedReason)
            XCTAssertEqual(f.remote.confirmations, 1)
        }
    }

    func testPendingDeletionCannotClearFreshSameUserContextThroughEitherEntryPoint() async throws {
        for useConfirm in [false, true] {
            let f = try await fixture()
            f.fault.failuresRemaining = 1
            let initial = await f.controller.confirmDeletion(authStore: f.auth, kitchenStore: f.kitchen)
            XCTAssertFalse(initial)
            XCTAssertTrue(f.controller.needsLocalCleanup)
            let originalContext = try XCTUnwrap(f.auth.sessionOwnership.context)
            let userID = try XCTUnwrap(f.auth.currentUserID)
            var sawGuest = false
            let observation = f.auth.$status.sink { if $0 == .guest { sawGuest = true } }
            defer { observation.cancel() }

            let signedIn = await f.auth.signIn(email: "a@example.com", password: "fixture")
            XCTAssertTrue(signedIn)
            let freshContext = try XCTUnwrap(f.auth.sessionOwnership.context)
            XCTAssertNotEqual(freshContext, originalContext)
            XCTAssertEqual(f.auth.currentUserID, userID)
            let records = try await seedCurrentContext(f)
            let result = useConfirm
                ? await f.controller.confirmDeletion(authStore: f.auth, kitchenStore: f.kitchen)
                : await f.controller.retryLocalCleanup(authStore: f.auth, kitchenStore: f.kitchen)

            XCTAssertFalse(result, "the same user UUID must not transfer an old cleanup permit to fresh authentication")
            try await assertPreserved(f, records: records)
            XCTAssertFalse(sawGuest)
            XCTAssertEqual(f.auth.currentUserID, userID)
            XCTAssertEqual(f.auth.sessionOwnership.context, freshContext)
            XCTAssertEqual(f.authService.signOuts, 0)
            XCTAssertTrue(f.controller.needsLocalCleanup)
            XCTAssertFalse(f.controller.didComplete)
            XCTAssertNotNil(f.controller.localCleanupBlockedReason)
            XCTAssertEqual(f.remote.confirmations, 1)
        }
    }

    func testSessionLossCannotAuthorizeGuestCleanupOrRestoredSameAccount() async throws {
        for restoreSameAccount in [false, true] {
            let f = try await fixture()
            f.fault.failuresRemaining = 1
            _ = await f.controller.confirmDeletion(authStore: f.auth, kitchenStore: f.kitchen)
            await f.auth.signOut()
            if restoreSameAccount { _ = await f.auth.signIn(email: "a@example.com", password: "fixture") }
            let records = try await seedCurrentContext(f)
            let result = await f.controller.retryLocalCleanup(authStore: f.auth, kitchenStore: f.kitchen)
            XCTAssertFalse(result, "a lost session ends cleanup ownership, even if the same UUID later returns")
            try await assertPreserved(f, records: records)
            XCTAssertTrue(f.controller.needsLocalCleanup)
            XCTAssertFalse(f.controller.didComplete)
            XCTAssertEqual(f.remote.confirmations, 1)
        }
    }

    func testPendingDeletionCannotClearAReplacementKitchenStore() async throws {
        let f = try await fixture()
        f.fault.failuresRemaining = 1
        _ = await f.controller.confirmDeletion(authStore: f.auth, kitchenStore: f.kitchen)
        let replacement = KitchenStore(userDefaults: defaults(),
                                       persistence: KitchenPersistenceFactory.isolatedInMemory(),
                                       recoverySnapshot: KitchenRecoverySnapshotStore(directoryURL: directory.appending(path: UUID().uuidString)))
        replacement.addInventory(name: "替换上下文", quantity: 4, unit: "份", expiryDate: nil)
        let before = replacement.inventory
        let result = await f.controller.retryLocalCleanup(authStore: f.auth, kitchenStore: replacement)
        XCTAssertFalse(result)
        XCTAssertEqual(replacement.inventory, before)
        XCTAssertEqual(f.auth.currentUserID, f.authService.userID)
        XCTAssertTrue(f.controller.needsLocalCleanup)
        XCTAssertEqual(f.remote.confirmations, 1)
    }

    func testAccountSwitchDuringExternalConfirmationPreservesNewContext() async throws {
        let f = try await fixture()
        let gate = AsyncGate()
        f.remote.gate = gate
        let operation = Task { await f.controller.confirmDeletion(authStore: f.auth, kitchenStore: f.kitchen) }
        await gate.waitUntilEntered()
        await f.auth.signOut()
        f.authService.userID = UUID()
        _ = await f.auth.signIn(email: "b@example.com", password: "fixture")
        let records = try await seedCurrentContext(f)
        gate.resume()
        let result = await operation.value
        XCTAssertFalse(result)
        try await assertPreserved(f, records: records)
        XCTAssertEqual(f.auth.currentUserID, f.authService.userID)
        XCTAssertEqual(f.authService.signOuts, 1)
        XCTAssertTrue(f.controller.needsLocalCleanup, "remote completion of A must remain recorded")
        XCTAssertFalse(f.controller.didComplete)
        XCTAssertEqual(f.remote.confirmations, 1)
    }

    func testFreshSameUserAuthenticationDuringExternalConfirmationPreservesNewContext() async throws {
        let f = try await fixture()
        let gate = AsyncGate()
        f.remote.gate = gate
        let originalContext = try XCTUnwrap(f.auth.sessionOwnership.context)
        let userID = try XCTUnwrap(f.auth.currentUserID)
        var sawGuest = false
        let observation = f.auth.$status.sink { if $0 == .guest { sawGuest = true } }
        defer { observation.cancel() }
        let operation = Task { await f.controller.confirmDeletion(authStore: f.auth, kitchenStore: f.kitchen) }
        await gate.waitUntilEntered()

        let signedIn = await f.auth.signIn(email: "a@example.com", password: "fixture")
        XCTAssertTrue(signedIn)
        let freshContext = try XCTUnwrap(f.auth.sessionOwnership.context)
        XCTAssertNotEqual(freshContext, originalContext)
        XCTAssertEqual(f.auth.currentUserID, userID)
        let records = try await seedCurrentContext(f)
        gate.resume()
        let result = await operation.value

        XCTAssertFalse(result)
        try await assertPreserved(f, records: records)
        XCTAssertFalse(sawGuest)
        XCTAssertEqual(f.auth.currentUserID, userID)
        XCTAssertEqual(f.auth.sessionOwnership.context, freshContext)
        XCTAssertEqual(f.authService.signOuts, 0)
        XCTAssertTrue(f.controller.needsLocalCleanup, "the original remote completion must remain recorded")
        XCTAssertFalse(f.controller.didComplete)
        XCTAssertNotNil(f.controller.localCleanupBlockedReason)
        XCTAssertEqual(f.remote.confirmations, 1)
    }

    func testAccountSwitchWhileSyncClearIsSuspendedPreservesNewBookkeeping() async throws {
        let barrier = ClearGate()
        let f = try await fixture(clearBarrier: barrier)
        let operation = Task { await f.controller.confirmDeletion(authStore: f.auth, kitchenStore: f.kitchen) }
        await barrier.waitUntilEntered()
        await f.auth.signOut()
        f.authService.userID = UUID()
        _ = await f.auth.signIn(email: "b@example.com", password: "fixture")
        let records = try await seedCurrentContext(f)
        await barrier.resume()
        let result = await operation.value
        XCTAssertFalse(result)
        try await assertPreserved(f, records: records)
        XCTAssertEqual(f.auth.currentUserID, f.authService.userID)
        XCTAssertEqual(f.authService.signOuts, 1)
        XCTAssertTrue(f.controller.needsLocalCleanup)
        XCTAssertFalse(f.controller.didComplete)
        XCTAssertEqual(f.remote.confirmations, 1)
    }

    func testFreshSameUserAuthenticationWhileSyncClearIsSuspendedPreservesNewBookkeeping() async throws {
        let barrier = ClearGate()
        let f = try await fixture(clearBarrier: barrier)
        let originalContext = try XCTUnwrap(f.auth.sessionOwnership.context)
        let userID = try XCTUnwrap(f.auth.currentUserID)
        var sawGuest = false
        let observation = f.auth.$status.sink { if $0 == .guest { sawGuest = true } }
        defer { observation.cancel() }
        let operation = Task { await f.controller.confirmDeletion(authStore: f.auth, kitchenStore: f.kitchen) }
        await barrier.waitUntilEntered()

        let signedIn = await f.auth.signIn(email: "a@example.com", password: "fixture")
        XCTAssertTrue(signedIn)
        let freshContext = try XCTUnwrap(f.auth.sessionOwnership.context)
        XCTAssertNotEqual(freshContext, originalContext)
        XCTAssertEqual(f.auth.currentUserID, userID)
        let records = try await seedCurrentContext(f)
        await barrier.resume()
        let result = await operation.value

        XCTAssertFalse(result)
        try await assertPreserved(f, records: records)
        XCTAssertFalse(sawGuest)
        XCTAssertEqual(f.auth.currentUserID, userID)
        XCTAssertEqual(f.auth.sessionOwnership.context, freshContext)
        XCTAssertEqual(f.authService.signOuts, 0)
        XCTAssertTrue(f.controller.needsLocalCleanup)
        XCTAssertFalse(f.controller.didComplete)
        XCTAssertNotNil(f.controller.localCleanupBlockedReason)
        XCTAssertEqual(f.remote.confirmations, 1)
    }

    func testAccountSwitchDuringFinalSignOutPreservesReplacementSession() async throws {
        let f = try await fixture()
        let gate = AsyncGate()
        f.authService.signOutGate = gate
        let operation = Task { await f.controller.confirmDeletion(authStore: f.auth, kitchenStore: f.kitchen) }
        await gate.waitUntilEntered()
        let bID = UUID()
        f.authService.userID = bID
        f.authService.changes.yield(.sessionUpdated(AuthSession(
            user: AuthUser(id: bID, email: "b@example.com"), accessToken: "isolated-b")))
        for await status in f.auth.$status.values {
            if case .signedIn(let user) = status, user.id == bID { break }
        }
        let records = try await seedCurrentContext(f)
        gate.resume()
        let result = await operation.value
        XCTAssertFalse(result)
        try await assertPreserved(f, records: records)
        XCTAssertEqual(f.auth.currentUserID, bID, "a late sign-out for A must not clear B's session")
        XCTAssertTrue(f.controller.needsLocalCleanup)
        XCTAssertFalse(f.controller.didComplete)
        let retried = await f.controller.retryLocalCleanup(authStore: f.auth, kitchenStore: f.kitchen)
        XCTAssertFalse(retried)
        XCTAssertEqual(f.authService.signOuts, 1)
        XCTAssertEqual(f.remote.confirmations, 1)
    }

    func testSignOutFailureRetriesOnlySignOutWithoutClearingNewLocalRecords() async throws {
        let f = try await fixture()
        f.authService.signOutFailures = 1
        let first = await f.controller.confirmDeletion(authStore: f.auth, kitchenStore: f.kitchen)
        XCTAssertFalse(first, "a failed sign-out is not full completion")
        XCTAssertTrue(f.controller.needsLocalCleanup)
        XCTAssertFalse(f.controller.didComplete)
        XCTAssertTrue(f.kitchen.inventory.isEmpty)
        let records = try await seedCurrentContext(f)
        let retried = await f.controller.retryLocalCleanup(authStore: f.auth, kitchenStore: f.kitchen)
        XCTAssertTrue(retried)
        try await assertPreserved(f, records: records)
        XCTAssertNil(f.auth.currentUserID)
        XCTAssertEqual(f.authService.signOuts, 2)
        XCTAssertEqual(f.remote.confirmations, 1)
    }

    func testRevokedPermitCannotClearActualSwiftDataSyncRecords() async throws {
        let f = try await fixture()
        let records = try await seedCurrentContext(f)
        let authorization = AccountDeletionCleanupAuthorization()
        authorization.revoke()
        let cleared = try await f.bundle.sync.clearAllSyncState(authorizedBy: authorization)
        XCTAssertFalse(cleared)
        try await assertPreserved(f, records: records)
        XCTAssertEqual(f.remote.confirmations, 0)
    }

    func testSyncClearFailureLeavesKitchenAndSessionPendingAcrossRetries() async throws {
        let f = try await fixture(failingSync: true)
        let records = try await seedCurrentContext(f)
        for useConfirm in [true, false] {
            let result = useConfirm
                ? await f.controller.confirmDeletion(authStore: f.auth, kitchenStore: f.kitchen)
                : await f.controller.retryLocalCleanup(authStore: f.auth, kitchenStore: f.kitchen)
            XCTAssertFalse(result)
            try await assertPreserved(f, records: records)
            XCTAssertTrue(f.controller.needsLocalCleanup)
            XCTAssertFalse(f.controller.didComplete)
            XCTAssertEqual(f.auth.currentUserID, f.authService.userID)
            XCTAssertEqual(f.authService.signOuts, 0)
            XCTAssertEqual(f.remote.confirmations, 1)
            XCTAssertTrue(f.controller.errorMessage?.contains("同步记录清理失败") == true)
        }
    }

    func testExpectedGuestEventDuringOwnedFinalSignOutCompletesNormally() async throws {
        let f = try await providerFixture()
        let gate = ProviderSessionGate()
        await f.transport.enqueue(ProviderSessionTransport.logoutRoute, hold: gate)
        let operation = Task { await f.controller.confirmDeletion(authStore: f.auth, kitchenStore: f.base.kitchen) }
        await gate.waitForArrival()
        XCTAssertNil(f.storage.bytes, "the real SDK removes locally before the logout response")
        XCTAssertTrue(f.auth.sessionOwnership.isTransitioning)
        XCTAssertNil(f.auth.currentAccessToken())
        await gate.open()
        let result = await operation.value
        XCTAssertTrue(result)
        XCTAssertTrue(f.controller.didComplete)
        XCTAssertFalse(f.controller.needsLocalCleanup)
        XCTAssertNil(f.controller.localCleanupBlockedReason)
        XCTAssertEqual(f.auth.status, .guest)
        XCTAssertTrue(f.base.kitchen.inventory.isEmpty)
        XCTAssertEqual(f.remote.confirmations, 1)
    }


    func testCancellationDuringOwnedRealSDKSignOutRetainsCleanupUntilSettlement() async throws {
        for replaceSession in [false, true] {
            let f = try await providerFixture()
            let context = try XCTUnwrap(f.auth.sessionOwnership.context)
            let signOut = ProviderSessionGate()
            await f.transport.enqueue(ProviderSessionTransport.logoutRoute, hold: signOut)
            let operation = Task { await f.controller.confirmDeletion(authStore: f.auth, kitchenStore: f.base.kitchen) }
            await signOut.waitForArrival()
            let signOutID = try XCTUnwrap(f.auth.sessionOwnership.signOutOperationID)
            XCTAssertEqual(f.auth.sessionOwnership.endingContext, context)
            XCTAssertTrue(f.auth.sessionOwnership.isTransitioning)
            XCTAssertNil(f.storage.bytes, "the admitted SDK sign-out has already removed its local session")
            XCTAssertTrue(f.base.kitchen.inventory.isEmpty)
            XCTAssertEqual(f.remote.confirmations, 1)

            operation.cancel()
            // Drain the already-enqueued MainActor cancellation continuation,
            // without awaiting an operation that must retain the held SDK worker.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            XCTAssertTrue(f.controller.isConfirming, "caller cancellation must not release active cleanup ownership")
            XCTAssertTrue(f.controller.needsLocalCleanup)
            XCTAssertFalse(f.controller.didComplete)
            XCTAssertNil(f.controller.localCleanupBlockedReason)
            XCTAssertEqual(f.auth.sessionOwnership.signOutOperationID, signOutID)
            // This owned FIFO marker rejects after A's guest acknowledgment;
            // it adds neither an SDK write nor another auth-state reduction.
            let settled = f.coordinator.submit(.refresh, expectedContext: context)
            let b = providerSession(user: UUID(), credential: "cancellation-replacement", now: f.clock.now())
            let drain = ProviderSessionGate()
            var replacement: ProviderSessionTicket<ProviderSessionCoordinator.Result>?
            var sawB = false
            var clearedReplacementSession = false
            let observation = f.auth.$status.sink { status in
                if case .signedIn(let user) = status, user.id == b.user.id { sawB = true }
                if sawB && status == .guest { clearedReplacementSession = true }
            }
            if replaceSession {
                await f.transport.enqueue(ProviderSessionTransport.passwordRoute, data: try providerResponse(b))
                f.account.holdToken = b.accessToken
                f.account.gate = drain
                replacement = f.coordinator.submit(.signIn, email: "fixture@example.invalid", password: "synthetic-only")
            }
            let records = try await seedCurrentContext(f.base)
            await signOut.open()
            do {
                _ = try await settled.value()
                XCTFail("the ended context cannot authorize the queued refresh marker")
            } catch {
                XCTAssertTrue(error is AuthenticationError)
            }
            if replaceSession { await drain.waitForArrival() }
            let result = await operation.value
            if replaceSession {
                XCTAssertFalse(result, "A's deletion cannot finish against B's newly admitted context")
                XCTAssertFalse(f.controller.didComplete)
                XCTAssertTrue(f.controller.needsLocalCleanup)
                XCTAssertNotNil(f.controller.localCleanupBlockedReason)
                await drain.open()
                _ = try await replacement?.value()
                XCTAssertEqual(f.auth.currentUserID, b.user.id)
                XCTAssertEqual(try f.storage.storedSession(), b)
                XCTAssertNotNil(f.auth.currentAccessToken())
            } else {
                XCTAssertTrue(result, "successful SDK/event/ack settlement must finish despite caller cancellation")
                XCTAssertTrue(f.controller.didComplete)
                XCTAssertFalse(f.controller.needsLocalCleanup)
                XCTAssertNil(f.controller.localCleanupBlockedReason)
                XCTAssertEqual(f.auth.status, .guest)
                XCTAssertEqual(f.auth.sessionOwnership.signOutOperationID, signOutID)
                XCTAssertFalse(f.auth.sessionOwnership.isTransitioning)
                XCTAssertNil(f.storage.bytes)
            }
            let retry = await f.controller.retryLocalCleanup(authStore: f.auth, kitchenStore: f.base.kitchen)
            XCTAssertFalse(retry, "settled completion or B's context cannot restart A's local cleanup")
            try await assertPreserved(f.base, records: records)
            XCTAssertFalse(clearedReplacementSession, "no transient B -> guest -> B is permitted after cancellation")
            observation.cancel()
            XCTAssertEqual(f.remote.confirmations, 1)
            let requests = await f.transport.trace
            XCTAssertEqual(requests.filter { $0 == ProviderSessionTransport.logoutRoute }.count, 1)
            XCTAssertEqual(requests.filter { $0 == ProviderSessionTransport.passwordRoute }.count, replaceSession ? 3 : 2)
            let unexpected = await f.transport.unexpectedCount
            let remaining = await f.transport.remainingResponses
            XCTAssertEqual(unexpected, 0)
            XCTAssertEqual(remaining, 0)
        }
    }

    func testPendingDeletionCannotMoveToAnotherAuthStoreWithSameUser() async throws {
        let f = try await fixture()
        f.fault.failuresRemaining = 1
        _ = await f.controller.confirmDeletion(authStore: f.auth, kitchenStore: f.kitchen)
        let otherService = SwitchingAuth()
        otherService.userID = f.authService.userID
        let otherAuth = AuthStore(authService: otherService, accountService: UnavailableAccountService())
        _ = await otherAuth.signIn(email: "a@example.com", password: "fixture")
        let records = try await seedCurrentContext(f)
        let result = await f.controller.retryLocalCleanup(authStore: otherAuth, kitchenStore: f.kitchen)
        XCTAssertFalse(result)
        try await assertPreserved(f, records: records)
        XCTAssertEqual(otherAuth.currentUserID, otherService.userID)
        XCTAssertNotNil(f.controller.localCleanupBlockedReason)
        XCTAssertTrue(f.controller.needsLocalCleanup)
        XCTAssertEqual(f.remote.confirmations, 1)
    }

    func testLateUnscopedSignOutEventMustNotClearReplacementAccount() async throws {
        // The frozen original reproduces the unsafe fake schedule. This stronger
        // boundary test keeps its transient-state assertion with the real SDK.
        let f = try await providerFixture()
        let signOut = ProviderSessionGate()
        await f.transport.enqueue(ProviderSessionTransport.logoutRoute, hold: signOut)
        let operation = Task { await f.controller.confirmDeletion(authStore: f.auth, kitchenStore: f.base.kitchen) }
        await signOut.waitForArrival()
        let b = providerSession(user: UUID(), credential: "replacement", now: f.clock.now())
        await f.transport.enqueue(ProviderSessionTransport.passwordRoute, data: try providerResponse(b))
        let drain = ProviderSessionGate()
        f.account.holdToken = b.accessToken
        f.account.gate = drain
        var sawB = false
        var clearedReplacementSession = false
        let observation = f.auth.$status.sink { status in
            if case .signedIn(let user) = status, user.id == b.user.id { sawB = true }
            if sawB && status == .guest { clearedReplacementSession = true }
        }
        // Synchronous admission, not a scheduling sleep or UI busy flag.
        let replacement = f.coordinator.submit(.signIn, email: "fixture@example.invalid", password: "synthetic-only")
        let held = await f.transport.trace
        XCTAssertEqual(held.filter { $0 == ProviderSessionTransport.passwordRoute }.count, 2,
                       "B may be queued but cannot mutate while A remains in the SDK")
        await signOut.open()
        // This marker is entered only after A's SDK effects and its guest
        // reduction have drained, and B's actual session has been published.
        await drain.waitForArrival()
        XCTAssertFalse(clearedReplacementSession,
                       "A's unscoped late signedOut event cleared B before the drain marker")
        XCTAssertEqual(try f.storage.storedSession(), b)
        let records = try await seedCurrentContext(f.base)
        let result = await operation.value
        XCTAssertFalse(result)
        await drain.open()
        _ = try await replacement.value()
        XCTAssertFalse(clearedReplacementSession, "no transient B -> guest -> B is permitted after admission")
        observation.cancel()
        try await assertPreserved(f.base, records: records)
        XCTAssertEqual(f.auth.currentUserID, b.user.id)
        XCTAssertNotNil(f.auth.currentAccessToken())
        XCTAssertEqual(try f.storage.storedSession(), b)
        let retry = await f.controller.retryLocalCleanup(authStore: f.auth, kitchenStore: f.base.kitchen)
        XCTAssertFalse(retry)
        try await assertPreserved(f.base, records: records)
        XCTAssertEqual(f.remote.confirmations, 1)
        let requests = await f.transport.trace
        XCTAssertEqual(requests.filter { $0 == ProviderSessionTransport.logoutRoute }.count, 1)
    }

    func testRealSDKRemoveFailureRetriesLocalSignOutWithoutReauthenticationOrReclearing() async throws {
        let f = try await providerFixture()
        let original = try f.storage.storedSession()
        let context = f.auth.sessionOwnership.context
        f.storage.failNext("remove")
        await f.transport.enqueue(ProviderSessionTransport.logoutRoute)
        let first = await f.controller.confirmDeletion(authStore: f.auth, kitchenStore: f.base.kitchen)
        XCTAssertFalse(first)
        XCTAssertTrue(f.controller.needsLocalCleanup)
        XCTAssertFalse(f.controller.didComplete)
        XCTAssertEqual(try f.storage.storedSession(), original)
        XCTAssertEqual(f.auth.sessionOwnership.context, context)
        let records = try await seedCurrentContext(f.base)
        await f.transport.enqueue(ProviderSessionTransport.logoutRoute)
        let retry = await f.controller.retryLocalCleanup(authStore: f.auth, kitchenStore: f.base.kitchen)
        XCTAssertTrue(retry)
        XCTAssertTrue(f.controller.didComplete)
        try await assertPreserved(f.base, records: records)
        XCTAssertNil(f.storage.bytes)
        XCTAssertEqual(f.auth.status, .guest)
        XCTAssertEqual(f.remote.confirmations, 1)
        let requests = await f.transport.trace
        XCTAssertEqual(requests.filter { $0 == ProviderSessionTransport.passwordRoute }.count, 2,
                       "local retries never authenticate a deleted account again")
    }


    private struct Records {
        let inventory: [InventoryItem]
        let prepared: [PreparedComponent]
        let scope: SyncScope
        let metadata: [SyncMetadata]
        let pending: [PendingMutation]
    }
    private func seedCurrentContext(_ f: Fixture) async throws -> Records {
        f.kitchen.addInventory(name: "当前上下文专属记录", quantity: 7, unit: "份", expiryDate: nil)
        _ = f.kitchen.addPreparedComponent(PreparedComponent(name: "当前上下文备餐", portionsRemaining: 5,
            state: .cooked, storage: .refrigerated, preparedAt: Date(), expiryDate: Date()))
        let scope = SyncScope(type: .user, id: f.auth.currentUserID ?? UUID())
        _ = try await f.bundle.sync.stageInventoryMutation(entityId: UUID(), scope: scope, operation: .upsert,
                                                          payloadData: Data("{}".utf8), now: Date())
        try await f.bundle.sync.advanceCursor(scope: scope, to: SyncCursorValue("17"), at: Date())
        return Records(inventory: f.kitchen.inventory, prepared: f.kitchen.preparedComponents, scope: scope,
                       metadata: try await f.bundle.sync.allMetadata(scope: scope),
                       pending: try await f.bundle.sync.allPendingMutations(scope: scope))
    }
    private func assertPreserved(_ f: Fixture, records: Records, file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertEqual(f.kitchen.inventory, records.inventory, file: file, line: line)
        XCTAssertEqual(f.kitchen.preparedComponents, records.prepared, file: file, line: line)
        let reopened = KitchenPersistenceFactory.bundle(container: try KitchenPersistenceFactory.makeContainer(
            configuration: ModelConfiguration(url: f.url)))
        XCTAssertEqual(try reopened.inventory.loadInventory(), records.inventory, file: file, line: line)
        XCTAssertEqual(try reopened.preparedComponents.loadComponents(), records.prepared, file: file, line: line)
        let metadata = try await reopened.sync.allMetadata(scope: records.scope)
        let pending = try await reopened.sync.allPendingMutations(scope: records.scope)
        let cursor = try await reopened.sync.cursor(for: records.scope)
        XCTAssertEqual(metadata, records.metadata, file: file, line: line)
        XCTAssertEqual(pending, records.pending, file: file, line: line)
        XCTAssertEqual(cursor.value, try SyncCursorValue("17"), file: file, line: line)
    }
    private struct Fixture {
        let url: URL
        let bundle: KitchenPersistenceBundle
        let kitchen: KitchenStore
        let fault: ClearFault
        let authService: SwitchingAuth
        let accountService: EventAccountService
        let auth: AuthStore
        let remote: Remote
        let controller: AccountDeletionController
    }
    private func fixture(clearBarrier: ClearGate? = nil, failingSync: Bool = false) async throws -> Fixture {
        let url = directory.appending(path: "\(UUID()).store")
        let container = try KitchenPersistenceFactory.makeContainer(configuration: ModelConfiguration(url: url))
        let bundle = KitchenPersistenceFactory.bundle(container: container)
        let fault = ClearFault(wrapped: bundle.preparedComponents)
        let kitchen = KitchenStore(userDefaults: defaults(),
            inventoryPersistence: bundle.inventory, shoppingListPersistence: bundle.shoppingList,
            todayPlanPersistence: bundle.todayPlan, consumptionPersistence: bundle.consumption,
            weeklyPlanPersistence: bundle.weeklyPlan, preparedComponentPersistence: fault,
            specialPlanPersistence: bundle.specialPlans, recoverySnapshot: KitchenRecoverySnapshotStore(directoryURL: directory.appending(path: UUID().uuidString)))
        kitchen.addInventory(name: "A 的旧记录", quantity: 1, unit: "份", expiryDate: nil)
        let authService = SwitchingAuth()
        let accountService = EventAccountService()
        let auth = AuthStore(authService: authService, accountService: accountService)
        await auth.start()
        _ = await auth.signIn(email: "a@example.com", password: "fixture")
        let remote = Remote()
        let sync: any SyncPersistenceProtocol
        if let clearBarrier {
            sync = await Task.detached {
                SuspendedClearPersistence(modelContainer: container, barrier: clearBarrier)
            }.value
        } else if failingSync { sync = FailingSyncPersistence() }
        else { sync = bundle.sync }
        let controller = AccountDeletionController(persistence: sync, service: remote)
        await controller.loadPreview(authStore: auth)
        _ = await controller.reauthenticateForDeletion(password: "fixture", authStore: auth)
        return Fixture(url: url, bundle: bundle, kitchen: kitchen, fault: fault, authService: authService,
                       accountService: accountService, auth: auth, remote: remote, controller: controller)
    }

    private struct ProviderFixture {
        let base: Fixture
        let storage: ProviderSessionMemoryStorage
        let transport: ProviderSessionTransport
        let coordinator: ProviderSessionCoordinator
        let clock: ProviderSessionClock
        let auth: AuthStore
        let account: ProviderAccountService
        let remote: Remote
        let controller: AccountDeletionController
    }
    private func providerFixture() async throws -> ProviderFixture {
        let base = try await fixture()
        let storage = ProviderSessionMemoryStorage(ProviderSessionLedger())
        let transport = ProviderSessionTransport()
        let clock = ProviderSessionClock()
        let coordinator = ProviderSessionCoordinator(url: ProviderSessionTransport.url,
            storageKey: ProviderSessionMemoryStorage.key, storage: storage,
            fetch: { try await transport.fetch($0) }, notifications: NotificationCenter(),
            automaticRefresh: false)
        let account = ProviderAccountService()
        let auth = AuthStore(authService: SupabaseAuthService(coordinator: coordinator), accountService: account)
        await auth.start()
        let a = providerSession(user: base.authService.userID, credential: "deletion-A", now: clock.now())
        await transport.enqueue(ProviderSessionTransport.passwordRoute, data: try providerResponse(a))
        let signed = await auth.signIn(email: "fixture@example.invalid", password: "synthetic-only")
        XCTAssertTrue(signed)
        let remote = Remote()
        let controller = AccountDeletionController(persistence: base.bundle.sync, service: remote)
        await controller.loadPreview(authStore: auth)
        let proofSession = providerSession(user: base.authService.userID, credential: "deletion-proof", now: clock.now())
        await transport.enqueue(ProviderSessionTransport.passwordRoute, data: try providerResponse(proofSession))
        let proof = await controller.reauthenticateForDeletion(password: "synthetic-only", authStore: auth)
        XCTAssertTrue(proof)
        return ProviderFixture(base: base, storage: storage, transport: transport, coordinator: coordinator,
            clock: clock, auth: auth, account: account, remote: remote, controller: controller)
    }
    private final class ProviderAccountService: AccountService {
        var holdToken: String?
        var gate: ProviderSessionGate?
        func currentAccount(accessToken: String) async throws -> CurrentAccount {
            if accessToken == holdToken, let gate { await gate.pass() }
            throw AccountServiceError.temporarilyUnavailable
        }
    }

    private final class EventAccountService: AccountService {
        var marker: AsyncGate?
        func currentAccount(accessToken: String) async throws -> CurrentAccount {
            if accessToken == "drain-marker", let marker { await marker.pause() }
            throw AccountServiceError.temporarilyUnavailable
        }
    }
    private final class SwitchingAuth: AuthService {
        var userID = UUID()
        var signOuts = 0
        let authStateChanges: AsyncStream<AuthStateChange>
        let changes: AsyncStream<AuthStateChange>.Continuation
        var signOutGate: AsyncGate?
        var signOutFailures = 0
        var lateEvents: [AuthStateChange] = []
        init() { (authStateChanges, changes) = AsyncStream.makeStream() }
        func restoreSession() async throws -> AuthSession? { nil }
        func signUp(email: String, password: String) async throws -> SignUpOutcome { throw AuthenticationError.unavailable }
        func signIn(email: String, password: String) async throws -> AuthSession {
            AuthSession(user: AuthUser(id: userID, email: email), accessToken: "isolated-only")
        }
        func reauthenticate(email: String, password: String) async throws -> AuthSession { try await signIn(email: email, password: password) }
        func signOut() async throws {
            signOuts += 1
            if let signOutGate { await signOutGate.pause() }
            if signOutFailures > 0 { signOutFailures -= 1; throw AuthenticationError.unavailable }
            for event in lateEvents { changes.yield(event) }
        }
    }
    private final class ClearFault: PreparedComponentPersistenceProtocol {
        let wrapped: PreparedComponentPersistenceProtocol
        var failuresRemaining = 0
        init(wrapped: PreparedComponentPersistenceProtocol) { self.wrapped = wrapped }
        func loadComponents() throws -> [PreparedComponent] { try wrapped.loadComponents() }
        func replaceComponents(with components: [PreparedComponent]) throws { try wrapped.replaceComponents(with: components) }
        func upsert(_ component: PreparedComponent) throws { try wrapped.upsert(component) }
        func delete(id: UUID) throws { try wrapped.delete(id: id) }
        func deleteAll() throws {
            if failuresRemaining > 0 { failuresRemaining -= 1; throw SyncError.persistence }
            try wrapped.deleteAll()
        }
    }
    private final class Remote: AccountDeletionService {
        var confirmations = 0
        var gate: AsyncGate?
        func preview(accessToken: String) async throws -> AccountDeletionPreview {
            AccountDeletionPreview(canDelete: true, blockingReason: nil, householdCount: 0, ownedHouseholdCount: 0,
                requiresOwnershipTransfer: false, requiresHouseholdDeletion: false,
                pendingMutationCountBucket: "0", confirmationVersion: "isolated")
        }
        func transferCandidates(accessToken: String, householdId: UUID) async throws -> [TransferCandidate] { [] }
        func transferOwnership(accessToken: String, householdId: UUID, newOwnerUserId: UUID) async throws {}
        func createReauthenticationProof(accessToken: String, confirmationVersion: String) async throws -> AccountDeletionReauthenticationResult {
            AccountDeletionReauthenticationResult(reauthenticationProof: "isolated")
        }
        func confirmDeletion(accessToken: String, idempotencyKey: UUID, confirmationVersion: String,
                             reauthenticationProof: String) async throws -> AccountDeletionConfirmResult {
            confirmations += 1
            if let gate { await gate.pause() }
            return AccountDeletionConfirmResult(status: "completed")
        }
    }
    private final class AsyncGate {
        private var entered: CheckedContinuation<Void, Never>?
        private var released: CheckedContinuation<Void, Never>?
        private var hasEntered = false
        func pause() async {
            await withCheckedContinuation { continuation in
                released = continuation; hasEntered = true; entered?.resume(); entered = nil
            }
        }
        func waitUntilEntered() async {
            if hasEntered { return }
            await withCheckedContinuation { entered = $0 }
        }
        func resume() { released?.resume(); released = nil }
    }
    actor ClearGate {
        private var entered: CheckedContinuation<Void, Never>?
        private var released: CheckedContinuation<Void, Never>?
        private var hasEntered = false
        func pause() async {
            await withCheckedContinuation { continuation in
                released = continuation; hasEntered = true; entered?.resume(); entered = nil
            }
        }
        func waitUntilEntered() async {
            if hasEntered { return }
            await withCheckedContinuation { entered = $0 }
        }
        func resume() { released?.resume(); released = nil }
    }
    @ModelActor
    actor SuspendedClearPersistence: SyncPersistenceProtocol {
    var barrier: ClearGate? = nil
    init(modelContainer: ModelContainer, barrier: ClearGate) {
        self.modelContainer = modelContainer
        modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(modelContainer))
        self.barrier = barrier
    }
    func metadata(entityType: SyncEntityType, entityId: UUID) throws -> SyncMetadata? { throw SyncError.persistence }
    func saveMetadata(_ metadata: SyncMetadata) throws { throw SyncError.persistence }
    func deleteMetadata(entityType: SyncEntityType, entityId: UUID) throws { throw SyncError.persistence }
    func pendingMutations(scope: SyncScope, maxAttempts: Int) throws -> [PendingMutation] { throw SyncError.persistence }
    func pendingMutation(id: UUID) throws -> PendingMutation? { throw SyncError.persistence }
    func savePending(_ mutation: PendingMutation) throws { throw SyncError.persistence }
    func discardPendingMutation(id: UUID) throws { throw SyncError.persistence }
    func markInFlight(ids: [UUID], attemptedAt: Date, maxAttempts: Int) throws { throw SyncError.persistence }
    func resolvePending(_ result: SyncMutationResult, resolvedAt: Date) throws { throw SyncError.persistence }
    func markPendingFailed(ids: [UUID], code: String, attemptedAt: Date, maxAttempts: Int) throws { throw SyncError.persistence }
    func cursor(for scope: SyncScope) throws -> SyncCursor { throw SyncError.persistence }
    func advanceCursor(scope: SyncScope, to value: SyncCursorValue, at date: Date) throws { throw SyncError.persistence }
    func commitInventoryAndSync(item: InventoryItem?, removeInventory: Bool, metadata: SyncMetadata, mutation: PendingMutation) throws { throw SyncError.persistence }
    func applyRemoteInventory(item: InventoryItem?, removeInventory: Bool, metadata: SyncMetadata) throws { throw SyncError.persistence }
    func inventoryItem(id: UUID) throws -> InventoryItem? { throw SyncError.persistence }
    func activeGuestMergeSession(userId: UUID, householdId: UUID, entityType: SyncEntityType) throws -> GuestMergeSession? { throw SyncError.persistence }
    func guestMergeSession(id: UUID) throws -> GuestMergeSession? { throw SyncError.persistence }
    func saveGuestMergeSession(_ session: GuestMergeSession) throws { throw SyncError.persistence }
    func enrollment(userId: UUID, householdId: UUID) throws -> InventorySyncEnrollment? { throw SyncError.persistence }
    func saveEnrollment(_ enrollment: InventorySyncEnrollment) throws { throw SyncError.persistence }
    func pendingMutationForEntity(entityType: SyncEntityType, entityId: UUID) throws -> PendingMutation? { throw SyncError.persistence }
    func stageInventoryMutation(entityId: UUID, scope: SyncScope, operation: SyncOperation, payloadData: Data, now: Date) throws -> InventoryMutationStagingOutcome { throw SyncError.persistence }
    func allMetadata(scope: SyncScope) throws -> [SyncMetadata] { throw SyncError.persistence }
    func allPendingMutations(scope: SyncScope) throws -> [PendingMutation] { throw SyncError.persistence }
    func clearAllSyncState(authorizedBy authorization: AccountDeletionCleanupAuthorization) async throws -> Bool {
        await barrier?.pause()
        return try authorization.perform { try eraseSyncState() }
    }
    func clearAllSyncState() async throws {
        await barrier?.pause()
        try eraseSyncState()
    }
    private func eraseSyncState() throws {
        for record in try modelContext.fetch(FetchDescriptor<SyncMetadataRecord>()) { modelContext.delete(record) }
        for record in try modelContext.fetch(FetchDescriptor<PendingMutationRecord>()) { modelContext.delete(record) }
        for record in try modelContext.fetch(FetchDescriptor<SyncCursorRecord>()) { modelContext.delete(record) }
        for record in try modelContext.fetch(FetchDescriptor<GuestMergeSessionRecord>()) { modelContext.delete(record) }
        for record in try modelContext.fetch(FetchDescriptor<InventorySyncEnrollmentRecord>()) { modelContext.delete(record) }
        try modelContext.save()
    }
}

}
