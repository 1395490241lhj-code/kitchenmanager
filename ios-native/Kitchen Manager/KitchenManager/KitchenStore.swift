import Foundation
import Combine
import SwiftUI

enum AppTab: Hashable {
    case today, inventory, shopping, recipes, settings
}

enum InventoryFocus: Equatable {
    case all
    case expired
    case expiringSoon
    case lowStock

    var title: String {
        switch self {
        case .all: "全部食材"
        case .expired: "已过期"
        case .expiringSoon: "即将到期"
        case .lowStock: "库存不足"
        }
    }
}

/// Stable, user-facing Inventory notice text shared by the store and the
/// presentation layer. The String notice contract remains unchanged.
enum InventoryNoticeText {
    private static let importedItemsPrefix = "已添加 "
    private static let importedItemsSuffix = " 项食材"

    static func importedItemsMessage(count: Int) -> String {
        "\(importedItemsPrefix)\(count)\(importedItemsSuffix)"
    }

    static func importedItemsCount(from message: String) -> Int? {
        guard message.hasPrefix(importedItemsPrefix),
              message.hasSuffix(importedItemsSuffix) else { return nil }
        let countText = String(
            message.dropFirst(importedItemsPrefix.count).dropLast(importedItemsSuffix.count)
        )
        guard let count = Int(countText), count > 0 else { return nil }
        return count
    }
}

/// The single navigation destination type for inventory-detail pushes. Every entry
/// point (inventory grid, pantry staples list, home expiry sheet) must push this
/// value — never a bare UUID — so each NavigationStack's `navigationDestination`
/// registration is unambiguous and can't collide with an unrelated UUID-keyed route.
enum InventoryRoute: Hashable {
    case detail(UUID)
}

@MainActor
final class AppNavigationStore: ObservableObject {
    @Published var selectedTab: AppTab = .today
    @Published var inventoryFocus: InventoryFocus = .all
    @Published private(set) var isShoppingStockInRequested = false

    func showInventory(_ focus: InventoryFocus) {
        inventoryFocus = focus
        selectedTab = .inventory
    }

    func showShoppingStockIn() {
        isShoppingStockInRequested = true
        selectedTab = .shopping
    }

    func consumeShoppingStockInRequest() {
        isShoppingStockInRequested = false
    }
}

/// What kind of thing an inventory row is. One stored axis, three mutually
/// exclusive values — deliberately *not* a second boolean beside `isStaple`,
/// which is now a projection of this enum rather than its own stored fact.
///
/// The two behaviours that actually differ per kind are declared here, so no
/// call site re-derives them from a name, a category string or a keyword table:
/// whether the row is date-tracked at all, and whether an AI recipe may treat
/// it as raw material.
enum InventoryItemKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Ordinary groceries. Date-tracked, and free material for a new recipe.
    case ordinary
    /// The pantry shelf: rice, salt, soy sauce. Tracked by stock level, never
    /// by an expiry date, but still perfectly good as a seasoning or support
    /// ingredient in a generated recipe.
    case staple
    /// Already marinated, pre-seasoned, wrapped or otherwise part-made: 腌好的
    /// 冷冻鱼柳, 调味鸡翅, 包好的饺子. Kept, counted and date-tracked exactly like
    /// ordinary inventory, but it is a finished preparation, not raw material,
    /// so a recipe-*creation* prompt must never be handed it.
    case readyToCook

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ordinary: return "普通"
        case .staple: return "常备"
        case .readyToCook: return "预制"
        }
    }

    var caption: String {
        switch self {
        case .ordinary: return "按保质期跟踪，可用于 AI 创作菜谱。"
        case .staple: return "按库存量跟踪，默认不跟踪保质期。可作为调味或辅助食材参与 AI 创作。"
        case .readyToCook: return "已腌制 / 预制 / 即烹，正常跟踪保质期，但不会用于 AI 创作菜谱。"
        }
    }

    /// Staples are stock-tracked, not date-tracked: nothing may invent an
    /// expiry date for one. Ready-to-cook food spoils like anything else and
    /// keeps the ordinary date behaviour.
    var tracksExpiry: Bool { self != .staple }

    /// Whether a recipe-creation request may use this row as an ingredient.
    /// Ready-to-cook food is excluded — it is already a dish.
    var canInspireRecipeCreation: Bool { self != .readyToCook }
}

struct InventoryItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var quantity: Double
    var unit: String
    var expiryDate: Date?
    /// The single stored classification axis. `isStaple` below is its
    /// projection, kept so the sync, merge, restock and pantry-shelf code that
    /// has always spoken in terms of "is this a staple" needs no rewrite.
    var kind: InventoryItemKind = .ordinary
    /// Optional so inventories saved before lifecycle cards existed remain decodable.
    /// New normal inventory batches record this once and never overwrite it on edits.
    var createdAt: Date?
    // Added for inventory-consumption tracking; optional so decoding data saved before
    // this feature existed still succeeds (missing key -> nil, not a decode failure).
    var updatedAt: Date?
    /// When set, a staple item is considered low-stock once quantity drops below this.
    /// Only meaningful when `isStaple` is true — not every ingredient needs a threshold.
    var lowStockThreshold: Double?
    var defaultRestockQuantity: Double?
    var autoSuggestRestock = false
    var stapleNote: String?
    var stapleCategory: String?
    var stapleTrackingMode: StapleTrackingMode = .quantity
    var stapleAvailabilityStatus: StapleAvailabilityStatus = .available

    /// Reads and writes `kind`. Setting it false only demotes an actual staple
    /// back to ordinary — it never silently reclassifies a ready-to-cook row.
    var isStaple: Bool {
        get { kind == .staple }
        set {
            if newValue {
                kind = .staple
            } else if kind == .staple {
                kind = .ordinary
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, quantity, unit, expiryDate, isStaple, kind, createdAt, updatedAt, lowStockThreshold
        case defaultRestockQuantity, autoSuggestRestock, stapleNote, stapleCategory
        case stapleTrackingMode, stapleAvailabilityStatus
    }

    /// `kind` wins when given; `isStaple` remains accepted so the sync,
    /// merge-smoke and test call sites that predate `InventoryItemKind` keep
    /// working unchanged and simply resolve to `.staple` / `.ordinary`.
    init(
        id: UUID = UUID(),
        name: String,
        quantity: Double,
        unit: String,
        expiryDate: Date?,
        isStaple: Bool = false,
        kind: InventoryItemKind? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        lowStockThreshold: Double? = nil,
        defaultRestockQuantity: Double? = nil,
        autoSuggestRestock: Bool = false,
        stapleNote: String? = nil,
        stapleCategory: String? = nil,
        stapleTrackingMode: StapleTrackingMode = .quantity,
        stapleAvailabilityStatus: StapleAvailabilityStatus = .available
    ) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.expiryDate = expiryDate
        self.kind = kind ?? (isStaple ? .staple : .ordinary)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lowStockThreshold = lowStockThreshold
        self.defaultRestockQuantity = defaultRestockQuantity
        self.autoSuggestRestock = autoSuggestRestock
        self.stapleNote = stapleNote
        self.stapleCategory = stapleCategory
        self.stapleTrackingMode = stapleTrackingMode
        self.stapleAvailabilityStatus = stapleAvailabilityStatus
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        quantity = try container.decode(Double.self, forKey: .quantity)
        unit = try container.decode(String.self, forKey: .unit)
        expiryDate = try container.decodeIfPresent(Date.self, forKey: .expiryDate)
        // Payloads written before `kind` existed carry only `isStaple`, so they
        // decode to `.staple` / `.ordinary` — never to `.readyToCook`. Nothing
        // reclassifies old rows from their names.
        let legacyIsStaple = try container.decodeIfPresent(Bool.self, forKey: .isStaple) ?? false
        kind = try container.decodeIfPresent(InventoryItemKind.self, forKey: .kind)
            ?? (legacyIsStaple ? .staple : .ordinary)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        lowStockThreshold = try container.decodeIfPresent(Double.self, forKey: .lowStockThreshold)
        defaultRestockQuantity = try container.decodeIfPresent(Double.self, forKey: .defaultRestockQuantity)
        autoSuggestRestock = try container.decodeIfPresent(Bool.self, forKey: .autoSuggestRestock) ?? false
        stapleNote = try container.decodeIfPresent(String.self, forKey: .stapleNote)
        stapleCategory = try container.decodeIfPresent(String.self, forKey: .stapleCategory)
        stapleTrackingMode = try container.decodeIfPresent(StapleTrackingMode.self, forKey: .stapleTrackingMode) ?? .quantity
        stapleAvailabilityStatus = try container.decodeIfPresent(StapleAvailabilityStatus.self, forKey: .stapleAvailabilityStatus)
            ?? (quantity <= 0 ? .missing : .available)
    }

    /// Written by hand because `isStaple` is computed: the synthesized encoder
    /// would silently drop it, and backups/legacy payloads still read that key.
    /// Both keys are emitted, so a backup taken here still restores correctly
    /// in a build that predates `kind`.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(quantity, forKey: .quantity)
        try container.encode(unit, forKey: .unit)
        try container.encodeIfPresent(expiryDate, forKey: .expiryDate)
        try container.encode(isStaple, forKey: .isStaple)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lowStockThreshold, forKey: .lowStockThreshold)
        try container.encodeIfPresent(defaultRestockQuantity, forKey: .defaultRestockQuantity)
        try container.encode(autoSuggestRestock, forKey: .autoSuggestRestock)
        try container.encodeIfPresent(stapleNote, forKey: .stapleNote)
        try container.encodeIfPresent(stapleCategory, forKey: .stapleCategory)
        try container.encode(stapleTrackingMode, forKey: .stapleTrackingMode)
        try container.encode(stapleAvailabilityStatus, forKey: .stapleAvailabilityStatus)
    }

    var isAvailable: Bool { quantity > 0 }

    var remainingDays: Int? {
        guard let expiryDate else { return nil }
        return Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: Date()),
            to: Calendar.current.startOfDay(for: expiryDate)
        ).day
    }

    /// The single source of truth for expiry status — every page reads this instead of
    /// re-deriving its own remainingDays<=N thresholds.
    var expiryStatus: InventoryExpiryStatus {
        guard let days = remainingDays else { return .unknown }
        if days < 0 { return .expired }
        if days == 0 { return .today }
        if days <= 3 { return .soon }
        if days <= 7 { return .upcoming }
        return .normal
    }

    var isExpiringSoon: Bool {
        switch expiryStatus {
        case .expired, .today, .soon: return true
        case .upcoming, .normal, .unknown: return false
        }
    }

    /// How much of the known storage lifetime has elapsed. Older records without a
    /// creation timestamp intentionally return nil instead of inventing a start date.
    var expiryProgress: Double? {
        guard let expiryDate else { return nil }
        guard let referenceDate = createdAt ?? updatedAt else { return nil }
        guard expiryDate > referenceDate else { return 1 }
        let elapsed = Date().timeIntervalSince(referenceDate)
        let total = expiryDate.timeIntervalSince(referenceDate)
        return min(max(elapsed / total, 0), 1)
    }

    var expiryStatusText: String {
        guard let remainingDays else { return "未设置保质期" }
        if remainingDays < 0 { return "已过期 \(-remainingDays) 天" }
        if remainingDays == 0 { return "今天到期" }
        return "剩余 \(remainingDays) 天"
    }

    /// A stock-to-threshold ratio for staples only. It is intentionally separate
    /// from `expiryProgress`: a full bar here means sufficiently stocked.
    var stapleStockProgress: Double? {
        guard isStaple,
              stapleTrackingMode == .quantity,
              let lowStockThreshold,
              lowStockThreshold > 0 else {
            return nil
        }
        return min(max(quantity / lowStockThreshold, 0), 1)
    }

    var isLowOnStock: Bool {
        isStaple && stapleStatus == .low
    }

    var stapleStatus: StapleStockStatus {
        if stapleTrackingMode == .status {
            switch stapleAvailabilityStatus {
            case .available: return .sufficient
            case .low: return .low
            case .missing: return .outOfStock
            }
        }
        return stapleStockStatus(
            currentQuantity: quantity,
            currentUnit: unit,
            minimumQuantity: lowStockThreshold,
            minimumUnit: unit
        )
    }
}

