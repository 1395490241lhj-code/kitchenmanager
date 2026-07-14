import SwiftUI

@main
struct KitchenManagerApp: App {
    @StateObject private var recipeStore: RecipeStore
    @StateObject private var kitchenStore: KitchenStore
    @StateObject private var authStore: AuthStore
    @StateObject private var guestMergeController: GuestMergeController
    #if DEBUG
    @StateObject private var syncSmokeController: SyncSmokeController
    #endif
    @StateObject private var navigationStore = AppNavigationStore()
    @StateObject private var recommendationStore = HomeRecommendationStore()
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
                .environmentObject(authStore)
                .environmentObject(guestMergeController)
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
        #endif
    }
}

#Preview {
    ContentView()
        .environmentObject(RecipeStore())
        .environmentObject(KitchenStore())
        .environmentObject(AppNavigationStore())
        .environmentObject(HomeRecommendationStore())
        .environmentObject(AuthStore.guestPreview())
        .environmentObject(GuestMergeController(
            persistence: KitchenPersistenceFactory.isolatedInMemory().sync
        ))
        #if DEBUG
        .environmentObject(SyncSmokeController(
            persistence: KitchenPersistenceFactory.isolatedInMemory().sync
        ))
        #endif
}
