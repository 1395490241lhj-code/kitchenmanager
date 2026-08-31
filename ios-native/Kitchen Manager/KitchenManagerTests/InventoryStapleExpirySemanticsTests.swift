import XCTest
@testable import KitchenManager

/// R2 — the staple / expiry invariant.
///
/// The canonical rule this file pins is deliberately *split*, and each half
/// has to be tested separately because they pull in opposite directions:
///
/// - **Raw storage and the wire stay lossless.** A row may physically carry
///   `kind == .staple` together with a non-nil `expiryDate` — from data written
///   before staples stopped being date-tracked, from a restored backup, or from
///   a remote row this client projected onto `.staple`. Nothing rewrites it.
/// - **Product-semantic readers must treat that date as absent.** A staple is
///   stock-tracked, so no notification, ranking, coverage check, AI priority
///   signal or merge comparison may observe the date.
///
/// `ordinary` and `readyToCook` keep the exact expiry behaviour they always
/// had — `readyToCook` in particular is date-tracked and must never be caught
/// by a rule aimed at staples.
@MainActor
final class InventoryStapleExpirySemanticsTests: XCTestCase {
    private let notificationIDsKey = "native_km_expiry_notification_ids_v1"
    private let notificationsEnabledKey = "expiryNotificationsEnabled"
    private let leadTime3Key = "notifyLeadTime3Day"
    private var savedIDs: Any?
    private var savedEnabled: Any?
    private var savedLead3: Any?

    override func setUp() {
        super.setUp()
        savedIDs = UserDefaults.standard.object(forKey: notificationIDsKey)
        savedEnabled = UserDefaults.standard.object(forKey: notificationsEnabledKey)
        savedLead3 = UserDefaults.standard.object(forKey: leadTime3Key)
        UserDefaults.standard.removeObject(forKey: notificationIDsKey)
    }

    override func tearDown() {
        restore(savedIDs, forKey: notificationIDsKey)
        restore(savedEnabled, forKey: notificationsEnabledKey)
        restore(savedLead3, forKey: leadTime3Key)
        super.tearDown()
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Fixtures

    private func days(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Date())!
    }

    /// The row this whole file is about: legally stored, semantically nonsense.
    private func stapleCarryingARawDate(
        _ name: String = "陈年生抽",
        quantity: Double = 1,
        unit: String = "瓶",
        offsetDays: Int = 2
    ) -> InventoryItem {
        InventoryItem(
            name: name, quantity: quantity, unit: unit,
            expiryDate: days(offsetDays), kind: .staple, createdAt: days(-30)
        )
    }

    private func ordinary(
        _ name: String, quantity: Double = 1, unit: String = "个", offsetDays: Int?
    ) -> InventoryItem {
        InventoryItem(
            name: name, quantity: quantity, unit: unit,
            expiryDate: offsetDays.map(days), kind: .ordinary, createdAt: days(-1)
        )
    }

    // MARK: - Semantic projection

    func testAStapleProjectsNoEffectiveExpiryEvenWhenItStoresOne() {
        let staple = stapleCarryingARawDate()
        XCTAssertNotNil(staple.expiryDate, "the raw column must keep its value — R2 never rewrites the row")
        XCTAssertNil(staple.effectiveExpiryDate, "a staple is stock-tracked, so it has no semantic expiry")
        XCTAssertNil(staple.remainingDays)
        XCTAssertEqual(staple.expiryStatus, .unknown)
        XCTAssertFalse(staple.isExpiringSoon)
        XCTAssertNil(staple.expiryProgress)
        XCTAssertEqual(staple.expiryStatusText, "未设置保质期")
    }

    func testOrdinaryAndReadyToCookKeepTheirExpirySemanticsExactly() {
        let date = days(2)
        for kind in [InventoryItemKind.ordinary, .readyToCook] {
            let item = InventoryItem(
                name: "腌鱼柳", quantity: 1, unit: "份",
                expiryDate: date, kind: kind, createdAt: days(-1)
            )
            XCTAssertEqual(item.effectiveExpiryDate, date, "\(kind) is date-tracked")
            XCTAssertEqual(item.remainingDays, 2, "\(kind) must keep its remaining days")
            XCTAssertTrue(item.isExpiringSoon, "\(kind) must still be able to expire soon")
            XCTAssertNotNil(item.expiryProgress)
        }
    }