enum StapleTrackingMode: String, Codable, CaseIterable, Identifiable {
    case status
    case quantity
    var id: String { rawValue }
    var title: String { self == .status ? "状态模式" : "数量模式" }
}

enum StapleAvailabilityStatus: String, Codable, CaseIterable, Identifiable {
    case available
    case low
    case missing
    var id: String { rawValue }
    var title: String {
        switch self { case .available: "有货"; case .low: "快没了"; case .missing: "缺货" }
    }
    var next: Self {
        switch self { case .available: .low; case .low: .missing; case .missing: .available }
    }
}

enum StapleStockStatus: Int, Codable, CaseIterable {
    case outOfStock = 0
    case low = 1
    case unknown = 2
    case sufficient = 3

    var label: String {
        switch self {
        case .outOfStock: return "缺货"
        case .low: return "需要补货"
        case .unknown: return "未设置阈值"
        case .sufficient: return "充足"
        }
    }

    var color: Color {
        switch self {
        case .outOfStock: return .red
        case .low: return AppTheme.warning
        case .unknown: return .secondary
        case .sufficient: return AppTheme.success
        }
    }
}

func stapleStockStatus(
    currentQuantity: Double?,
    currentUnit: String?,
    minimumQuantity: Double?,
    minimumUnit: String?
) -> StapleStockStatus {
    guard let currentQuantity else { return .unknown }
    if currentQuantity <= 0 { return .outOfStock }
    guard let minimumQuantity, minimumQuantity >= 0 else { return .unknown }
    let current: Double
    if let currentUnit, let minimumUnit {
        guard let converted = UnitConverter.convert(currentQuantity, from: currentUnit, to: minimumUnit) else {
            return .unknown
        }
        current = converted
    } else {
        current = currentQuantity
    }
    return current < minimumQuantity ? .low : .sufficient
}

enum InventoryExpiryStatus: String, Hashable {
    case expired
    case today
    case soon
    case upcoming
    case normal
    case unknown

    var label: String {
        switch self {
        case .expired: return "已过期"
        case .today: return "今天到期"
        case .soon: return "即将到期"
        case .upcoming: return "近期到期"
        case .normal: return "正常"
        case .unknown: return "未设置到期日"
        }
    }

    var color: Color {
        switch self {
        case .expired: return AppTheme.inventoryExpired
        case .today: return AppTheme.inventoryToday
        case .soon: return AppTheme.inventoryExpiring
        case .upcoming: return AppTheme.inventoryUpcoming
        case .normal: return AppTheme.inventoryFresh
        case .unknown: return .secondary
        }
    }

    var backgroundColor: Color {
        switch self {
        case .expired: return AppTheme.inventoryExpiredBackground
        case .today: return AppTheme.inventoryTodayBackground
        case .soon: return AppTheme.inventoryExpiringBackground
        case .upcoming: return AppTheme.inventoryUpcomingBackground
        case .normal: return AppTheme.inventoryFreshBackground
        case .unknown: return AppTheme.inventoryUnknownBackground
        }
    }

    var sortPriority: Int {
        switch self {
        case .expired: return 0
        case .today: return 1
        case .soon: return 2
        case .upcoming: return 3
        case .normal: return 4
        case .unknown: return 5
        }
    }
}

enum PantryStapleError: LocalizedError {
    case missingName

    var errorDescription: String? { "请填写常备食材名称。" }
}

struct MealPlanItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var recipeID: String
    var recipeName: String
    var date = Date()
    var servings = 1
    var isCooked = false
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct KitchenShoppingItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var quantity: Double = 1
    var unit: String = "份"
    var source: String = "手动添加"
    var isDone = false
    var remark: String?
}

struct InventoryImportItem: Hashable {
    var name: String
    var quantity: Double
    var unit: String
    var expiryDate: Date?
    var kind: InventoryItemKind = .ordinary
    var category: String?

    init(
        name: String,
        quantity: Double,
        unit: String,
        expiryDate: Date?,
        isStaple: Bool = false,
        kind: InventoryItemKind? = nil,
        category: String? = nil
    ) {
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.expiryDate = expiryDate
        self.kind = kind ?? (isStaple ? .staple : .ordinary)
        self.category = category
    }
}

@MainActor
final class KitchenStore: ObservableObject {
    @Published var inventory: [InventoryItem] = [] {
        didSet {
            // R1b: the *central* edit gate. It has to live here rather than
            // in a View, because a SwiftUI `Binding` writes straight into
            // `inventory[index]` (see `PantryStaples.swift`'s id-resolved
            // binding) and never passes through a `KitchenStore` method, so
            // a `.disabled(isSyncing)` modifier could not prove anything.
            // While a sync consistency window is open, an ordinary local
            // mutation is refused outright: it is not persisted, not staged
            // outbound, and not kept in memory.
            if isInventoryLockedForSync, !isPublishingDurableInventory {
                revertLockedInventoryEdit(to: oldValue)
                return
            }
            persistInventoryIfNeeded(previous: oldValue)
            Self.rescheduleNotificationsIfEnabled(for: inventory)
            // Phase B3: skipped during the startup load for the same reason
            // `persistInventoryIfNeeded()` is — the assignment below in
            // `init` runs through the `@Published` setter, so this observer
            // fires on the pre-first-frame main thread and made `App.init`
            // the first thing in the process to touch
            // `UNUserNotificationCenter`. The startup pass is not dropped:
            // the app root runs it once, after the first frame, via
            // `PantryRestockNotificationScheduler.syncInitialIfNeeded(for:)`.
            if !isLoading {
                PantryRestockNotificationScheduler.sync(for: inventory)
            }
            // Phase 2B-4: a single, generic hook for "ordinary inventory
            // content changed" — deliberately not called during startup load
            // or any of the explicit suppressed-publish paths (consumption,
            // backup restore, shopping stock-in, clear-all), which are a
            // different, out-of-scope kind of bulk change, not a discrete
            // user CRUD edit. KitchenStore itself stays unaware of what (if
            // anything) is wired to this closure — no Auth/Sync import here.
            if !isLoading, !suppressInventoryPersistence {
                onInventoryChanged?(oldValue, inventory)
            }
        }
    }
    /// Phase 2B-4: optional, injected by the app's composition root
    /// (`ContentView.swift`) to let a sync-aware coordinator observe
    /// ordinary inventory edits without `KitchenStore` importing anything
    /// about Auth/Sync itself. Never required — nil is exactly today's
    /// (Phase ≤2B-3) behavior.
    var onInventoryChanged: (([InventoryItem], [InventoryItem]) -> Void)?
    @Published var plans: [MealPlanItem] = [] { didSet { persistPlansIfNeeded() } }
    @Published var shoppingItems: [KitchenShoppingItem] = [] { didSet { persistShoppingIfNeeded() } }
    @Published var weeklyPlan: WeeklyMealPlan? { didSet { persistWeeklyPlanIfNeeded() } }
    @Published var consumptionRecords: [InventoryConsumptionRecord] = [] { didSet { persistConsumptionIfNeeded() } }
    /// Batches made ahead. A separate collection from `inventory` on purpose:
    /// restock, shopping matching and recipe recommendation all treat an
    /// `InventoryItem` as a purchasable raw ingredient, which these are not.
    @Published var preparedComponents: [PreparedComponent] = [] { didSet { persistPreparedComponentsIfNeeded() } }
    @Published var inventoryNotice: String?
    @Published var shoppingNotice: String?
    @Published var planNotice: String?
    @Published var consumptionNotice: String?
    @Published var weeklyPlanNotice: String?
    @Published var preparedComponentNotice: String?

