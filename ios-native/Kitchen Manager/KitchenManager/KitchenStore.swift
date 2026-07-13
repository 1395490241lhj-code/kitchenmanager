import Foundation
import Combine
import SwiftUI

enum AppTab: Hashable {
    case today, inventory, shopping, recipes, settings
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
}

struct InventoryItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var quantity: Double
    var unit: String
    var expiryDate: Date?
    var isStaple = false
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

    enum CodingKeys: String, CodingKey {
        case id, name, quantity, unit, expiryDate, isStaple, createdAt, updatedAt, lowStockThreshold
        case defaultRestockQuantity, autoSuggestRestock, stapleNote, stapleCategory
        case stapleTrackingMode, stapleAvailabilityStatus
    }

    init(
        id: UUID = UUID(),
        name: String,
        quantity: Double,
        unit: String,
        expiryDate: Date?,
        isStaple: Bool = false,
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
        self.isStaple = isStaple
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
        isStaple = try container.decodeIfPresent(Bool.self, forKey: .isStaple) ?? false
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
        case .soon: return AppTheme.warning
        case .upcoming: return AppTheme.inventoryUpcoming
        case .normal: return AppTheme.success
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
    var isStaple = false
    var category: String?
}

@MainActor
final class KitchenStore: ObservableObject {
    @Published var inventory: [InventoryItem] = [] {
        didSet {
            persistInventoryIfNeeded()
            Self.rescheduleNotificationsIfEnabled(for: inventory)
            PantryRestockNotificationScheduler.sync(for: inventory)
        }
    }
    @Published var plans: [MealPlanItem] = [] { didSet { persistPlansIfNeeded() } }
    @Published var shoppingItems: [KitchenShoppingItem] = [] { didSet { persistShoppingIfNeeded() } }
    @Published var weeklyPlan: WeeklyMealPlan? { didSet { persistWeeklyPlanIfNeeded() } }
    @Published var consumptionRecords: [InventoryConsumptionRecord] = [] { didSet { persistConsumptionIfNeeded() } }
    @Published var inventoryNotice: String?
    @Published var shoppingNotice: String?
    @Published var planNotice: String?
    @Published var consumptionNotice: String?
    @Published var weeklyPlanNotice: String?

    private let inventoryKey = InventoryMigration.legacyInventoryKey
    private let plansKey = TodayPlanMigration.legacyPlansKey
    private let shoppingKey = ShoppingListMigration.legacyShoppingKey
    private let weeklyPlanKey = WeeklyPlanMigration.legacyKey
    private let consumptionRecordsKey = ConsumptionMigration.legacyRecordsKey
    private var isLoading = true
    private var suppressInventoryPersistence = false
    private var suppressShoppingPersistence = false
    private var suppressPlanPersistence = false
    private var suppressConsumptionPersistence = false
    private var suppressWeeklyPlanPersistence = false
    /// Defaults to the real app defaults so every existing call site (`KitchenStore()`)
    /// is unaffected; tests inject an isolated `UserDefaults(suiteName:)` instead.
    private let userDefaults: UserDefaults
    private let inventoryPersistence: InventoryPersistenceProtocol
    private let shoppingListPersistence: ShoppingListPersistenceProtocol
    private let todayPlanPersistence: TodayPlanPersistenceProtocol
    private let consumptionPersistence: ConsumptionPersistenceProtocol
    private let weeklyPlanPersistence: WeeklyPlanPersistenceProtocol

    init(
        userDefaults: UserDefaults = .standard,
        inventoryPersistence: InventoryPersistenceProtocol? = nil,
        shoppingListPersistence: ShoppingListPersistenceProtocol? = nil,
        todayPlanPersistence: TodayPlanPersistenceProtocol? = nil,
        consumptionPersistence: ConsumptionPersistenceProtocol? = nil,
        weeklyPlanPersistence: WeeklyPlanPersistenceProtocol? = nil
    ) {
        let defaultBundle: KitchenPersistenceBundle?
        if inventoryPersistence == nil || shoppingListPersistence == nil || todayPlanPersistence == nil || consumptionPersistence == nil || weeklyPlanPersistence == nil {
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
        isLoading = false
    }

    var availableInventory: [InventoryItem] { inventory.filter(\.isAvailable) }
    var expiringItems: [InventoryItem] {
        inventory
            .filter { $0.isAvailable && $0.isExpiringSoon }
            .sorted { ($0.remainingDays ?? 999) < ($1.remainingDays ?? 999) }
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
        category: String? = nil
    ) {
        var updated = inventory
        Self.mergeOrAppendInventoryItem(
            name: name,
            quantity: quantity,
            unit: unit,
            expiryDate: expiryDate,
            isStaple: isStaple,
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
                isStaple: item.isStaple,
                category: item.category,
                into: &updated
            )
        }
        inventory = updated
        inventoryNotice = validItems.isEmpty ? nil : "已添加 \(validItems.count) 项食材"
        return validItems.count
    }

