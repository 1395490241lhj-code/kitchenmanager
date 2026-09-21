import Foundation
import Combine
import SwiftUI

/// The four top-level destinations, one per user intent: execute today, plan
/// what is next, know what is in the kitchen, manage the account. 买菜 and 菜谱
/// are no longer tabs — they are pushes on the tab that owns their subject
/// (see `InventoryRoute.shopping` and `PlannerRoute.recipeLibrary`).
enum AppTab: Hashable {
    case today, plan, inventory, settings
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

    /// The short form for a filter control, where the surrounding control
    /// already says what is being filtered.
    var shortTitle: String {
        switch self {
        case .all: "全部"
        case .expired: "已过期"
        case .expiringSoon: "临期"
        case .lowStock: "缺货"
        }
    }

    /// Every case, in the order a filter control offers them.
    static let filterOrder: [InventoryFocus] = [.all, .expiringSoon, .expired, .lowStock]
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
    /// 买菜 in the four-destination IA: buying is what refills the inventory
    /// this tab is about, and stock-in already lands here, so the list is a
    /// push on the Inventory stack rather than a tab of its own.
    case shopping
}

@MainActor
final class AppNavigationStore: ObservableObject {
    @Published var selectedTab: AppTab = .today
    @Published var inventoryFocus: InventoryFocus = .all
    @Published private(set) var isShoppingStockInRequested = false
    /// The two tab-root paths that carry a formerly-top-level surface. They
    /// live here rather than in `ContentView`'s `@State` because every deep
    /// link that used to be a bare tab switch now has to seed the host tab's
    /// stack as well as select it.
    @Published var inventoryPath: [InventoryRoute] = []
    @Published var planPath: [PlannerRoute] = []

    func showInventory(_ focus: InventoryFocus) {
        inventoryFocus = focus
        // The filtered list is the destination, so a stack left on an item
        // detail or on 买菜 must not swallow the jump.
        inventoryPath.removeAll()
        selectedTab = .inventory
    }

    /// The inventory list itself, without touching the current filter.
    func showInventoryList() {
        inventoryPath.removeAll()
        selectedTab = .inventory
    }

    func showShopping() {
        inventoryPath = [.shopping]
        selectedTab = .inventory
    }

    func showRecipeLibrary() {
        planPath = [.recipeLibrary]
        selectedTab = .plan
    }

    /// Opens the Plan tab, optionally already standing on the route a contextual
    /// deep link names. The Planner owns the route values; this only carries them.
    func showPlanner(_ path: [PlannerRoute] = []) {
        planPath = path
        selectedTab = .plan
    }