    private let inventoryKey = InventoryMigration.legacyInventoryKey
    private let plansKey = TodayPlanMigration.legacyPlansKey
    private let shoppingKey = ShoppingListMigration.legacyShoppingKey
    private let weeklyPlanKey = WeeklyPlanMigration.legacyKey
    private let consumptionRecordsKey = ConsumptionMigration.legacyRecordsKey
    private var isLoading = true
    /// Suppresses *this one* publish from writing through to persistence and
    /// from staging an outbound mutation. Always set and cleared around a
    /// single synchronous assignment — never held across an `await`.
    private var suppressInventoryPersistence = false
    /// R1b: true for the whole duration of a sync operation that may write
    /// `InventoryRecord` behind this store's back, and deliberately *kept*
    /// true when the closing reconciliation fails — a still-stale in-memory
    /// array must not be editable, or the very next edit reproduces R1.
    /// Unlike `suppressInventoryPersistence`, this one is expected to span
    /// `await`s.
    @Published private(set) var isInventoryLockedForSync = false
    /// Lets a publish of state that is *already durable truth* through the
    /// closed gate — reconciliation, and the reset paths that wrote the
    /// database before publishing. Never set for an ordinary local edit.
    private var isPublishingDurableInventory = false
    /// How many sync operations currently own the window. A plain bool was
    /// wrong: `syncNow` and `confirmMerge` are guarded by *different* mutual-
    /// exclusion flags (`isSyncing` vs `isBusy`), so a merge that returns
    /// early from one of its own guards while a sync is still awaiting would
    /// have closed the sync's window and re-opened editing mid-flight.
    private var inventorySyncWindowDepth = 0
    /// Re-entrancy guard for the synchronous revert that undoes a refused
    /// edit. The revert assignment re-enters `didSet`; this makes that inner
    /// pass a pure no-op instead of a second revert, a second notice, or an
    /// unbounded recursion.
    private var isRevertingLockedInventoryEdit = false
    private var suppressShoppingPersistence = false
    private var suppressPlanPersistence = false
    private var suppressConsumptionPersistence = false
    private var suppressWeeklyPlanPersistence = false
    private var suppressPreparedComponentPersistence = false
    /// Defaults to the real app defaults so every existing call site (`KitchenStore()`)
    /// is unaffected; tests inject an isolated `UserDefaults(suiteName:)` instead.
    private let userDefaults: UserDefaults
    private let inventoryPersistence: InventoryPersistenceProtocol
    private let shoppingListPersistence: ShoppingListPersistenceProtocol
    private let todayPlanPersistence: TodayPlanPersistenceProtocol
    private let consumptionPersistence: ConsumptionPersistenceProtocol
    private let weeklyPlanPersistence: WeeklyPlanPersistenceProtocol
    private let preparedComponentPersistence: PreparedComponentPersistenceProtocol

    init(
        userDefaults: UserDefaults = .standard,
        inventoryPersistence: InventoryPersistenceProtocol? = nil,
        shoppingListPersistence: ShoppingListPersistenceProtocol? = nil,
        todayPlanPersistence: TodayPlanPersistenceProtocol? = nil,
        consumptionPersistence: ConsumptionPersistenceProtocol? = nil,
        weeklyPlanPersistence: WeeklyPlanPersistenceProtocol? = nil,
        preparedComponentPersistence: PreparedComponentPersistenceProtocol? = nil
    ) {
        let defaultBundle: KitchenPersistenceBundle?
        if inventoryPersistence == nil || shoppingListPersistence == nil || todayPlanPersistence == nil || consumptionPersistence == nil || weeklyPlanPersistence == nil || preparedComponentPersistence == nil {
            defaultBundle = KitchenPersistenceFactory.isolatedInMemory()
        } else {
            defaultBundle = nil
        }
        self.userDefaults = userDefaults
        self.inventoryPersistence = inventoryPersistence ?? defaultBundle!.inventory
        self.shoppingListPersistence = shoppingListPersistence ?? defaultBundle!.shoppingList
        self.todayPlanPersistence = todayPlanPersistence ?? defaultBundle!.todayPlan
        self.consumptionPersistence = consumptionPersistence ?? defaultBundle!.consumption
        self.weeklyPlanPersistence = weeklyPlanPersistence ?? defaultBundle!.weeklyPlan
        self.preparedComponentPersistence = preparedComponentPersistence ?? defaultBundle!.preparedComponents
        let defaults = userDefaults
        do {
            inventory = try InventoryMigration.migrateIfNeeded(
                userDefaults: defaults,
                persistence: self.inventoryPersistence
            )
        } catch {
            inventory = (try? InventoryMigration.loadLegacyInventory(from: defaults)) ?? []
            inventoryNotice = error.localizedDescription
            #if DEBUG
            print("[InventoryMigration] failed: \(error)")
            #endif
        }
        do {
            plans = try TodayPlanMigration.migrateIfNeeded(
                userDefaults: defaults,
                persistence: self.todayPlanPersistence
            )
        } catch {
            plans = (try? TodayPlanMigration.loadLegacyPlans(from: defaults)) ?? []
            planNotice = error.localizedDescription
            #if DEBUG
            print("[TodayPlanMigration] failed: \(error)")
            #endif
        }
        do {
            shoppingItems = try ShoppingListMigration.migrateIfNeeded(
                userDefaults: defaults,
                persistence: self.shoppingListPersistence
            )
        } catch {
            shoppingItems = (try? ShoppingListMigration.loadLegacyShoppingItems(from: defaults)) ?? []
            shoppingNotice = error.localizedDescription
            #if DEBUG
            print("[ShoppingListMigration] failed: \(error)")
            #endif
        }
        do {
            weeklyPlan = try WeeklyPlanMigration.migrateIfNeeded(
                userDefaults: defaults,
                persistence: self.weeklyPlanPersistence
            )
        } catch {
            weeklyPlan = try? WeeklyPlanMigration.loadLegacy(from: defaults)
            weeklyPlanNotice = error.localizedDescription
            #if DEBUG
            print("[WeeklyPlanMigration] failed: \(error)")
            #endif
        }
        do {
            consumptionRecords = try ConsumptionMigration.migrateIfNeeded(
                userDefaults: defaults,
                persistence: self.consumptionPersistence
            )
        } catch {
            consumptionRecords = (try? ConsumptionMigration.loadLegacyRecords(from: defaults)) ?? []
            consumptionNotice = error.localizedDescription
            #if DEBUG
            print("[ConsumptionMigration] failed: \(error)")
            #endif
        }
        // Brand-new data type: there is no legacy UserDefaults payload to
        // migrate, so this loads straight from SwiftData with no migration step.
        do {
            preparedComponents = try self.preparedComponentPersistence.loadComponents()
        } catch {
            preparedComponents = []
            preparedComponentNotice = "备餐记录暂时无法读取，原始数据仍保留在设备上。"
            #if DEBUG
            print("[PreparedComponentPersistence] load failed: \(error)")
            #endif
        }
        isLoading = false
    }

    var availableInventory: [InventoryItem] { inventory.filter(\.isAvailable) }
    /// Staples are excluded structurally, not because they happen to have no
    /// date: a pantry item is tracked by stock level, so it must never reach an
    /// expiry or expiring-soon surface even if a legacy row still carries a
    /// date written before staples stopped being date-tracked.
    var expiringItems: [InventoryItem] {
        inventory
            .filter { $0.isAvailable && !$0.isStaple && $0.isExpiringSoon }
            .sorted { ($0.remainingDays ?? 999) < ($1.remainingDays ?? 999) }
    }

