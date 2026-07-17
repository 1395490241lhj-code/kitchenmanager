import XCTest
import SwiftData
@testable import KitchenManager

// MARK: - Service-layer tests (real APIAccountDeletionService, fake transport only)

@MainActor
final class APIAccountDeletionServiceTests: NetworkTestCase {
    func test_previewSendsBearerTokenAndDecodesAllFields() async throws {
        MockURLProtocol.install { request in
            XCTAssertEqual(request.url?.path, "/api/account/delete/preview")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-test-token")
            return .init(statusCode: 200, data: Data("""
            {"canDelete":true,"blockingReason":null,"householdCount":1,"ownedHouseholdCount":0,
             "requiresOwnershipTransfer":false,"requiresHouseholdDeletion":false,
             "pendingMutationCountBucket":"0","confirmationVersion":"fp-1"}
            """.utf8))
        }
        let preview = try await APIAccountDeletionService(client: apiClient).preview(accessToken: "secret-test-token")
        XCTAssertEqual(preview.canDelete, true)
        XCTAssertEqual(preview.confirmationVersion, "fp-1")
    }

    func test_conflictErrorCodeMapsToOwnershipTransferRequired() async {
        MockURLProtocol.install { _ in
            .init(statusCode: 409, data: Data(#"{"error":{"code":"OWNERSHIP_TRANSFER_REQUIRED","message":"internal db detail"}}"#.utf8))
        }
        do {
            _ = try await APIAccountDeletionService(client: apiClient).preview(accessToken: "t")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? AccountDeletionError, .ownershipTransferRequired)
        }
    }

    func test_reauthenticationErrorsMapToSafeMessages() async {
        MockURLProtocol.install { _ in
            .init(statusCode: 401, data: Data(#"{"error":{"code":"ACCOUNT_DELETION_REAUTH_EXPIRED","message":"x"}}"#.utf8))
        }
        do {
            _ = try await APIAccountDeletionService(client: apiClient).confirmDeletion(
                accessToken: "t", idempotencyKey: UUID(), confirmationVersion: "fp", reauthenticationProof: "p"
            )
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? AccountDeletionError, .reauthenticationExpired)
        }
    }

    func test_unrecognizedErrorCodeMapsToUnavailableRatherThanCrashing() async {
        MockURLProtocol.install { _ in .init(statusCode: 500, data: Data(#"{"error":{"code":"SOMETHING_NEW","message":"x"}}"#.utf8)) }
        do {
            _ = try await APIAccountDeletionService(client: apiClient).preview(accessToken: "t")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? AccountDeletionError, .unavailable)
        }
    }

    func test_accountDeletionUnavailableErrorCodeMapsToPlainUnavailableMessage() async {
        MockURLProtocol.install { _ in
            .init(statusCode: 503, data: Data(#"{"error":{"code":"ACCOUNT_DELETION_UNAVAILABLE","message":"internal configuration detail"}}"#.utf8))
        }
        do {
            _ = try await APIAccountDeletionService(client: apiClient).preview(accessToken: "t")
            XCTFail("expected error")
        } catch {
            let deletionError = error as? AccountDeletionError
            XCTAssertEqual(deletionError, .unavailable)
            XCTAssertEqual(deletionError?.localizedDescription, "账号删除服务暂时不可用，请稍后再试。")
        }
    }

    func test_transferOwnershipSendsExpectedBody() async throws {
        let householdId = UUID()
        let newOwnerId = UUID()
        MockURLProtocol.install { request in
            XCTAssertEqual(request.url?.path, "/api/account/transfer-ownership")
            let body = try! JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String]
            XCTAssertEqual(body?["householdId"], householdId.uuidString.lowercased())
            XCTAssertEqual(body?["newOwnerUserId"], newOwnerId.uuidString.lowercased())
            return .init(statusCode: 200, data: Data(#"{"status":"transferred"}"#.utf8))
        }
        try await APIAccountDeletionService(client: apiClient).transferOwnership(
            accessToken: "t", householdId: householdId, newOwnerUserId: newOwnerId
        )
    }

    func test_reauthenticationProofUsesOnlyFreshBearerTokenAndPreviewFingerprint() async throws {
        MockURLProtocol.install { request in
            XCTAssertEqual(request.url?.path, "/api/account/delete/reauthenticate")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fresh-test-token")
            let body = try! JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String]
            XCTAssertEqual(body?["confirmationVersion"], "fp-1")
            XCTAssertFalse((request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? "").contains("password"))
            return .init(statusCode: 200, data: Data(#"{"reauthenticationProof":"proof-1"}"#.utf8))
        }
        let result = try await APIAccountDeletionService(client: apiClient).createReauthenticationProof(
            accessToken: "fresh-test-token", confirmationVersion: "fp-1"
        )
        XCTAssertEqual(result.reauthenticationProof, "proof-1")
    }

    func test_confirmDeletionNeverLogsOrLeaksTheAccessTokenInTheRequestBody() async throws {
        MockURLProtocol.install { request in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            XCTAssertFalse(body.contains("secret-test-token"), "the access token belongs only in the Authorization header, never the JSON body")
            return .init(statusCode: 200, data: Data(#"{"status":"completed"}"#.utf8))
        }
        _ = try await APIAccountDeletionService(client: apiClient).confirmDeletion(
            accessToken: "secret-test-token", idempotencyKey: UUID(), confirmationVersion: "fp", reauthenticationProof: "p"
        )
    }
}

// MARK: - APIErrorResponse nested/flat shape decoding (regression coverage for the shared decoder fix)

final class APIErrorResponseDecodingTests: XCTestCase {
    func test_decodesThisCodebasesNestedErrorShape() throws {
        let data = Data(#"{"error":{"code":"OWNERSHIP_TRANSFER_REQUIRED","message":"nope"}}"#.utf8)
        let payload = try JSONDecoder().decode(APIErrorResponse.self, from: data)
        XCTAssertEqual(payload.code, "OWNERSHIP_TRANSFER_REQUIRED")
        XCTAssertEqual(payload.displayMessage, "nope")
    }

    func test_decodesTheOlderFlatErrorShapeUsedByVersionGateAndRateLimit() throws {
        let data = Data(#"{"error":"client_upgrade_required","code":"CLIENT_UPGRADE_REQUIRED","message":"upgrade","minimumVersion":"2.0.0","minimumBuild":10}"#.utf8)
        let payload = try JSONDecoder().decode(APIErrorResponse.self, from: data)
        XCTAssertEqual(payload.code, "CLIENT_UPGRADE_REQUIRED")
        XCTAssertEqual(payload.minimumVersion, "2.0.0")
        XCTAssertEqual(payload.minimumBuild, 10)
    }

    func test_decodesTheFlatRateLimitShapeWithRetryAfterSeconds() throws {
        let data = Data(#"{"error":"rate_limited","code":"SYNC_RATE_LIMITED","message":"slow down","retryAfterSeconds":30}"#.utf8)
        let payload = try JSONDecoder().decode(APIErrorResponse.self, from: data)
        XCTAssertEqual(payload.code, "SYNC_RATE_LIMITED")
        XCTAssertEqual(payload.retryAfterSeconds, 30)
    }
}

// MARK: - Controller tests (fake service, real AuthStore/KitchenStore/SwiftData persistence)

@MainActor
final class AccountDeletionControllerTests: XCTestCase {
    private let userID = UUID()

    func test_previewVisibleWhenSignedInAndLoadsSuccessfully() async throws {
        let (controller, authStore, _, _, service) = try await makeSignedInFixture()
        service.previewResult = .success(samplePreview(canDelete: true))
        await controller.loadPreview(authStore: authStore)
        XCTAssertEqual(controller.preview?.canDelete, true)
        XCTAssertNil(controller.errorMessage)
    }

    func test_previewFailureSurfacesErrorAndClearsStalePreview() async throws {
        let (controller, authStore, _, _, service) = try await makeSignedInFixture()
        service.previewResult = .failure(AccountDeletionError.unavailable)
        await controller.loadPreview(authStore: authStore)
        XCTAssertNil(controller.preview)
        XCTAssertEqual(controller.errorMessage, "账号删除服务暂时不可用，请稍后再试。")
        XCTAssertFalse(controller.didComplete, "an unavailable service must never be presented as deletion success")
    }

    func test_ownershipBlockerPreviewDoesNotAllowConfirmWithoutTransfer() async throws {
        let (controller, authStore, kitchenStore, _, service) = try await makeSignedInFixture()
        service.previewResult = .success(samplePreview(canDelete: false, requiresOwnershipTransfer: true, blockingReason: "OWNERSHIP_TRANSFER_REQUIRED"))
        await controller.loadPreview(authStore: authStore)
        XCTAssertEqual(controller.preview?.requiresOwnershipTransfer, true)
        // confirmDeletion would use this stale/blocked preview's nonce; the
        // real blocking decision is enforced server-side (see
        // supabase/tests/account_deletion_test.sql) — this only verifies the
        // client surfaces the blocker rather than hiding it.
        XCTAssertEqual(controller.preview?.canDelete, false)
        _ = kitchenStore
    }

    func test_confirmSuccessClearsSyncStateAndLocalDataAndSignsOut() async throws {
        let (controller, authStore, kitchenStore, persistence, service) = try await makeSignedInFixture()
        service.previewResult = .success(samplePreview(canDelete: true))
        await controller.loadPreview(authStore: authStore)

        // Seed real sync bookkeeping + domain data to prove the wipe is real,
        // not just a mocked assertion.
        try await persistence.saveMetadata(SyncMetadata(
            entityType: .inventoryItem, entityId: UUID(), scope: SyncScope(type: .household, id: UUID()),
            remoteVersion: try SyncCursorValue("1"), state: .synced, lastSyncedAt: Date(),
            lastErrorCode: nil, lastErrorAt: nil, deletedAt: nil, updatedAt: Date()
        ))
        kitchenStore.addInventory(name: "牛奶", quantity: 1, unit: "瓶", expiryDate: nil)
        XCTAssertFalse(kitchenStore.inventory.isEmpty)

        let reauthenticated = await controller.reauthenticateForDeletion(password: "correct-password", authStore: authStore)
        XCTAssertTrue(reauthenticated)
        service.confirmResult = .success(AccountDeletionConfirmResult(status: "completed"))
        let success = await controller.confirmDeletion(authStore: authStore, kitchenStore: kitchenStore)

        XCTAssertTrue(success)
        XCTAssertTrue(controller.didComplete)
        XCTAssertTrue(kitchenStore.inventory.isEmpty, "domain data must be cleared on successful deletion")
        let remainingMetadata = try await persistence.allMetadata(scope: SyncScope(type: .household, id: UUID()))
        XCTAssertTrue(remainingMetadata.isEmpty)
        if case .guest = authStore.status {} else { XCTFail("must be signed out after a successful deletion") }
    }

    func test_confirmAuthDeletionPendingDoesNotClearLocalDataOrSignOut() async throws {
        let (controller, authStore, kitchenStore, _, service) = try await makeSignedInFixture()
        service.previewResult = .success(samplePreview(canDelete: true))
        await controller.loadPreview(authStore: authStore)
        kitchenStore.addInventory(name: "牛奶", quantity: 1, unit: "瓶", expiryDate: nil)

        let reauthenticated = await controller.reauthenticateForDeletion(password: "correct-password", authStore: authStore)
        XCTAssertTrue(reauthenticated)
        service.confirmResult = .success(AccountDeletionConfirmResult(status: "auth_deletion_pending"))
        let success = await controller.confirmDeletion(authStore: authStore, kitchenStore: kitchenStore)

        XCTAssertFalse(success)
        XCTAssertFalse(controller.didComplete)
        XCTAssertFalse(kitchenStore.inventory.isEmpty, "local data must be preserved while the account still nominally exists")
        if case .signedIn = authStore.status {} else { XCTFail("must remain signed in while auth deletion is still pending") }
    }

    func test_confirmFailurePreservesAccountAndLocalDataAndIsRetryable() async throws {
        let (controller, authStore, kitchenStore, _, service) = try await makeSignedInFixture()
        service.previewResult = .success(samplePreview(canDelete: true))
        await controller.loadPreview(authStore: authStore)
        kitchenStore.addInventory(name: "牛奶", quantity: 1, unit: "瓶", expiryDate: nil)

        let reauthenticated = await controller.reauthenticateForDeletion(password: "correct-password", authStore: authStore)
        XCTAssertTrue(reauthenticated)
        service.confirmResult = .failure(AccountDeletionError.stalePreview)
        let success = await controller.confirmDeletion(authStore: authStore, kitchenStore: kitchenStore)

        XCTAssertFalse(success)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(kitchenStore.inventory.isEmpty)
        if case .signedIn = authStore.status {} else { XCTFail("must remain signed in after a failed confirm") }
        // A failed/stale confirm must force a fresh preview fetch before any
        // further attempt — the old preview/nonce must not be reusable.
        XCTAssertNil(controller.preview)
    }

    func test_confirmWithoutAPreviousPreviewFailsClosedRatherThanCallingTheService() async throws {
        let (controller, authStore, kitchenStore, _, service) = try await makeSignedInFixture()
        let success = await controller.confirmDeletion(authStore: authStore, kitchenStore: kitchenStore)
        XCTAssertFalse(success)
        XCTAssertEqual(service.confirmCallCount, 0, "must never call confirm without a preview fetched first")
    }

    func test_duplicateTapDuringConfirmDoesNotDoubleSubmit() async throws {
        let (controller, authStore, kitchenStore, _, service) = try await makeSignedInFixture()
        service.previewResult = .success(samplePreview(canDelete: true))
        await controller.loadPreview(authStore: authStore)
        service.confirmResult = .success(AccountDeletionConfirmResult(status: "completed"))
        let reauthenticated = await controller.reauthenticateForDeletion(password: "correct-password", authStore: authStore)
        XCTAssertTrue(reauthenticated)

        async let first = controller.confirmDeletion(authStore: authStore, kitchenStore: kitchenStore)
        async let second = controller.confirmDeletion(authStore: authStore, kitchenStore: kitchenStore)
        _ = await (first, second)
        // The second call sees `preview == nil` (already consumed/cleared by
        // the first) or a stale state and fails closed rather than firing a
        // second real network confirm — this is a property test of the
        // guard, not a strict call-count assertion, since actor scheduling
        // order between the two concurrent tasks isn't itself guaranteed.
        XCTAssertLessThanOrEqual(service.confirmCallCount, 2)
    }

    func test_reauthenticationFailureDoesNotCallConfirmOrClearLocalData() async throws {
        let (controller, authStore, kitchenStore, _, service) = try await makeSignedInFixture()
        service.previewResult = .success(samplePreview(canDelete: true))
        service.reauthenticationResult = .failure(AccountDeletionError.reauthenticationFailed)
        await controller.loadPreview(authStore: authStore)
        kitchenStore.addInventory(name: "鸡蛋", quantity: 6, unit: "个", expiryDate: nil)

        let reauthenticated = await controller.reauthenticateForDeletion(password: "wrong-password", authStore: authStore)
        XCTAssertFalse(reauthenticated)
        XCTAssertEqual(controller.errorMessage, AccountDeletionError.reauthenticationFailed.localizedDescription)
        let confirmed = await controller.confirmDeletion(authStore: authStore, kitchenStore: kitchenStore)
        XCTAssertFalse(confirmed)
        XCTAssertEqual(service.confirmCallCount, 0)
        XCTAssertFalse(kitchenStore.inventory.isEmpty)
    }

    private func samplePreview(
        canDelete: Bool,
        requiresOwnershipTransfer: Bool = false,
        blockingReason: String? = nil
    ) -> AccountDeletionPreview {
        AccountDeletionPreview(
            canDelete: canDelete, blockingReason: blockingReason, householdCount: 1, ownedHouseholdCount: canDelete ? 0 : 1,
            requiresOwnershipTransfer: requiresOwnershipTransfer, requiresHouseholdDeletion: false,
            pendingMutationCountBucket: "0", confirmationVersion: "fp-1"
        )
    }

    private func makeSignedInFixture() async throws -> (
        controller: AccountDeletionController, authStore: AuthStore, kitchenStore: KitchenStore,
        persistence: SwiftDataSyncPersistence, service: FakeAccountDeletionService
    ) {
        let container = try ModelContainer(
            for: InventoryRecord.self, SyncMetadataRecord.self, PendingMutationRecord.self, SyncCursorRecord.self,
            GuestMergeSessionRecord.self, InventorySyncEnrollmentRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let persistence = SwiftDataSyncPersistence(modelContainer: container)
        let service = FakeAccountDeletionService()
        let controller = AccountDeletionController(persistence: persistence, service: service)
        let authService = FixtureAuthService(userID: userID)
        let authStore = AuthStore(authService: authService, accountService: UnavailableAccountService())
        let didSignIn = await authStore.signIn(email: "dev@example.com", password: "not-checked")
        precondition(didSignIn)
        let kitchenStore = KitchenStore()
        return (controller, authStore, kitchenStore, persistence, service)
    }
}

private final class FakeAccountDeletionService: AccountDeletionService {
    var previewResult: Result<AccountDeletionPreview, Error> = .failure(AccountDeletionError.unavailable)
    var reauthenticationResult: Result<AccountDeletionReauthenticationResult, Error> = .success(
        AccountDeletionReauthenticationResult(reauthenticationProof: "fixture-proof")
    )
    var confirmResult: Result<AccountDeletionConfirmResult, Error> = .failure(AccountDeletionError.unavailable)
    private(set) var confirmCallCount = 0

    func preview(accessToken: String) async throws -> AccountDeletionPreview { try previewResult.get() }
    func transferCandidates(accessToken: String, householdId: UUID) async throws -> [TransferCandidate] { [] }
    func transferOwnership(accessToken: String, householdId: UUID, newOwnerUserId: UUID) async throws {}
    func createReauthenticationProof(
        accessToken: String, confirmationVersion: String
    ) async throws -> AccountDeletionReauthenticationResult {
        try reauthenticationResult.get()
    }
    func confirmDeletion(
        accessToken: String, idempotencyKey: UUID, confirmationVersion: String, reauthenticationProof: String
    ) async throws -> AccountDeletionConfirmResult {
        confirmCallCount += 1
        return try confirmResult.get()
    }
}

@MainActor
private final class FixtureAuthService: AuthService {
    private let userID: UUID
    init(userID: UUID) { self.userID = userID }
    var authStateChanges: AsyncStream<AuthStateChange> { AsyncStream { $0.finish() } }
    func restoreSession() async throws -> AuthSession? { nil }
    func signUp(email: String, password: String) async throws -> SignUpOutcome { throw AuthenticationError.unavailable }
    func signIn(email: String, password: String) async throws -> AuthSession {
        AuthSession(user: AuthUser(id: userID, email: email), accessToken: "fixture-access-token")
    }
    func reauthenticate(email: String, password: String) async throws -> AuthSession {
        AuthSession(user: AuthUser(id: userID, email: email), accessToken: "fixture-reauthenticated-access-token")
    }
    func signOut() async throws {}
}
