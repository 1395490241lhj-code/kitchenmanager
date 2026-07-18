import SwiftUI

@main
struct KitchenManagerApp: App {
    @StateObject private var recipeStore: RecipeStore
    @StateObject private var kitchenStore: KitchenStore
    @StateObject private var authStore: AuthStore
    @StateObject private var guestMergeController: GuestMergeController
    @StateObject private var accountDeletionController: AccountDeletionController
    #if DEBUG
    @StateObject private var syncSmokeController: SyncSmokeController
    #endif
    @StateObject private var navigationStore = AppNavigationStore()
    @StateObject private var recommendationStore = HomeRecommendationStore()
    @StateObject private var sharedImportCoordinator = SharedImportCoordinator(queue: SharedImportConfig.makeQueue())
    @AppStorage("appearance") private var appearanceRawValue = AppAppearance.system.rawValue

    init() {
        let persistence = KitchenPersistenceFactory.application()
        _recipeStore = StateObject(
            wrappedValue: RecipeStore(
                userRecipePersistence: persistence.userRecipes,
                recipePreferencePersistence: persistence.recipePreferences
            )
        )
        let kitchenStoreInstance = KitchenStore(
            inventoryPersistence: persistence.inventory,
            shoppingListPersistence: persistence.shoppingList,
            todayPlanPersistence: persistence.todayPlan,
            consumptionPersistence: persistence.consumption,
            weeklyPlanPersistence: persistence.weeklyPlan
        )
        let authStoreInstance = AuthenticationAssembly.make()
        let guestMergeControllerInstance = GuestMergeController(persistence: persistence.sync)

        // Phase 2B-4: the only place `KitchenStore` is told anything about
        // sync — a plain closure capturing weak references, reading the
        // *current* signed-in user/household fresh on every inventory
        // change (never a frozen snapshot). `KitchenStore` itself never
        // imports Auth/Sync types; this stays entirely in the composition
        // root. Never touches the network — only stages a local mutation.
        kitchenStoreInstance.onInventoryChanged = { [weak guestMergeControllerInstance, weak authStoreInstance] old, new in
            guard let guestMergeControllerInstance else { return }
            let userId = authStoreInstance?.currentUserID
            let householdId = authStoreInstance?.account?.households.first(where: { $0.role == "owner" })?.id
                ?? authStoreInstance?.account?.households.first?.id
            Task { @MainActor in
                await guestMergeControllerInstance.handleInventoryDidChange(old: old, new: new, userId: userId, householdId: householdId)
            }
        }

        _kitchenStore = StateObject(wrappedValue: kitchenStoreInstance)
        _authStore = StateObject(wrappedValue: authStoreInstance)
        _guestMergeController = StateObject(wrappedValue: guestMergeControllerInstance)
        _accountDeletionController = StateObject(wrappedValue: AccountDeletionController(persistence: persistence.sync))
        #if DEBUG
        _syncSmokeController = StateObject(
            wrappedValue: SyncSmokeController(persistence: persistence.sync)
        )
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recipeStore)
                .environmentObject(kitchenStore)
                .environmentObject(navigationStore)
                .environmentObject(recommendationStore)
                .environmentObject(sharedImportCoordinator)
                .environmentObject(authStore)
                .environmentObject(guestMergeController)
                .environmentObject(accountDeletionController)
                #if DEBUG
                .environmentObject(syncSmokeController)
                #endif
                .preferredColorScheme((AppAppearance(rawValue: appearanceRawValue) ?? .system).colorScheme)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var recipeStore: RecipeStore
    @EnvironmentObject private var navigationStore: AppNavigationStore
    @EnvironmentObject private var kitchenStore: KitchenStore
    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var sharedImportCoordinator: SharedImportCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var inventoryPath = NavigationPath()