    /// The ingredient candidate list every recipe-creation path must start
    /// from — AI generation, AI recommendation and the local ranking that
    /// shares their pool. Ready-to-cook rows are dropped here, one layer
    /// *above* any prompt or request payload, so no service is ever asked to
    /// please-ignore them.
    var recipeCreationInventory: [InventoryItem] {
        availableInventory.filter(\.kind.canInspireRecipeCreation)
    }

    /// The expiring subset of the same pool, for the "use this up first" hint
    /// that travels with a recipe-creation request. Ready-to-cook food still
    /// appears in the ordinary `expiringItems` alerts — it just cannot steer a
    /// recipe that would be invented around it.
    var recipeCreationExpiringItems: [InventoryItem] {
        expiringItems.filter(\.kind.canInspireRecipeCreation)
    }
    var sortedFreshInventory: [InventoryItem] {
        inventory
            .filter { !$0.isStaple }
            .sorted { lhs, rhs in
                let lhsPriority = lhs.expiryStatus.sortPriority
                let rhsPriority = rhs.expiryStatus.sortPriority
                if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                let lhsExpiry = lhs.expiryDate ?? .distantFuture
                let rhsExpiry = rhs.expiryDate ?? .distantFuture
                if lhsExpiry != rhsExpiry { return lhsExpiry < rhsExpiry }
                return lhs.name.localizedCompare(rhs.name) == .orderedAscending
            }
    }
    var pendingShoppingItems: [KitchenShoppingItem] { shoppingItems.filter { !$0.isDone } }
    var todayPlans: [MealPlanItem] {
        plans.filter { Calendar.current.isDateInToday($0.date) }
    }
    var pendingTodayPlans: [MealPlanItem] { todayPlans.filter { !$0.isCooked } }

    func addInventory(
        name: String,
        quantity: Double,
        unit: String,
        expiryDate: Date?,
        isStaple: Bool = false,
        kind: InventoryItemKind? = nil,
        category: String? = nil
    ) {
        var updated = inventory
        Self.mergeOrAppendInventoryItem(
            name: name,
            quantity: quantity,
            unit: unit,
            expiryDate: expiryDate,
            kind: kind ?? (isStaple ? .staple : .ordinary),
            category: category,
            into: &updated
        )
        inventory = updated
    }

    /// Adds every item in one pass: mutates a local copy and publishes exactly once,
    /// instead of once per item. Every current caller (receipt import, multi-line manual
    /// entry, stock-in-shopping) adds several items back-to-back — publishing `inventory`
    /// once per item fired a burst of rapid, synchronous updates to the List/LazyVGrid of
    /// `NavigationLink(value:)` cards while SwiftUI was still diffing the previous one,
    /// which is what caused a single tap to land on a stale/later push target (reproduced
    /// with a real XCUITest tap, not just code review — see InventoryNavigationUITests).
    @discardableResult
    func importInventory(_ items: [InventoryImportItem]) -> Int {
        let validItems = items.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var updated = inventory
        for item in validItems {
            Self.mergeOrAppendInventoryItem(
                name: item.name,
                quantity: item.quantity,
                unit: item.unit,
                expiryDate: item.expiryDate,
                kind: item.kind,
                category: item.category,
                into: &updated
            )
        }
        inventory = updated
        inventoryNotice = validItems.isEmpty ? nil : InventoryNoticeText.importedItemsMessage(count: validItems.count)
        return validItems.count
    }

    private static func mergeOrAppendInventoryItem(
        name: String,
        quantity: Double,
        unit: String,
        expiryDate: Date?,
        kind: InventoryItemKind,
        category: String?,
        into inventory: inout [InventoryItem]
    ) {
        let cleanName = IngredientNormalizer.normalizedName(name)
        let cleanUnit = IngredientNormalizer.normalizedUnit(unit)
        guard !cleanName.isEmpty else { return }
        let safeQuantity = quantity.isFinite && quantity > 0 ? quantity : 1
        // Explicit dates always win. Staples deliberately remain undated when
        // no date was supplied. Ordinary (non-staple) items always end up
        // with a real date now — InventoryExpirySuggestion itself no longer
        // returns nil for recognized-or-not ordinary ingredients, but this
        // +7-day fallback is kept as defense in depth so a normal add can
        // never silently persist a nil expiryDate.
        let suggestedExpiryDate = InventoryExpirySuggestion.suggestedExpiryDate(
            for: cleanName,
            category: category
        )
        // A staple is never date-tracked, so an explicitly supplied date is
        // dropped too rather than becoming a fake expiry on the pantry shelf.
        let effectiveExpiryDate: Date? = kind.tracksExpiry
            ? (expiryDate ?? suggestedExpiryDate ?? Calendar.current.date(byAdding: .day, value: 7, to: Date()))
            : nil
        #if DEBUG
        logInventoryAdd(
            rawInput: name,
            parsedName: cleanName,
            quantity: safeQuantity,
            unit: cleanUnit,
            explicitExpiry: expiryDate,
            suggestedExpiry: suggestedExpiryDate,
            effectiveExpiry: effectiveExpiryDate
        )
        #endif
        if let index = inventory.firstIndex(where: {
            IngredientNormalizer.normalizedName($0.name) == cleanName
                && IngredientNormalizer.normalizedUnit($0.unit) == cleanUnit
                && Self.expiryDatesCanMerge($0.expiryDate, effectiveExpiryDate)
        }) {
            inventory[index].quantity += safeQuantity
            // A more specific incoming kind promotes an ordinary row (the old
            // `isStaple || isStaple` rule, generalised); an already-classified
            // row is never silently reclassified by a later import.
            if inventory[index].kind == .ordinary { inventory[index].kind = kind }
            if inventory[index].kind.tracksExpiry {
                if inventory[index].expiryDate == nil { inventory[index].expiryDate = effectiveExpiryDate }
            } else {
                inventory[index].expiryDate = nil
            }
            #if DEBUG
            print("[InventoryAdd] mergedIntoExistingItemID=\(inventory[index].id) savedItemExpiry=\(logDate(inventory[index].expiryDate))")
            #endif
        } else {
            let newItem = InventoryItem(
                name: cleanName,
                quantity: safeQuantity,
                unit: cleanUnit,
                expiryDate: effectiveExpiryDate,
                kind: kind,
                createdAt: Date()
            )
            inventory.append(newItem)
            #if DEBUG
            print("[InventoryAdd] newItemID=\(newItem.id) savedItemExpiry=\(logDate(newItem.expiryDate))")
            #endif
        }
    }