    // MARK: - A1. Expiry notifications

    func testAStapleWithARawDateSchedulesNoExpiryNotification() {
        UserDefaults.standard.set(true, forKey: notificationsEnabledKey)
        UserDefaults.standard.set(true, forKey: leadTime3Key)
        // +5 days with a 3-day lead fires in 2 days: comfortably in the future,
        // so a skipped notification means the *rule* skipped it, not the clock.
        let staple = stapleCarryingARawDate(offsetDays: 5)
        let perishable = ordinary("牛奶", offsetDays: 5)

        ExpiryNotificationScheduler.rescheduleAll(
            for: [staple, perishable], leadTimes: [.threeDaysBefore]
        )

        let scheduled = UserDefaults.standard.stringArray(forKey: notificationIDsKey) ?? []
        XCTAssertFalse(
            scheduled.contains { $0.contains(staple.id.uuidString) },
            "一个常备食材不该因为历史遗留的日期收到「快到期了」通知"
        )
        XCTAssertTrue(
            scheduled.contains { $0.contains(perishable.id.uuidString) },
            "普通食材的到期提醒必须完全不受影响"
        )
    }

    // MARK: - A5. FEFO consumption ordering

    func testFEFODoesNotPreferAStapleJustBecauseItCarriesAStaleDate() {
        let planner = InventoryConsumptionPlanner()
        // Same ingredient, two rows: the staple's stale date is *sooner* than the
        // ordinary row's real one. FEFO must not drain the pantry row first.
        //
        // Both rows carry a date so the post-fix ordering is decided by a real
        // comparison rather than by an unstable tie between two nil keys.
        let staple = stapleCarryingARawDate("番茄", quantity: 5, unit: "个", offsetDays: 1)
        let plain = ordinary("番茄", quantity: 5, unit: "个", offsetDays: 9)
        let recipe = Recipe(
            id: UUID().uuidString, title: "菜", cookingTime: nil, difficulty: nil,
            tags: [], ingredients: ["番茄 2个"], steps: ["步骤"]
        )

        let drafts = planner.plan(
            for: [.init(recipe: recipe, servings: 1)],
            inventory: [staple, plain]
        )

        let draft = try? XCTUnwrap(drafts.first)
        XCTAssertEqual(
            draft?.matchedInventoryID, plain.id,
            "常备行的历史日期不得让它在 FEFO 里排到无日期的普通行前面"
        )
    }

    func testFEFOStillOrdersOrdinaryRowsByTheirRealDates() {
        let planner = InventoryConsumptionPlanner()
        let soon = ordinary("番茄", quantity: 5, unit: "个", offsetDays: 1)
        let later = ordinary("番茄", quantity: 5, unit: "个", offsetDays: 9)
        let recipe = Recipe(
            id: UUID().uuidString, title: "菜", cookingTime: nil, difficulty: nil,
            tags: [], ingredients: ["番茄 2个"], steps: ["步骤"]
        )

        let drafts = planner.plan(
            for: [.init(recipe: recipe, servings: 1)],
            inventory: [later, soon]
        )
        XCTAssertEqual(drafts.first?.matchedInventoryID, soon.id, "普通食材之间的先进先出必须保持不变")
    }

    // MARK: - A6. Shopping coverage

    func testAStapleWithAPastRawDateStillCoversARequirement() {
        let generator = ShoppingListGenerator()
        let recipeStore = RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        // Not a seasoning: with `includeSeasonings: false` a seasoning line is
        // dropped before coverage is ever computed, which would prove nothing.
        let staple = stapleCarryingARawDate("番茄", quantity: 10, unit: "个", offsetDays: -30)
        let recipe = Recipe(
            id: UUID().uuidString, title: "菜", cookingTime: nil, difficulty: nil,
            tags: [], ingredients: ["番茄 2个"], steps: ["步骤"]
        )

        let draft = generator.generate(
            source: .recipe(recipe, servings: 1),
            inventory: [staple],
            existingShoppingItems: [],
            recipeStore: recipeStore,
            includeSeasonings: false
        )

        XCTAssertTrue(
            draft.missingItems.isEmpty,
            "橱柜里的盐不该因为一个历史遗留日期被当成过期，从而重复加进购物清单"
        )
        XCTAssertEqual(draft.coveredItems.count, 1)
    }

