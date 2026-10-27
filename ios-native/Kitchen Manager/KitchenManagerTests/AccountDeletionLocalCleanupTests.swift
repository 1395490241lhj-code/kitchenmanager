import XCTest
import SwiftData
@testable import KitchenManager

@MainActor
final class AccountDeletionLocalCleanupTests: XCTestCase {
    private var directory: URL!
    private var suite: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "account-cleanup-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "account-cleanup-\(UUID())"
    }

    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }

    private func bundle() throws -> KitchenPersistenceBundle {
        KitchenPersistenceFactory.bundle(container: try KitchenPersistenceFactory.makeContainer(
            configuration: ModelConfiguration(url: directory.appending(path: "kitchen.store")))
        )
    }

    func testRemoteCompletionThenFailedLocalClearPreservesLibraryAndNeverRepeatsConfirmation() async throws {
        let bundle = try bundle()
        let batch = PreparedComponent(name: "卤鸡腿", portionsRemaining: 3, state: .cooked,
                                      storage: .refrigerated, preparedAt: Date(), expiryDate: Date())
        try bundle.preparedComponents.replaceComponents(with: [batch])
        let failing = LocalClearFault(wrapping: bundle.preparedComponents)
        let kitchen = KitchenStore(
            userDefaults: UserDefaults(suiteName: suite)!, inventoryPersistence: bundle.inventory,
            shoppingListPersistence: bundle.shoppingList, todayPlanPersistence: bundle.todayPlan,
            consumptionPersistence: bundle.consumption, weeklyPlanPersistence: bundle.weeklyPlan,
            preparedComponentPersistence: failing, specialPlanPersistence: bundle.specialPlans,
            recoverySnapshot: KitchenRecoverySnapshotStore(directoryURL: directory.appending(path: "recovery"))
        )
        kitchen.addInventory(name: "保留至清理成功的食材", quantity: 2, unit: "份", expiryDate: nil)
        let recipe = Recipe(id: "retained-recipe", title: "保留的用户菜谱", cookingTime: 10,
                            difficulty: "简单", tags: ["家常"], ingredients: ["鸡腿"], seasonings: ["盐"], steps: ["煮熟"])
        let preferences = [RecipePreference(recipeID: recipe.id, isFavorite: true, isFrequent: true),
                           RecipePreference(recipeID: "other-recipe", isFavorite: true, isFrequent: false)]
        try bundle.userRecipes.replaceRecipes(with: [recipe])
        try bundle.recipePreferences.replacePreferences(with: preferences)
        let auth = AuthStore(authService: AccountLifecycleFixtureAuthService(fixture: .owner),
                             accountService: AccountLifecycleFixtureAccountService(fixture: .owner))
        let signedIn = await auth.signIn(email: "fixture@example.com", password: "local-fixture-only")
        XCTAssertTrue(signedIn)
        let service = CompletedDeletionService()
        let controller = AccountDeletionController(persistence: bundle.sync, service: service)
        await controller.loadPreview(authStore: auth)
        let verified = await controller.reauthenticateForDeletion(password: "local-fixture-only", authStore: auth)
        XCTAssertTrue(verified)
        XCTAssertFalse(kitchen.isPreparedComponentUnavailable, "the collection starts readable")
        service.onCompleted = { failing.failuresRemaining = 3 }

        for attempt in 0..<4 {
            if attempt == 1 {
                await controller.loadPreview(authStore: auth)
                let reauthenticated = await controller.reauthenticateForDeletion(password: "must-not-be-used", authStore: auth)
                XCTAssertFalse(reauthenticated)
                XCTAssertEqual(service.previews, 1, "partial completion cannot return to the preview loop")
                XCTAssertEqual(service.proofs, 1, "local recovery must not reauthenticate")
                failing.failReads = true
                XCTAssertThrowsError(try kitchen.reloadPreparedComponents().get())
                let retried = await controller.retryLocalCleanup(authStore: auth, kitchenStore: kitchen)
                XCTAssertFalse(retried)
                XCTAssertTrue(controller.needsLocalCleanup)
                XCTAssertTrue(kitchen.isPreparedComponentUnavailable)
                XCTAssertTrue(controller.errorMessage?.contains("暂时无法读取") ?? false)
                XCTAssertEqual(service.confirmations, 1)
                try assertLibrary(bundle, recipe: recipe, preferences: preferences)
                failing.failReads = false
            }
            // Also defend an old caller that invokes confirm while local work
            // is pending: it must route locally without another service call.
            let completed = attempt == 0 || attempt == 2
                ? await controller.confirmDeletion(authStore: auth, kitchenStore: kitchen)
                : await controller.retryLocalCleanup(authStore: auth, kitchenStore: kitchen)
            XCTAssertEqual(completed, attempt == 3)
            XCTAssertEqual(controller.didComplete, attempt == 3)
            XCTAssertEqual(controller.needsLocalCleanup, attempt < 3)
            XCTAssertFalse(controller.isConfirming)
            XCTAssertEqual(service.confirmations, 1, "local cleanup retries must not request external deletion again")
            try assertLibrary(bundle, recipe: recipe, preferences: preferences)
            if attempt < 3 {
                XCTAssertFalse(kitchen.isPreparedComponentUnavailable, "an injected delete failure is not a failed Prepared read")
                XCTAssertFalse(kitchen.inventory.isEmpty)
                XCTAssertEqual(try bundle.preparedComponents.loadComponents(), [batch])
                XCTAssertFalse(controller.errorMessage?.contains("「我的」") ?? false, "Settings clears a broader scope")
                XCTAssertFalse(controller.errorMessage?.contains("重新读取备餐") ?? false, "describe the actual clear failure")
                XCTAssertFalse(controller.errorMessage?.contains("无法读取") ?? false)
                XCTAssertTrue(controller.errorMessage?.contains("清理失败") ?? false)
                if case .signedIn = auth.status {} else { XCTFail("sign-out must follow successful kitchen cleanup") }
            }
        }
        XCTAssertTrue(kitchen.inventory.isEmpty)
        XCTAssertTrue(kitchen.preparedComponents.isEmpty)
        XCTAssertTrue(try self.bundle().preparedComponents.loadComponents().isEmpty)
        XCTAssertNil(controller.errorMessage)
        if case .guest = auth.status {} else { XCTFail("successful cleanup must finish the established sign-out") }
    }

    private func assertLibrary(_ bundle: KitchenPersistenceBundle, recipe: Recipe,
                               preferences: [RecipePreference]) throws {
        for persistence in [bundle, try self.bundle()] {
            XCTAssertEqual(try persistence.userRecipes.loadRecipes(), [recipe])
            XCTAssertEqual(try persistence.recipePreferences.loadPreferences().sorted { $0.recipeID < $1.recipeID },
                           preferences.sorted { $0.recipeID < $1.recipeID })
        }
    }

    func testSuccessfulDeletionDoesNotLatchCompletionForAnotherAccount() async throws {
        let authService = SwitchableAuthService()
        let auth = AuthStore(authService: authService, accountService: UnavailableAccountService())
        let service = CompletedDeletionService()
        let bundle = try bundle()
        let kitchen = KitchenStore(userDefaults: UserDefaults(suiteName: suite)!, persistence: bundle,
                                   recoverySnapshot: KitchenRecoverySnapshotStore(directoryURL: directory.appending(path: "recovery")))
        let controller = AccountDeletionController(persistence: bundle.sync, service: service)
        let firstSignIn = await auth.signIn(email: "first@example.com", password: "fixture-only")
        XCTAssertTrue(firstSignIn)
        await controller.loadPreview(authStore: auth)
        let firstProof = await controller.reauthenticateForDeletion(password: "fixture-only", authStore: auth)
        XCTAssertTrue(firstProof)
        let firstDeletion = await controller.confirmDeletion(authStore: auth, kitchenStore: kitchen)
        XCTAssertTrue(firstDeletion)
        XCTAssertTrue(controller.didComplete)

        authService.userID = UUID()
        let nextSignIn = await auth.signIn(email: "second@example.com", password: "fixture-only")
        XCTAssertTrue(nextSignIn)
        kitchen.addInventory(name: "另一个账号的本机食材", quantity: 1, unit: "份", expiryDate: nil)
        let withoutPreview = await controller.confirmDeletion(authStore: auth, kitchenStore: kitchen)
        XCTAssertFalse(withoutPreview, "a different account cannot inherit a completed deletion result")
        XCTAssertFalse(kitchen.inventory.isEmpty)
        XCTAssertEqual(service.confirmations, 1)
        await controller.loadPreview(authStore: auth)
        XCTAssertFalse(controller.didComplete)
        XCTAssertNotNil(controller.preview)
        XCTAssertEqual(service.previews, 2)
        let secondProof = await controller.reauthenticateForDeletion(password: "fixture-only", authStore: auth)
        XCTAssertTrue(secondProof)
        let secondDeletion = await controller.confirmDeletion(authStore: auth, kitchenStore: kitchen)
        XCTAssertTrue(secondDeletion)
        XCTAssertEqual(service.confirmations, 2)
        XCTAssertTrue(kitchen.inventory.isEmpty)
    }

    private enum Fault: Error { case localClear }

    private final class SwitchableAuthService: AuthService {
        var userID = UUID()
        var authStateChanges: AsyncStream<AuthStateChange> { AsyncStream { $0.finish() } }
        func restoreSession() async throws -> AuthSession? { nil }
        func signUp(email: String, password: String) async throws -> SignUpOutcome { throw AuthenticationError.unavailable }
        func signIn(email: String, password: String) async throws -> AuthSession {
            AuthSession(user: AuthUser(id: userID, email: email), accessToken: "isolated-account-token")
        }
        func reauthenticate(email: String, password: String) async throws -> AuthSession {
            try await signIn(email: email, password: password)
        }
        func signOut() async throws {}
    }
    private final class LocalClearFault: PreparedComponentPersistenceProtocol {
        let wrapped: PreparedComponentPersistenceProtocol
        var failuresRemaining = 0
        var failReads = false
        init(wrapping wrapped: PreparedComponentPersistenceProtocol) { self.wrapped = wrapped }
        func loadComponents() throws -> [PreparedComponent] {
            if failReads { throw Fault.localClear }
            return try wrapped.loadComponents()
        }
        func replaceComponents(with components: [PreparedComponent]) throws { try wrapped.replaceComponents(with: components) }
        func upsert(_ component: PreparedComponent) throws { try wrapped.upsert(component) }
        func delete(id: UUID) throws { try wrapped.delete(id: id) }
        func deleteAll() throws {
            if failuresRemaining > 0 { failuresRemaining -= 1; throw Fault.localClear }
            try wrapped.deleteAll()
        }
    }

    private final class CompletedDeletionService: AccountDeletionService {
        var confirmations = 0
        var previews = 0
        var proofs = 0
        var onCompleted: (() -> Void)?
        func preview(accessToken: String) async throws -> AccountDeletionPreview {
            previews += 1
            return AccountDeletionPreview(canDelete: true, blockingReason: nil, householdCount: 0, ownedHouseholdCount: 0,
                                   requiresOwnershipTransfer: false, requiresHouseholdDeletion: false,
                                   pendingMutationCountBucket: "0", confirmationVersion: "isolated-cleanup")
        }
        func transferCandidates(accessToken: String, householdId: UUID) async throws -> [TransferCandidate] { [] }
        func transferOwnership(accessToken: String, householdId: UUID, newOwnerUserId: UUID) async throws {}
        func createReauthenticationProof(accessToken: String, confirmationVersion: String) async throws -> AccountDeletionReauthenticationResult {
            proofs += 1
            return AccountDeletionReauthenticationResult(reauthenticationProof: "isolated-proof")
        }
        func confirmDeletion(accessToken: String, idempotencyKey: UUID, confirmationVersion: String,
                             reauthenticationProof: String) async throws -> AccountDeletionConfirmResult {
            confirmations += 1
            let callback = onCompleted
            onCompleted = nil
            callback?()
            return AccountDeletionConfirmResult(status: "completed")
        }
    }
}