    #if DEBUG
    private static func logDate(_ date: Date?) -> String {
        guard let date else { return "nil" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func logInventoryAdd(
        rawInput: String,
        parsedName: String,
        quantity: Double,
        unit: String,
        explicitExpiry: Date?,
        suggestedExpiry: Date?,
        effectiveExpiry: Date?
    ) {
        print("""
        [InventoryAdd]
        rawInput=\(rawInput)
        parsedName=\(parsedName)
        quantity=\(quantity) unit=\(unit)
        explicitExpiry=\(logDate(explicitExpiry))
        suggestedExpiry=\(logDate(suggestedExpiry))
        effectiveExpiry=\(logDate(effectiveExpiry))
        """)
    }
    #endif

    func clearInventoryNotice() {
        inventoryNotice = nil
    }

    func clearAllLocalData() {
        let defaults = userDefaults
        let previousInventory = inventory
        let previousShoppingItems = shoppingItems
        let previousPlans = plans
        let previousConsumptionRecords = consumptionRecords
        let previousWeeklyPlan = weeklyPlan
        let previousPreparedComponents = preparedComponents
        do {
            try preparedComponentPersistence.deleteAll()
            try weeklyPlanPersistence.deleteAll()
            try consumptionPersistence.deleteAll()
            try todayPlanPersistence.deleteAll()
            try shoppingListPersistence.deleteAll()
            try inventoryPersistence.deleteAll()
        } catch {
            try? inventoryPersistence.replaceInventory(with: previousInventory)
            try? shoppingListPersistence.replaceShoppingItems(with: previousShoppingItems)
            try? todayPlanPersistence.replacePlans(with: previousPlans)
            try? consumptionPersistence.replaceRecords(with: previousConsumptionRecords)
            try? weeklyPlanPersistence.replacePlan(with: previousWeeklyPlan)
            try? preparedComponentPersistence.replaceComponents(with: previousPreparedComponents)
            inventoryNotice = "厨房数据暂时无法清除，请稍后重试。"
            #if DEBUG
            print("[KitchenPersistence] clear failed: \(error)")
            #endif
            return
        }
        publishDurableInventory([])
        suppressPlanPersistence = true
        plans = []
        suppressPlanPersistence = false
        suppressShoppingPersistence = true
        shoppingItems = []
        suppressShoppingPersistence = false
        suppressWeeklyPlanPersistence = true
        weeklyPlan = nil
        suppressWeeklyPlanPersistence = false
        suppressConsumptionPersistence = true
        consumptionRecords = []
        suppressConsumptionPersistence = false
        suppressPreparedComponentPersistence = true
        preparedComponents = []
        suppressPreparedComponentPersistence = false
        [inventoryKey, plansKey, shoppingKey, weeklyPlanKey, consumptionRecordsKey].forEach {
            defaults.removeObject(forKey: $0)
        }
        inventoryNotice = nil
        shoppingNotice = nil
        planNotice = nil
        consumptionNotice = nil
        weeklyPlanNotice = nil
    }

    func addPlan(recipe: Recipe, servings: Int = 1) {
        addPlans([(recipe, servings)])
    }

    /// Applies multi-recipe additions to one local snapshot so week-plan imports
    /// publish and persist only their final, deduplicated result.
    func addPlans(_ additions: [(recipe: Recipe, servings: Int)]) {
        var updated = plans
        let today = Date()
        for addition in additions {
            guard !updated.contains(where: {
                Calendar.current.isDate($0.date, inSameDayAs: today)
                    && $0.recipeID == addition.recipe.id
            }) else { continue }
            updated.append(
                MealPlanItem(
                    recipeID: addition.recipe.id,
                    recipeName: addition.recipe.title,
                    date: today,
                    servings: min(max(addition.servings, 1), 12)
                )
            )
        }
        if updated != plans { plans = updated }
    }

    func markPlanCooked(_ plan: MealPlanItem) {
        setPlanCooked(plan.id, isCooked: true)
    }

    func setPlanCooked(_ id: UUID, isCooked: Bool) {
        guard let index = plans.firstIndex(where: { $0.id == id }),
              plans[index].isCooked != isCooked else { return }
        var updated = plans
        updated[index].isCooked = isCooked
        plans = updated
    }

    func markAllTodayCooked() {
        let ids = Set(pendingTodayPlans.map(\.id))
        guard !ids.isEmpty else { return }
        var updated = plans
        for index in updated.indices where ids.contains(updated[index].id) {
            updated[index].isCooked = true
        }
        plans = updated
    }

    func removePlan(_ plan: MealPlanItem) {
        plans.removeAll { $0.id == plan.id }
    }

    /// A plan already covered by a non-undone consumption record must not be deducted
    /// twice (e.g. re-opening "全部做完" after a partial confirmation).
    func hasConsumedPlan(_ planID: UUID) -> Bool {
        consumptionRecords.contains { !$0.isUndone && $0.planIDs.contains(planID) }
    }

    /// Deducts the selected drafts from inventory, spilling across every matching
    /// batch (earliest-expiring first) rather than just the one row shown in the
    /// confirmation UI — this is what "同名食材有多个批次" actually resolves to, since
    /// a batch here is simply another InventoryItem row sharing the same name.
    @discardableResult
    func applyConsumption(
        _ drafts: [InventoryConsumptionDraft],
        planIDs: [UUID],
        recipeID: String?,
        recipeName: String
    ) -> InventoryConsumptionRecord {
        // R1b: this path writes the database from the in-memory snapshot
        // *before* publishing, so the `didSet` gate cannot protect it — it
        // has to refuse up front or it would replay a stale snapshot over
        // rows a sync just wrote. The caller treats a record that is absent
        // from `consumptionRecords` as "not applied" (see
        // `InventoryConsumptionDraftState.confirm`), which is exactly right.
        guard !refuseBulkInventoryChangeIfLocked() else {
            consumptionNotice = Self.inventoryLockedForSyncNotice
            return InventoryConsumptionRecord(
                id: UUID(), date: Date(), recipeID: recipeID,
                recipeName: recipeName, planIDs: planIDs, items: []
            )
        }
        var recordItems: [InventoryConsumptionRecordItem] = []
        var updatedInventory = inventory

        for draft in drafts where draft.isSelected {
            guard var remaining = draft.consumedQuantity, remaining > 0 else { continue }
            let matchingIndices = updatedInventory.indices
                .filter {
                    updatedInventory[$0].isAvailable
                        && IngredientNormalizer.matchKey(updatedInventory[$0].name) == IngredientNormalizer.matchKey(draft.ingredientName)
                }
                .sorted { (updatedInventory[$0].remainingDays ?? 9999) < (updatedInventory[$1].remainingDays ?? 9999) }

            for index in matchingIndices {
                guard remaining > 0 else { break }
                let item = updatedInventory[index]
                let convertedAvailable = draft.requiredUnit
                    .flatMap { UnitConverter.convert(item.quantity, from: item.unit, to: $0) } ?? item.quantity
                guard convertedAvailable > 0 else { continue }

                let consumeFromThisBatch = min(remaining, convertedAvailable)
                let consumeInItemUnit = draft.requiredUnit
                    .flatMap { UnitConverter.convert(consumeFromThisBatch, from: $0, to: item.unit) }
                    ?? consumeFromThisBatch

                let previous = updatedInventory[index].quantity
                let resulting = max(0, previous - consumeInItemUnit)
                updatedInventory[index].quantity = resulting
                updatedInventory[index].updatedAt = Date()

                recordItems.append(
                    InventoryConsumptionRecordItem(
                        inventoryItemID: updatedInventory[index].id,
                        ingredientName: updatedInventory[index].name,
                        consumedQuantity: previous - resulting,
                        unit: updatedInventory[index].unit,
                        previousQuantity: previous,
                        resultingQuantity: resulting
                    )
                )
                remaining -= consumeFromThisBatch
            }
        }

        let record = InventoryConsumptionRecord(
            id: UUID(),
            date: Date(),
            recipeID: recipeID,
            recipeName: recipeName,
            planIDs: planIDs,
            items: recordItems
        )
        let updatedRecords = [record] + consumptionRecords
        do {
            try inventoryPersistence.replaceInventory(with: updatedInventory)
            do {
                try consumptionPersistence.replaceRecords(with: updatedRecords)
            } catch {
                try? inventoryPersistence.replaceInventory(with: inventory)
                throw error
            }
        } catch {
            consumptionNotice = "消耗记录保存失败，库存未变更。"
            #if DEBUG
            print("[Consumption] apply failed: \(error)")
            #endif
            return record
        }
        publishDurableInventory(updatedInventory)
        suppressConsumptionPersistence = true
        consumptionRecords = updatedRecords
        suppressConsumptionPersistence = false
        return record
    }

    /// Restores inventory quantities from a consumption record. Only the inventory
    /// change is undone — the plan(s) stay marked cooked, since re-deriving which
    /// specific plans should flip back to "not cooked" is ambiguous once other state
    /// may have changed since the record was created.
    func undoConsumption(_ record: InventoryConsumptionRecord) {
        // R1b — same reason as `applyConsumption`.
        guard !refuseBulkInventoryChangeIfLocked() else {
            consumptionNotice = Self.inventoryLockedForSyncNotice
            return
        }
        guard let recordIndex = consumptionRecords.firstIndex(where: { $0.id == record.id }),
              !consumptionRecords[recordIndex].isUndone else { return }
        var updatedInventory = inventory
        for item in record.items {
            guard let index = updatedInventory.firstIndex(where: { $0.id == item.inventoryItemID }) else { continue }
            updatedInventory[index].quantity = item.previousQuantity
            updatedInventory[index].updatedAt = Date()
        }
        var updatedRecords = consumptionRecords
        updatedRecords[recordIndex].isUndone = true
        do {
            try inventoryPersistence.replaceInventory(with: updatedInventory)
            do {
                try consumptionPersistence.replaceRecords(with: updatedRecords)
            } catch {
                try? inventoryPersistence.replaceInventory(with: inventory)
                throw error
            }
        } catch {
            consumptionNotice = "撤销消耗失败，库存未变更。"
            #if DEBUG
            print("[Consumption] undo failed: \(error)")
            #endif
            return
        }
        publishDurableInventory(updatedInventory)
        suppressConsumptionPersistence = true
        consumptionRecords = updatedRecords
        suppressConsumptionPersistence = false
    }

    func deleteConsumptionRecord(_ id: UUID) {
        consumptionRecords.removeAll { $0.id == id }
    }

    func clearConsumptionRecords() {
        consumptionRecords = []
    }

    func addShopping(
        name: String,
        quantity: Double = 1,
        unit: String = "份",
        source: String = "手动添加",
        remark: String? = nil
    ) {
        addShoppingItems([
            KitchenShoppingItem(
                name: name,
                quantity: quantity,
                unit: unit,
                source: source,
                remark: remark
            )
        ])
    }

    /// Merges a complete batch in a local snapshot and publishes once. Recipe, weekly
    /// menu, and staple-restock imports use this to avoid one database write per row.
    func addShoppingItems(_ additions: [KitchenShoppingItem]) {
        var updated = shoppingItems
        for addition in additions {
            Self.mergeOrAppendShoppingItem(addition, into: &updated)
        }
        shoppingItems = updated
    }

    private static func mergeOrAppendShoppingItem(
        _ addition: KitchenShoppingItem,
        into shoppingItems: inout [KitchenShoppingItem]
    ) {
        let name = addition.name
        let quantity = addition.quantity
        let unit = addition.unit
        let source = addition.source
        let remark = addition.remark
        let cleanName = IngredientNormalizer.normalizedName(name)
        var cleanUnit = IngredientNormalizer.normalizedUnit(unit)
        var safeQuantity = quantity.isFinite && quantity > 0 ? quantity : 1
        guard !cleanName.isEmpty else { return }
        if let index = shoppingItems.firstIndex(where: {
            !$0.isDone && IngredientNormalizer.matchKey($0.name) == IngredientNormalizer.matchKey(cleanName)
                && (IngredientNormalizer.normalizedUnit($0.unit) == cleanUnit || UnitConverter.areConvertible($0.unit, cleanUnit))
        }) {
            if shoppingItems[index].unit != cleanUnit,
               let converted = UnitConverter.convert(safeQuantity, from: cleanUnit, to: shoppingItems[index].unit) {
                safeQuantity = converted
                cleanUnit = shoppingItems[index].unit
            }
            shoppingItems[index].quantity += safeQuantity
            if let remark, !remark.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                shoppingItems[index].remark = remark.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            shoppingItems.append(KitchenShoppingItem(
                id: addition.id,
                name: cleanName,
                quantity: safeQuantity,
                unit: cleanUnit,
                source: source,
                isDone: addition.isDone,
                remark: remark?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ))
        }
    }

    var pantryStaples: [InventoryItem] {
        inventory.filter(\.isStaple).sorted {
            if $0.stapleStatus.rawValue != $1.stapleStatus.rawValue {
                return $0.stapleStatus.rawValue < $1.stapleStatus.rawValue
            }
            return $0.name.localizedCompare($1.name) == .orderedAscending
        }
    }

    func saveStaple(
        id: UUID?,
        name: String,
        quantity: Double,
        unit: String,
        minimumQuantity: Double?,
        defaultRestockQuantity: Double?,
        autoSuggestRestock: Bool,
        note: String?,
        category: String?,
        trackingMode: StapleTrackingMode = .quantity,
        availabilityStatus: StapleAvailabilityStatus = .available
    ) throws {
        let cleanName = IngredientNormalizer.normalizedName(name)
        let cleanUnit = IngredientNormalizer.normalizedUnit(unit)
        guard !cleanName.isEmpty else { throw PantryStapleError.missingName }
        let index = id.flatMap { target in inventory.firstIndex(where: { $0.id == target }) }
            ?? inventory.firstIndex(where: {
                IngredientNormalizer.matchKey($0.name) == IngredientNormalizer.matchKey(cleanName)
                    && IngredientNormalizer.normalizedUnit($0.unit) == cleanUnit
            })
        if let index {
            inventory[index].name = cleanName
            inventory[index].quantity = max(0, quantity)
            inventory[index].unit = cleanUnit
            inventory[index].kind = .staple
            // Promoting an existing ordinary row to the pantry shelf drops the
            // date it was carrying. Leaving it behind was the actual reason a
            // staple could still show up in 即将过期 / 已过期.
            inventory[index].expiryDate = nil
            inventory[index].lowStockThreshold = minimumQuantity
            inventory[index].defaultRestockQuantity = defaultRestockQuantity
            inventory[index].autoSuggestRestock = autoSuggestRestock
            inventory[index].stapleNote = note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            inventory[index].stapleCategory = category?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            inventory[index].stapleTrackingMode = trackingMode
            inventory[index].stapleAvailabilityStatus = availabilityStatus
            inventory[index].updatedAt = Date()
        } else {
            inventory.append(InventoryItem(
                name: cleanName,
                quantity: max(0, quantity),
                unit: cleanUnit,
                expiryDate: nil,
                isStaple: true,
                createdAt: Date(),
                updatedAt: Date(),
                lowStockThreshold: minimumQuantity,
                defaultRestockQuantity: defaultRestockQuantity,
                autoSuggestRestock: autoSuggestRestock,
                stapleNote: note,
                stapleCategory: category,
                stapleTrackingMode: trackingMode,
                stapleAvailabilityStatus: availabilityStatus
            ))
        }
    }

    func cycleStapleStatus(_ id: UUID) {
        guard let index = inventory.firstIndex(where: { $0.id == id && $0.isStaple }) else { return }
        inventory[index].stapleAvailabilityStatus = inventory[index].stapleAvailabilityStatus.next
        if inventory[index].stapleAvailabilityStatus == .missing { inventory[index].quantity = 0 }
        if inventory[index].stapleAvailabilityStatus == .available && inventory[index].quantity <= 0 {
            inventory[index].quantity = 1
        }
        inventory[index].updatedAt = Date()
    }

    func adjustStapleQuantity(_ id: UUID, by delta: Double) {
        guard let index = inventory.firstIndex(where: { $0.id == id && $0.isStaple }) else { return }
        inventory[index].quantity = max(0, inventory[index].quantity + delta)
        inventory[index].stapleAvailabilityStatus = inventory[index].quantity <= 0 ? .missing : .available
        inventory[index].updatedAt = Date()
    }

    func cancelStaple(_ id: UUID) {
        setInventoryKind(id, to: .ordinary)
    }

    /// The one place an inventory row changes classification. Every consequence
    /// of the change lives here, so the add sheet, the detail screen and the
    /// pantry shelf cannot each implement a slightly different version of it:
    ///
    /// - leaving `.staple` drops the shelf-only settings and stops its restock
    ///   notification, exactly as `cancelStaple` always did;
    /// - leaving `.staple` also re-seeds an expiry date, because the row is
    ///   date-tracked again and an undated ordinary item is not a state the
    ///   rest of the app expects;
    /// - becoming `.staple` clears the date rather than parking a far-future
    ///   one, so "not tracked" is genuinely absent, not disguised.
    func setInventoryKind(_ id: UUID, to kind: InventoryItemKind) {
        guard let index = inventory.firstIndex(where: { $0.id == id }) else { return }
        let previousKind = inventory[index].kind
        guard previousKind != kind else { return }
        inventory[index].kind = kind

        if previousKind == .staple {
            PantryRestockNotificationScheduler.remove(for: id)
            inventory[index].lowStockThreshold = nil
            inventory[index].defaultRestockQuantity = nil
            inventory[index].autoSuggestRestock = false
            inventory[index].stapleNote = nil
            inventory[index].stapleCategory = nil
        }

        if kind.tracksExpiry {
            if inventory[index].expiryDate == nil {
                inventory[index].expiryDate = InventoryExpirySuggestion.suggestedExpiryDate(
                    for: inventory[index].name
                ) ?? Calendar.current.date(byAdding: .day, value: 7, to: Date())
            }
        } else {
            inventory[index].expiryDate = nil
        }
        inventory[index].updatedAt = Date()
    }

    func deleteInventory(_ id: UUID) {
        PantryRestockNotificationScheduler.remove(for: id)
        inventory.removeAll { $0.id == id }
    }

    func exportBackupData() throws -> Data {
        try JSONEncoder().encode(KitchenBackupPayload(
            inventory: inventory,
            plans: plans,
            shoppingItems: shoppingItems,
            weeklyPlan: weeklyPlan,
            consumptionRecords: consumptionRecords,
            preparedComponents: preparedComponents
        ))
    }

    func restoreBackupData(_ data: Data) throws {
        // R1b — same reason as `applyConsumption`. A restore is a whole-table
        // replacement, so running it against a table a sync is concurrently
        // writing would discard the sync's rows outright.
        guard !refuseBulkInventoryChangeIfLocked() else {
            throw KitchenBackupError.inventoryPersistenceFailed
        }
        let backup: KitchenBackupPayload
        do {
            backup = try JSONDecoder().decode(KitchenBackupPayload.self, from: data)
        } catch {
            throw KitchenBackupError.invalidFile
        }
        let previousInventory = inventory
        let previousShoppingItems = shoppingItems
        let previousPlans = plans
        do {
            try inventoryPersistence.replaceInventory(with: backup.inventory)
            do {
                try shoppingListPersistence.replaceShoppingItems(with: backup.shoppingItems)
            } catch {
                try? inventoryPersistence.replaceInventory(with: previousInventory)
                throw KitchenBackupError.shoppingPersistenceFailed
            }
            do {
                try todayPlanPersistence.replacePlans(with: backup.plans)
            } catch {
                try? inventoryPersistence.replaceInventory(with: previousInventory)
                try? shoppingListPersistence.replaceShoppingItems(with: previousShoppingItems)
                throw KitchenBackupError.todayPlanPersistenceFailed
            }
            do {
                try consumptionPersistence.replaceRecords(with: backup.consumptionRecords)
            } catch {
                try? inventoryPersistence.replaceInventory(with: previousInventory)
                try? shoppingListPersistence.replaceShoppingItems(with: previousShoppingItems)
                try? todayPlanPersistence.replacePlans(with: previousPlans)
                throw KitchenBackupError.consumptionPersistenceFailed
            }
            do {
                try weeklyPlanPersistence.replacePlan(with: backup.weeklyPlan)
            } catch {
                try? inventoryPersistence.replaceInventory(with: previousInventory)
                try? shoppingListPersistence.replaceShoppingItems(with: previousShoppingItems)
                try? todayPlanPersistence.replacePlans(with: previousPlans)
                try? consumptionPersistence.replaceRecords(with: consumptionRecords)
                throw KitchenBackupError.weeklyPlanPersistenceFailed
            }
            do {
                try preparedComponentPersistence.replaceComponents(with: backup.preparedComponents)
            } catch {
                try? inventoryPersistence.replaceInventory(with: previousInventory)
                try? shoppingListPersistence.replaceShoppingItems(with: previousShoppingItems)
                try? todayPlanPersistence.replacePlans(with: previousPlans)
                try? consumptionPersistence.replaceRecords(with: consumptionRecords)
                try? weeklyPlanPersistence.replacePlan(with: weeklyPlan)
                throw KitchenBackupError.preparedComponentPersistenceFailed
            }
        } catch {
            if let backupError = error as? KitchenBackupError {
                throw backupError
            }
            throw KitchenBackupError.inventoryPersistenceFailed
        }
        publishDurableInventory(backup.inventory)
        suppressPlanPersistence = true
        plans = backup.plans
        suppressPlanPersistence = false
        suppressShoppingPersistence = true
        shoppingItems = backup.shoppingItems
        suppressShoppingPersistence = false
        suppressWeeklyPlanPersistence = true
        weeklyPlan = backup.weeklyPlan
        suppressWeeklyPlanPersistence = false
        suppressConsumptionPersistence = true
        consumptionRecords = backup.consumptionRecords
        suppressConsumptionPersistence = false
        suppressPreparedComponentPersistence = true
        preparedComponents = backup.preparedComponents
        suppressPreparedComponentPersistence = false
    }

    func toggleShopping(_ item: KitchenShoppingItem) {
        guard let index = shoppingItems.firstIndex(where: { $0.id == item.id }) else { return }
        shoppingItems[index].isDone.toggle()
    }

    func deleteShopping(_ id: UUID) {
        shoppingItems.removeAll { $0.id == id }
    }

    func clearCompletedShopping() {
        shoppingItems.removeAll { $0.isDone }
    }

    func markAllPendingShoppingPurchased() {
        guard shoppingItems.contains(where: { !$0.isDone }) else { return }
        var updated = shoppingItems
        for index in updated.indices where !updated[index].isDone {
            updated[index].isDone = true
        }
        shoppingItems = updated
    }

    func stockInCompletedShopping() {
        // R1b — same reason as `applyConsumption`.
        guard !refuseBulkInventoryChangeIfLocked() else {
            shoppingNotice = Self.inventoryLockedForSyncNotice
            return
        }
        let completed = shoppingItems.filter(\.isDone)
        var updated = inventory
        for item in completed {
            Self.mergeOrAppendInventoryItem(
                name: item.name,
                quantity: item.quantity,
                unit: item.unit,
                expiryDate: nil,
                kind: .ordinary,
                category: nil,
                into: &updated
            )
        }
        let completedIDs = Set(completed.map(\.id))
        let remainingShoppingItems = shoppingItems.filter { !completedIDs.contains($0.id) }
        let previousInventory = inventory

        do {
            try inventoryPersistence.replaceInventory(with: updated)
            do {
                try shoppingListPersistence.replaceShoppingItems(with: remainingShoppingItems)
            } catch {
                try? inventoryPersistence.replaceInventory(with: previousInventory)
                throw error
            }
        } catch {
            shoppingNotice = "入库未完成，购物清单已保持不变。"
            #if DEBUG
            print("[ShoppingStockIn] persistence failed: \(error)")
            #endif
            return
        }

        publishDurableInventory(updated)
        suppressShoppingPersistence = true
        shoppingItems = remainingShoppingItems
        suppressShoppingPersistence = false
    }

    func saveWeeklyPlan(_ plan: WeeklyMealPlan) {
        weeklyPlan = plan
    }

    func deleteWeeklyPlan() {
        weeklyPlan = nil
    }

    @discardableResult
    func duplicateWeeklyPlanForNextWeek() -> WeeklyMealPlan? {
        guard let weeklyPlan,
              let nextStart = Calendar.current.date(byAdding: .day, value: 7, to: weeklyPlan.startDate) else {
            return nil
        }
        var copy = weeklyPlan
        copy.startDate = nextStart
        copy.createdAt = Date()
        for dayIndex in copy.days.indices {
            for mealIndex in copy.days[dayIndex].meals.indices {
                for recipeIndex in copy.days[dayIndex].meals[mealIndex].recipes.indices {
                    copy.days[dayIndex].meals[mealIndex].recipes[recipeIndex].isSavedToLibrary = false
                }
            }
        }
        self.weeklyPlan = copy
        return copy
    }

    /// The saved weekly plan's dishes that correspond to today's date, if any.
    func todaysWeeklyMeals() -> [WeeklyMealPlanRecipe] {
        guard let weeklyPlan else { return [] }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: weeklyPlan.startDate)
        guard let offset = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: Date())).day,
              let day = weeklyPlan.days.first(where: { $0.dayIndex == offset }) else {
            return []
        }
        return day.meals.flatMap(\.recipes)
    }

    /// R1 defence-in-depth: persist only the rows this publish actually
    /// changed, instead of replaying the whole in-memory array.
    ///
    /// The old `replaceInventory(with: inventory)` deleted every stored row
    /// absent from the snapshot and re-inserted every row present in it, so a
    /// snapshot that had gone stale relative to a sync write did collateral
    /// damage far beyond the row the user touched: it erased remotely
    /// inserted rows and resurrected remotely deleted ones. A row-scoped diff
    /// makes both structurally impossible, whatever the state of the rest of
    /// the array.
    ///
    /// This deliberately changes only the `didSet` path. The explicit
    /// `replaceInventory(with:)` call sites elsewhere in this type
    /// (`restoreBackupData`, the consumption/stock-in bulk writes) mean
    /// "replace the table with exactly this", and keep saying so.
    ///
    /// Same-row staleness is *not* this method's job — an edit to a row that
    /// changed remotely is a genuine conflict, and R1b's edit gate is what
    /// keeps the window in which one could be produced from existing.
    private func persistInventoryIfNeeded(previous: [InventoryItem]) {
        guard !isLoading, !suppressInventoryPersistence else { return }
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var currentIDs = Set<UUID>()
        var upserts: [InventoryItem] = []
        for item in inventory {
            currentIDs.insert(item.id)
            guard previousByID[item.id] != item else { continue }
            upserts.append(item)
        }
        let deletions = previousByID.keys.filter { !currentIDs.contains($0) }
        do {
            // One transaction, so a batch publish can never leave a committed
            // prefix on disk with the remainder only in memory.
            try inventoryPersistence.applyChanges(upserting: upserts, deleting: deletions)
        } catch {
            inventoryNotice = "库存保存失败，请稍后重试。"
            #if DEBUG
            print("[InventoryPersistence] save failed: \(error)")
            #endif
        }
    }

    // MARK: - R1 / R1b: inventory sync consistency boundary

    static let inventoryLockedForSyncNotice = "正在同步库存，请稍后再试。"
    static let inventoryReconciliationFailedNotice = "同步后无法读取本地库存，库存已暂时锁定，请稍后重试同步。"

    /// Opens the consistency window. Must be called *before* the first
    /// durable inventory write an operation can make — for the merge and
    /// rollback paths that is the staging step, which writes `InventoryRecord`
    /// through `SwiftDataSyncPersistence.commitInventoryAndSync` well before
    /// any coordinator run.
    func beginInventorySyncConsistencyWindow() {
        inventorySyncWindowDepth += 1
        isInventoryLockedForSync = true
    }

    /// Closes the window — but only if reconciliation succeeded. A failed
    /// load leaves the lock in place on purpose (see
    /// `isInventoryLockedForSync`); call this again to retry once the cause
    /// is gone. Returns whether the store is now consistent and editable.
    @discardableResult
    func endInventorySyncConsistencyWindow() -> Bool {
        if inventorySyncWindowDepth > 0 { inventorySyncWindowDepth -= 1 }
        let reconciled = reconcileInventoryFromPersistence()
        // An outer operation still owns the window: reconcile (always safe and
        // useful) but leave the gate closed for it.
        guard inventorySyncWindowDepth == 0 else { return reconciled }
        if reconciled {
            isInventoryLockedForSync = false
            if inventoryNotice == Self.inventoryLockedForSyncNotice
                || inventoryNotice == Self.inventoryReconciliationFailedNotice {
                inventoryNotice = nil
            }
        }
        return reconciled
    }

    /// Re-hydrates the in-memory array from durable storage after another
    /// `ModelContext` may have written `InventoryRecord`. Never persists and
    /// never stages an outbound mutation — a reconciliation is not a user
    /// edit, and treating it as one would echo every pulled change straight
    /// back out again. Returns whether the durable read succeeded.
    @discardableResult
    func reconcileInventoryFromPersistence() -> Bool {
        let fresh: [InventoryItem]
        do {
            fresh = try inventoryPersistence.loadInventory()
        } catch {
            inventoryNotice = Self.inventoryReconciliationFailedNotice
            #if DEBUG
            print("[InventoryReconciliation] load failed: \(error)")
            #endif
            return false
        }
        guard fresh != inventory else { return true }
        publishDurableInventory(fresh)
        return true
    }

    /// Publishes an array that is *already* the durable truth: bypasses the
    /// edit gate (which exists to stop ordinary local edits racing a sync),
    /// writes nothing back, and stages nothing outbound. Both flags are
    /// cleared before this returns and nothing here awaits, so no other
    /// main-actor work can interleave with the open window.
    private func publishDurableInventory(_ items: [InventoryItem]) {
        isPublishingDurableInventory = true
        suppressInventoryPersistence = true
        defer {
            suppressInventoryPersistence = false
            isPublishingDurableInventory = false
        }
        inventory = items
    }

    /// R1b: the gate in `didSet` only protects publishes. These bulk paths
    /// write the database *before* publishing, from the in-memory snapshot —
    /// so during an open consistency window they would replay a stale
    /// snapshot over rows a sync had just written, and only then have their
    /// publish refused. They have to be refused up front instead.
    private func refuseBulkInventoryChangeIfLocked() -> Bool {
        guard isInventoryLockedForSync else { return false }
        inventoryNotice = Self.inventoryLockedForSyncNotice
        return true
    }

    /// Undoes a local edit refused by the open consistency window. The
    /// assignment below re-enters `didSet`, where the re-entrancy guard turns
    /// that inner pass into a no-op — so the revert performs no persistence
    /// write, stages nothing outbound, and emits exactly one notice.
    private func revertLockedInventoryEdit(to previous: [InventoryItem]) {
        guard !isRevertingLockedInventoryEdit else { return }
        isRevertingLockedInventoryEdit = true
        defer { isRevertingLockedInventoryEdit = false }
        inventory = previous
        inventoryNotice = Self.inventoryLockedForSyncNotice
    }

    private func persistShoppingIfNeeded() {
        guard !isLoading, !suppressShoppingPersistence else { return }
        do {
            try shoppingListPersistence.replaceShoppingItems(with: shoppingItems)
        } catch {
            shoppingNotice = "购物清单保存失败，请稍后重试。"
            #if DEBUG
            print("[ShoppingListPersistence] save failed: \(error)")
            #endif
        }
    }

    private func persistPlansIfNeeded() {
        guard !isLoading, !suppressPlanPersistence else { return }
        do {
            try todayPlanPersistence.replacePlans(with: plans)
        } catch {
            planNotice = "今日计划保存失败，请稍后重试。"
            #if DEBUG
            print("[TodayPlanPersistence] save failed: \(error)")
            #endif
        }
    }

    private func persistConsumptionIfNeeded() {
        guard !isLoading, !suppressConsumptionPersistence else { return }
        do {
            try consumptionPersistence.replaceRecords(with: consumptionRecords)
        } catch {
            consumptionNotice = "消耗记录保存失败，请稍后重试。"
            #if DEBUG
            print("[ConsumptionPersistence] save failed: \(error)")
            #endif
        }
    }

    // MARK: - Prepared components
    //
    // Deliberately isolated from the inventory lifecycle: none of these touch
    // restock suggestions, the shopping list, or `InventoryConsumptionRecord`.
    // A batch is made, portions are taken from it, and it is gone.

    func addPreparedComponent(_ component: PreparedComponent) {
        guard !component.name.isEmpty else { return }
        preparedComponents.append(component)
    }

    func updatePreparedComponent(_ component: PreparedComponent) {
        guard let index = preparedComponents.firstIndex(where: { $0.id == component.id }),
              !component.name.isEmpty else { return }
        preparedComponents[index] = component
    }

    func removePreparedComponent(id: UUID) {
        preparedComponents.removeAll { $0.id == id }
    }

    /// Eating one portion. The last portion removes the batch rather than
    /// leaving a zero-portion row behind — an empty batch is not a thing that
    /// exists in the kitchen, and inventory's habit of keeping depleted rows is
    /// exactly the behaviour this type is meant to avoid.
    ///
    /// Returns the batch as it was, so a caller can describe what happened.
    @discardableResult
    func consumePreparedPortion(id: UUID) -> PreparedComponent? {
        guard let index = preparedComponents.firstIndex(where: { $0.id == id }) else { return nil }
        let previous = preparedComponents[index]
        if previous.portionsRemaining > 1 {
            preparedComponents[index].portionsRemaining = previous.portionsRemaining - 1
        } else {
            preparedComponents.remove(at: index)
        }
        return previous
    }

    private func persistPreparedComponentsIfNeeded() {
        guard !isLoading, !suppressPreparedComponentPersistence else { return }
        do {
            try preparedComponentPersistence.replaceComponents(with: preparedComponents)
        } catch {
            preparedComponentNotice = "备餐记录保存失败，请稍后重试。"
            #if DEBUG
            print("[PreparedComponentPersistence] save failed: \(error)")
            #endif
        }
    }

    private func persistWeeklyPlanIfNeeded() {
        guard !isLoading, !suppressWeeklyPlanPersistence else { return }
        do {
            try weeklyPlanPersistence.replacePlan(with: weeklyPlan)
        } catch {
            weeklyPlanNotice = "周菜单保存失败，请稍后重试。"
            #if DEBUG
            print("[WeeklyPlanPersistence] save failed: \(error)")
            #endif
        }
    }

    private func saveNonInventoryData() {
        guard !isLoading else { return }
    }

    private static func expiryDatesCanMerge(_ lhs: Date?, _ rhs: Date?) -> Bool {
        guard let lhs, let rhs else { return true }
        return Calendar.current.isDate(lhs, inSameDayAs: rhs)
    }

    /// Reads the same `@AppStorage` keys SettingsView writes and, if the user has
    /// notifications turned on, resyncs every pending expiry notification. Runs on
    /// every inventory change so add/edit/merge/delete all "just work" without needing
    /// KitchenStore to own a duplicate settings store.
    private static func rescheduleNotificationsIfEnabled(for inventory: [InventoryItem]) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "expiryNotificationsEnabled") != nil,
              defaults.bool(forKey: "expiryNotificationsEnabled") else { return }
        var leadTimes: Set<ExpiryNotificationLeadTime> = []
        if defaults.bool(forKey: "notifyLeadTime1Day") { leadTimes.insert(.oneDayBefore) }
        if defaults.bool(forKey: "notifyLeadTime3Day") { leadTimes.insert(.threeDaysBefore) }
        if defaults.bool(forKey: "notifyLeadTimeDayOf") { leadTimes.insert(.dayOf) }
        Task { @MainActor in
            ExpiryNotificationScheduler.rescheduleAll(for: inventory, leadTimes: leadTimes)
        }
    }
}

