import Foundation
import Supabase
import XCTest
@testable import KitchenManager

// Ported from the frozen spike against supabase-swift 2.51.0 @ 27f31bfb7be836a33c89f6636ef69a2cfff9a3fd.
@MainActor
final class ProviderSessionCoordinatorTests: XCTestCase {
    private let a = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let b = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    private func active(_ context: Int, _ user: UUID) -> String { "active:\(context):\(user.uuidString)" }

    @discardableResult
    private func login(_ f: ProviderSessionFixture, _ user: UUID, credential: String = "A") async throws -> ProviderSessionCoordinator.Result {
        let session = f.session(user, credential)
        await f.transport.enqueue(ProviderSessionTransport.passwordRoute, data: try providerResponse(session))
        let result = try await f.perform(.signIn)
        XCTAssertEqual(result.session, session)
        XCTAssertNotNil(result.context)
        XCTAssertEqual(result.context, f.coordinator.context)
        XCTAssertEqual(try f.storage.storedSession(), session)
        XCTAssertEqual(f.consumer.snapshots.last?.session, session)
        return result
    }

    private func rejected(_ body: () async throws -> Void,
                          file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("expected failure", file: file, line: line) } catch {}
    }

    private func cancelled(_ task: Task<ProviderSessionCoordinator.Result, Error>,
                           file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await task.value; XCTFail("expected cancellation", file: file, line: line) }
        catch { XCTAssertTrue(error is CancellationError, file: file, line: line) }
    }

    private func assertTrace(_ f: ProviderSessionFixture, _ expected: [String], unexpected: Int = 0,
                             file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertEqual(f.consumer.trace, expected, file: file, line: line)
        XCTAssertEqual(f.ledger.outsideWrites, 0, file: file, line: line)
        XCTAssertEqual(f.ledger.overlappingTurns, 0, file: file, line: line)
        XCTAssertEqual(f.storage.unexpectedKeyCount, 0, file: file, line: line)
        XCTAssertEqual(f.storage.remainingFailures, 0, file: file, line: line)
        let signupIDs = Set(f.consumer.snapshots.filter { $0.operation == .signUp }.map(\.operationID))
        let verifierWriters = f.ledger.writerIDs(for: ProviderSessionMemoryStorage.codeVerifierKey)
        XCTAssertTrue(verifierWriters.allSatisfy { $0.map { signupIDs.contains($0) } == true }, file: file, line: line)
        if !signupIDs.isEmpty {
            XCTAssertFalse(verifierWriters.isEmpty, "real PKCE signup writes its verifier inside admission", file: file, line: line)
            XCTAssertNotNil(f.storage.allBytes[ProviderSessionMemoryStorage.codeVerifierKey], file: file, line: line)
        }
        let unexpectedCount = await f.transport.unexpectedCount
        let remainingResponses = await f.transport.remainingResponses
        XCTAssertEqual(unexpectedCount, unexpected, file: file, line: line)
        XCTAssertEqual(remainingResponses, 0, file: file, line: line)
        var pending: ProviderSessionCoordinator.Snapshot?
        var settledContext: UUID?
        var terminalCount = 0
        for snapshot in f.consumer.snapshots {
            switch snapshot.phase {
            case .transition:
                XCTAssertNil(pending, "new writer preceded consumer acknowledgment", file: file, line: line)
                XCTAssertNil(snapshot.session, file: file, line: line)
                switch snapshot.operation {
                case .signIn?, .signUp?, .reauthenticate?:
                    XCTAssertNil(snapshot.context, "fresh authentication revokes old admission", file: file, line: line)
                default:
                    XCTAssertEqual(snapshot.context, settledContext, file: file, line: line)
                }
                if snapshot.operation == .signOut {
                    XCTAssertEqual(snapshot.endingContext, settledContext, file: file, line: line)
                }
                pending = snapshot
            case .settled, .unavailable:
                terminalCount += 1
                if let operation = snapshot.operation {
                    XCTAssertEqual(pending?.operation, operation, file: file, line: line)
                    XCTAssertEqual(pending?.operationID, snapshot.operationID, file: file, line: line)
                } else {
                    XCTAssertNil(pending, file: file, line: line)
                    XCTAssertNil(snapshot.session, file: file, line: line)
                    XCTAssertNil(snapshot.context, file: file, line: line)
                }
                XCTAssertEqual(snapshot.session == nil, snapshot.context == nil, file: file, line: line)
                if case .unavailable = snapshot.phase {
                    XCTAssertNil(snapshot.session, file: file, line: line)
                    XCTAssertNil(snapshot.context, file: file, line: line)
                    XCTAssertNil(snapshot.endingContext, file: file, line: line)
                }
                settledContext = snapshot.context
                pending = nil
            }
            if snapshot.operation != .signOut { XCTAssertNil(snapshot.endingContext, file: file, line: line) }
        }
        XCTAssertNil(pending, file: file, line: line)
        XCTAssertEqual(f.consumer.acknowledgments, terminalCount, file: file, line: line)
        XCTAssertEqual(f.coordinator.context, settledContext, file: file, line: line)
        XCTAssertEqual(f.consumer.snapshots.last?.session, try f.storage.storedSession(), file: file, line: line)
    }

    func testBootstrapEmptyValidAndLegacyStorage() async throws {
        for mode in ["empty", "valid", "legacy"] {
            let clock = ProviderSessionClock()
            let session = mode == "empty" ? nil : providerSession(user: a, credential: "seed", now: clock.now())
            let f = try ProviderSessionFixture(seed: session, legacy: mode == "legacy", clock: clock)
            let result = try await f.perform(.bootstrap)
            XCTAssertEqual(result.session, session)
            XCTAssertEqual(try f.storage.storedSession(), session)
            XCTAssertEqual(f.consumer.snapshots.last?.session, session)
            XCTAssertEqual(result.context, f.coordinator.context)
            if session != nil { XCTAssertNotNil(result.context) }
            XCTAssertNil(f.storage.allBytes["supabase.session"])
            await assertTrace(f, ["transition:bootstrap", session == nil ? "guest" : active(1, a)])
        }
    }

    func testExpiredBootstrapAndExplicitRestoreRefreshInsideAdmission() async throws {
        let clock = ProviderSessionClock()
        let old = providerSession(user: a, credential: "expired", now: clock.now(), lifetime: -10)
        let f = try ProviderSessionFixture(seed: old, clock: clock)
        let fresh = f.session(a, "fresh")
        await f.transport.enqueue(ProviderSessionTransport.refreshRoute, data: try providerResponse(fresh))
        let first = try await f.perform(.bootstrap)
        XCTAssertEqual(first.session, fresh)
        let restored = try await f.perform(.restore)
        XCTAssertEqual(restored.session, fresh)
        XCTAssertEqual(restored.context, first.context)
        try f.storage.seed(f.session(a, "expired-again", lifetime: -10))
        let freshAgain = f.session(a, "fresh-again")
        await f.transport.enqueue(ProviderSessionTransport.refreshRoute, data: try providerResponse(freshAgain))
        let last = try await f.perform(.restore)
        XCTAssertEqual(last.context, first.context)
        XCTAssertEqual(last.session, freshAgain)
        XCTAssertEqual(try f.storage.storedSession(), freshAgain)
        await assertTrace(f, ["transition:bootstrap", active(1, a), "transition:restore", active(1, a),
                              "transition:restore", active(1, a)])
    }

    func testExistingEnvelopeAndSDKEncoderMigrateInsideAdmission() async throws {
        struct LegacyEnvelope: Encodable { let session: Session; let expirationDate: Date }
        for envelope in [false, true] {
            let f = try ProviderSessionFixture()
            let session = f.session(a, "legacy-encoding")
            let encoder = AuthClient.Configuration.jsonEncoder
            let data = envelope
                ? try encoder.encode(LegacyEnvelope(session: session, expirationDate: f.clock.now()))
                : try encoder.encode(session)
            f.storage.seedEncodedFixture(data)
            let restored = try await f.perform(.bootstrap)
            XCTAssertEqual(restored.session, session)
            XCTAssertEqual(try f.storage.storedSession(), session)
            XCTAssertTrue(f.ledger.trace.contains("store:" + ProviderSessionMemoryStorage.key))
            await assertTrace(f, ["transition:bootstrap", active(1, a)])
        }
    }

    func testSignUpReauthenticationAndRefreshHaveDistinctLineage() async throws {
        let f = try ProviderSessionFixture()
        _ = try await f.perform(.bootstrap)
        let signedSession = f.session(a, "signup")
        await f.transport.enqueue("POST /signup", data: try providerResponse(signedSession))
        let signed = try await f.perform(.signUp)
        XCTAssertEqual(signed.session, signedSession)
        XCTAssertEqual(try f.storage.storedSession(), signedSession)
        let reauthenticatedSession = f.session(a, "reauthenticated")
        await f.transport.enqueue(ProviderSessionTransport.passwordRoute, data: try providerResponse(reauthenticatedSession))
        let newer = try await f.perform(.reauthenticate, expectedContext: signed.context)
        XCTAssertNotNil(newer.context)
        XCTAssertNotEqual(signed.context, newer.context)
        XCTAssertEqual(newer.session, reauthenticatedSession)
        XCTAssertEqual(try f.storage.storedSession(), reauthenticatedSession)
        let rotated = f.session(a, "rotated")
        await f.transport.enqueue(ProviderSessionTransport.refreshRoute, data: try providerResponse(rotated))
        let refreshed = try await f.perform(.refresh, expectedContext: newer.context)
        XCTAssertEqual(refreshed.context, newer.context)
        XCTAssertEqual(refreshed.session, rotated)
        XCTAssertEqual(try f.storage.storedSession(), rotated)
        let before = f.storage.allBytes
        await rejected { _ = try await f.perform(.signOut, expectedContext: signed.context) }
        XCTAssertEqual(f.storage.allBytes, before)
        XCTAssertEqual(f.coordinator.context, newer.context)
        let refreshSnapshots = f.consumer.snapshots.suffix(2)
        XCTAssertTrue(refreshSnapshots.allSatisfy { $0.context == newer.context })
        await assertTrace(f, ["transition:bootstrap", "guest", "transition:signUp", active(1, a),
                              "transition:reauthenticate", active(2, a), "transition:refresh", active(2, a)])
    }

    func testSameUserNewAuthenticationAndSessionLossNeverReuseOldAuthority() async throws {
        for loseSession in [false, true] {
            let f = try ProviderSessionFixture()
            _ = try await f.perform(.bootstrap)
            let old = try await login(f, a)
            if loseSession {
                await f.transport.enqueue(ProviderSessionTransport.logoutRoute)
                _ = try await f.perform(.signOut, expectedContext: old.context)
                XCTAssertNil(f.storage.bytes)
            }
            let newer = try await login(f, a, credential: "same-user-new-login")
            XCTAssertNotEqual(old.context, newer.context)
            let before = f.storage.allBytes
            for operation in [ProviderSessionCoordinator.Operation.signOut, .refresh, .reauthenticate] {
                await rejected { _ = try await f.perform(operation, expectedContext: old.context) }
            }
            XCTAssertEqual(f.storage.allBytes, before)
            XCTAssertEqual(f.coordinator.context, newer.context)
            var expected = ["transition:bootstrap", "guest", "transition:signIn", active(1, a)]
            if loseSession { expected += ["transition:signOut", "guest"] }
            expected += ["transition:signIn", active(2, a)]
            await assertTrace(f, expected)
        }
    }

    func testCurrentSignOutUsesGlobalScopeAndMatchingEndingContextOnly() async throws {
        let f = try ProviderSessionFixture()
        _ = try await f.perform(.bootstrap)
        let current = try await login(f, b)
        let operationID = UUID()
        await f.transport.enqueue(ProviderSessionTransport.logoutRoute)
        let result = try await f.perform(.signOut, expectedContext: current.context, operationID: operationID)
        XCTAssertNil(result.session)
        XCTAssertNil(result.context)
        XCTAssertNil(f.storage.bytes)
        XCTAssertNil(f.coordinator.context)
        let ending = f.consumer.snapshots.suffix(2)
        XCTAssertTrue(ending.allSatisfy { $0.operationID == operationID && $0.endingContext == current.context })
        let requests = await f.transport.trace
        XCTAssertEqual(requests, [ProviderSessionTransport.passwordRoute, ProviderSessionTransport.logoutRoute])
        await assertTrace(f, ["transition:bootstrap", "guest", "transition:signIn", active(1, b),
                              "transition:signOut", "guest"])
    }

    func testAllRealSDKSessionCleanupErrorsSettleBeforeNextAuthentication() async throws {
        for code in ["session_not_found", "session_expired", "refresh_token_not_found", "refresh_token_already_used"] {
            let f = try ProviderSessionFixture()
            _ = try await f.perform(.bootstrap)
            let current = try await login(f, a)
            await f.transport.enqueue(ProviderSessionTransport.refreshRoute, data: providerError(code), status: 403)
            await rejected { _ = try await f.perform(.refresh, expectedContext: current.context) }
            XCTAssertNil(f.storage.bytes)
            XCTAssertNil(f.coordinator.context)
            _ = try await login(f, b, credential: "B")
            await assertTrace(f, ["transition:bootstrap", "guest", "transition:signIn", active(1, a),
                                  "transition:refresh", "guest", "transition:signIn", active(2, b)])
        }
    }

    func testTransportFailuresSettleAndPermitNextAuthentication() async throws {
        for signOut in [false, true] {
            let f = try ProviderSessionFixture()
            _ = try await f.perform(.bootstrap)
            let current = try await login(f, a)
            let operation: ProviderSessionCoordinator.Operation = signOut ? .signOut : .signIn
            await f.transport.enqueue(signOut ? ProviderSessionTransport.logoutRoute : ProviderSessionTransport.passwordRoute,
                                      failure: true)
            await rejected { _ = try await f.perform(operation, expectedContext: signOut ? current.context : nil) }
            XCTAssertEqual(try f.storage.storedSession(), signOut ? nil : current.session)
            _ = try await login(f, b, credential: "B")
            await assertTrace(f, ["transition:bootstrap", "guest", "transition:signIn", active(1, a),
                                  "transition:" + operation.rawValue, signOut ? "guest" : active(1, a),
                                  "transition:signIn", active(2, b)])
        }
    }

    func testStorageReadStoreAndRemoveFailuresFailClosedWithoutLatchingQueue() async throws {
        for storageOperation in ["read", "store", "remove"] {
            let f = try ProviderSessionFixture()
            _ = try await f.perform(.bootstrap)
            let current = try await login(f, a)
            let removing = storageOperation == "remove"
            let operation: ProviderSessionCoordinator.Operation = removing ? .signOut : .signIn
            if removing { await f.transport.enqueue(ProviderSessionTransport.logoutRoute) }
            else {
                await f.transport.enqueue(ProviderSessionTransport.passwordRoute,
                                          data: try providerResponse(f.session(b, "failed-B")))
            }
            let before = f.storage.allBytes
            f.storage.failNext(storageOperation)
            await rejected { _ = try await f.perform(operation, expectedContext: removing ? current.context : nil) }
            var expected = ["transition:bootstrap", "guest", "transition:signIn", active(1, a),
                            "transition:" + operation.rawValue, removing ? active(1, a) : "unavailable"]
            if removing {
                XCTAssertEqual(f.storage.allBytes, before)
                XCTAssertEqual(try f.storage.storedSession(), current.session)
                XCTAssertEqual(f.coordinator.context, current.context)
                XCTAssertEqual(f.consumer.snapshots.last?.session, current.session)
                XCTAssertEqual(f.consumer.snapshots.last?.context, current.context)
                XCTAssertNil(f.consumer.snapshots.last?.endingContext)
                if case .settled? = f.consumer.snapshots.last?.phase {} else {
                    XCTFail("readable unchanged A must settle while failed sign-out returns an error")
                }
                await assertTrace(f, expected)
                await f.transport.enqueue(ProviderSessionTransport.logoutRoute)
                let retry = try await f.perform(.signOut, expectedContext: current.context)
                XCTAssertNil(retry.session)
                XCTAssertNil(retry.context)
                XCTAssertNil(f.storage.bytes)
                XCTAssertNil(f.coordinator.context)
                XCTAssertEqual(f.consumer.snapshots.last?.endingContext, current.context)
                expected += ["transition:signOut", "guest"]
            } else {
                XCTAssertNil(f.coordinator.context)
                XCTAssertNil(f.consumer.snapshots.last?.session)
            }
            _ = try await login(f, b, credential: "successful-B")
            await assertTrace(f, expected + ["transition:signIn", active(2, b)])
        }
    }

    func testCancellationKeepsSDKMutationAndConsumerAcknowledgmentAheadOfNextWriter() async throws {
        let f = try ProviderSessionFixture()
        _ = try await f.perform(.bootstrap)
        let current = try await login(f, a)
        let transportGate = ProviderSessionGate()
        let acknowledgmentGate = ProviderSessionGate()
        f.consumer.nextAcknowledgment = acknowledgmentGate
        let refreshedA = f.session(a, "refreshed-A")
        await f.transport.enqueue(ProviderSessionTransport.refreshRoute, data: try providerResponse(refreshedA), hold: transportGate)
        let old = f.start(.refresh, expectedContext: current.context)
        await transportGate.waitForArrival()
        let expectedB = f.session(b, "B")
        await f.transport.enqueue(ProviderSessionTransport.passwordRoute, data: try providerResponse(expectedB))
        let replacement = f.start(.signIn)
        old.cancel()
        await cancelled(old)
        let heldRequests = await f.transport.trace
        XCTAssertEqual(heldRequests, [ProviderSessionTransport.passwordRoute, ProviderSessionTransport.refreshRoute])
        XCTAssertEqual(try f.storage.storedSession(), current.session)
        XCTAssertEqual(f.consumer.trace, ["transition:bootstrap", "guest", "transition:signIn", active(1, a), "transition:refresh"])
        await transportGate.open()
        await acknowledgmentGate.waitForArrival()
        let unacknowledgedRequests = await f.transport.trace
        XCTAssertEqual(unacknowledgedRequests, heldRequests)
        XCTAssertEqual(try f.storage.storedSession(), refreshedA)
        XCTAssertEqual(f.consumer.acknowledgments, 2)
        XCTAssertEqual(f.consumer.trace, ["transition:bootstrap", "guest", "transition:signIn", active(1, a),
                                         "transition:refresh", active(1, a)])
        await acknowledgmentGate.open()
        let result = try await replacement.value
        XCTAssertEqual(result.session, expectedB)
        XCTAssertEqual(try f.storage.storedSession(), expectedB)
        XCTAssertEqual(f.consumer.snapshots.last?.session, expectedB)
        await assertTrace(f, ["transition:bootstrap", "guest", "transition:signIn", active(1, a),
                              "transition:refresh", active(1, a), "transition:signIn", active(2, b)])
    }

    func testSignOutAndRefreshErrorRemovalFinishBeforeReplacementWriter() async throws {
        for errorRemoval in [false, true] {
            let f = try ProviderSessionFixture()
            _ = try await f.perform(.bootstrap)
            let current = try await login(f, a)
            let transportGate = ProviderSessionGate()
            let acknowledgmentGate = ProviderSessionGate()
            f.consumer.nextAcknowledgment = acknowledgmentGate
            let operation: ProviderSessionCoordinator.Operation = errorRemoval ? .refresh : .signOut
            await f.transport.enqueue(errorRemoval ? ProviderSessionTransport.refreshRoute : ProviderSessionTransport.logoutRoute,
                data: errorRemoval ? providerError("refresh_token_not_found") : Data(),
                status: errorRemoval ? 403 : 200, hold: transportGate)
            let old = f.start(operation, expectedContext: current.context)
            await transportGate.waitForArrival()
            if errorRemoval { XCTAssertEqual(try f.storage.storedSession(), current.session) }
            else { XCTAssertNil(f.storage.bytes, "real SDK removes storage before the logout response") }
            let expectedB = f.session(b, "B")
            await f.transport.enqueue(ProviderSessionTransport.passwordRoute, data: try providerResponse(expectedB))
            let newer = f.start(.signIn)
            let heldRequests = await f.transport.trace
            XCTAssertEqual(heldRequests, [ProviderSessionTransport.passwordRoute,
                                         errorRemoval ? ProviderSessionTransport.refreshRoute : ProviderSessionTransport.logoutRoute])
            await transportGate.open()
            await acknowledgmentGate.waitForArrival()
            XCTAssertNil(f.storage.bytes)
            let beforeAcknowledgment = await f.transport.trace
            XCTAssertEqual(beforeAcknowledgment, heldRequests)
            XCTAssertEqual(f.consumer.trace, ["transition:bootstrap", "guest", "transition:signIn", active(1, a),
                                             "transition:" + operation.rawValue, "guest"])
            await acknowledgmentGate.open()
            if errorRemoval { await rejected { _ = try await old.value } }
            else { _ = try await old.value }
            let result = try await newer.value
            XCTAssertEqual(result.session, expectedB)
            XCTAssertEqual(try f.storage.storedSession(), expectedB)
            XCTAssertEqual(f.consumer.snapshots.last?.session, expectedB)
            await assertTrace(f, ["transition:bootstrap", "guest", "transition:signIn", active(1, a),
                                  "transition:" + operation.rawValue, "guest", "transition:signIn", active(2, b)])
        }
    }

    func testStorageFailureConsumerMustAcknowledgeBeforeReplacementWriter() async throws {
        let f = try ProviderSessionFixture()
        _ = try await f.perform(.bootstrap)
        let current = try await login(f, a)
        let acknowledgmentGate = ProviderSessionGate()
        f.consumer.nextAcknowledgment = acknowledgmentGate
        f.storage.failNext("store")
        await f.transport.enqueue(ProviderSessionTransport.passwordRoute, data: try providerResponse(f.session(b, "failed-B")))
        let failed = f.start(.signIn)
        await acknowledgmentGate.waitForArrival()
        let expectedB = f.session(b, "good-B")
        await f.transport.enqueue(ProviderSessionTransport.passwordRoute, data: try providerResponse(expectedB))
        let next = f.start(.signIn)
        let requests = await f.transport.trace
        XCTAssertEqual(requests, [ProviderSessionTransport.passwordRoute, ProviderSessionTransport.passwordRoute])
        XCTAssertEqual(f.consumer.acknowledgments, 2)
        XCTAssertNil(f.coordinator.context)
        XCTAssertEqual(try f.storage.storedSession(), current.session)
        XCTAssertEqual(f.consumer.trace, ["transition:bootstrap", "guest", "transition:signIn", active(1, a),
                                         "transition:signIn", "unavailable"])
        await acknowledgmentGate.open()
        await rejected { _ = try await failed.value }
        let result = try await next.value
        XCTAssertEqual(result.session, expectedB)
        XCTAssertEqual(try f.storage.storedSession(), expectedB)
        XCTAssertEqual(f.consumer.snapshots.last?.session, expectedB)
        await assertTrace(f, ["transition:bootstrap", "guest", "transition:signIn", active(1, a),
                              "transition:signIn", "unavailable", "transition:signIn", active(2, b)])
    }

    func testQueuedCancellationDoesNotWriteAndNextRequestProgresses() async throws {
        let f = try ProviderSessionFixture()
        _ = try await f.perform(.bootstrap)
        let current = try await login(f, a)
        let gate = ProviderSessionGate()
        await f.transport.enqueue(ProviderSessionTransport.refreshRoute, data: try providerResponse(f.session(a, "A2")), hold: gate)
        let old = f.start(.refresh, expectedContext: current.context)
        await gate.waitForArrival()
        let queued = f.start(.signIn)
        queued.cancel()
        await cancelled(queued)
        let expectedB = f.session(b, "B")
        await f.transport.enqueue(ProviderSessionTransport.passwordRoute, data: try providerResponse(expectedB))
        let next = f.start(.signIn)
        await gate.open()
        _ = try await old.value
        let result = try await next.value
        XCTAssertEqual(result.session, expectedB)
        XCTAssertEqual(try f.storage.storedSession(), expectedB)
        await assertTrace(f, ["transition:bootstrap", "guest", "transition:signIn", active(1, a),
                              "transition:refresh", active(1, a), "transition:signIn", active(2, b)])
    }

    #if DEBUG
    func testUnknownOriginPreservesStorageAndRequiresFreshAuthentication() async throws {
        let f = try ProviderSessionFixture()
        _ = try await f.perform(.bootstrap)
        let old = try await login(f, b)
        let before = f.storage.bytes
        await f.coordinator.injectUnknownEventForTesting()
        XCTAssertNil(f.coordinator.context)
        XCTAssertEqual(f.storage.bytes, before)
        await rejected { _ = try await f.perform(.signOut, expectedContext: old.context) }
        await rejected { _ = try await f.perform(.restore) }
        await rejected { _ = try await f.perform(.bootstrap) }
        let user = f.session(a, "confirmation-only").user
        await f.transport.enqueue("POST /signup", data: try AuthClient.Configuration.jsonEncoder.encode(user))
        await rejected { _ = try await f.perform(.signUp) }
        XCTAssertEqual(f.storage.bytes, before)
        XCTAssertNil(f.coordinator.context)
        let newer = try await login(f, b, credential: "fresh-B")
        XCTAssertNotEqual(old.context, newer.context)
        await assertTrace(f, ["transition:bootstrap", "guest", "transition:signIn", active(1, b), "unavailable",
                              "transition:signUp", "unavailable", "transition:signIn", active(2, b)])
    }
    #endif

    func testSessionlessSignupConfirmsEmailWithoutCreatingAuthentication() async throws {
        for storedSession in [false, true] {
            let f = try ProviderSessionFixture()
            _ = try await f.perform(.bootstrap)
            let prior = storedSession ? try await login(f, b) : nil
            let before = f.storage.bytes
            let user = f.session(a, "confirmation-only").user
            await f.transport.enqueue("POST /signup", data: try AuthClient.Configuration.jsonEncoder.encode(user))
            let result = try await f.perform(.signUp)
            XCTAssertEqual(result.confirmationEmail, user.email)
            XCTAssertEqual(result.session, prior?.session)
            XCTAssertEqual(result.context, prior?.context)
            XCTAssertEqual(f.storage.bytes, before)
            XCTAssertEqual(try f.storage.storedSession(), prior?.session)
            var expected = ["transition:bootstrap", "guest"]
            if storedSession { expected += ["transition:signIn", active(1, b)] }
            expected += ["transition:signUp", storedSession ? active(1, b) : "guest"]
            await assertTrace(f, expected)
        }
    }

    func testExpiredBootstrapTransportFailureCannotPublishExpiredAuthentication() async throws {
        let clock = ProviderSessionClock()
        let expired = providerSession(user: a, credential: "expired", now: clock.now(), lifetime: -10)
        let f = try ProviderSessionFixture(seed: expired, clock: clock)
        await f.transport.enqueue(ProviderSessionTransport.refreshRoute, failure: true)
        await rejected { _ = try await f.perform(.bootstrap) }
        XCTAssertEqual(try f.storage.storedSession(), expired)
        XCTAssertNil(f.coordinator.context)
        XCTAssertNil(f.consumer.snapshots.last?.session)
        _ = try await login(f, b, credential: "after-bootstrap-failure")
        await assertTrace(f, ["transition:bootstrap", "unavailable", "transition:signIn", active(1, b)])
    }

    func testOwnedRefreshEligibilityAndLifecycleUseControlledClock() async throws {
        let clock = ProviderSessionClock()
        let initial = providerSession(user: a, credential: "near-expiry", now: clock.now(), lifetime: 125)
        let f = try ProviderSessionFixture(seed: initial, clock: clock)
        let bootstrapped = try await f.perform(.bootstrap)
        try await f.coordinator.refreshIfNeeded()
        clock.advance(by: 5)
        try await f.coordinator.refreshIfNeeded()
        var requests = await f.transport.trace
        XCTAssertTrue(requests.isEmpty)
        clock.advance(by: 25)
        let fresh = f.session(a, "clock-refresh")
        await f.transport.enqueue(ProviderSessionTransport.refreshRoute, data: try providerResponse(fresh))
        try await f.coordinator.refreshIfNeeded()
        XCTAssertEqual(try f.storage.storedSession(), fresh)
        XCTAssertEqual(f.coordinator.context, bootstrapped.context)
        f.coordinator.setActive(false)
        clock.advance(by: 3570)
        try await f.coordinator.refreshIfNeeded()
        requests = await f.transport.trace
        XCTAssertEqual(requests, [ProviderSessionTransport.refreshRoute])
        let reactivated = f.session(a, "reactivated")
        await f.transport.enqueue(ProviderSessionTransport.refreshRoute, data: try providerResponse(reactivated))
        f.coordinator.setActive(true)
        try await f.coordinator.refreshIfNeeded()
        XCTAssertEqual(try f.storage.storedSession(), reactivated)
        XCTAssertEqual(f.coordinator.context, bootstrapped.context)
        await assertTrace(f, ["transition:bootstrap", active(1, a), "transition:refresh", active(1, a),
                              "transition:refresh", active(1, a)])
    }

    func testOwnedRefreshCoalescesWhileSDKIsSuspended() async throws {
        let clock = ProviderSessionClock()
        let initial = providerSession(user: a, credential: "near-expiry", now: clock.now(), lifetime: 90)
        let f = try ProviderSessionFixture(seed: initial, clock: clock)
        let bootstrapped = try await f.perform(.bootstrap)
        let gate = ProviderSessionGate()
        let fresh = f.session(a, "coalesced-refresh")
        await f.transport.enqueue(ProviderSessionTransport.refreshRoute, data: try providerResponse(fresh), hold: gate)
        let refresh = Task { try await f.coordinator.refreshIfNeeded() }
        await gate.waitForArrival()
        clock.advance(by: 120)
        for _ in 0..<4 { try await f.coordinator.refreshIfNeeded() }
        let requests = await f.transport.trace
        XCTAssertEqual(requests, [ProviderSessionTransport.refreshRoute])
        await gate.open()
        try await refresh.value
        XCTAssertEqual(try f.storage.storedSession(), fresh)
        XCTAssertEqual(f.coordinator.context, bootstrapped.context)
        await assertTrace(f, ["transition:bootstrap", active(1, a), "transition:refresh", active(1, a)])
    }

    func testForegroundLifecycleStartsOwnedRefreshWithoutWallClockSleep() async throws {
        let clock = ProviderSessionClock()
        let initial = providerSession(user: a, credential: "near-expiry", now: clock.now(), lifetime: 90)
        let tick = ProviderSessionGate()
        let f = try ProviderSessionFixture(seed: initial, initiallyActive: false, automaticRefresh: true,
                                         clock: clock, sleep: { interval in
            XCTAssertEqual(interval, 30)
            await tick.pass()
            throw CancellationError()
        })
        let original = try await f.perform(.bootstrap)
        try await f.coordinator.refreshIfNeeded()
        let inactiveRequests = await f.transport.trace
        XCTAssertTrue(inactiveRequests.isEmpty)
        let fresh = f.session(a, "foreground-refresh")
        await f.transport.enqueue(ProviderSessionTransport.refreshRoute, data: try providerResponse(fresh))
        f.coordinator.setActive(true)
        await tick.waitForArrival()
        XCTAssertEqual(try f.storage.storedSession(), fresh)
        XCTAssertEqual(f.coordinator.context, original.context)
        f.coordinator.setActive(false)
        await tick.open()
        await assertTrace(f, ["transition:bootstrap", active(1, a), "transition:refresh", active(1, a)])
    }

    func testUnexpectedTransportFailsClosedAndNextAuthenticationWorks() async throws {
        let f = try ProviderSessionFixture()
        _ = try await f.perform(.bootstrap)
        await rejected { _ = try await f.perform(.signIn) }
        XCTAssertNil(f.storage.bytes)
        _ = try await login(f, a)
        await assertTrace(f, ["transition:bootstrap", "guest", "transition:signIn", "guest",
                              "transition:signIn", active(1, a)], unexpected: 1)
    }

    func testUnfencedRealSDKRefreshErrorActuallyErasesReplacementSession() async throws {
        let ledger = ProviderSessionLedger()
        let storage = ProviderSessionMemoryStorage(ledger)
        let transport = ProviderSessionTransport()
        let observed = ProviderSessionRawTrace()
        let clock = ProviderSessionClock()
        let client = AuthClient(configuration: .init(url: ProviderSessionTransport.url,
            storageKey: ProviderSessionMemoryStorage.key, localStorage: storage, logger: nil,
            fetch: { try await transport.fetch($0) }, autoRefreshToken: false,
            emitLocalSessionAsInitialSession: false))
        ledger.begin(UUID())
        let listener = await client.onAuthStateChange { observed.append($0, $1) }
        defer { listener.remove() }
        ledger.end()
        let sessionA = providerSession(user: a, credential: "A", now: clock.now())
        await transport.enqueue(ProviderSessionTransport.passwordRoute, data: try providerResponse(sessionA))
        ledger.begin(UUID())
        let first = try await client.signIn(email: "fixture@example.invalid", password: "synthetic-only")
        ledger.end()
        XCTAssertEqual(first, sessionA)
        XCTAssertEqual(try storage.storedSession(), sessionA)
        let gate = ProviderSessionGate()
        await transport.enqueue(ProviderSessionTransport.refreshRoute, data: providerError("refresh_token_not_found"), status: 403, hold: gate)
        ledger.begin(UUID())
        let stale = Task { try await client.refreshSession() }
        await gate.waitForArrival()
        ledger.end() // Negative control deliberately releases A's ownership before its SDK mutation ends.
        let sessionB = providerSession(user: b, credential: "B", now: clock.now())
        await transport.enqueue(ProviderSessionTransport.passwordRoute, data: try providerResponse(sessionB))
        ledger.begin(UUID())
        let replacement = try await client.signIn(email: "fixture@example.invalid", password: "synthetic-only")
        ledger.end()
        XCTAssertEqual(replacement, sessionB)
        XCTAssertEqual(try storage.storedSession(), sessionB, "all Session fields must belong to B before A resumes")
        await gate.open()
        await rejected { _ = try await stale.value }
        XCTAssertNil(storage.bytes, "real pinned SDK removes B after A's refresh cleanup error")
        XCTAssertEqual(observed.trace, ["INITIAL_SESSION:guest", "SIGNED_IN:\(a.uuidString)",
                                       "SIGNED_IN:\(b.uuidString)", "SIGNED_OUT:guest"])
        XCTAssertGreaterThan(ledger.outsideWrites, 0)
        let requests = await transport.trace
        XCTAssertEqual(requests, [ProviderSessionTransport.passwordRoute, ProviderSessionTransport.refreshRoute,
                                  ProviderSessionTransport.passwordRoute])
        let unexpected = await transport.unexpectedCount
        let remaining = await transport.remainingResponses
        XCTAssertEqual(unexpected, 0)
        XCTAssertEqual(remaining, 0)
    }
}
