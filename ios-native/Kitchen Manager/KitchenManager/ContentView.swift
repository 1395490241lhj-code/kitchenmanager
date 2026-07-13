import SwiftUI

@main
struct KitchenManagerApp: App {
    @StateObject private var recipeStore: RecipeStore
    @StateObject private var kitchenStore: KitchenStore
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
        _kitchenStore = StateObject(
            wrappedValue: KitchenStore(
                inventoryPersistence: persistence.inventory,
                shoppingListPersistence: persistence.shoppingList,
                todayPlanPersistence: persistence.todayPlan,
                consumptionPersistence: persistence.consumption
                , weeklyPlanPersistence: persistence.weeklyPlan
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recipeStore)
                .environmentObject(kitchenStore)
                .environmentObject(navigationStore)
                .environmentObject(recommendationStore)
                .preferredColorScheme((AppAppearance(rawValue: appearanceRawValue) ?? .system).colorScheme)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var recipeStore: RecipeStore
    @EnvironmentObject private var navigationStore: AppNavigationStore
    @EnvironmentObject private var kitchenStore: KitchenStore
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
}