struct KitchenBackupPayload: Codable {
    var format = "kitchen-manager-native-backup"
    var version = 1
    var exportedAt = Date()
    var inventory: [InventoryItem]
    var plans: [MealPlanItem]
    var shoppingItems: [KitchenShoppingItem]
    var weeklyPlan: WeeklyMealPlan?
    var consumptionRecords: [InventoryConsumptionRecord]
    /// Added in P1-B. Decoded with `decodeIfPresent` like every other field, so
    /// a backup written before prepared components existed restores as empty
    /// rather than failing.
    var preparedComponents: [PreparedComponent]

    enum CodingKeys: String, CodingKey {
        case format, version, exportedAt, inventory, plans, shoppingItems, weeklyPlan, consumptionRecords
        case preparedComponents
    }

    init(
        inventory: [InventoryItem],
        plans: [MealPlanItem],
        shoppingItems: [KitchenShoppingItem],
        weeklyPlan: WeeklyMealPlan?,
        consumptionRecords: [InventoryConsumptionRecord],
        preparedComponents: [PreparedComponent] = []
    ) {
        self.inventory = inventory
        self.plans = plans
        self.shoppingItems = shoppingItems
        self.weeklyPlan = weeklyPlan
        self.consumptionRecords = consumptionRecords
        self.preparedComponents = preparedComponents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decodeIfPresent(String.self, forKey: .format) ?? "kitchen-manager-native-backup"
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        exportedAt = try container.decodeIfPresent(Date.self, forKey: .exportedAt) ?? Date()
        inventory = try container.decodeIfPresent([InventoryItem].self, forKey: .inventory) ?? []
        plans = try container.decodeIfPresent([MealPlanItem].self, forKey: .plans) ?? []
        shoppingItems = try container.decodeIfPresent([KitchenShoppingItem].self, forKey: .shoppingItems) ?? []
        weeklyPlan = try container.decodeIfPresent(WeeklyMealPlan.self, forKey: .weeklyPlan)
        consumptionRecords = try container.decodeIfPresent([InventoryConsumptionRecord].self, forKey: .consumptionRecords) ?? []
        preparedComponents = try container.decodeIfPresent([PreparedComponent].self, forKey: .preparedComponents) ?? []
    }
}

enum KitchenBackupError: LocalizedError {
    case invalidFile
    case inventoryPersistenceFailed
    case shoppingPersistenceFailed
    case todayPlanPersistenceFailed
    case consumptionPersistenceFailed
    case weeklyPlanPersistenceFailed
    case preparedComponentPersistenceFailed

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            return "无法读取这个厨房备份文件。"
        case .inventoryPersistenceFailed:
            return "备份中的库存暂时无法保存，请稍后重试。"
        case .shoppingPersistenceFailed:
            return "备份中的购物清单暂时无法保存，请稍后重试。"
        case .todayPlanPersistenceFailed:
            return "备份中的今日计划暂时无法保存，请稍后重试。"
        case .consumptionPersistenceFailed:
            return "备份中的消耗记录暂时无法保存，请稍后重试。"
        case .weeklyPlanPersistenceFailed:
            return "备份中的周菜单暂时无法保存，请稍后重试。"
        case .preparedComponentPersistenceFailed:
            return "备份中的备餐记录暂时无法保存，请稍后重试。"
        }
    }
}