    private static func mergeOrAppendInventoryItem(
        name: String,
        quantity: Double,
        unit: String,
        expiryDate: Date?,
        isStaple: Bool,
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
        let effectiveExpiryDate = expiryDate ?? (isStaple
            ? nil
            : (suggestedExpiryDate ?? Calendar.current.date(byAdding: .day, value: 7, to: Date())))
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
            inventory[index].isStaple = inventory[index].isStaple || isStaple
            if inventory[index].expiryDate == nil { inventory[index].expiryDate = effectiveExpiryDate }
            #if DEBUG
            print("[InventoryAdd] mergedIntoExistingItemID=\(inventory[index].id) savedItemExpiry=\(logDate(inventory[index].expiryDate))")
            #endif
        } else {
            let newItem = InventoryItem(
                name: cleanName,
                quantity: safeQuantity,
                unit: cleanUnit,
                expiryDate: effectiveExpiryDate,
                isStaple: isStaple,
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
        do {
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
            inventoryNotice = "厨房数据暂时无法清除，请稍后重试。"
            #if DEBUG
            print("[KitchenPersistence] clear failed: \(error)")
            #endif
            return
        }
        suppressInventoryPersistence = true
        inventory = []
        suppressInventoryPersistence = false
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
        suppressInventoryPersistence = true
        inventory = updatedInventory
        suppressInventoryPersistence = false
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
        suppressInventoryPersistence = true
        inventory = updatedInventory
        suppressInventoryPersistence = false
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
            inventory[index].isStaple = true
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
        guard let index = inventory.firstIndex(where: { $0.id == id }) else { return }
        PantryRestockNotificationScheduler.remove(for: id)
        inventory[index].isStaple = false
        inventory[index].lowStockThreshold = nil
        inventory[index].defaultRestockQuantity = nil
        inventory[index].autoSuggestRestock = false
        inventory[index].stapleNote = nil
        inventory[index].stapleCategory = nil
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
            consumptionRecords: consumptionRecords
        ))
    }

    func restoreBackupData(_ data: Data) throws {
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
        } catch {
            if let backupError = error as? KitchenBackupError {
                throw backupError
            }
            throw KitchenBackupError.inventoryPersistenceFailed
        }
        suppressInventoryPersistence = true
        inventory = backup.inventory
        suppressInventoryPersistence = false
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

    func stockInCompletedShopping() {
        let completed = shoppingItems.filter(\.isDone)
        var updated = inventory
        for item in completed {
            Self.mergeOrAppendInventoryItem(
                name: item.name,
                quantity: item.quantity,
                unit: item.unit,
                expiryDate: nil,
                isStaple: false,
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

        suppressInventoryPersistence = true
        inventory = updated
        suppressInventoryPersistence = false
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

    private func persistInventoryIfNeeded() {
        guard !isLoading, !suppressInventoryPersistence else { return }
        do {
            try inventoryPersistence.replaceInventory(with: inventory)
        } catch {
            inventoryNotice = "库存保存失败，请稍后重试。"
            #if DEBUG
            print("[InventoryPersistence] save failed: \(error)")
            #endif
        }
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

    enum CodingKeys: String, CodingKey {
        case format, version, exportedAt, inventory, plans, shoppingItems, weeklyPlan, consumptionRecords
    }

    init(
        inventory: [InventoryItem],
        plans: [MealPlanItem],
        shoppingItems: [KitchenShoppingItem],
        weeklyPlan: WeeklyMealPlan?,
        consumptionRecords: [InventoryConsumptionRecord]
    ) {
        self.inventory = inventory
        self.plans = plans
        self.shoppingItems = shoppingItems
        self.weeklyPlan = weeklyPlan
        self.consumptionRecords = consumptionRecords
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
    }
}

enum KitchenBackupError: LocalizedError {
    case invalidFile
    case inventoryPersistenceFailed
    case shoppingPersistenceFailed
    case todayPlanPersistenceFailed
    case consumptionPersistenceFailed
    case weeklyPlanPersistenceFailed

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
        }
    }
}
