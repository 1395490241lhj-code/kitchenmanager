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
    /// UI-test-only handle used solely to seed deterministic merge-conflict
    /// fixtures. Never read on a normal launch.
    private let uiTestSyncPersistence: any SyncPersistenceProtocol
    /// True once the conflict fixture's session is present. Drives a zero-size,
    /// accessibility-only marker UI tests wait on instead of sleeping.
    @State private var conflictFixtureSeeded = false
    /// Same purpose for the UI-5B2B-B2A preview-summary fixtures.
    @State private var summaryFixtureSeeded = false
    #endif
    @StateObject private var navigationStore = AppNavigationStore()
    @StateObject private var recommendationStore = HomeRecommendationStore()
    @StateObject private var dayRhythmStore = DayRhythmStore()
    @StateObject private var mealPortionStore = MealPortionStore()
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
        // The whole bundle, never a hand-listed subset: naming persistences one
        // by one is how `preparedComponents` was left out and prepared batches
        // ended up in an isolated in-memory container that dies with the app.
        let kitchenStoreInstance = KitchenStore(persistence: persistence)
        #if DEBUG
        // The generic account fixture resets local data and adds 测试库存 under a
        // fresh UUID on every launch. That is fine for single-launch tests, but
        // it makes a seeded merge plan stale on the next launch — the very thing
        // the cold-relaunch acceptance fixture has to survive. So that fixture
        // owns this step explicitly, and its resume phase does nothing at all.
        switch AccountLifecycleSummaryFixture.restartLaunchMode {
        case .seed:
            kitchenStoreInstance.clearAllLocalData()
            kitchenStoreInstance.inventory = AccountLifecycleSummaryFixture.restartLocalItems
        case .resume:
            break
        case .none:
            if AccountLifecycleFixture.active != nil {
                kitchenStoreInstance.clearAllLocalData()
                kitchenStoreInstance.addInventory(name: "测试库存", quantity: 1, unit: "项", expiryDate: nil)
            }
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
        // R1: the inbound direction of the same boundary — a sync operation
        // that writes `InventoryRecord` through its own `ModelContext` must
        // be able to re-hydrate this store afterwards. Set here and only
        // here, symmetrically with `onInventoryChanged` above; without it
        // every inventory sync operation fails closed rather than running
        // with nowhere to reconcile to.
        guestMergeControllerInstance.kitchenStore = kitchenStoreInstance

        _kitchenStore = StateObject(wrappedValue: kitchenStoreInstance)
        _authStore = StateObject(wrappedValue: authStoreInstance)
        _guestMergeController = StateObject(wrappedValue: guestMergeControllerInstance)
        _accountDeletionController = StateObject(wrappedValue: AccountDeletionController(persistence: persistence.sync))
        #if DEBUG
        _syncSmokeController = StateObject(
            wrappedValue: SyncSmokeController(persistence: persistence.sync)
        )
        // UI-5B2B-B1: the conflict screen is only reachable from a *persisted*
        // session whose status is `.conflict`, so the fixture must write one before
        // the merge flow runs. This is the only place holding a `persistence.sync`
        // handle and it already hosts every other `UITEST_SEED_*` hook, hence
        // reusing it instead of standing up a second fixture composition. The
        // write itself happens in the `.task` below, since it is async.
        uiTestSyncPersistence = persistence.sync
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
        // Same reasoning, same place, for the day rhythm: Home's recommendation
        // slot renders quick-meal assembly on a quick day and ordinary recipe
        // recommendation otherwise, so a suite that did not pin it would depend
        // on whatever the simulator had saved. Written before the first body
        // evaluation, and before `dayRhythmStore` is first read.
        DayRhythmStore.applyUITestDayTypeIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recipeStore)
                .environmentObject(kitchenStore)
                .environmentObject(navigationStore)
                .environmentObject(recommendationStore)
                .environmentObject(dayRhythmStore)
                .environmentObject(mealPortionStore)
                .environmentObject(sharedImportCoordinator)
                .environmentObject(authStore)
                .environmentObject(guestMergeController)
                .environmentObject(accountDeletionController)
                // Phase B3: the staple-restock baseline used to be synced from
                // `KitchenStore.init`'s `inventory` didSet, which made
                // `App.init` the first code in the process to touch
                // `UNUserNotificationCenter` — before the first frame. Same
                // pass, same inputs, just after the first frame instead; the
                // scheduler's own gate keeps it to one run per process even
                // though `.task` can restart.
                .task {
                    PantryRestockNotificationScheduler.syncInitialIfNeeded(
                        for: kitchenStore.inventory
                    )
                }
                #if DEBUG
                .environmentObject(syncSmokeController)
                // UI-5B2B-B1: writes a deterministic `.conflict` session so the
                // merge flow opens on the conflict screen. Local persistence only —
                // no network, no sync coordinator run, no staged mutation — and it
                // returns immediately unless one of the conflict launch arguments
                // is present. Lives here rather than in `ContentView` because the
                // persistence handle belongs to this composition root.
                .task {
                    conflictFixtureSeeded = await AccountLifecycleConflictFixture.seedIfRequested(
                        persistence: uiTestSyncPersistence,
                        userID: AccountLifecycleFixture.owner.user.id
                    )
                }
                // UI-5B2B-B2A: the same single injection point, for the
                // `.previewReady` summary states. `localItems` is the live local
                // inventory, which the fixture folds into a real plan hash so
                // `preparePreview` treats the seeded plan as current instead of
                // regenerating it and discarding the recorded choices.
                .task {
                    summaryFixtureSeeded = await AccountLifecycleSummaryFixture.seedIfRequested(
                        persistence: uiTestSyncPersistence,
                        userID: AccountLifecycleFixture.owner.user.id,
                        localItems: kitchenStore.inventory
                    )
                }
                // Minimal observable "seed finished" markers so UI tests can wait on
                // the actual completion instead of sleeping. Zero-size and
                // accessibility-only, so they change nothing a user can see, and they
                // exist only in DEBUG.
                .overlay(alignment: .topLeading) {
                    if conflictFixtureSeeded {
                        Color.clear
                            .frame(width: 1, height: 1)
                            .allowsHitTesting(false)
                            .accessibilityIdentifier("uitest.conflictFixtureSeeded")
                    }
                }
                // UI-5B2B-B2B cold-relaunch probes. At the app root so they
                // survive every push/pop inside the merge flow — the previous
                // markers lived inside the preview screen and vanished as soon
                // as navigation changed, which is why the test could not find
                // them. Fixed identifiers; all state lives in the value.
                .overlay(alignment: .bottomLeading) {
                    if AccountLifecycleSummaryFixture.restartLaunchMode != .none {
                        RestartUITestProbeView(
                            controller: guestMergeController,
                            kitchenStore: kitchenStore
                        )
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if summaryFixtureSeeded {
                        Color.clear
                            .frame(width: 1, height: 1)
                            .allowsHitTesting(false)
                            .accessibilityIdentifier("uitest.summaryFixtureSeeded")
                    }
                }
                #endif
                .preferredColorScheme((AppAppearance(rawValue: appearanceRawValue) ?? .system).colorScheme)
        }
    }
}

