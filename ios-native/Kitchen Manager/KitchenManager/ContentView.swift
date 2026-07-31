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
        #if DEBUG
        // Must run before the coordinator's first `refresh` reads the queue.
        // No-op unless KitchenManagerUITests passes the opt-in arguments.
        SharedImportConfig.applyUITestQueueSeedingIfRequested()
        #endif
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
        #if DEBUG
        if AccountLifecycleFixture.active != nil {
            kitchenStoreInstance.clearAllLocalData()
            kitchenStoreInstance.addInventory(name: "测试库存", quantity: 1, unit: "项", expiryDate: nil)
        }
        #endif
        let authStoreInstance = AuthenticationAssembly.make()
        #if DEBUG
        let guestMergeControllerInstance: GuestMergeController
        if AccountLifecycleFixture.active != nil {
            guestMergeControllerInstance = GuestMergeController(
                persistence: persistence.sync,
                configuration: InventoryMergeConfiguration(isEnabled: true),
                uiConfiguration: InventoryMergeUIConfiguration(isEnabled: true),
                dogfoodConfiguration: InventorySyncDogfoodConfiguration(
                    isDogfoodEnabled: true,
                    isMergeUIEnabled: true,
                    isManualSyncEnabled: true,
                    diagnosticsEnabled: true,
                    allowHostedWrites: false,
                    environmentName: "ui-test-fixture"
                ),
                transportFactory: { _ in AccountLifecycleFixtureTransport() }
            )
        } else {
            guestMergeControllerInstance = GuestMergeController(persistence: persistence.sync)
        }
        #else
        let guestMergeControllerInstance = GuestMergeController(persistence: persistence.sync)
        #endif

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
        // UI-test-only appearance hook. Setting the simulator's appearance from
        // XCTest (`XCUIDevice.appearance`, or an "-AppleInterfaceStyle Dark"
        // launch argument) did not reliably reach the app before its first
        // render, so the Dark Mode screenshot silently came out light. Writing
        // the app's own `appearance` preference before the first body evaluation
        // drives the exact `preferredColorScheme(.dark)` path a user gets from
        // 设置 → 显示模式 → 深色. Never fires for a real user or a normal debug run.
        //
        // The preference persists in UserDefaults across launches on the same
        // simulator, so any UI-test launch *without* the flag explicitly resets
        // it — otherwise one dark screenshot would tint every later test.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains(where: { $0.hasPrefix("UITEST_") }) {
            let appearance: AppAppearance =
                arguments.contains("UITEST_FORCE_DARK_APPEARANCE") ? .dark : .system
            UserDefaults.standard.set(appearance.rawValue, forKey: "appearance")
        }
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