    func testAnOrdinaryRowThatIsGenuinelyExpiredStillFailsToCover() {
        let generator = ShoppingListGenerator()
        let recipeStore = RecipeStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let rotten = ordinary("番茄", quantity: 5, unit: "个", offsetDays: -3)
        let recipe = Recipe(
            id: UUID().uuidString, title: "菜", cookingTime: nil, difficulty: nil,
            tags: [], ingredients: ["番茄 2个"], steps: ["步骤"]
        )

        let draft = generator.generate(
            source: .recipe(recipe, servings: 1),
            inventory: [rotten],
            existingShoppingItems: [],
            recipeStore: recipeStore,
            includeSeasonings: false
        )
        XCTAssertEqual(draft.missingItems.count, 1, "真正过期的普通食材必须继续算作未覆盖")
    }

    // MARK: - A2. Quick meal ranking

    func testAStapleWithARawDateIsNotTreatedAsExpiringInTheQuickMealPool() {
        let staple = stapleCarryingARawDate("大米", quantity: 1, unit: "袋", offsetDays: 1)
        let candidate = QuickMealCandidate(inventoryItem: staple)
        XCTAssertFalse(
            candidate.isExpiringSoon,
            "常备食材的历史日期不得让它在快手餐/组件餐排序里抢占「快过期」优先级"
        )
    }

    func testAnOrdinaryRowIsStillTreatedAsExpiringInTheQuickMealPool() {
        let perishable = ordinary("菠菜", offsetDays: 1)
        XCTAssertTrue(QuickMealCandidate(inventoryItem: perishable).isExpiringSoon)
    }

    // MARK: - A3 / A4. AI priority signals

    func testAStapleIsNeverSentToTheModelAsAnExpiringIngredient() {
        let staple = stapleCarryingARawDate("生抽", offsetDays: 1)
        let perishable = ordinary("菠菜", offsetDays: 1)

        // Both AI paths express "expiring" as `(remainingDays ?? 999) <= 3`,
        // so pinning the projection pins every one of them at once.
        XCTAssertNil(staple.remainingDays, "AI 优先级信号读的是 remainingDays")
        XCTAssertFalse((staple.remainingDays ?? 999) <= 3)
        XCTAssertTrue((perishable.remainingDays ?? 999) <= 3, "普通食材仍要被识别为临期")
    }

    // MARK: - Merge: the phantom conflict

    private func remote(
        id: UUID, name: String = "生抽", unit: String = "瓶",
        quantity: Double = 1, expiryDate: Date?, kind: InventoryItemKind
    ) -> RemoteInventorySnapshotItem {
        RemoteInventorySnapshotItem(
            id: id, name: name, unit: unit, quantity: quantity,
            expiryDate: expiryDate, kind: kind
        )
    }

    func testAStapleWhoseRemoteRowCarriesADateIsNotAnExpiryConflict() {
        let id = UUID()
        let local = InventoryItem(
            id: id, name: "生抽", quantity: 1, unit: "瓶",
            expiryDate: nil, kind: .staple, createdAt: days(-10)
        )
        let plan = InventoryMergePlanner.makePlan(
            sessionId: UUID(), householdId: UUID(),
            localItems: [local],
            knownRemoteItems: [remote(id: id, expiryDate: days(30), kind: .staple)],
            remoteSnapshotFetchedAt: Date()
        )

        let candidate = plan.candidates.first
        XCTAssertNotEqual(
            candidate?.conflictReason, .expiryMismatch,
            "常备食材没有保质期语义，不该让用户去解决一个本不存在的保质期冲突"
        )
        XCTAssertTrue(
            plan.expiryConflicts.isEmpty,
            "phantom expiry conflict 是 keepLocal 把 expiryDate:null 写回家庭数据的入口"
        )
    }