#if DEBUG
private enum RecipeUITestSeed {
    static var isolatesRecipeStore: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return [
            "UITEST_SEED_EMPTY_HOME",
            "UITEST_SEED_RECIPE_COOKING",
            "UITEST_SEED_RECIPE_LONG",
            "UITEST_RECIPE_EMPTY_SCREENSHOT",
            "UITEST_SEED_ACCESSIBILITY_RECOMMENDATION"
        ].contains { arguments.contains($0) }
    }

    static let cookingRecipes: [Recipe] = (1...18).map { index in
        Recipe(
            id: String(format: "ui-test-recipe-cooking-%02d", index),
            title: "UI 测试家常菜 " + String(index),
            cookingTime: 15 + index,
            difficulty: "简单",
            tags: ["UI 测试"],
            ingredients: ["鸡蛋 2 个", "番茄 1 个"],
            steps: ["准备食材。", "下锅翻炒。", "调味后出锅。"]
        )
    } + [
        Recipe(
            id: "ui-test-recipe-list-final",
            title: "UI 测试固定最后一行",
            cookingTime: 30,
            difficulty: "简单",
            tags: ["UI 测试"],
            ingredients: ["豆腐 1 块"],
            steps: ["豆腐切块。", "下锅烧熟。"]
        )
    ]

    static let accessibilityRecommendationOne = Recipe(
        id: "ui-test-accessibility-recommendation-one",
        title: "超长名称的番茄香草鸡腿家庭晚餐蔬菜炖锅",
        cookingTime: 55,
        difficulty: "中等",
        tags: ["家庭晚餐"],
        ingredients: [
            "超长进口有机高山蔬菜组合 1 份",
            "新鲜香草番茄家庭料理配料 2 份",
            "去骨鸡腿肉 4 块"
        ],
        steps: ["准备食材并慢炖至入味。"]
    )

    static let accessibilityRecommendationTwo = Recipe(
        id: "ui-test-accessibility-recommendation-two",
        title: "周末慢炖牛肉番茄根茎蔬菜家庭分享锅",
        cookingTime: 70,
        difficulty: "中等",
        tags: ["周末料理"],
        ingredients: [
            "高山根茎蔬菜家庭组合 1 份",
            "番茄洋葱香草调味配料 2 份",
            "牛腩肉 500 克"
        ],
        steps: ["准备食材并慢炖至软嫩。"]
    )

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
#if DEBUG
    // Read only by the `UITEST_SEED_*` hooks below, which need to write the
    // day's rhythm and portion state through the *live* instances rather than a
    // second store over the same UserDefaults. Compiled out of release.
    @EnvironmentObject private var dayRhythmStore: DayRhythmStore
    @EnvironmentObject private var mealPortionStore: MealPortionStore