    var body: some View {
        TabView(selection: $navigationStore.selectedTab) {
            Tab("首页", systemImage: "house", value: AppTab.today) {
                NavigationStack {
                    HomeView()
                }
            }

            Tab("食材", systemImage: "shippingbox", value: AppTab.inventory) {
                NavigationStack(path: $inventoryPath) {
                    InventoryView(onSelectItem: { itemID in
                        inventoryPath.append(InventoryRoute.detail(itemID))
                    })
                }
                #if DEBUG
                .onChange(of: inventoryPath.count) { oldValue, newValue in
                    print("[InventoryNavigation] path \(oldValue) -> \(newValue)")
                }
                #endif
            }

            Tab("买菜", systemImage: "checklist", value: AppTab.shopping) {
                NavigationStack {
                    ShoppingView()
                }
            }

            Tab("菜谱", systemImage: "book.closed", value: AppTab.recipes) {
                NavigationStack {
                    RecipeListView()
                }
            }

            Tab("我的", systemImage: "person", value: AppTab.settings) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        .tint(AppTheme.primary)
        .tabBarMinimizeBehavior(.onScrollDown)
        .task {
            await authStore.start()
            if recipeStore.remoteRecipes.isEmpty {
                await recipeStore.loadRecipes()
            }
        }
        .task {
            // Initial check after launch completes — auth restoring runs
            // concurrently above and never blocks this; a pending shared
            // import is a purely local, guest-safe read.
            sharedImportCoordinator.refresh(isAnotherImportFlowPresented: false)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            sharedImportCoordinator.refresh(isAnotherImportFlowPresented: false)
        }
        #if DEBUG
        // UI-test-only seed hook: only runs when KitchenManagerUITests passes this
        // launch argument, so it never fires for a real user or a normal debug run.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_INVENTORY") else { return }
            kitchenStore.clearAllLocalData()
            let now = Date()
            kitchenStore.importInventory([
                InventoryImportItem(name: "豆腐", quantity: 1, unit: "块", expiryDate: Calendar.current.date(byAdding: .day, value: 10, to: now)),
                InventoryImportItem(name: "莴笋", quantity: 1, unit: "根", expiryDate: Calendar.current.date(byAdding: .day, value: 13, to: now)),
                InventoryImportItem(name: "土豆", quantity: 1, unit: "个", expiryDate: Calendar.current.date(byAdding: .day, value: 16, to: now)),
                InventoryImportItem(name: "韭菜花", quantity: 1, unit: "份", expiryDate: Calendar.current.date(byAdding: .day, value: 19, to: now)),
            ])
            navigationStore.selectedTab = .inventory
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_HOME_DASHBOARD") else { return }
            kitchenStore.clearAllLocalData()
            let now = Date()
            kitchenStore.importInventory([
                InventoryImportItem(name: "临期牛奶", quantity: 1, unit: "盒", expiryDate: Calendar.current.date(byAdding: .day, value: 1, to: now)),
                InventoryImportItem(name: "过期生菜", quantity: 1, unit: "颗", expiryDate: Calendar.current.date(byAdding: .day, value: -1, to: now)),
                InventoryImportItem(name: "大米", quantity: 1, unit: "袋", expiryDate: nil, isStaple: true)
            ])
            if let riceIndex = kitchenStore.inventory.firstIndex(where: { $0.name == "大米" }) {
                kitchenStore.inventory[riceIndex].lowStockThreshold = 2
            }
            kitchenStore.addShopping(name: "鸡蛋", quantity: 1, unit: "盒")
            kitchenStore.addShopping(name: "青菜", quantity: 1, unit: "份")
            kitchenStore.addPlans(
                Recipe.samples.prefix(3).enumerated().map { offset, recipe in
                    (recipe: recipe, servings: offset + 1)
                }
            )
            navigationStore.selectedTab = .today
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_EMPTY_HOME") else { return }
            kitchenStore.clearAllLocalData()
            navigationStore.selectedTab = .today
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_HOME_STOCK_IN") else { return }
            kitchenStore.clearAllLocalData()
            kitchenStore.importInventory([
                InventoryImportItem(
                    name: "过期生菜",
                    quantity: 1,
                    unit: "颗",
                    expiryDate: Calendar.current.date(byAdding: .day, value: -1, to: Date())
                )
            ])
            kitchenStore.addShopping(name: "牛奶", quantity: 1, unit: "盒")
            if let milk = kitchenStore.shoppingItems.first(where: { $0.name == "牛奶" }) {
                kitchenStore.toggleShopping(milk)
            }
            navigationStore.selectedTab = .today
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_HOME_ERROR") else { return }
            kitchenStore.clearAllLocalData()
            kitchenStore.inventoryNotice = "库存保存失败，请稍后重试。"
            navigationStore.selectedTab = .today
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_RECIPE_COOKING") else { return }
            kitchenStore.clearAllLocalData()
            navigationStore.selectedTab = .recipes
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_SHOPPING") else { return }
            kitchenStore.clearAllLocalData()
            kitchenStore.addShopping(name: "番茄", quantity: 2, unit: "个")
            kitchenStore.addShopping(name: "大米", quantity: 1, unit: "袋")
            kitchenStore.addShopping(name: "牛奶", quantity: 1, unit: "盒")
            if let milk = kitchenStore.shoppingItems.first(where: { $0.name == "牛奶" }) {
                kitchenStore.toggleShopping(milk)
            }
            navigationStore.selectedTab = .shopping
        }
        #endif
    }
}

#Preview {
    ContentView()
        .environmentObject(RecipeStore())
        .environmentObject(KitchenStore())
        .environmentObject(AppNavigationStore())
        .environmentObject(HomeRecommendationStore())
        .environmentObject(SharedImportCoordinator(queue: nil))
        .environmentObject(AuthStore.guestPreview())
        .environmentObject(GuestMergeController(
            persistence: KitchenPersistenceFactory.isolatedInMemory().sync
        ))
        .environmentObject(AccountDeletionController(
            persistence: KitchenPersistenceFactory.isolatedInMemory().sync
        ))
        #if DEBUG
        .environmentObject(SyncSmokeController(
            persistence: KitchenPersistenceFactory.isolatedInMemory().sync
        ))
        #endif
}