    func testTwoOrdinaryRowsWithDifferentDatesAreStillAnExpiryConflict() {
        let id = UUID()
        let local = InventoryItem(
            id: id, name: "牛奶", quantity: 1, unit: "盒",
            expiryDate: days(2), kind: .ordinary, createdAt: days(-1)
        )
        let plan = InventoryMergePlanner.makePlan(
            sessionId: UUID(), householdId: UUID(),
            localItems: [local],
            knownRemoteItems: [remote(id: id, name: "牛奶", unit: "盒", expiryDate: days(9), kind: .ordinary)],
            remoteSnapshotFetchedAt: Date()
        )
        XCTAssertEqual(
            plan.candidates.first?.conflictReason, .expiryMismatch,
            "真正的保质期差异必须继续是冲突"
        )
    }

    func testTheSymmetricCaseIsAlsoNotAConflict() {
        // The other direction: a *local* staple carrying a legacy date against
        // a clean remote staple. Normalising only one side would just flip the
        // phantom conflict rather than remove it.
        let id = UUID()
        let local = InventoryItem(
            id: id, name: "生抽", quantity: 1, unit: "瓶",
            expiryDate: days(30), kind: .staple, createdAt: days(-10)
        )
        let plan = InventoryMergePlanner.makePlan(
            sessionId: UUID(), householdId: UUID(),
            localItems: [local],
            knownRemoteItems: [remote(id: id, expiryDate: nil, kind: .staple)],
            remoteSnapshotFetchedAt: Date()
        )
        XCTAssertNotEqual(plan.candidates.first?.conflictReason, .expiryMismatch)
    }

    /// A staple can still reach the conflict UI through a *quantity* mismatch.
    /// When it does, the card must not print 保质期 for a row the rest of the app
    /// insists has no expiry semantics.
    func testAStapleConflictCardNeverShowsAnExpiryDate() {
        let id = UUID()
        let local = InventoryItem(
            id: id, name: "大米", quantity: 5, unit: "袋",
            expiryDate: days(30), kind: .staple, createdAt: days(-10)
        )
        let plan = InventoryMergePlanner.makePlan(
            sessionId: UUID(), householdId: UUID(),
            localItems: [local],
            knownRemoteItems: [
                remote(id: id, name: "大米", unit: "袋", quantity: 9, expiryDate: days(30), kind: .staple)
            ],
            remoteSnapshotFetchedAt: Date()
        )

        let candidate = plan.candidates.first
        XCTAssertEqual(candidate?.conflictReason, .quantityMismatch, "数量冲突本身必须保留")
        XCTAssertNil(candidate?.localExpiryDate, "常备行的冲突卡片不该展示保质期")
        XCTAssertNil(candidate?.remoteExpiryDate)
    }

    func testAnOrdinaryConflictCardStillShowsBothDates() {
        let id = UUID()
        let localDate = days(2)
        let remoteDate = days(2)
        let local = InventoryItem(
            id: id, name: "牛奶", quantity: 1, unit: "盒",
            expiryDate: localDate, kind: .ordinary, createdAt: days(-1)
        )
        let plan = InventoryMergePlanner.makePlan(
            sessionId: UUID(), householdId: UUID(),
            localItems: [local],
            knownRemoteItems: [
                remote(id: id, name: "牛奶", unit: "盒", quantity: 4, expiryDate: remoteDate, kind: .ordinary)
            ],
            remoteSnapshotFetchedAt: Date()
        )
        XCTAssertEqual(plan.candidates.first?.localExpiryDate, localDate)
        XCTAssertEqual(plan.candidates.first?.remoteExpiryDate, remoteDate)
    }

    // MARK: - Plan hashing