    func showShoppingStockIn() {
        isShoppingStockInRequested = true
        showShopping()
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
    nonisolated var tracksExpiry: Bool { self != .staple }

    /// R2 — the one and only owner of "does this classification have a
    /// *semantic* expiry date". Every product-semantic reader (notifications,
    /// FEFO, quick-meal ranking, AI priority, shopping coverage, merge
    /// comparison) resolves the date through here.
    ///
    /// Two *write*-side sites still spell the same shape out inline — the
    /// add/import merge below and `ReceiptImport`'s draft conversion. They
    /// decide what to store rather than how to read it, and both are pinned by
    /// Node source guards, so they are deliberately left as they are.
    ///
    /// The split this exists to hold: raw storage and the wire stay lossless,
    /// so a row may physically carry `.staple` together with a date — written
    /// before staples stopped being date-tracked, restored from a backup, or
    /// pulled from a remote row this client projects onto `.staple`. R2 never
    /// rewrites such a row; it only stops the date from being *believed*.
    /// `nonisolated` because the merge planner is a pure, nonisolated value
    /// layer and must be able to project a date without hopping to the main
    /// actor — the app target's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
    /// would otherwise isolate this the way it isolated the pure helpers
    /// cleaned up in `e81bd1c`.
    nonisolated func effectiveExpiryDate(raw: Date?) -> Date? { tracksExpiry ? raw : nil }

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
    nonisolated var isStaple: Bool {
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

    /// The date this row *means*, as opposed to the date it stores. Delegates
    /// to the single owner on `InventoryItemKind`; see the note there for why
    /// `expiryDate` itself is deliberately left untouched.
    nonisolated var effectiveExpiryDate: Date? { kind.effectiveExpiryDate(raw: expiryDate) }

    var remainingDays: Int? {
        guard let expiryDate = effectiveExpiryDate else { return nil }
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
        guard let expiryDate = effectiveExpiryDate else { return nil }
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

nonisolated struct MealPlanItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var recipeID: String
    var recipeName: String
    var date = Date()
    /// How many recipe servings this plan is actually preparing — the numerator
    /// a future scaler divides by `Recipe.baseServings`.
    ///
    /// `nil` means nobody stated a target. That case has to be representable:
    /// this field previously defaulted to `1` and carried three different
    /// meanings depending on who wrote it (an unset placeholder from the
    /// one-tap add buttons, a recipe yield the user chose in the AI generator,
    /// and the weekly planner's household headcount). Scaling quantities by a
    /// number that might be any of those would be confidently wrong, so the
    /// ambiguity is removed at the source rather than guessed at downstream.
    ///
    /// It is not a headcount, not `SpecialPlan.peopleCount`, not
    /// `MealPortionPlan` (which tracks portions eaten now vs. kept for later),
    /// and not the recipe's own base yield.
    var plannedServings: Int?
    var isCooked = false

    enum CodingKeys: String, CodingKey {
        case id, recipeID, recipeName, date, plannedServings, isCooked
    }

    init(
        id: UUID = UUID(),
        recipeID: String,
        recipeName: String,
        date: Date = Date(),
        plannedServings: Int? = nil,
        isCooked: Bool = false
    ) {
        self.id = id
        self.recipeID = recipeID
        self.recipeName = recipeName
        self.date = date
        self.plannedServings = Recipe.validatedBaseServings(plannedServings)
        self.isCooked = isCooked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        recipeID = try container.decode(String.self, forKey: .recipeID)
        recipeName = try container.decode(String.self, forKey: .recipeName)
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        // A backup written before this field existed carries only the old
        // `servings`, whose provenance is unknowable: a stored 4 could be a
        // real target or a household headcount. Deliberately dropped rather
        // than migrated — losing a hint that may have been right is better than
        // feeding a headcount into ingredient maths as if it were a target.
        plannedServings = Recipe.validatedBaseServings(
            try container.decodeIfPresent(Int.self, forKey: .plannedServings)
        )
        isCooked = try container.decodeIfPresent(Bool.self, forKey: .isCooked) ?? false
    }
}

extension MealPlanItem {
    /// Normalizes an explicitly chosen Planner day to local noon.
    ///
    /// The Planner asks for a civil day; `date` stores an absolute instant.
    /// Noon sits as far from both midnight boundaries as the day allows, so a
    /// spring-forward or fall-back hour cannot slide the entry into the day
    /// next door.
    ///
    /// This is a normalization strategy, not timezone independence. The stored
    /// value remains an absolute `Date`, and a large enough change in the
    /// device's timezone still changes the civil day it renders as. Civil-date
    /// semantics that survive timezone travel would need a model decision this
    /// phase does not make.
    ///
    /// `byAdding: .hour` rather than `bySettingHour:` because a day whose
    /// midnight does not exist still has to produce a usable instant.
    static func normalizedPlannerDate(for day: Date, calendar: Calendar = .current) -> Date {
        let startOfDay = calendar.startOfDay(for: day)
        return calendar.date(byAdding: .hour, value: 12, to: startOfDay) ?? startOfDay
    }
}

/// Outcome of a canonical ordinary-meal mutation.
///
/// Three cases rather than a `Bool` because a caller has to tell a stale
/// reference apart from a failed write: a Planner edit sheet retries a
/// `.persistenceFailed` from the same input, but a `.notFound` names a plan
/// that is already gone and retrying cannot help.
///
/// `.persistenceFailed` carries a guarantee: nothing was published. `plans`
/// still holds the pre-mutation array, so this case can never be describing a
/// change that is actually visible in memory.
nonisolated enum PlanMutationOutcome<Value> {
    case saved(Value)
    case notFound
    case persistenceFailed

    var value: Value? {
        guard case .saved(let value) = self else { return nil }
        return value
    }

    var didPersist: Bool {
        guard case .saved = self else { return false }
        return true
    }

    var didFailToPersist: Bool {
        guard case .persistenceFailed = self else { return false }
        return true
    }

    var isNotFound: Bool {
        guard case .notFound = self else { return false }
        return true
    }
}

/// A removed plan and the position it held, so an Undo restores the identical
/// value at the same place instead of appending a lookalike.
nonisolated struct PlanRemoval: Equatable {
    let item: MealPlanItem
    let index: Int
}

/// Why a canonical batch was refused before it ever reached persistence.
///
/// Separate from `PlanMutationOutcome.notFound`: these name a structurally
/// invalid *request*, not a stale reference. Each case carries the offending
/// ids so a caller can say which rows it got wrong instead of guessing.
nonisolated enum PlanBatchRejection: Equatable {
    /// Nothing to write. A batch is a deliberate act, so an empty one is a
    /// caller mistake rather than a vacuous success.
    case empty
    /// The same `MealPlanItem.id` appears more than once in one request.
    case duplicateIDsInBatch([UUID])
    /// The request reuses an id that `plans` already holds. Appending it would
    /// collide with `TodayPlanRecord`'s unique `id`, and `replacePlans` would
    /// silently collapse the pair into one row.
    case idsAlreadyPresent([UUID])
}

/// Outcome of a canonical *batch* append.
///
/// Deliberately not `PlanMutationOutcome`: that type's three cases have no room
/// for a refused precondition, and widening it would change a shipped contract
/// three Planner call sites switch over exhaustively.
///
/// `.persistenceFailed` carries the same guarantee as the single-item
/// contract — nothing was published, so `plans` still holds the pre-batch array.
/// `.rejected` carries a stronger one: nothing was even attempted.
nonisolated enum PlanBatchOutcome: Equatable {
    case saved([MealPlanItem])
    case rejected(PlanBatchRejection)
    case persistenceFailed

    var items: [MealPlanItem]? {
        guard case .saved(let items) = self else { return nil }
        return items
    }

    var didPersist: Bool {
        guard case .saved = self else { return false }
        return true
    }

    var didFailToPersist: Bool {
        guard case .persistenceFailed = self else { return false }
        return true
    }

    var rejection: PlanBatchRejection? {
        guard case .rejected(let reason) = self else { return nil }
        return reason
    }
}

/// Why a domain mutation was refused before it reached persistence.
///
/// A structurally invalid *request*, never a stale reference — that is
/// `.notFound`. Each case carries the offending ids where it has them, so a
/// caller can say what it got wrong rather than guessing.
nonisolated enum DomainMutationRejection: Equatable {
    /// Nothing to write. A batch is a deliberate act, so an empty one is a
    /// caller mistake rather than a vacuous success.
    case empty
    /// The same target appears more than once, so the request does not describe
    /// one outcome.
    case duplicateTargets([UUID])
}

/// Outcome of a domain mutation made on a conversation's behalf.
///
/// Four cases rather than reusing `PlanMutationOutcome`: a model-driven request
/// can be structurally wrong — empty, or naming one target twice — in a way a
/// Planner form cannot, and collapsing that into `.notFound` would tell the user
/// their dish disappeared when the request itself was malformed.
///
/// `.rejected` and `.notFound` both guarantee nothing was attempted;
/// `.persistenceFailed` guarantees nothing was published.
nonisolated enum DomainMutationOutcome<Value> {
    case saved(Value)
    /// A target id current state does not hold.
    case notFound
    /// A request refused before it reached the disk.
    case rejected(DomainMutationRejection)
    case persistenceFailed

    var value: Value? {
        guard case .saved(let value) = self else { return nil }
        return value
    }

    var didPersist: Bool {
        guard case .saved = self else { return false }
        return true
    }

    var didFailToPersist: Bool {
        guard case .persistenceFailed = self else { return false }
        return true
    }

    var isNotFound: Bool {
        guard case .notFound = self else { return false }
        return true
    }

    var wasRejected: Bool {
        guard case .rejected = self else { return false }
        return true
    }

    var rejection: DomainMutationRejection? {
        guard case .rejected(let reason) = self else { return nil }
        return reason
    }
}

/// One ordinary meal's target restated: same plan row, different dish.
nonisolated struct PlanRecipeReplacement: Equatable, Sendable {
    let planID: UUID
    let recipeID: String
    let recipeName: String
    let plannedServings: Int?
}

/// Why a replacement batch was refused before it reached persistence. Carries
/// the offending ids so a caller can say which rows it got wrong.
nonisolated enum PlanReplacementRejection: Equatable {
    case empty
    /// The same plan id appears more than once, so the batch does not describe
    /// one outcome.
    case duplicateTargets([UUID])
    /// Ids `plans` does not hold. The resolvable half must not land alone.
    case missingTargets([UUID])
    /// Rows a non-undone consumption record already covers.
    ///
    /// Replacing one would leave that record naming a plan whose dish it never
    /// deducted, and `CookConsumptionStore` reads exactly that pair — plan
    /// present, `hasConsumedPlan` true — as "already satisfied". The user would
    /// be shown the new dish as cookable, confirm it, be told it succeeded, and
    /// have nothing deducted. Releasing or rewriting the record instead is a
    /// product decision this write path does not own, so it refuses.
    case consumedTargets([UUID])
}

nonisolated enum PlanReplacementOutcome: Equatable {
    /// The replaced rows, in request order.
    case saved([MealPlanItem])
    case rejected(PlanReplacementRejection)
    case persistenceFailed
}

/// One Special Plan dish's target restated. The dish keeps its id and place.
nonisolated struct SpecialPlanDishReplacement: Equatable, Sendable {
    let dishID: UUID
    let recipeID: String
    let recipeName: String
}

/// The shopping list either side of a batch addition, which is everything a
/// deterministic Undo needs.
nonisolated struct ShoppingMutationReceipt: Equatable, Sendable {
    let before: [KitchenShoppingItem]
    let after: [KitchenShoppingItem]
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// `nonisolated` for the same reason as `MealPlanItem` and `SpecialPlan`: this is
// a value, and the conversation layer's Undo receipts have to carry it off the
// main actor. No behavior change.
nonisolated struct KitchenShoppingItem: Identifiable, Codable, Hashable {
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
    /// Event-level special plans (multi-dish events). A separate planning source
    /// from `plans`; `PlannerProjection` merges the two for the Planner surface.
    @Published var specialPlans: [SpecialPlan] = [] { didSet { persistSpecialPlansIfNeeded() } }
    @Published var inventoryNotice: String?
    @Published var shoppingNotice: String?
    @Published var planNotice: String?
    @Published var consumptionNotice: String?
    @Published var weeklyPlanNotice: String?
    @Published var preparedComponentNotice: String?
    @Published var specialPlanNotice: String?

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
    private var suppressSpecialPlanPersistence = false
    /// Defaults to the real app defaults so every existing call site (`KitchenStore()`)
    /// is unaffected; tests inject an isolated `UserDefaults(suiteName:)` instead.
    private let userDefaults: UserDefaults
    private let inventoryPersistence: InventoryPersistenceProtocol
    private let shoppingListPersistence: ShoppingListPersistenceProtocol
    private let todayPlanPersistence: TodayPlanPersistenceProtocol
    private let consumptionPersistence: ConsumptionPersistenceProtocol
    private let weeklyPlanPersistence: WeeklyPlanPersistenceProtocol
    private let preparedComponentPersistence: PreparedComponentPersistenceProtocol
    private let specialPlanPersistence: SpecialPlanPersistenceProtocol
    /// The durable copy taken before a restore replaces the kitchen.
    let recoverySnapshot: KitchenRecoverySnapshotStore
    /// How the most recent restore attempt ended. Phase 6 presents it; nothing
    /// in this slice renders it, and it is the only place the difference
    /// between a proven recovery and an uncertain one is recorded.
    @Published private(set) var lastRestoreOutcome: KitchenRestoreOutcome?

    /// The composition-root initializer. `nil` on the designated initializer
    /// below is a *test and preview* convenience — it quietly substitutes an
    /// isolated in-memory container for whatever was not passed, which is
    /// exactly the right behaviour for a `#Preview` and exactly the wrong
    /// behaviour for the app, where a forgotten argument means that module's
    /// data silently stops reaching disk. Taking the whole bundle means the app
    /// never names dependencies one at a time, so it cannot leave one out.
    ///
    /// This is a safer call site, not an enforced one: the designated
    /// initializer below is still reachable from the app target, so the app
    /// composition root is additionally guarded at source level by
    /// `test/ios-native-kitchen-store-composition.test.mjs`.
    convenience init(
        userDefaults: UserDefaults = .standard,
        persistence: KitchenPersistenceBundle,
        recoverySnapshot: KitchenRecoverySnapshotStore? = nil
    ) {
        self.init(
            userDefaults: userDefaults,
            inventoryPersistence: persistence.inventory,
            shoppingListPersistence: persistence.shoppingList,
            todayPlanPersistence: persistence.todayPlan,
            consumptionPersistence: persistence.consumption,
            weeklyPlanPersistence: persistence.weeklyPlan,
            preparedComponentPersistence: persistence.preparedComponents,
            specialPlanPersistence: persistence.specialPlans,
            // Isolated unless a caller supplies the real one, exactly like the
            // persistences above. The app's single production slot lives in
            // Application Support and survives between runs, so defaulting to it
            // here would make every test share — and block — one another.
            // Production wires it explicitly at the composition root.
            recoverySnapshot: recoverySnapshot
        )
    }

    init(
        userDefaults: UserDefaults = .standard,
        inventoryPersistence: InventoryPersistenceProtocol? = nil,
        shoppingListPersistence: ShoppingListPersistenceProtocol? = nil,
        todayPlanPersistence: TodayPlanPersistenceProtocol? = nil,
        consumptionPersistence: ConsumptionPersistenceProtocol? = nil,
        weeklyPlanPersistence: WeeklyPlanPersistenceProtocol? = nil,
        preparedComponentPersistence: PreparedComponentPersistenceProtocol? = nil,
        specialPlanPersistence: SpecialPlanPersistenceProtocol? = nil,
        recoverySnapshot: KitchenRecoverySnapshotStore? = nil
    ) {
        let defaultBundle: KitchenPersistenceBundle?
        if inventoryPersistence == nil || shoppingListPersistence == nil || todayPlanPersistence == nil || consumptionPersistence == nil || weeklyPlanPersistence == nil || preparedComponentPersistence == nil
            || specialPlanPersistence == nil {
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
        self.specialPlanPersistence = specialPlanPersistence ?? defaultBundle!.specialPlans
        // Isolated unless a caller supplies the real one, for the same reason
        // the persistences above are: a preview or a test must never write to,
        // or be blocked by, the app's single production recovery slot.
        self.recoverySnapshot = recoverySnapshot ?? .isolated()
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
        do {
            specialPlans = try self.specialPlanPersistence.loadPlans()
        } catch {
            specialPlans = []
            specialPlanNotice = "特殊计划暂时无法读取，原始数据仍保留在设备上。"
            #if DEBUG
            print("[SpecialPlanPersistence] load failed: \(error)")
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
            let previousKind = inventory[index].kind
            if inventory[index].kind == .ordinary { inventory[index].kind = kind }
            if inventory[index].kind.tracksExpiry {
                if inventory[index].expiryDate == nil { inventory[index].expiryDate = effectiveExpiryDate }
            } else if previousKind.tracksExpiry {
                // R2: clear on an actual *promotion* — the row was date-tracked
                // a moment ago and must not keep a date on the pantry shelf.
                // A row that was already a staple keeps whatever it stores: a
                // stock-in must not destroy an opaque value (see
                // `GuestMergeController.carryingForwardOpaqueExpiry`), and the
                // projection already hides it from every product reader.
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
        let previousSpecialPlans = specialPlans
        do {
            try specialPlanPersistence.deleteAll()
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
            try? specialPlanPersistence.replacePlans(with: previousSpecialPlans)
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
        suppressSpecialPlanPersistence = true
        specialPlans = []
        suppressSpecialPlanPersistence = false
        [inventoryKey, plansKey, shoppingKey, weeklyPlanKey, consumptionRecordsKey].forEach {
            defaults.removeObject(forKey: $0)
        }
        inventoryNotice = nil
        shoppingNotice = nil
        planNotice = nil
        consumptionNotice = nil
        weeklyPlanNotice = nil
    }

    // MARK: - Special plans

    func addSpecialPlan(_ plan: SpecialPlan) {
        guard !plan.title.isEmpty else { return }
        if let index = specialPlans.firstIndex(where: { $0.id == plan.id }) {
            specialPlans[index] = plan
        } else {
            specialPlans.append(plan)
        }
    }

    func updateSpecialPlan(_ plan: SpecialPlan) {
        guard !plan.title.isEmpty else { return }
        guard let index = specialPlans.firstIndex(where: { $0.id == plan.id }) else { return }
        specialPlans[index] = plan
    }

    @discardableResult
    func removeSpecialPlan(id: UUID) -> SpecialPlan? {
        guard let index = specialPlans.firstIndex(where: { $0.id == id }) else { return nil }
        // Deleting a special plan never touches recipes: `specialPlans` only
        // references recipe ids, so this is a pure plan-row removal.
        return specialPlans.remove(at: index)
    }

    /// Adds or replaces a dish reference on an existing plan. The dish only
    /// stores `recipeID` + a display `recipeName` snapshot; the `Recipe` itself
    /// stays the source of truth in `RecipeStore`.
    @discardableResult
    func addDish(_ dish: SpecialPlanDish, toSpecialPlan id: UUID) -> Bool {
        guard let index = specialPlans.firstIndex(where: { $0.id == id }) else { return false }
        var updated = specialPlans[index]
        guard !updated.dishes.contains(where: { $0.recipeID == dish.recipeID }) else { return false }
        updated.dishes.append(dish)
        updated.updatedAt = Date()
        specialPlans[index] = updated
        return true
    }

    @discardableResult
    func removeDish(id: UUID, fromSpecialPlan planID: UUID) -> Bool {
        guard let index = specialPlans.firstIndex(where: { $0.id == planID }) else { return false }
        var updated = specialPlans[index]
        let before = updated.dishes.count
        updated.dishes.removeAll { $0.id == id }
        guard updated.dishes.count != before else { return false }
        updated.updatedAt = Date()
        specialPlans[index] = updated
        return true
    }

    @discardableResult
    func moveDish(_ dishID: UUID, inSpecialPlan planID: UUID, to index: Int) -> Bool {
        guard let planIndex = specialPlans.firstIndex(where: { $0.id == planID }),
              let from = specialPlans[planIndex].dishes.firstIndex(where: { $0.id == dishID }) else {
            return false
        }
        var updated = specialPlans[planIndex]
        let dish = updated.dishes.remove(at: from)
        let clamped = min(max(index, 0), updated.dishes.count)
        updated.dishes.insert(dish, at: clamped)
        updated.updatedAt = Date()
        specialPlans[planIndex] = updated
        return true
    }

    @discardableResult
    func setDishCooked(_ dishID: UUID, inSpecialPlan planID: UUID, isCooked: Bool) -> Bool {
        guard let planIndex = specialPlans.firstIndex(where: { $0.id == planID }),
              let dishIndex = specialPlans[planIndex].dishes.firstIndex(where: { $0.id == dishID }) else {
            return false
        }
        var updated = specialPlans[planIndex]
        updated.dishes[dishIndex].isCooked = isCooked
        updated.updatedAt = Date()
        specialPlans[planIndex] = updated
        return true
    }

    private func persistSpecialPlansIfNeeded() {
        guard !isLoading, !suppressSpecialPlanPersistence else { return }
        do {
            try specialPlanPersistence.replacePlans(with: specialPlans)
        } catch {
            // No view reads `specialPlanNotice` today. If one ever does, the
            // Special Plan menu acceptance path would show this *and* its own
            // `.planSaveFailed` message for one failure; that surface should
            // defer to the caller's more specific copy.
            specialPlanNotice = "特殊计划保存失败，请稍后重试。"
            #if DEBUG
            print("[SpecialPlanPersistence] save failed: \(error)")
            #endif
        }
    }

    #if DEBUG
    func injectSpecialPlanPersistenceFailureForTesting(_ error: Error) {
        (specialPlanPersistence as? SwiftDataSpecialPlanPersistence)?.failNextReplaceSaveForTesting = error
    }
    #endif

    /// `plannedServings` defaults to `nil`, not `1`: a caller that has not asked
    /// the user how much to make must not silently assert one serving.
    func addPlan(recipe: Recipe, plannedServings: Int? = nil) {
        addPlans([(recipe, plannedServings)])
    }

    /// Applies multi-recipe additions to one local snapshot so week-plan imports
    /// publish and persist only their final, deduplicated result.
    func addPlans(_ additions: [(recipe: Recipe, plannedServings: Int?)]) {
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
                    // Validated, never clamped: an out-of-range value is not
                    // silently reshaped into a plausible-looking target.
                    plannedServings: addition.plannedServings
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

    // MARK: - Ordinary meal CRUD (canonical write path)
    //
    // The Planner's create / edit / move / delete operations all route through
    // `commitPlans`. The one-tap Today paths above keep their own semantics —
    // `addPlans`' same-day dedup protects a double tap on a recommendation card,
    // which an explicitly dated Planner save is not.

    /// Persists first and publishes only on success.
    ///
    /// The ordinary `plans` setter runs persistence *after* the fact from
    /// `didSet`, where a failure can only become `planNotice` copy while the
    /// in-memory array keeps a change the disk never took. That is fine for a
    /// one-tap add whose caller has nothing to decide, and wrong for a form that
    /// has to stay open on failure.
    ///
    /// So this inverts the order: the durable write happens first, and `plans`
    /// is republished only once it succeeded. A caller holding `.saved` is
    /// looking at a durable fact; a caller holding `.persistenceFailed` is
    /// looking at a store that never changed, which is why no rollback is
    /// needed here.
    ///
    /// The publish is suppressed so `didSet` does not immediately repeat the
    /// write that just succeeded — the same idiom `clearAllLocalData` and
    /// `restoreBackupData` already use.
    private func commitPlans(_ updated: [MealPlanItem]) -> Bool {
        do {
            try todayPlanPersistence.replacePlans(with: updated)
        } catch {
            planNotice = "今日计划保存失败，请稍后重试。"
            #if DEBUG
            print("[TodayPlanPersistence] save failed: \(error)")
            #endif
            return false
        }
        suppressPlanPersistence = true
        plans = updated
        suppressPlanPersistence = false
        return true
    }

    /// Adds one ordinary meal on a stated day.
    ///
    /// Duplicates are allowed: the same dish twice on one day is a real plan,
    /// and an explicit save with an explicit date is a deliberate act rather
    /// than the accidental second tap `addPlans` guards against.
    @discardableResult
    func addPlan(
        recipe: Recipe,
        on day: Date,
        plannedServings: Int? = nil,
        calendar: Calendar = .current
    ) -> PlanMutationOutcome<MealPlanItem> {
        // `MealPlanItem.init` validates `plannedServings`, so an out-of-range
        // value arrives here and leaves as `nil` rather than as a clamped number.
        let item = MealPlanItem(
            recipeID: recipe.id,
            recipeName: recipe.title,
            date: MealPlanItem.normalizedPlannerDate(for: day, calendar: calendar),
            plannedServings: plannedServings
        )
        guard commitPlans(plans + [item]) else { return .persistenceFailed }
        return .saved(item)
    }

    /// Appends a batch of fully formed ordinary meals in one durable write.
    ///
    /// The caller supplies whole `MealPlanItem` values, ids included, because
    /// weekly materialization has to be able to *retry with the same ids* after
    /// a failed write: the ids are recorded in a receipt before this is ever
    /// called, so allocating them here would make recovery impossible.
    ///
    /// Deliberately not an overload of `addPlans(_ additions:)`. That one
    /// deduplicates against today for the one-tap paths; this one must not
    /// deduplicate at all, and two methods sharing a name would leave a reader
    /// unable to tell which rule applies.
    ///
    /// All of the requested rows or none: one `commitPlans`, which persists
    /// before publishing. Structural problems are refused up front, so a
    /// `.rejected` result means nothing was even attempted.
    @discardableResult
    func appendPlans(
        _ items: [MealPlanItem],
        calendar: Calendar = .current
    ) -> PlanBatchOutcome {
        guard !items.isEmpty else { return .rejected(.empty) }

        var seen = Set<UUID>()
        var repeated: [UUID] = []
        for item in items where !seen.insert(item.id).inserted {
            if !repeated.contains(item.id) { repeated.append(item.id) }
        }
        guard repeated.isEmpty else { return .rejected(.duplicateIDsInBatch(repeated)) }

        // An id already in `plans` cannot be appended: `TodayPlanRecord.id` is
        // unique and `replacePlans` uniques its incoming array by id, so the
        // pair would silently become one row. Refusing here is what stops a
        // retry from overwriting the rows a previous attempt already wrote.
        let present = Set(plans.map(\.id))
        let colliding = items.map(\.id).filter { present.contains($0) }
        guard colliding.isEmpty else { return .rejected(.idsAlreadyPresent(colliding)) }

        // Only the date is touched, so `plannedServings` passes through exactly
        // as the caller stated it — `nil` stays `nil`. Normalization lives here
        // rather than at the call site so there is one implementation of what a
        // Planner date means.
        let normalized = items.map { item -> MealPlanItem in
            var copy = item
            copy.date = MealPlanItem.normalizedPlannerDate(for: item.date, calendar: calendar)
            return copy
        }

        guard commitPlans(plans + normalized) else { return .persistenceFailed }
        return .saved(normalized)
    }

    /// Moves a plan to another day and restates its target, in one write.
    ///
    /// `id`, `recipeID`, `recipeName` and `isCooked` are untouched by
    /// construction: only the two editable fields are assigned. Changing which
    /// dish a plan refers to is a delete and a re-add, not an edit.
    @discardableResult
    func updatePlan(
        id: UUID,
        on day: Date,
        plannedServings: Int?,
        calendar: Calendar = .current
    ) -> PlanMutationOutcome<MealPlanItem> {
        guard let index = plans.firstIndex(where: { $0.id == id }) else { return .notFound }
        var updated = plans
        updated[index].date = MealPlanItem.normalizedPlannerDate(for: day, calendar: calendar)
        // Assigning the field directly bypasses the initialiser, so the same
        // validation is restated here rather than assumed.
        updated[index].plannedServings = Recipe.validatedBaseServings(plannedServings)
        guard commitPlans(updated) else { return .persistenceFailed }
        return .saved(updated[index])
    }

    /// Removes a plan and hands back what is needed to put it back.
    @discardableResult
    func removePlan(id: UUID) -> PlanMutationOutcome<PlanRemoval> {
        guard let index = plans.firstIndex(where: { $0.id == id }) else { return .notFound }
        let removal = PlanRemoval(item: plans[index], index: index)
        var updated = plans
        updated.remove(at: index)
        guard commitPlans(updated) else { return .persistenceFailed }
        return .saved(removal)
    }

    /// Re-inserts a removed plan, keeping its original `id` so anything that
    /// referenced it — a consumption record's `planIDs`, most importantly —
    /// still resolves.
    ///
    /// Idempotent: restoring an id that is already present is a no-op success
    /// rather than a second copy, because two rows sharing one `id` would
    /// collapse to a single `TodayPlanRecord` on the next write and leave memory
    /// describing something the database does not hold.
    ///
    /// The already-present branch still writes. Returning `.saved` off the back
    /// of an in-memory lookup would be a claim this store cannot support: a row
    /// can sit in `plans` without being durable, because the legacy `didSet`
    /// paths keep a change whose write failed. Re-committing the array as it
    /// stands costs one write and keeps `.saved` meaning what it says.
    ///
    /// The index is clamped: in-memory changes between the delete and the Undo
    /// can make the captured position no longer exist.
    @discardableResult
    func restorePlan(_ item: MealPlanItem, at index: Int) -> PlanMutationOutcome<MealPlanItem> {
        var updated = plans
        if let existing = updated.firstIndex(where: { $0.id == item.id }) {
            guard commitPlans(updated) else { return .persistenceFailed }
            return .saved(updated[existing])
        }
        updated.insert(item, at: min(max(index, 0), updated.count))
        guard commitPlans(updated) else { return .persistenceFailed }
        return .saved(item)
    }

    // MARK: - AI-safe canonical mutation seams
    //
    // Additive write paths for mutations a conversation proposes. Nothing here
    // changes an existing call site: the Planner and Today surfaces keep the
    // methods they already use.
    //
    // Two properties every method below holds to. Persist before publish, so a
    // caller that is told a write failed is looking at a store that never
    // changed. And all-or-none, because a model acting on several rows at once
    // has no user watching to notice that half of it landed.

    /// Restates which dish a set of existing plan rows refers to, in one write.
    ///
    /// Deliberately not a remove plus an add: `id` and `date` are what the rest
    /// of the app joins against — a consumption record's `planIDs` most of all —
    /// so reissuing them would quietly orphan history. Only the dish identity
    /// and the stated servings change.
    ///
    /// `isCooked` resets on a replaced row and only there: it is now a different
    /// dish, so the old execution state is not a fact about it. Rows nobody
    /// named keep theirs.
    ///
    /// Every target is resolved against a local copy before anything is written,
    /// so a duplicate, missing or already-consumed id is refused with nothing
    /// attempted.
    @discardableResult
    func replacePlanRecipes(_ replacements: [PlanRecipeReplacement]) -> PlanReplacementOutcome {
        guard !replacements.isEmpty else { return .rejected(.empty) }

        var seen = Set<UUID>()
        var repeated: [UUID] = []
        for replacement in replacements where !seen.insert(replacement.planID).inserted {
            if !repeated.contains(replacement.planID) { repeated.append(replacement.planID) }
        }
        guard repeated.isEmpty else { return .rejected(.duplicateTargets(repeated)) }

        var updated = plans
        var targets: [Int] = []
        var missing: [UUID] = []
        for replacement in replacements {
            if let index = updated.firstIndex(where: { $0.id == replacement.planID }) {
                targets.append(index)
            } else {
                missing.append(replacement.planID)
            }
        }
        guard missing.isEmpty else { return .rejected(.missingTargets(missing)) }

        // A consumption record that already covers a row is a fact about the
        // dish that row used to name. Resetting `isCooked` under it would make
        // the meal look cookable while the consumption layer still reads it as
        // settled, so the new dish would silently never be deducted. Refusing a
        // replacement this floor cannot make consistent is the honest answer;
        // half-applying one is not.
        let consumed = replacements.map(\.planID).filter { hasConsumedPlan($0) }
        guard consumed.isEmpty else { return .rejected(.consumedTargets(consumed)) }

        for (replacement, index) in zip(replacements, targets) {
            updated[index].recipeID = replacement.recipeID
            updated[index].recipeName = replacement.recipeName
            // Assigning the field directly bypasses the initialiser, so the
            // same validation is restated here rather than assumed.
            updated[index].plannedServings = Recipe.validatedBaseServings(replacement.plannedServings)
            updated[index].isCooked = false
        }

        guard commitPlans(updated) else { return .persistenceFailed }
        return .saved(targets.map { updated[$0] })
    }

    /// Writes a set of plan rows back exactly as they were, in one write.
    ///
    /// The deterministic reversal for `replacePlanRecipes`: the snapshot carries
    /// the original dish, servings and cooked state, so Undo restores the row
    /// rather than approximating it.
    ///
    /// Restates rows that still exist; it does not re-insert a deleted one, and
    /// says `.notFound` instead of inventing it. Putting a *removed* plan back is
    /// `restorePlan(_:at:)`, which also knows where it sat.
    @discardableResult
    func restorePlanItems(_ snapshot: [MealPlanItem]) -> PlanMutationOutcome<[MealPlanItem]> {
        // An empty restore is a caller mistake rather than a vacuous success:
        // a receipt that reverses nothing should never have been offered.
        guard !snapshot.isEmpty else { return .notFound }

        var updated = plans
        for item in snapshot {
            guard let index = updated.firstIndex(where: { $0.id == item.id }) else { return .notFound }
            updated[index] = item
        }
        guard commitPlans(updated) else { return .persistenceFailed }
        return .saved(snapshot)
    }

    /// Persists first and publishes only on success — `commitPlans` for events.
    ///
    /// The ordinary `specialPlans` setter runs persistence after the fact from
    /// `didSet`, where a failure can only become `specialPlanNotice` copy while
    /// the in-memory array keeps a change the disk never took.
    private func commitSpecialPlans(_ updated: [SpecialPlan]) -> Bool {
        do {
            try specialPlanPersistence.replacePlans(with: updated)
        } catch {
            specialPlanNotice = "特殊计划保存失败，请稍后重试。"
            #if DEBUG
            print("[SpecialPlanPersistence] save failed: \(error)")
            #endif
            return false
        }
        suppressSpecialPlanPersistence = true
        specialPlans = updated
        suppressSpecialPlanPersistence = false
        return true
    }

    /// Replaces a plan's whole menu in one durable write.
    ///
    /// Used when a menu is accepted as a unit, where every dish reference is
    /// new. Everything else about the event — title, date, people, constraints —
    /// is untouched by construction: only `dishes` is assigned.
    ///
    /// An empty menu is refused rather than written. This is a whole-list
    /// assignment, so accepting one would erase an event's menu in a single
    /// durable write — a destructive outcome no caller asks for by saying
    /// "nothing". Clearing a menu deliberately is a different, explicit act.
    @discardableResult
    func setSpecialPlanDishes(
        planID: UUID,
        dishes: [SpecialPlanDish],
        now: Date = Date()
    ) -> DomainMutationOutcome<SpecialPlan> {
        guard !dishes.isEmpty else { return .rejected(.empty) }
        guard let index = specialPlans.firstIndex(where: { $0.id == planID }) else { return .notFound }
        var updated = specialPlans
        updated[index].dishes = dishes
        updated[index].updatedAt = now
        guard commitSpecialPlans(updated) else { return .persistenceFailed }
        return .saved(updated[index])
    }

    /// Persist-first completion update for one dish in a Special Plan.
    /// Uses `commitSpecialPlans` so disk durability precedes in-memory publication.
    @discardableResult
    func setSpecialPlanDishCookedPersisted(
        planID: UUID,
        dishID: UUID,
        isCooked: Bool,
        now: Date = Date()
    ) -> DomainMutationOutcome<SpecialPlan> {
        guard let planIndex = specialPlans.firstIndex(where: { $0.id == planID }),
              let dishIndex = specialPlans[planIndex].dishes.firstIndex(where: { $0.id == dishID }) else {
            return .notFound
        }
        var updated = specialPlans
        updated[planIndex].dishes[dishIndex].isCooked = isCooked
        updated[planIndex].updatedAt = now
        guard commitSpecialPlans(updated) else { return .persistenceFailed }
        return .saved(updated[planIndex])
    }

    /// Restates which recipe named dishes point at, leaving the rest of the
    /// event alone. One durable write for the whole set.
    ///
    /// Same rule as the ordinary Planner path: a dish keeps its id and its
    /// position, a replaced dish loses its cooked state, and every target is
    /// resolved on a local copy before anything is written.
    @discardableResult
    func replaceSpecialPlanDishes(
        planID: UUID,
        replacements: [SpecialPlanDishReplacement]
    ) -> DomainMutationOutcome<SpecialPlan> {
        guard !replacements.isEmpty else { return .rejected(.empty) }

        // Naming one dish twice does not describe one outcome, and silently
        // applying the last of the pair would hide half the request.
        var seen = Set<UUID>()
        var repeated: [UUID] = []
        for replacement in replacements where !seen.insert(replacement.dishID).inserted {
            if !repeated.contains(replacement.dishID) { repeated.append(replacement.dishID) }
        }
        guard repeated.isEmpty else { return .rejected(.duplicateTargets(repeated)) }

        guard var dishes = specialPlans.first(where: { $0.id == planID })?.dishes else { return .notFound }

        for replacement in replacements {
            guard let index = dishes.firstIndex(where: { $0.id == replacement.dishID }) else { return .notFound }
            // Rebuilt through the initialiser rather than assigned field by
            // field, so the display name gets the same trim every other
            // `SpecialPlanDish` receives. The dish keeps its id and its place.
            dishes[index] = SpecialPlanDish(
                id: dishes[index].id,
                recipeID: replacement.recipeID,
                recipeName: replacement.recipeName,
                isCooked: false
            )
        }

        return setSpecialPlanDishes(planID: planID, dishes: dishes)
    }

    /// Writes an event back exactly as it was, in one durable write.
    ///
    /// The deterministic reversal for the two methods above. A plan that has
    /// since been deleted is `.notFound`: Undo restores an event, it does not
    /// resurrect one.
    ///
    /// The whole event is overwritten, so this is only a reversal while the plan
    /// still matches the state the action left behind. A caller must verify that
    /// before restoring: an Undo issued after the user renamed the event or
    /// edited its dishes would discard that work rather than undo the action.
    /// Establishing the check is the action coordinator's job, not this seam's.
    @discardableResult
    func restoreSpecialPlan(_ snapshot: SpecialPlan) -> DomainMutationOutcome<SpecialPlan> {
        guard let index = specialPlans.firstIndex(where: { $0.id == snapshot.id }) else { return .notFound }
        var updated = specialPlans
        updated[index] = snapshot
        guard commitSpecialPlans(updated) else { return .persistenceFailed }
        return .saved(snapshot)
    }

    /// Persists first and publishes only on success — `commitPlans` for the
    /// shopping list.
    private func commitShoppingItems(_ updated: [KitchenShoppingItem]) -> Bool {
        do {
            try shoppingListPersistence.replaceShoppingItems(with: updated)
        } catch {
            shoppingNotice = "购物清单保存失败，请稍后重试。"
            #if DEBUG
            print("[ShoppingListPersistence] save failed: \(error)")
            #endif
            return false
        }
        suppressShoppingPersistence = true
        shoppingItems = updated
        suppressShoppingPersistence = false
        return true
    }

    /// Adds a batch to the shopping list, publishing only once it is durable.
    ///
    /// The merge is the existing one, reached through the same private helper
    /// `addShoppingItems` uses: a pending row with a matching name and a
    /// compatible unit absorbs the addition rather than becoming a second line.
    /// Only the write order differs.
    ///
    /// The receipt carries the whole list either side, because the merge means a
    /// reversal cannot be expressed as "remove these ids" — an absorbed addition
    /// left no row of its own to remove.
    @discardableResult
    func addShoppingItemsPersisted(
        _ additions: [KitchenShoppingItem]
    ) -> DomainMutationOutcome<ShoppingMutationReceipt> {
        guard !additions.isEmpty else { return .rejected(.empty) }
        let before = shoppingItems
        var updated = before
        for addition in additions {
            Self.mergeOrAppendShoppingItem(addition, into: &updated)
        }
        guard commitShoppingItems(updated) else { return .persistenceFailed }
        return .saved(ShoppingMutationReceipt(before: before, after: updated))
    }

    /// Writes the shopping list back exactly as it was.
    ///
    /// An empty snapshot is legitimate: it is what reversing the first addition
    /// to an empty list means.
    ///
    /// The whole list is overwritten, so this is only a reversal while the list
    /// still matches the state the action left behind. A caller must verify that
    /// before restoring: an Undo issued after the user added or ticked off a row
    /// would discard that work rather than undo the action. Establishing the
    /// check is the action coordinator's job, not this seam's.
    @discardableResult
    func restoreShoppingItems(
        _ snapshot: [KitchenShoppingItem]
    ) -> DomainMutationOutcome<[KitchenShoppingItem]> {
        guard commitShoppingItems(snapshot) else { return .persistenceFailed }
        return .saved(snapshot)
    }

    /// A plan already covered by a non-undone consumption record must not be deducted
    /// twice when the same plan is confirmed again.
    func hasConsumedPlan(_ planID: UUID) -> Bool {
        consumptionRecords.contains { !$0.isUndone && $0.planIDs.contains(planID) }
    }

    /// A Special Plan dish covered by a non-undone consumption record must not be deducted
    /// twice when the same dish is confirmed again.
    func hasConsumedSpecialPlanDish(planID: UUID, dishID: UUID) -> Bool {
        consumptionRecords.contains {
            !$0.isUndone && $0.specialPlanID == planID && $0.specialPlanDishID == dishID
        }
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
        recipeName: String,
        specialPlanID: UUID? = nil,
        specialPlanDishID: UUID? = nil,
        specialPlanTitleSnapshot: String? = nil
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
                recipeName: recipeName, planIDs: planIDs,
                specialPlanID: specialPlanID,
                specialPlanDishID: specialPlanDishID,
                specialPlanTitleSnapshot: specialPlanTitleSnapshot,
                items: []
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
            specialPlanID: specialPlanID,
            specialPlanDishID: specialPlanDishID,
            specialPlanTitleSnapshot: specialPlanTitleSnapshot,
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
            let wasAlreadyStaple = inventory[index].kind == .staple
            inventory[index].kind = .staple
            // Promoting an existing ordinary row to the pantry shelf drops the
            // date it was carrying. Leaving it behind was the actual reason a
            // staple could still show up in 即将过期 / 已过期.
            //
            // R2: only on that promotion. Saving an *already* staple — a
            // threshold or note edit from the pantry form — must not erase an
            // opaque stored value, or the next full-snapshot upsert would send
            // `expiryDate: null` and destroy the household's date.
            if !wasAlreadyStaple { inventory[index].expiryDate = nil }
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

    /// The current backup scope as one value. The single definition of "what a
    /// backup covers", shared by export, the pre-restore recovery copy and the
    /// recovery comparison, so those three can never drift apart.
    private func currentBackupPayload() -> KitchenBackupPayload {
        KitchenBackupPayload(
            inventory: inventory,
            plans: plans,
            shoppingItems: shoppingItems,
            weeklyPlan: weeklyPlan,
            consumptionRecords: consumptionRecords,
            preparedComponents: preparedComponents,
            specialPlans: specialPlans
        )
    }

    func exportBackupData() throws -> Data {
        try JSONEncoder().encode(currentBackupPayload())
    }

    /// Replaces the backup scope, and reports truthfully what happened.
    ///
    /// Still throws for every non-success outcome, so existing callers are
    /// unchanged, but the attempt now also leaves a classified result in
    /// `lastRestoreOutcome`. The distinction the throw cannot carry — put back
    /// and proven, versus could not be proven — lives there.
    ///
    /// This is not atomic and does not claim to be. Seven independent commits
    /// remain seven independent commits; what is guaranteed is a successful
    /// restore or a truthful result.
    func restoreBackupData(_ data: Data) throws {
        try performRestore(data, reusingOutstandingRecoveryCopy: false)
    }

    /// Puts the outstanding recovery copy back, through the same pipeline.
    ///
    /// Not a bypass: the copy is validated like any candidate, the same outcome
    /// contract applies, and the same domains are written in the same order.
    /// The one difference is that no new copy is prepared over it — the copy
    /// being restored *is* the good state, and taking a fresh copy of the
    /// uncertain current kitchen would overwrite the only way back with the
    /// thing it is there to undo. If this restore fails, the copy survives for
    /// another attempt.
    func restoreFromRecoverySnapshot() throws {
        guard let data = try recoverySnapshot.outstandingSnapshot() else {
            lastRestoreOutcome = .preparationFailed
            throw KitchenRecoverySnapshotError.storageUnavailable
        }
        try performRestore(data, reusingOutstandingRecoveryCopy: true)
    }

    private func performRestore(_ data: Data, reusingOutstandingRecoveryCopy reusing: Bool) throws {
        // R1b — same reason as `applyConsumption`. A restore is a whole-table
        // replacement, so running it against a table a sync is concurrently
        // writing would discard the sync's rows outright. Nothing has been
        // written, so this is a preparation outcome.
        guard !refuseBulkInventoryChangeIfLocked() else {
            lastRestoreOutcome = .preparationFailed
            throw KitchenBackupError.inventoryPersistenceFailed
        }
        // Nothing below this line may run for a file that has not been proven
        // to be a supported Kitchen Manager backup: every write that follows is
        // an irreversible whole-table replacement, and a tolerant decode alone
        // would let an unrelated JSON object replace the kitchen with nothing.
        let backup: KitchenBackupPayload
        do {
            backup = try KitchenBackupValidator.validate(data)
        } catch {
            lastRestoreOutcome = .validationFailed
            throw error
        }
        // The last precondition of the point of no return: a durable copy of
        // the kitchen as it stands right now, provably readable, before the
        // first write makes the old state unrecoverable. The same value is kept
        // in memory as the recovery target, so the target is exactly the
        // pre-restore backup scope rather than seven separate assumptions.
        let previous = currentBackupPayload()
        if !reusing {
            do {
                try recoverySnapshot.prepare(try JSONEncoder().encode(previous))
            } catch {
                lastRestoreOutcome = .preparationFailed
                throw error
            }
        }

        if let failure = writeBackupScope(backup) {
            try recover(to: previous, after: failure)
        }

        publishBackupScope(backup)
        lastRestoreOutcome = .success
        // The restore completed, so the copy has done its job and the slot is
        // released. A failed removal leaves it outstanding, which fails the
        // next restore closed with a stated reason rather than silently
        // discarding a member's recovery asset — so it is not a silent loss.
        try? recoverySnapshot.resolve()
    }

    /// Writes the seven domains in their established order. Returns the domain
    /// that failed, or `nil` when all seven landed.
    private func writeBackupScope(_ payload: KitchenBackupPayload) -> KitchenBackupDomain? {
        for domain in KitchenBackupDomain.restoreOrder {
            do {
                try write(domain, from: payload)
            } catch {
                return domain
            }
        }
        return nil
    }

    private func write(_ domain: KitchenBackupDomain, from payload: KitchenBackupPayload) throws {
        switch domain {
        case .inventory:
            try inventoryPersistence.replaceInventory(with: payload.inventory)
        case .shoppingItems:
            try shoppingListPersistence.replaceShoppingItems(with: payload.shoppingItems)
        case .plans:
            try todayPlanPersistence.replacePlans(with: payload.plans)
        case .consumptionRecords:
            try consumptionPersistence.replaceRecords(with: payload.consumptionRecords)
        case .weeklyPlan:
            try weeklyPlanPersistence.replacePlan(with: payload.weeklyPlan)
        case .preparedComponents:
            try preparedComponentPersistence.replaceComponents(with: payload.preparedComponents)
        case .specialPlans:
            try specialPlanPersistence.replacePlans(with: payload.specialPlans)
        }
    }

    /// Puts the pre-restore state back, then decides whether that can honestly
    /// be called recovered. Always throws: a restore that began and failed is
    /// never a success, whatever the recovery result.
    private func recover(to previous: KitchenBackupPayload, after failed: KitchenBackupDomain) throws {
        let compensationFailures = compensate(to: previous, before: failed)

        let stored: KitchenBackupPayload
        do {
            stored = try loadBackupScope()
        } catch let domain as KitchenBackupDomain {
            // Nothing was published: a half-read must never become half-published
            // in-memory state, and there is no observable truth to compare, so
            // this cannot be called recovered.
            lastRestoreOutcome = .failedUnsafe(.reconciliationFailed(domain))
            throw failed.persistenceError
        }
        // The read succeeded, so this *is* what is stored. Publish it even when
        // it turns out not to match: presenting the pre-restore arrays after an
        // uncertain failure would be presenting values that may not be stored.
        publishBackupScope(stored)

        guard compensationFailures.isEmpty else {
            // A compensating write that reported failure is uncertainty, and
            // uncertainty is never upgraded into "recovered" — not even when the
            // comparison below would have passed.
            lastRestoreOutcome = .failedUnsafe(.compensationFailed(compensationFailures))
            throw failed.persistenceError
        }
        guard stored.matchesBackupScope(of: previous) else {
            lastRestoreOutcome = .failedUnsafe(.restoredStateDiffers)
            throw failed.persistenceError
        }
        lastRestoreOutcome = .failedAndRecovered(failed)
        // Proven, so the copy has done its job. Same reasoning as the success
        // path for a removal that itself fails.
        try? recoverySnapshot.resolve()
        throw failed.persistenceError
    }

    /// Writes the pre-restore state back to every domain that had already been
    /// written. The failed domain is skipped: its own write did not land.
    ///
    /// Continues past a failure rather than stopping at the first one, so the
    /// remaining domains still get put back, and returns every domain that
    /// could not be compensated. Nothing here is discarded with `try?`.
    private func compensate(
        to previous: KitchenBackupPayload,
        before failed: KitchenBackupDomain
    ) -> [KitchenBackupDomain] {
        var failures: [KitchenBackupDomain] = []
        for domain in KitchenBackupDomain.restoreOrder {
            if domain == failed { break }
            do {
                try write(domain, from: previous)
            } catch {
                failures.append(domain)
            }
        }
        return failures
    }

    /// Reads every backup-scoped domain from persistence into locals and
    /// returns them as one value. Publishes nothing and throws the first domain
    /// that could not be read, so a partial read can never become partial
    /// in-memory state.
    private func loadBackupScope() throws -> KitchenBackupPayload {
        let loadedInventory: [InventoryItem]
        do { loadedInventory = try inventoryPersistence.loadInventory() }
        catch { throw KitchenBackupDomain.inventory }
        let loadedShopping: [KitchenShoppingItem]
        do { loadedShopping = try shoppingListPersistence.loadShoppingItems() }
        catch { throw KitchenBackupDomain.shoppingItems }
        let loadedPlans: [MealPlanItem]
        do { loadedPlans = try todayPlanPersistence.loadPlans() }
        catch { throw KitchenBackupDomain.plans }
        let loadedConsumption: [InventoryConsumptionRecord]
        do { loadedConsumption = try consumptionPersistence.loadRecords() }
        catch { throw KitchenBackupDomain.consumptionRecords }
        let loadedWeekly: WeeklyMealPlan?
        do { loadedWeekly = try weeklyPlanPersistence.loadPlan() }
        catch { throw KitchenBackupDomain.weeklyPlan }
        let loadedComponents: [PreparedComponent]
        do { loadedComponents = try preparedComponentPersistence.loadComponents() }
        catch { throw KitchenBackupDomain.preparedComponents }
        let loadedSpecial: [SpecialPlan]
        do { loadedSpecial = try specialPlanPersistence.loadPlans() }
        catch { throw KitchenBackupDomain.specialPlans }
        return KitchenBackupPayload(
            inventory: loadedInventory,
            plans: loadedPlans,
            shoppingItems: loadedShopping,
            weeklyPlan: loadedWeekly,
            consumptionRecords: loadedConsumption,
            preparedComponents: loadedComponents,
            specialPlans: loadedSpecial
        )
    }

    /// Publishes a whole backup scope that is already durable truth: bypasses
    /// the persistence hooks, exactly as the success path has always done.
    private func publishBackupScope(_ payload: KitchenBackupPayload) {
        publishDurableInventory(payload.inventory)
        suppressPlanPersistence = true
        plans = payload.plans
        suppressPlanPersistence = false
        suppressShoppingPersistence = true
        shoppingItems = payload.shoppingItems
        suppressShoppingPersistence = false
        suppressWeeklyPlanPersistence = true
        weeklyPlan = payload.weeklyPlan
        suppressWeeklyPlanPersistence = false
        suppressConsumptionPersistence = true
        consumptionRecords = payload.consumptionRecords
        suppressConsumptionPersistence = false
        suppressPreparedComponentPersistence = true
        preparedComponents = payload.preparedComponents
        suppressPreparedComponentPersistence = false
        suppressSpecialPlanPersistence = true
        specialPlans = payload.specialPlans
        suppressSpecialPlanPersistence = false
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

    /// Persists the generated menu first and publishes only on success.
    ///
    /// `saveWeeklyPlan` publishes immediately and writes from `didSet`, where a
    /// failure can only become `weeklyPlanNotice` copy while the in-memory draft
    /// keeps a change the disk never took. That is tolerable for an ordinary
    /// edit and wrong for a materialization receipt: the whole point of writing
    /// the intended plan ids *before* the canonical batch is that a caller can
    /// trust they are durable. A receipt that was only published would leave an
    /// interrupted materialization unrecoverable.
    ///
    /// Returns whether the write happened. The publish is suppressed so `didSet`
    /// does not immediately repeat the write that just succeeded — the same
    /// idiom `commitPlans` uses.
    @discardableResult
    func commitWeeklyPlan(_ plan: WeeklyMealPlan) -> Bool {
        do {
            try weeklyPlanPersistence.replacePlan(with: plan)
        } catch {
            weeklyPlanNotice = "周菜单保存失败，请稍后重试。"
            #if DEBUG
            print("[WeeklyPlanPersistence] save failed: \(error)")
            #endif
            return false
        }
        suppressWeeklyPlanPersistence = true
        weeklyPlan = plan
        suppressWeeklyPlanPersistence = false
        return true
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
        // A copy is a new menu, so it has never been added to the meal plan. It
        // must not inherit the original's materialization receipt: those ids
        // belong to meals already standing on the original's own days, and a
        // finished receipt would leave the copy unable to be added at all.
        copy.materialization = nil
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
    /// Added in the Planner foundation slice. Decoded with `decodeIfPresent`
    /// like every other field, so backups written before special plans existed
    /// restore as empty rather than failing.
    var specialPlans: [SpecialPlan]

    enum CodingKeys: String, CodingKey {
        case format, version, exportedAt, inventory, plans, shoppingItems, weeklyPlan, consumptionRecords
        case preparedComponents
        case specialPlans
    }

    init(
        inventory: [InventoryItem],
        plans: [MealPlanItem],
        shoppingItems: [KitchenShoppingItem],
        weeklyPlan: WeeklyMealPlan?,
        consumptionRecords: [InventoryConsumptionRecord],
        preparedComponents: [PreparedComponent] = [],
        specialPlans: [SpecialPlan] = []
    ) {
        self.inventory = inventory
        self.plans = plans
        self.shoppingItems = shoppingItems
        self.weeklyPlan = weeklyPlan
        self.consumptionRecords = consumptionRecords
        self.preparedComponents = preparedComponents
        self.specialPlans = specialPlans
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
        specialPlans = try container.decodeIfPresent([SpecialPlan].self, forKey: .specialPlans) ?? []
    }
}

enum KitchenBackupError: LocalizedError {
    case invalidFile
    case unrecognizedBackup
    case unsupportedVersion(Int)
    case inventoryPersistenceFailed
    case shoppingPersistenceFailed
    case todayPlanPersistenceFailed
    case consumptionPersistenceFailed
    case weeklyPlanPersistenceFailed
    case preparedComponentPersistenceFailed
    case specialPlanPersistenceFailed

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            return "无法读取这个厨房备份文件。"
        case .unrecognizedBackup:
            return "这个文件不是 Kitchen Manager 备份。"
        case .unsupportedVersion(let version):
            return version > KitchenBackupValidator.supportedVersion
                ? "这个备份来自更新版本的 Kitchen Manager，当前版本无法读取。"
                : "这个备份的版本当前无法读取。"
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
        case .specialPlanPersistenceFailed:
            return "备份中的特殊计划暂时无法保存，请稍后重试。"
        }
    }
}