#endif
    @Environment(\.scenePhase) private var scenePhase
    @State private var inventoryPath = NavigationPath()

    var body: some View {
        TabView(selection: $navigationStore.selectedTab) {
            Tab("首页", systemImage: "house", value: AppTab.today) {
                NavigationStack {
                    HomeView()
                }
                // Home's add button is a real toolbar item now, and toolbar
                // content resolves its tint from the navigation container rather
                // than from the view the `.toolbar` modifier is attached to — so
                // the `brand` tint has to sit here, exactly as it does for the
                // Recipes tab below. Inside HomeView it would leave the "+" on
                // the container's `primary` blue.
                .tint(AppTheme.brand)
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
                // Recipes is on the cooking-journey path, which AppTheme assigns
                // `brand`. This has to sit on the NavigationStack rather than on
                // the list inside it: toolbar content is hoisted into the
                // navigation bar and resolves its tint from the navigation
                // container, so a tint applied further down never reached the
                // filter and add buttons — they stayed `primary` blue directly
                // above green filter chips and green empty-state CTAs.
                Group {
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
                .tint(AppTheme.brand)
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
        }
        // Deliberately a separate `.task` from the auth restore above rather
        // than a second `await` inside it. The recipe pack is public and needs
        // no session, so serializing it behind session restore only delayed the
        // first request by the whole restore (measured ~265 ms as a guest, and
        // a signed-in user additionally pays a token refresh plus /api/me).
        // Both run concurrently now; neither reads the other's state.
        .task {
            #if DEBUG
            guard !RecipeUITestSeed.isolatesRecipeStore else { return }
            #endif
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
            guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_SPECIAL_PLAN") else { return }
            kitchenStore.clearAllLocalData()
            let calendar = Calendar.current
            // Anchor the event to this week's Saturday (Monday + 5) so the
            // planner's default "current week" view always shows it, and the
            // meal to this week's Monday so Home renders execution mode. Using
            // today + N would drift into the next week depending on run day.
            let todayStart = calendar.startOfDay(for: Date())
            let monday = PlannerProjection.startOfWeek(containing: todayStart, calendar: calendar)
            let eventDate = calendar.date(byAdding: .day, value: 5, to: monday) ?? monday
            let scheduled = calendar.date(byAdding: .hour, value: 18, to: eventDate) ?? eventDate
            // The AI-menu tests need the same event with no menu yet, which is
            // the only state that offers 「AI 帮我设计菜单」 as the empty action.
            let startsWithoutAMenu = ProcessInfo.processInfo.arguments
                .contains("UITEST_SEED_SPECIAL_PLAN_EMPTY_MENU")
            var plan = SpecialPlan(
                title: "朋友聚餐",
                scheduledAt: scheduled,
                peopleCount: 7,
                constraintNotes: ["1 人不吃辣"],
                notes: "测试聚餐",
                dishes: startsWithoutAMenu ? [] : [
                    SpecialPlanDish(recipeID: "sample-mapotofu", recipeName: "麻婆豆腐"),
                    SpecialPlanDish(recipeID: "sample-tomato-eggs", recipeName: "番茄炒鸡蛋")
                ]
            )
            plan.createdAt = Date()
            plan.updatedAt = plan.createdAt
            kitchenStore.addSpecialPlan(plan)
            // A Monday meal makes Home render the plan card (execution mode),
            // which is the entry point the smoke test taps.
            kitchenStore.addPlan(recipe: Recipe.samples[0], servings: 2)
            navigationStore.selectedTab = .today
        }
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
        // UI-test-only seed for the prepared-component usage loop: two ordinary
        // staples plus one cooked batch, which is exactly the combination that
        // makes 牛肉青菜饭 stand up. Pair it with UITEST_FORCE_QUICK_DAY.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_QUICK_MEAL_PREPARED") else { return }
            kitchenStore.clearAllLocalData()
            mealPortionStore.applyUITestResetIfRequested()
            let now = Date()
            kitchenStore.importInventory([
                InventoryImportItem(name: "米饭", quantity: 1, unit: "份", expiryDate: Calendar.current.date(byAdding: .day, value: 3, to: now)),
                InventoryImportItem(name: "上海青", quantity: 1, unit: "份", expiryDate: Calendar.current.date(byAdding: .day, value: 4, to: now))
            ])
            kitchenStore.addPreparedComponent(
                PreparedComponent(
                    name: "卤牛肉", portionsRemaining: 3, state: .cooked, storage: .refrigerated,
                    preparedAt: now,
                    expiryDate: Calendar.current.date(byAdding: .day, value: 3, to: now) ?? now
                )
            )
        }
        // UI-test-only seed for the meal-prep board and the component meal:
        // two staples plus one cooked batch, which is the 红薯 + 卤鸡腿 + 西兰花
        // plate. The second batch has a later date so board ordering is visible.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_COMPONENT_MEAL") else { return }
            kitchenStore.clearAllLocalData()
            mealPortionStore.applyUITestResetIfRequested()
            let now = Date()
            kitchenStore.importInventory([
                InventoryImportItem(name: "红薯", quantity: 2, unit: "份", expiryDate: Calendar.current.date(byAdding: .day, value: 6, to: now)),
                InventoryImportItem(name: "西兰花", quantity: 2, unit: "份", expiryDate: Calendar.current.date(byAdding: .day, value: 5, to: now))
            ])
            kitchenStore.addPreparedComponent(
                PreparedComponent(
                    name: "卤鸡腿", portionsRemaining: 3, state: .cooked, storage: .refrigerated,
                    preparedAt: now,
                    expiryDate: Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
                )
            )
            kitchenStore.addPreparedComponent(
                PreparedComponent(
                    name: "腌鸡肉", portionsRemaining: 2, state: .prepped, storage: .refrigerated,
                    preparedAt: now,
                    expiryDate: Calendar.current.date(byAdding: .day, value: 4, to: now) ?? now
                )
            )
        }
        // Clears everything and stays put. `UITEST_SEED_EMPTY_INVENTORY` also
        // switches to the inventory tab, which is wrong for a Home empty state.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_EMPTY_KITCHEN") else { return }
            kitchenStore.clearAllLocalData()
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
            mealPortionStore.applyUITestResetIfRequested()
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
                Recipe.samples.prefix(1).enumerated().map { offset, recipe in
                    (recipe: recipe, servings: offset + 1)
                }
            )
            navigationStore.selectedTab = .today
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_ACCESSIBILITY_TODAY_PLAN") else { return }
            kitchenStore.clearAllLocalData()
            kitchenStore.addPlan(recipe: Recipe(
                id: "uitest-accessibility-today-plan",
                title: "超长名称的番茄牛腩炖土豆配时令蔬菜家庭晚餐",
                cookingTime: 45,
                difficulty: "简单",
                tags: [],
                ingredients: ["番茄 2 个"],
                steps: ["炖熟。"]
            ), servings: 4)
            navigationStore.selectedTab = .today
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_ACCESSIBILITY_RESTOCK") else { return }
            kitchenStore.clearAllLocalData()
            try? kitchenStore.saveStaple(
                id: nil,
                name: "超市自有品牌低脂高钙纯牛奶家庭装",
                quantity: 0,
                unit: "箱",
                minimumQuantity: 2,
                defaultRestockQuantity: 2,
                autoSuggestRestock: true,
                note: nil,
                category: "乳制品"
            )
            navigationStore.selectedTab = .inventory
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_ACCESSIBILITY_RECOMMENDATION") else { return }
            kitchenStore.clearAllLocalData()
            recipeStore.clearLocalData()
            recipeStore.add(RecipeUITestSeed.accessibilityRecommendationOne)
            recipeStore.add(RecipeUITestSeed.accessibilityRecommendationTwo)
            kitchenStore.importInventory([
                InventoryImportItem(
                    name: "超长进口有机高山蔬菜组合",
                    quantity: 1,
                    unit: "份",
                    expiryDate: Calendar.current.date(byAdding: .day, value: 1, to: Date())
                )
            ])
            navigationStore.selectedTab = .today
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_EMPTY_HOME") else { return }
            kitchenStore.clearAllLocalData()
            mealPortionStore.applyUITestResetIfRequested()
            recipeStore.clearLocalData()
            navigationStore.selectedTab = .today
        }
        // Home V2 seeds.
        //
        // The exact contradiction Home V2 removes: a dinner marked 外食 while a
        // Today Plan from earlier in the day is still sitting there. Home must
        // keep the plan and must not offer a prominent 开始准备 beside 今晚外食.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_HOME_EAT_OUT_WITH_PLAN") else { return }
            kitchenStore.clearAllLocalData()
            mealPortionStore.applyUITestResetIfRequested()
            kitchenStore.addPlans(
                Recipe.samples.prefix(2).enumerated().map { offset, recipe in
                    (recipe: recipe, servings: offset + 1)
                }
            )
            dayRhythmStore.setIntent(.eatOut, for: .dinner)
            navigationStore.selectedTab = .today
        }
        // The approved Home V2 quick-day state, kept as a seed so the screen
        // that was signed off can be re-rendered on demand: a quick day with a
        // prepared batch the assembly can use, one ingredient going off
        // tomorrow, one staple running low, and a portion left from last night.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_HOME_V2_QUICK") else { return }
            kitchenStore.clearAllLocalData()
            mealPortionStore.applyUITestResetIfRequested()
            let now = Date()
            kitchenStore.importInventory([
                InventoryImportItem(name: "挂面", quantity: 1, unit: "袋", expiryDate: nil),
                InventoryImportItem(name: "上海青", quantity: 1, unit: "把", expiryDate: Calendar.current.date(byAdding: .day, value: 1, to: now)),
                InventoryImportItem(name: "鸡蛋", quantity: 2, unit: "个", expiryDate: nil, isStaple: true)
            ])
            if let eggIndex = kitchenStore.inventory.firstIndex(where: { $0.name == "鸡蛋" }) {
                kitchenStore.inventory[eggIndex].lowStockThreshold = 12
            }
            // Three days out: usable by the assembly, not yet time sensitive, so
            // it belongs in the meal and not in 需要处理.
            kitchenStore.addPreparedComponent(
                PreparedComponent(
                    name: "卤牛肉", portionsRemaining: 3, state: .cooked, storage: .refrigerated,
                    preparedAt: now,
                    expiryDate: Calendar.current.date(byAdding: .day, value: 3, to: now) ?? now
                )
            )
            if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now) {
                mealPortionStore.setReservedForNextLunchPortions(1, from: yesterday)
            }
            navigationStore.selectedTab = .today
        }
        // A prepared batch going off, on a day that is *not* a 备餐日. Before
        // Home V2 this was invisible: 需要处理 only ever saw `InventoryItem`.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_HOME_PREPARED_ATTENTION") else { return }
            kitchenStore.clearAllLocalData()
            mealPortionStore.applyUITestResetIfRequested()
            let now = Date()
            kitchenStore.importInventory([
                InventoryImportItem(name: "上海青", quantity: 1, unit: "把", expiryDate: Calendar.current.date(byAdding: .day, value: 1, to: now))
            ])
            kitchenStore.addPreparedComponent(
                PreparedComponent(
                    name: "卤鸡腿", portionsRemaining: 3, state: .cooked, storage: .refrigerated,
                    preparedAt: now,
                    expiryDate: Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
                )
            )
            // Four days out: belongs on the board, never in 需要处理.
            kitchenStore.addPreparedComponent(
                PreparedComponent(
                    name: "腌鸡肉", portionsRemaining: 2, state: .prepped, storage: .refrigerated,
                    preparedAt: now,
                    expiryDate: Calendar.current.date(byAdding: .day, value: 4, to: now) ?? now
                )
            )
            navigationStore.selectedTab = .today
        }
        // Execution mode with more than one dish, so the plan reads as a list
        // rather than as a single row with a count beside it.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_HOME_TWO_PLANS") else { return }
            kitchenStore.clearAllLocalData()
            mealPortionStore.applyUITestResetIfRequested()
            let now = Date()
            kitchenStore.importInventory([
                InventoryImportItem(name: "上海青", quantity: 1, unit: "把", expiryDate: Calendar.current.date(byAdding: .day, value: 1, to: now)),
                InventoryImportItem(name: "鸡蛋", quantity: 2, unit: "个", expiryDate: nil, isStaple: true)
            ])
            if let eggIndex = kitchenStore.inventory.firstIndex(where: { $0.name == "鸡蛋" }) {
                kitchenStore.inventory[eggIndex].lowStockThreshold = 12
            }
            kitchenStore.addPlans(
                Recipe.samples.prefix(2).map { (recipe: $0, servings: 2) }
            )
            navigationStore.selectedTab = .today
        }
        // Both halves of carryover at once, so a test can prove they are shown
        // in two different places: yesterday's portion is today's food, tonight's
        // reservation is tomorrow's.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_HOME_CARRYOVER") else { return }
            kitchenStore.clearAllLocalData()
            mealPortionStore.applyUITestResetIfRequested()
            if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) {
                mealPortionStore.setReservedForNextLunchPortions(1, from: yesterday)
            }
            mealPortionStore.setCurrentMealPortions(2, slot: .dinner)
            mealPortionStore.setReservedForNextLunchPortions(1)
            navigationStore.selectedTab = .today
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_HOME_STOCK_IN") else { return }
            kitchenStore.clearAllLocalData()
            mealPortionStore.applyUITestResetIfRequested()
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
        // Purchased-awaiting-stock-in with no expired inventory, so the
        // stock-in reminder is the one Home surfaces.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_HOME_STOCK_IN_ONLY") else { return }
            kitchenStore.clearAllLocalData()
            mealPortionStore.applyUITestResetIfRequested()
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
            recipeStore.clearLocalData()
            for recipe in RecipeUITestSeed.cookingRecipes.reversed() {
                recipeStore.add(recipe)
            }
            navigationStore.selectedTab = .recipes
        }
        #if DEBUG
        .task {
            guard ProcessInfo.processInfo.arguments.contains("UITEST_RECIPE_EMPTY_SCREENSHOT") else { return }
            kitchenStore.clearAllLocalData()
            recipeStore.clearLocalData()
            navigationStore.selectedTab = .recipes
        }
        // Deliberately absent from `isolatesRecipeStore`, so the real
        // `loadRecipes()` runs and fails against the unreachable test backend —
        // the only way to reach the confirmed sample-fallback state in a UI test.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_RECIPE_LOAD_FAILURE") else { return }
            kitchenStore.clearAllLocalData()
            recipeStore.clearLocalData()
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