    func testAStaplesRawDateDoesNotDestabiliseThePlanHashes() {
        let id = UUID()
        let sessionId = UUID()
        let householdId = UUID()
        func plan(localRaw: Date?, remoteRaw: Date?) -> InventoryMergePlan {
            InventoryMergePlanner.makePlan(
                sessionId: sessionId, householdId: householdId,
                localItems: [
                    InventoryItem(
                        id: id, name: "大米", quantity: 5, unit: "袋",
                        expiryDate: localRaw, kind: .staple, createdAt: days(-10)
                    )
                ],
                knownRemoteItems: [
                    remote(id: id, name: "大米", unit: "袋", quantity: 5, expiryDate: remoteRaw, kind: .staple)
                ],
                remoteSnapshotFetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }

        XCTAssertEqual(
            plan(localRaw: nil, remoteRaw: nil).planHash,
            plan(localRaw: days(30), remoteRaw: days(90)).planHash,
            "常备行的 raw 日期没有语义，不该改变 plan/remote 指纹"
        )
    }

    func testAnOrdinaryRowsDateStillChangesThePlanHash() {
        let id = UUID()
        let sessionId = UUID()
        let householdId = UUID()
        func plan(_ raw: Date) -> InventoryMergePlan {
            InventoryMergePlanner.makePlan(
                sessionId: sessionId, householdId: householdId,
                localItems: [
                    InventoryItem(
                        id: id, name: "牛奶", quantity: 1, unit: "盒",
                        expiryDate: raw, kind: .ordinary, createdAt: days(-1)
                    )
                ]
            )
        }
        XCTAssertNotEqual(plan(days(2)).planHash, plan(days(9)).planHash)
    }

    /// The safety backstop for hashing the semantic date: a remote staple whose
    /// row changed server-side still invalidates the plan, because the version
    /// is folded into the fingerprint independently of any business field.
    func testRemoteDriftOnAStapleIsStillDetectedViaTheVersion() throws {
        let id = UUID()
        let base = RemoteInventorySnapshotItem(
            id: id, name: "大米", unit: "袋", quantity: 5,
            expiryDate: days(30), kind: .staple, remoteVersion: try SyncCursorValue("1")
        )
        let bumped = RemoteInventorySnapshotItem(
            id: id, name: "大米", unit: "袋", quantity: 5,
            expiryDate: days(30), kind: .staple, remoteVersion: try SyncCursorValue("2")
        )
        XCTAssertNotEqual(
            InventoryMergePlanner.remoteSnapshotHash([base]),
            InventoryMergePlanner.remoteSnapshotHash([bumped]),
            "语义化 expiry 之后，远端漂移仍然由 remoteVersion 兜底"
        )
    }

    // MARK: - Raw preservation: the whole reason this is a projection

    /// The core regression for choosing a domain projection over decode-time
    /// normalisation. If the date were nulled at decode, an unrelated local
    /// edit would later ship `expiryDate: null` on the full-snapshot upsert and
    /// destroy a value the server legitimately holds.
    func testHydratingARemoteStapleKeepsItsRawDateAndStillTransmitsItLater() throws {
        let raw = DateComponents(calendar: .current, year: 2026, month: 9, day: 30).date!
        var hydrated = InventoryItem(
            id: UUID(), name: "生抽", quantity: 1, unit: "瓶",
            expiryDate: raw, kind: .staple, createdAt: days(-30)
        )

        XCTAssertEqual(hydrated.expiryDate, raw, "raw 列必须无损保留")
        XCTAssertNil(hydrated.effectiveExpiryDate, "但语义上没有保质期")

        // The user edits something unrelated. The outbound payload is a full
        // snapshot, so this is exactly when a decode-time null would have been
        // written back to the family.
        hydrated.quantity = 2
        let payload = try JSONSerialization.jsonObject(
            with: try InventorySyncAdapter(persistence: FailingSyncPersistence())
                .encodedPayload(for: hydrated)
        ) as? [String: Any]

        XCTAssertEqual(
            payload?["expiryDate"] as? String, "2026-09-30",
            "一次无关的本地编辑不得把远端的保质期清成 null"
        )
        XCTAssertEqual(payload?["isStaple"] as? Bool, true)
    }

    /// The contract-legal `isStaple=true` + `preparationKind=readyToCook`
    /// combination (`SYNC_API_CONTRACT.md` §4.2). Precedence is unchanged —
    /// it still projects to `.staple` — and its stored date still survives.
    func testTheLegalStaplePlusReadyToCookRowKeepsItsRawDate() throws {
        let raw = DateComponents(calendar: .current, year: 2026, month: 9, day: 30).date!
        let item = InventoryItem(
            id: UUID(), name: "调味鸡翅", quantity: 6, unit: "只",
            expiryDate: raw, isStaple: true, kind: nil, createdAt: days(-3)
        )

        XCTAssertEqual(item.kind, .staple, "P3 的 staple > readyToCook > ordinary 优先级未改变")
        XCTAssertEqual(item.expiryDate, raw, "raw 日期仍然保留，未被 decode 或投影抹掉")
        XCTAssertNil(item.effectiveExpiryDate)

        let payload = try JSONSerialization.jsonObject(
            with: try InventorySyncAdapter(persistence: FailingSyncPersistence())
                .encodedPayload(for: item)
        ) as? [String: Any]
        XCTAssertEqual(
            payload?["expiryDate"] as? String, "2026-09-30",
            "合法组合的日期必须原样回传，R2 不得扩大 P3 已记录的 preparationKind collapse"
        )
    }

    // MARK: - Legacy / backup ingestion

    func testALegacyStapleRowKeepsItsRawDateThroughAStoreRoundTrip() throws {
        let raw = days(-3)
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let store = KitchenStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            persistence: bundle
        )
        let legacy = InventoryItem(
            name: "陈年生抽", quantity: 1, unit: "瓶",
            expiryDate: raw, kind: .staple, createdAt: days(-100)
        )
        store.inventory = [legacy]

        let reloaded = try XCTUnwrap(bundle.inventory.loadInventory().first)
        XCTAssertEqual(reloaded.expiryDate, raw, "durable row 不被 silent migration 重写")
        XCTAssertNil(reloaded.effectiveExpiryDate)
        XCTAssertTrue(store.expiringItems.isEmpty)
    }