#if DEBUG
private enum RecipeUITestSeed {
    static let longRecipe = Recipe(
        id: "ui-test-recipe-long",
        title: "周末慢炖番茄香草鸡腿蔬菜锅",
        cookingTime: 75,
        difficulty: "中等",
        tags: ["周末", "一锅炖", "家庭料理"],
        ingredients: [
            "去骨鸡腿肉 600 克", "番茄 5 个", "洋葱 1 个", "胡萝卜 2 根", "土豆 2 个",
            "西芹 2 根", "红甜椒 1 个", "白芸豆 1 罐", "新鲜罗勒 1 小把", "柠檬 1 个"
        ],
        seasonings: ["橄榄油 1 汤匙", "高汤 500 毫升", "黑胡椒 适量", "盐 适量"],
        steps: [
            "鸡腿肉擦干水分，切成大块并用少许盐和黑胡椒静置 10 分钟，让调味均匀进入肉里。",
            "锅中加热橄榄油，将鸡腿肉分批煎至两面金黄后盛出，避免一次放太多导致出水。",
            "放入洋葱、胡萝卜和西芹炒软，持续翻拌至边缘微微焦糖化。",
            "加入红甜椒和番茄块翻炒至出汁，用木铲刮起锅底的焦香部分。",
            "倒入高汤和鸡腿肉，小火焖煮 20 分钟，让汤汁慢慢收浓。",
            "加入土豆继续焖煮 15 分钟，期间偶尔翻动避免食材粘在锅底。",
            "放入白芸豆后再煮 10 分钟，直到鸡肉和土豆都软嫩入味。",
            "尝味后加入盐、黑胡椒和少量柠檬汁，平衡番茄的酸甜味道。",
            "关火后拌入一半罗勒，盖上锅盖静置 5 分钟让香气融合。",
            "盛盘前撒上剩余罗勒和少量柠檬皮屑，趁热搭配面包或米饭享用。"
        ]
    )
}
#endif

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
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("UITEST_RECIPE_DETAIL_SCREENSHOT") {
                    NavigationStack {
                        RecipeDetailView(recipe: RecipeUITestSeed.longRecipe)
                    }
                } else {
                    NavigationStack {
                        RecipeListView()
                    }
                }
                #else
                NavigationStack {
                    RecipeListView()
                }
                #endif
            }

            Tab("我的", systemImage: "person", value: AppTab.settings) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        .tint(AppTheme.primary)
        #if DEBUG
        .fullScreenCover(
            isPresented: Binding(
                get: { ProcessInfo.processInfo.arguments.contains("UITEST_RECIPE_COOKING_SCREENSHOT") },
                set: { _ in }
            )
        ) {
            RecipeCookingModeView(
                recipe: RecipeUITestSeed.longRecipe,
                session: RecipeCookingSession(servings: 4),
                todayPlan: nil,
                onFinish: {},
                onExit: {}
            )
        }
        #endif
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
            guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_EMPTY_INVENTORY") else { return }
            kitchenStore.clearAllLocalData()
            navigationStore.selectedTab = .inventory
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_INVENTORY_LARGE") else { return }
            kitchenStore.clearAllLocalData()
            let now = Date()
            kitchenStore.importInventory([
                InventoryImportItem(name: "嫩豆腐", quantity: 2, unit: "盒", expiryDate: Calendar.current.date(byAdding: .day, value: 1, to: now)),
                InventoryImportItem(name: "小番茄", quantity: 12, unit: "个", expiryDate: Calendar.current.date(byAdding: .day, value: 2, to: now)),
                InventoryImportItem(name: "西兰花", quantity: 1, unit: "颗", expiryDate: Calendar.current.date(byAdding: .day, value: 4, to: now)),
                InventoryImportItem(name: "三文鱼", quantity: 2, unit: "块", expiryDate: Calendar.current.date(byAdding: .day, value: 5, to: now)),
                InventoryImportItem(name: "鸡腿", quantity: 4, unit: "只", expiryDate: Calendar.current.date(byAdding: .day, value: 6, to: now)),
                InventoryImportItem(name: "上海青", quantity: 2, unit: "把", expiryDate: Calendar.current.date(byAdding: .day, value: 7, to: now)),
                InventoryImportItem(name: "口蘑", quantity: 1, unit: "盒", expiryDate: Calendar.current.date(byAdding: .day, value: 8, to: now)),
                InventoryImportItem(name: "胡萝卜", quantity: 3, unit: "根", expiryDate: Calendar.current.date(byAdding: .day, value: 10, to: now)),
                InventoryImportItem(name: "土豆", quantity: 5, unit: "个", expiryDate: Calendar.current.date(byAdding: .day, value: 12, to: now)),
                InventoryImportItem(name: "苹果", quantity: 6, unit: "个", expiryDate: Calendar.current.date(byAdding: .day, value: 14, to: now)),
                InventoryImportItem(name: "大米", quantity: 1, unit: "袋", expiryDate: nil, isStaple: true),
                InventoryImportItem(name: "鸡蛋", quantity: 8, unit: "个", expiryDate: nil, isStaple: true),
                InventoryImportItem(name: "橄榄油", quantity: 0, unit: "瓶", expiryDate: nil, isStaple: true)
            ])
            if let eggIndex = kitchenStore.inventory.firstIndex(where: { $0.name == "鸡蛋" }) {
                kitchenStore.inventory[eggIndex].lowStockThreshold = 12
            }
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
        #if DEBUG
        .task {
            guard ProcessInfo.processInfo.arguments.contains("UITEST_RECIPE_EMPTY_SCREENSHOT") else { return }
            kitchenStore.clearAllLocalData()
            navigationStore.selectedTab = .recipes
        }
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            guard arguments.contains("UITEST_RECIPE_DETAIL_SCREENSHOT") || arguments.contains("UITEST_RECIPE_COOKING_SCREENSHOT") else { return }
            navigationStore.selectedTab = .recipes
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_RECIPE_LONG") else { return }
            kitchenStore.clearAllLocalData()
            recipeStore.clearLocalData()
            recipeStore.add(RecipeUITestSeed.longRecipe)
            navigationStore.selectedTab = .recipes
        }
        #endif
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
