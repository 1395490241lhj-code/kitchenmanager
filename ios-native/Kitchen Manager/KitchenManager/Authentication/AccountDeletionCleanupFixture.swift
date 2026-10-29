#if DEBUG
import SwiftUI
import Combine

/// An opt-in, credential-free host for the real deletion screen. Both the
/// remote service and authentication are local fakes; persistence is isolated.
struct AccountDeletionCleanupFixture: View {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("UITEST_LOCAL_DELETION_CLEANUP") }
    @StateObject private var auth: AuthStore
    @StateObject private var kitchen: KitchenStore
    @StateObject private var library: RecipeStore
    @StateObject private var controller: AccountDeletionController
    @StateObject private var service: CompletedService
    @StateObject private var mergeController: GuestMergeController
    @State private var didStart = false
    @State private var showingDeletion = false

    init() {
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let defaults = UserDefaults(suiteName: "account-cleanup-ui-\(UUID())")!
        let fault = LocalClearFault(wrapping: bundle.preparedComponents)
        let kitchen = KitchenStore(
            userDefaults: defaults, inventoryPersistence: bundle.inventory,
            shoppingListPersistence: bundle.shoppingList, todayPlanPersistence: bundle.todayPlan,
            consumptionPersistence: bundle.consumption, weeklyPlanPersistence: bundle.weeklyPlan,
            preparedComponentPersistence: fault, specialPlanPersistence: bundle.specialPlans
        )
        kitchen.addPreparedComponent(PreparedComponent(name: "卤鸡腿", portionsRemaining: 3, state: .cooked,
                                                      storage: .refrigerated, preparedAt: Date(), expiryDate: Date()))
        kitchen.addInventory(name: "鸡蛋", quantity: 2, unit: "个", expiryDate: nil)
        let recipe = Recipe(id: "cleanup-retained-recipe", title: "保留的用户菜谱", cookingTime: 10,
                            difficulty: "简单", tags: [], ingredients: ["鸡蛋"], seasonings: [], steps: ["煮熟"])
        do {
            try bundle.userRecipes.replaceRecipes(with: [recipe])
            try bundle.recipePreferences.replacePreferences(with: [
                RecipePreference(recipeID: recipe.id, isFavorite: true, isFrequent: true)
            ])
        } catch { preconditionFailure("Could not seed isolated account cleanup fixture") }
        let library = RecipeStore(userDefaults: defaults, userRecipePersistence: bundle.userRecipes,
                                  recipePreferencePersistence: bundle.recipePreferences)
        let fixtureAuth = SwitchingAuth()
        let auth = AuthStore(authService: fixtureAuth, accountService: UnavailableAccountService())
        let service = CompletedService(fault: fault, authService: fixtureAuth)
        _mergeController = StateObject(wrappedValue: GuestMergeController(persistence: bundle.sync))
        _auth = StateObject(wrappedValue: auth)
        _kitchen = StateObject(wrappedValue: kitchen)
        _library = StateObject(wrappedValue: library)
        _service = StateObject(wrappedValue: service)
        _controller = StateObject(wrappedValue: AccountDeletionController(persistence: bundle.sync, service: service))
    }

    var body: some View {
        NavigationStack {
            List {
                Text("外部删除确认：\(service.confirmations) 次").accessibilityIdentifier("cleanupFixture.confirmations")
                Text("库存：\(kitchen.inventory.count)，备餐：\(kitchen.preparedComponents.count)")
                    .accessibilityIdentifier("cleanupFixture.kitchen")
                Text("用户菜谱：\(library.userRecipes.count)，收藏：\(library.favoriteRecipeIDs.count)，常做：\(library.frequentRecipeIDs.count)")
                    .accessibilityIdentifier("cleanupFixture.library")
                if case .guest = auth.status {
                    Text("游客模式").accessibilityIdentifier("cleanupFixture.guest")
                }
                Text(service.contextLabel).accessibilityIdentifier("cleanupFixture.context")
                Button("切换至隔离账号 B") {
                    Task {
                        await auth.signOut()
                        service.authService.userID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
                        _ = await auth.signIn(email: "b@example.com", password: "fixture-only")
                        seedChangedContext()
                        service.contextLabel = "隔离账号 B"
                    }
                }.accessibilityIdentifier("cleanupFixture.switchB")
                Button("切换至游客上下文") {
                    Task {
                        await auth.signOut()
                        seedChangedContext()
                        service.contextLabel = "游客上下文"
                    }
                }.accessibilityIdentifier("cleanupFixture.switchGuest")
                NavigationLink("打开设置") { SettingsView() }
                    .accessibilityIdentifier("cleanupFixture.settings")
                Button("打开删除账号") { showingDeletion = true }
                    .accessibilityIdentifier("cleanupFixture.open")
            }
            .navigationTitle("本地清理验证")
            .task {
                guard !didStart else { return }
                didStart = true
                _ = await auth.signIn(email: "fixture@example.com", password: "fixture-only")
                showingDeletion = true
            }
            .sheet(isPresented: $showingDeletion) {
                NavigationStack {
                    AccountDeletionView(controller: controller)
                        .environmentObject(auth)
                        .environmentObject(kitchen)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("返回验证入口") { showingDeletion = false }
                                    .accessibilityIdentifier("cleanupFixture.closeDeletion")
                            }
                        }
                }
            }
        }
        .environmentObject(auth)
        .environmentObject(kitchen)
        .environmentObject(library)
        .environmentObject(controller)
        .environmentObject(mergeController)
    }

    private func seedChangedContext() {
        kitchen.addInventory(name: "新上下文的保留食材", quantity: 7, unit: "份", expiryDate: nil)
        _ = kitchen.addPreparedComponent(PreparedComponent(name: "新上下文的保留备餐", portionsRemaining: 5,
            state: .cooked, storage: .refrigerated, preparedAt: Date(), expiryDate: Date()))
    }

    @MainActor
    private final class SwitchingAuth: AuthService {
        var userID = UUID()
        var authStateChanges: AsyncStream<AuthStateChange> { AsyncStream { $0.finish() } }
        func restoreSession() async throws -> AuthSession? { nil }
        func signUp(email: String, password: String) async throws -> SignUpOutcome { throw AuthenticationError.unavailable }
        func signIn(email: String, password: String) async throws -> AuthSession {
            AuthSession(user: AuthUser(id: userID, email: email), accessToken: "isolated-cleanup-fixture")
        }
        func reauthenticate(email: String, password: String) async throws -> AuthSession { try await signIn(email: email, password: password) }
        func signOut() async throws {}
    }

    @MainActor
    private final class LocalClearFault: PreparedComponentPersistenceProtocol {
        let wrapped: PreparedComponentPersistenceProtocol
        var failuresRemaining = 0
        init(wrapping wrapped: PreparedComponentPersistenceProtocol) { self.wrapped = wrapped }
        func loadComponents() throws -> [PreparedComponent] { try wrapped.loadComponents() }
        func replaceComponents(with components: [PreparedComponent]) throws { try wrapped.replaceComponents(with: components) }
        func upsert(_ component: PreparedComponent) throws { try wrapped.upsert(component) }
        func delete(id: UUID) throws { try wrapped.delete(id: id) }
        func deleteAll() throws {
            if failuresRemaining > 0 { failuresRemaining -= 1; throw InjectedClearFailure() }
            try wrapped.deleteAll()
        }
    }
    private struct InjectedClearFailure: Error {}

    @MainActor
    private final class CompletedService: ObservableObject, AccountDeletionService {
        @Published private(set) var confirmations = 0
        let fault: LocalClearFault
        let authService: SwitchingAuth
        @Published var contextLabel = "隔离账号 A"
        init(fault: LocalClearFault, authService: SwitchingAuth) {
            self.fault = fault
            self.authService = authService
        }
        func preview(accessToken: String) async throws -> AccountDeletionPreview {
            AccountDeletionPreview(canDelete: true, blockingReason: nil, householdCount: 0, ownedHouseholdCount: 0,
                                   requiresOwnershipTransfer: false, requiresHouseholdDeletion: false,
                                   pendingMutationCountBucket: "0", confirmationVersion: "isolated-ui-cleanup")
        }
        func transferCandidates(accessToken: String, householdId: UUID) async throws -> [TransferCandidate] { [] }
        func transferOwnership(accessToken: String, householdId: UUID, newOwnerUserId: UUID) async throws {}
        func createReauthenticationProof(accessToken: String, confirmationVersion: String) async throws -> AccountDeletionReauthenticationResult {
            AccountDeletionReauthenticationResult(reauthenticationProof: "isolated-ui-proof")
        }
        func confirmDeletion(accessToken: String, idempotencyKey: UUID, confirmationVersion: String,
                             reauthenticationProof: String) async throws -> AccountDeletionConfirmResult {
            confirmations += 1
            fault.failuresRemaining = 3
            return AccountDeletionConfirmResult(status: "completed")
        }
    }
}
#endif