    func testARestoredBackupMayCarryAStapleDateAndStillIgnoresIt() throws {
        let raw = days(-3)
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let source = KitchenStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            persistence: bundle
        )
        source.inventory = [
            InventoryItem(
                name: "陈年生抽", quantity: 1, unit: "瓶",
                expiryDate: raw, kind: .staple, createdAt: days(-100)
            )
        ]
        let backup = try source.exportBackupData()

        let target = KitchenStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            persistence: KitchenPersistenceFactory.isolatedInMemory()
        )
        try target.restoreBackupData(backup)

        let restored = try XCTUnwrap(target.inventory.first)
        XCTAssertEqual(restored.expiryDate, raw, "备份里的 raw 日期可以存活，R2 不做 silent repair")
        XCTAssertNil(restored.effectiveExpiryDate)
        XCTAssertTrue(target.expiringItems.isEmpty)
    }

    // MARK: - Local reclassification still normalises on write

    func testPromotingAnOrdinaryRowToStapleStillClearsTheStoredDate() {
        let store = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.addInventory(name: "食用油", quantity: 1, unit: "瓶", expiryDate: days(5))
        let id = try? XCTUnwrap(store.inventory.first?.id)
        XCTAssertNotNil(store.inventory.first?.expiryDate)

        store.setInventoryKind(try! XCTUnwrap(id), to: .staple)

        XCTAssertNil(
            store.inventory.first?.expiryDate,
            "普通用户写路径仍然把新写入的 staple 日期归一成 nil —— R2 只改变解释，不放宽写入"
        )
    }

    /// The write-side invariant has two halves that pull in opposite
    /// directions, so each gets its own explicit test rather than riding on
    /// the other. Half one: an actual *promotion* still clears.

    func testSaveStaplePromotingAnOrdinaryRowStillClearsItsDate() throws {
        let store = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.addInventory(name: "食用油", quantity: 1, unit: "瓶", expiryDate: days(5))
        XCTAssertNotNil(store.inventory.first?.expiryDate)

        try store.saveStaple(
            id: store.inventory.first?.id, name: "食用油", quantity: 1, unit: "瓶",
            minimumQuantity: 1, defaultRestockQuantity: nil, autoSuggestRestock: false,
            note: nil, category: nil
        )

        XCTAssertEqual(store.inventory.first?.kind, .staple)
        XCTAssertNil(
            store.inventory.first?.expiryDate,
            "把一个带日期的普通行提升为常备，仍然要丢掉它带着的日期"
        )
    }

    func testImportPromotingAnOrdinaryRowToStapleStillClearsItsDate() {
        let store = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.addInventory(name: "盐", quantity: 1, unit: "包", expiryDate: days(5))
        XCTAssertNotNil(store.inventory.first?.expiryDate)

        store.addInventory(name: "盐", quantity: 1, unit: "包", expiryDate: nil, isStaple: true)

        XCTAssertEqual(store.inventory.first?.kind, .staple)
        XCTAssertNil(store.inventory.first?.expiryDate, "合并时发生的提升同样清掉日期")
    }

    /// Half two: a row that is *already* a staple keeps the opaque value it
    /// carries. Erasing it here would send `expiryDate: null` on the next
    /// full-snapshot upsert and destroy the household's date.

    func testAnUnrelatedStockInIntoAnExistingStaplePreservesItsOpaqueDate() throws {
        let raw = days(30)
        let store = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.inventory = [
            InventoryItem(name: "大米", quantity: 1, unit: "袋", expiryDate: raw, kind: .staple, createdAt: days(-30))
        ]

        store.addInventory(name: "大米", quantity: 2, unit: "袋", expiryDate: nil, isStaple: true)

        let row = try XCTUnwrap(store.inventory.first)
        XCTAssertEqual(row.quantity, 3, "入库本身要正常生效")
        XCTAssertEqual(row.expiryDate, raw, "已经是常备的行，其 opaque 日期不得被入库抹掉")
        XCTAssertNil(row.effectiveExpiryDate)
    }

    func testAnUnrelatedPantryEditOnAnExistingStaplePreservesItsOpaqueDate() throws {
        let raw = days(30)
        let store = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let id = UUID()
        store.inventory = [
            InventoryItem(id: id, name: "大米", quantity: 5, unit: "袋", expiryDate: raw, kind: .staple, createdAt: days(-30))
        ]

        try store.saveStaple(
            id: id, name: "大米", quantity: 9, unit: "袋",
            minimumQuantity: 2, defaultRestockQuantity: nil, autoSuggestRestock: false,
            note: "整袋", category: nil
        )

        let row = try XCTUnwrap(store.inventory.first)
        XCTAssertEqual(row.quantity, 9)
        XCTAssertEqual(row.lowStockThreshold, 2)
        XCTAssertEqual(row.expiryDate, raw, "阈值/数量这类无关编辑不得抹掉 opaque 日期")
        XCTAssertNil(row.effectiveExpiryDate)
    }

    /// Leaving `.staple` is unchanged by this round: the row becomes
    /// date-tracked again and keeps whatever date it holds, seeding one only
    /// when it holds none. Pinned so the writer change above is visibly scoped
    /// to staple-preserving edits, not to classification changes.
    func testLeavingStapleKeepsAnExistingDateAndSeedsOneOtherwise() throws {
        let raw = days(30)
        let store = KitchenStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let carrying = UUID()
        let bare = UUID()
        store.inventory = [
            InventoryItem(id: carrying, name: "大米", quantity: 1, unit: "袋", expiryDate: raw, kind: .staple),
            InventoryItem(id: bare, name: "生抽", quantity: 1, unit: "瓶", expiryDate: nil, kind: .staple)
        ]

        store.setInventoryKind(carrying, to: .ordinary)
        store.setInventoryKind(bare, to: .readyToCook)

        let promoted = try XCTUnwrap(store.inventory.first(where: { $0.id == carrying }))
        XCTAssertEqual(promoted.expiryDate, raw)
        XCTAssertEqual(promoted.effectiveExpiryDate, raw, "回到 date-tracked kind 之后日期重新可见 —— 既有行为，本轮未改")
        XCTAssertNotNil(try XCTUnwrap(store.inventory.first(where: { $0.id == bare })).expiryDate)
    }
}
