import Combine
import Foundation
import SwiftUI

// MARK: - Ingredient name normalization
//
// The single source of truth for "is this the same ingredient" across inventory,
// receipt scanning, and shopping-list generation. `KitchenStore` delegates its own
// name/unit normalization here instead of keeping a second copy.

enum IngredientNormalizer {
    private static let nameAliases: [String: String] = [
        "tomato": "番茄", "tomatoes": "番茄", "西红柿": "番茄",
        "egg": "鸡蛋", "eggs": "鸡蛋", "large eggs": "鸡蛋",
        "milk": "牛奶", "homo milk": "牛奶", "tofu": "豆腐",
        "scallion": "葱", "green onion": "葱", "青葱": "葱", "小葱": "葱",
        "ginger": "姜", "garlic": "蒜",
        "potato": "土豆", "potatoes": "土豆", "马铃薯": "土豆",
        "猪绞肉": "猪肉末"
    ]

    private static let unitAliases: [String: String] = [
        "pieces": "个", "piece": "个", "pcs": "个", "pc": "个", "packs": "包", "pack": "包",
        "公斤": "千克"
    ]

    static func normalizedName(_ value: String) -> String {
        var name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"\s+(?:\d+(?:\.\d+)?\s*)?(?:g|kg|lb|oz|ml|l|ct|pcs?|packs?)$"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        name = nameAliases[name.lowercased()] ?? name
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedUnit(_ value: String) -> String {
        let unit = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return unitAliases[unit] ?? (unit.isEmpty ? "份" : unit)
    }

    /// A display-agnostic comparison key: normalized name, lowercased, whitespace stripped.
    static func matchKey(_ value: String) -> String {
        normalizedName(value).lowercased().filter { !$0.isWhitespace }
    }
}

// MARK: - Unit conversion
//
// Only converts within the same physical dimension (weight, volume). Counting units
// (个/盒/包/瓶/汤匙/茶匙/...) are never auto-converted between each other, per spec.

enum UnitConverter {
    private static let weightUnitsToGrams: [String: Double] = [
        "g": 1, "克": 1,
        "kg": 1000, "千克": 1000,
        "lb": 453.592, "磅": 453.592,
        "oz": 28.3495,
        "斤": 500, "两": 50
    ]
    private static let volumeUnitsToMilliliters: [String: Double] = [
        "ml": 1, "毫升": 1,
        "l": 1000, "升": 1000
    ]

    static func isWeightUnit(_ unit: String) -> Bool { weightUnitsToGrams[unit.lowercased()] != nil }
    static func isVolumeUnit(_ unit: String) -> Bool { volumeUnitsToMilliliters[unit.lowercased()] != nil }

    static func convert(_ quantity: Double, from unit: String, to targetUnit: String) -> Double? {
        let unit = unit.lowercased()
        let targetUnit = targetUnit.lowercased()
        if unit == targetUnit { return quantity }
        if let fromFactor = weightUnitsToGrams[unit], let toFactor = weightUnitsToGrams[targetUnit] {
            return quantity * fromFactor / toFactor
        }
        if let fromFactor = volumeUnitsToMilliliters[unit], let toFactor = volumeUnitsToMilliliters[targetUnit] {
            return quantity * fromFactor / toFactor
        }
        return nil
    }

    static func areConvertible(_ unitA: String, _ unitB: String) -> Bool {
        let a = unitA.lowercased()
        let b = unitB.lowercased()
        if a == b { return true }
        if weightUnitsToGrams[a] != nil && weightUnitsToGrams[b] != nil { return true }
        if volumeUnitsToMilliliters[a] != nil && volumeUnitsToMilliliters[b] != nil { return true }
        return false
    }
}

// MARK: - Ingredient string parsing
//
// Recipe.ingredients are free-text display strings (e.g. "鸡蛋 2 个", "盐 适量",
// "2 tomatoes"). This turns one line into a name + optional quantity/unit.

struct ParsedIngredient {
    let rawText: String
    let displayName: String
    let quantity: Double?
    let unit: String?
    let isVague: Bool
}

enum IngredientParser {
    private static let vagueWords = ["适量", "少许", "按需", "少量", "酌量", "适当"]

    private static let chineseNumerals: [String: Double] = [
        "半": 0.5, "一": 1, "两": 2, "二": 2, "三": 3, "四": 4, "五": 5,
        "六": 6, "七": 7, "八": 8, "九": 9, "十": 10
    ]

    private static let knownUnits: [String] = [
        "千克", "公斤", "kg", "克", "g", "磅", "lb", "oz", "斤", "两",
        "毫升", "ml", "升", "l", "汤匙", "茶匙",
        "个", "颗", "只", "盒", "包", "瓶", "袋", "把", "根", "块", "片", "份", "勺",
        "碗", "听", "罐", "束", "卷", "头", "打"
    ]

    static func parse(_ rawLine: String) -> ParsedIngredient {
        let raw = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return ParsedIngredient(rawText: rawLine, displayName: rawLine, quantity: nil, unit: nil, isVague: false)
        }

        for word in vagueWords where raw.hasSuffix(word) {
            let name = String(raw.dropLast(word.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return ParsedIngredient(rawText: raw, displayName: name, quantity: nil, unit: nil, isVague: true)
            }
        }

        if let (name, quantity, unit) = splitTrailingQuantityAndUnit(raw) {
            return ParsedIngredient(
                rawText: raw,
                displayName: name,
                quantity: quantity,
                unit: unit,
                isVague: false
            )
        }

        // A bare quantity is intentionally accepted only when separated from the
        // name. This supports "鸡蛋 2" while keeping "维生素B2" intact.
        if let (name, quantity) = splitSpacedTrailingQuantity(raw) {
            return ParsedIngredient(rawText: raw, displayName: name, quantity: quantity, unit: nil, isVague: false)
        }

        let tokens = raw.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard tokens.count > 1 else {
            if let (qty, unit, name) = splitGluedLeadingQuantifier(raw) {
                return ParsedIngredient(rawText: raw, displayName: name, quantity: qty, unit: unit, isVague: false)
            }
            return ParsedIngredient(rawText: raw, displayName: raw, quantity: nil, unit: nil, isVague: false)
        }

        if let (qty, unit, nameStart) = quantityAndUnit(fromLeading: tokens) {
            let name = tokens[nameStart...].joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return ParsedIngredient(rawText: raw, displayName: name, quantity: qty, unit: unit, isVague: false)
            }
        }

        return ParsedIngredient(rawText: raw, displayName: raw, quantity: nil, unit: nil, isVague: false)
    }

    /// Parses the explicit, unambiguous suffix form used by inventory entry:
    /// "韭菜花一份", "鸡蛋2个", "牛奶 1 盒". Units must be present, which
    /// prevents ordinary product names that merely contain a digit from being split.
    private static func splitTrailingQuantityAndUnit(_ value: String) -> (String, Double, String)? {
        let lowercased = value.lowercased()
        for unit in knownUnits.sorted(by: { $0.count > $1.count }) {
            guard lowercased.hasSuffix(unit.lowercased()) else { continue }
            let unitStart = value.index(value.endIndex, offsetBy: -unit.count)
            let beforeUnit = String(value[..<unitStart]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let (name, quantity) = splitTrailingQuantity(beforeUnit), !name.isEmpty else { continue }
            return (name, quantity, unit)
        }
        return nil
    }

    private static func splitSpacedTrailingQuantity(_ value: String) -> (String, Double)? {
        let tokens = value.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard tokens.count >= 2,
              let quantity = resolveQuantityToken(tokens[tokens.count - 1]) else {
            return nil
        }
        let name = tokens.dropLast().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : (name, quantity)
    }

    private static func splitTrailingQuantity(_ value: String) -> (String, Double)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let last = trimmed.last,
           let quantity = chineseNumerals[String(last)] {
            let name = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : (name, quantity)
        }

        var numberStart = trimmed.endIndex
        while numberStart > trimmed.startIndex {
            let previous = trimmed.index(before: numberStart)
            let character = trimmed[previous]
            // "/" is included so a trailing fraction like "1/2" is captured
            // as one token and handed to resolveQuantityToken below, instead
            // of the walk-back stopping at "/" and leaving a stray "1/" on
            // the name with only the "2" read as the quantity.
            guard character.isNumber || character == "." || character == "/" else { break }
            numberStart = previous
        }
        guard numberStart < trimmed.endIndex else { return nil }

        let numberText = String(trimmed[numberStart...])
        guard let quantity = resolveQuantityToken(numberText) else { return nil }
        let name = String(trimmed[..<numberStart])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            // A "食材：数量" style separator left immediately before the
            // quantity (e.g. "鸡胸肉：500克") is not part of the ingredient
            // name.
            .trimmingCharacters(in: CharacterSet(charactersIn: "：:"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        // "维生素B2片" is a product designation, not a quantity. A numeric
        // suffix directly attached to an ASCII letter is therefore left intact.
        if let preceding = name.last,
           preceding.isASCII,
           preceding.isLetter,
           let characterBeforeQuantity = trimmed[..<numberStart].last,
           !characterBeforeQuantity.isWhitespace {
            return nil
        }
        return (name, quantity)
    }

    private static func quantityAndUnit(fromTrailing tokens: [String]) -> (Double, String?, Int)? {
        guard let last = tokens.last else { return nil }

        if tokens.count >= 2 {
            let secondLast = tokens[tokens.count - 2]
            if knownUnits.contains(last.lowercased()), let qty = resolveQuantityToken(secondLast) {
                return (qty, last, tokens.count - 2)
            }
        }
        if let (qty, unit) = splitGluedQuantityUnit(last) {
            return (qty, unit, tokens.count - 1)
        }
        if let qty = resolveQuantityToken(last) {
            return (qty, nil, tokens.count - 1)
        }
        return nil
    }

    private static func quantityAndUnit(fromLeading tokens: [String]) -> (Double, String?, Int)? {
        guard let first = tokens.first else { return nil }

        if tokens.count >= 2 {
            let second = tokens[1]
            if knownUnits.contains(second.lowercased()), let qty = resolveQuantityToken(first) {
                return (qty, second, 2)
            }
        }
        if let (qty, unit) = splitGluedQuantityUnit(first) {
            return (qty, unit, 1)
        }
        if let qty = resolveQuantityToken(first) {
            return (qty, nil, 1)
        }
        return nil
    }

    private static func splitGluedQuantityUnit(_ token: String) -> (Double, String)? {
        let lower = token.lowercased()
        for unit in knownUnits.sorted(by: { $0.count > $1.count }) where lower.hasSuffix(unit) {
            let numericPart = String(token.dropLast(unit.count))
            guard !numericPart.isEmpty, let qty = resolveQuantityToken(numericPart) else { continue }
            return (qty, unit)
        }
        return nil
    }

    /// Compact Chinese phrasing with no spaces at all, e.g. "一把香菜", "两个鸡蛋", "一盒牛奶".
    private static func splitGluedLeadingQuantifier(_ token: String) -> (Double, String?, String)? {
        for (numeralText, value) in chineseNumerals.sorted(by: { $0.key.count > $1.key.count }) {
            guard token.hasPrefix(numeralText) else { continue }
            let remainder = String(token.dropFirst(numeralText.count))
            for unit in knownUnits.sorted(by: { $0.count > $1.count }) where remainder.hasPrefix(unit) {
                let name = String(remainder.dropFirst(unit.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                return (value, unit, name)
            }
        }
        return nil
    }

    private static func resolveQuantityToken(_ token: String) -> Double? {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let value = Double(trimmed) { return value }
        if let value = chineseNumerals[trimmed] { return value }
        if trimmed.contains("/") {
            let parts = trimmed.split(separator: "/")
            if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0 {
                return n / d
            }
        }
        if trimmed.contains("-") || trimmed.contains("~") {
            let parts = trimmed.components(separatedBy: CharacterSet(charactersIn: "-~"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let numbers = parts.compactMap { Double($0) ?? chineseNumerals[$0] }
            if numbers.count == 2 { return (numbers[0] + numbers[1]) / 2 }
        }
        return nil
    }
}

// MARK: - Requirement model

struct IngredientRequirement: Identifiable, Codable, Hashable {
    var id: String
    var normalizedName: String
    var displayName: String
    var requiredQuantity: Double?
    var unit: String?
    var availableQuantity: Double?
    var missingQuantity: Double?
    var sourceRecipeIDs: [String]
    var sourceRecipeNames: [String]
    var isSelected: Bool
    var warning: String?
    var isVague: Bool
    var isCoveredByInventory: Bool
}

struct ShoppingGenerationDraft {
    var missingItems: [IngredientRequirement]
    var coveredItems: [IngredientRequirement]
    var recipeCount: Int
    var warnings: [String]
}

enum ShoppingGenerationSource {
    case recipe(Recipe, servings: Int)
    case todayPlans([MealPlanItem])
    case weeklyPlan(WeeklyMealPlan)
    case selectedRecipes([Recipe], servings: Int)
}

// MARK: - Generator
//
// Deterministic, synchronous, local logic — no AI call in this pass. Reused by every
// entry point (recipe detail, today's plan, weekly plan) instead of each one building
// its own merge logic.

struct ShoppingListGenerator {
    func generate(
        source: ShoppingGenerationSource,
        inventory: [InventoryItem],
        existingShoppingItems: [KitchenShoppingItem],
        recipeStore: RecipeStore,
        includeSeasonings: Bool = false
    ) -> ShoppingGenerationDraft {
        let (recipesWithServings, sourceWarnings) = resolveRecipes(for: source, recipeStore: recipeStore)
        guard !recipesWithServings.isEmpty else {
            return ShoppingGenerationDraft(
                missingItems: [],
                coveredItems: [],
                recipeCount: 0,
                warnings: sourceWarnings.isEmpty ? ["没有找到可用的菜谱"] : sourceWarnings
            )
        }

        var merged: [String: IngredientRequirement] = [:]
        var servingsMismatch: Set<String> = []

        for (recipe, servings) in recipesWithServings {
            for line in Self.ingredientLines(from: recipe, includeSeasonings: includeSeasonings) {
                let parsed = IngredientParser.parse(line)
                let normalized = IngredientNormalizer.normalizedName(parsed.displayName)
                guard !normalized.isEmpty else { continue }

                let (canonicalQuantity, canonicalUnit) = Self.canonicalize(quantity: parsed.quantity, unit: parsed.unit)
                let key = "\(IngredientNormalizer.matchKey(normalized))|\(canonicalUnit ?? "none")"

                var requirement = merged[key] ?? IngredientRequirement(
                    id: key,
                    normalizedName: normalized,
                    displayName: normalized,
                    requiredQuantity: nil,
                    unit: canonicalUnit,
                    availableQuantity: nil,
                    missingQuantity: nil,
                    sourceRecipeIDs: [],
                    sourceRecipeNames: [],
                    isSelected: true,
                    warning: nil,
                    isVague: false,
                    isCoveredByInventory: false
                )

                if let quantity = canonicalQuantity {
                    requirement.requiredQuantity = (requirement.requiredQuantity ?? 0) + quantity
                } else {
                    requirement.isVague = true
                }
                if !requirement.sourceRecipeIDs.contains(recipe.id) {
                    requirement.sourceRecipeIDs.append(recipe.id)
                    requirement.sourceRecipeNames.append(recipe.title)
                }
                if servings != 1 { servingsMismatch.insert(key) }

                merged[key] = requirement
            }
        }

        for key in merged.keys {
            guard var requirement = merged[key] else { continue }
            if requirement.requiredQuantity == nil {
                requirement.warning = requirement.isVague ? "用量为“适量”，请确认是否需要购买" : "请确认数量"
            } else if requirement.isVague {
                requirement.warning = "部分菜谱未标注具体用量，已按可识别的用量合计"
            } else if servingsMismatch.contains(key) {
                requirement.warning = "菜谱没有标注份量，用量未按人数换算，请确认"
            }
            merged[key] = requirement
        }

        var missing: [IngredientRequirement] = []
        var covered: [IngredientRequirement] = []
        for var requirement in merged.values {
            let matchedInventory = Self.matchingInventory(for: requirement, in: inventory)
            let availableQuantity = Self.availableQuantity(matching: requirement, items: matchedInventory)
            requirement.availableQuantity = availableQuantity

            if let required = requirement.requiredQuantity {
                if let available = availableQuantity, available >= required {
                    requirement.missingQuantity = 0
                    requirement.isCoveredByInventory = true
                    covered.append(requirement)
                } else {
                    requirement.missingQuantity = max(0, required - (availableQuantity ?? 0))
                    requirement.isCoveredByInventory = false
                    missing.append(requirement)
                }
            } else {
                requirement.isCoveredByInventory = false
                missing.append(requirement)
            }
        }

        for index in missing.indices {
            let item = missing[index]
            if let existing = existingShoppingItems.first(where: {
                !$0.isDone && IngredientNormalizer.matchKey($0.name) == IngredientNormalizer.matchKey(item.displayName)
            }) {
                let note = "买菜清单中已有「\(existing.name) \(existing.quantity.formatted()) \(existing.unit)」，确认后会合并数量"
                missing[index].warning = missing[index].warning.map { "\($0)；\(note)" } ?? note
            }
        }

        return ShoppingGenerationDraft(
            missingItems: missing.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending },
            coveredItems: covered.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending },
            recipeCount: recipesWithServings.count,
            warnings: sourceWarnings
        )
    }

    private func resolveRecipes(
        for source: ShoppingGenerationSource,
        recipeStore: RecipeStore
    ) -> (recipes: [(recipe: Recipe, servings: Int)], warnings: [String]) {
        switch source {
        case .recipe(let recipe, let servings):
            return ([(recipe, servings)], [])

        case .selectedRecipes(let recipes, let servings):
            return (recipes.map { ($0, servings) }, [])

        case .todayPlans(let plans):
            var warnings: [String] = []
            let resolved: [(Recipe, Int)] = plans.compactMap { plan in
                guard let recipe = recipeStore.recipes.first(where: { $0.id == plan.recipeID }) else {
                    warnings.append("「\(plan.recipeName)」的菜谱信息缺失，已跳过")
                    return nil
                }
                return (recipe, plan.servings)
            }
            return (resolved, warnings)

        case .weeklyPlan(let plan):
            var resolved: [(Recipe, Int)] = []
            for day in plan.days {
                for meal in day.meals {
                    for recipe in meal.recipes {
                        resolved.append((
                            Recipe(
                                id: recipe.existingRecipeID ?? recipe.id,
                                title: recipe.title,
                                cookingTime: recipe.cookingTime,
                                difficulty: recipe.difficulty,
                                tags: recipe.tags,
                                ingredients: recipe.ingredients,
                                seasonings: recipe.seasonings ?? [],
                                steps: recipe.steps
                            ),
                            plan.servings
                        ))
                    }
                }
            }
            return (resolved, resolved.isEmpty ? ["本周计划中没有安排菜品"] : [])
        }
    }

    private static func ingredientLines(from recipe: Recipe, includeSeasonings: Bool) -> [String] {
        includeSeasonings ? recipe.ingredients + recipe.seasonings : recipe.ingredients
    }

    /// Converts weight/volume quantities into a canonical unit (克/毫升) so the same
    /// ingredient written as "500 g" in one recipe and "0.5 kg" in another still merges
    /// into a single requirement. Counting units (个/盒/包/...) pass through unchanged.
    private static func canonicalize(quantity: Double?, unit: String?) -> (Double?, String?) {
        guard let quantity, let unit else { return (quantity, unit) }
        if UnitConverter.isWeightUnit(unit) {
            return (UnitConverter.convert(quantity, from: unit, to: "克"), "克")
        }
        if UnitConverter.isVolumeUnit(unit) {
            return (UnitConverter.convert(quantity, from: unit, to: "毫升"), "毫升")
        }
        return (quantity, unit)
    }

    private static func matchingInventory(for requirement: IngredientRequirement, in inventory: [InventoryItem]) -> [InventoryItem] {
        inventory.filter { item in
            item.isAvailable
                && !isExpired(item)
                && IngredientNormalizer.matchKey(item.name) == IngredientNormalizer.matchKey(requirement.displayName)
        }
    }

    private static func isExpired(_ item: InventoryItem) -> Bool {
        guard let days = item.remainingDays else { return false }
        return days < 0
    }

    private static func availableQuantity(matching requirement: IngredientRequirement, items: [InventoryItem]) -> Double? {
        guard !items.isEmpty else { return nil }
        guard let targetUnit = requirement.unit else {
            return items.reduce(0) { $0 + $1.quantity }
        }
        var total = 0.0
        var matchedAny = false
        for item in items {
            if let converted = UnitConverter.convert(item.quantity, from: item.unit, to: targetUnit) {
                total += converted
                matchedAny = true
            }
        }
        return matchedAny ? total : nil
    }
}

// MARK: - Store

@MainActor
final class ShoppingListGenerationStore: ObservableObject {
    @Published private(set) var source: ShoppingGenerationSource?
    @Published var missingItems: [IngredientRequirement] = []
    @Published var coveredItems: [IngredientRequirement] = []
    @Published private(set) var recipeCount = 0
    @Published private(set) var isGenerating = false
    @Published var errorMessage: String?
    @Published private(set) var hasImported = false

    private let generator = ShoppingListGenerator()

    var selectedCount: Int { missingItems.filter(\.isSelected).count }

    func generate(
        source: ShoppingGenerationSource,
        kitchenStore: KitchenStore,
        recipeStore: RecipeStore,
        includeSeasonings: Bool = false
    ) {
        self.source = source
        isGenerating = true
        errorMessage = nil
        hasImported = false

        let draft = generator.generate(
            source: source,
            inventory: kitchenStore.inventory,
            existingShoppingItems: kitchenStore.shoppingItems,
            recipeStore: recipeStore,
            includeSeasonings: includeSeasonings
        )

        missingItems = draft.missingItems
        coveredItems = draft.coveredItems
        recipeCount = draft.recipeCount
        isGenerating = false

        if draft.missingItems.isEmpty && draft.coveredItems.isEmpty {
            errorMessage = draft.warnings.first ?? "没有找到可用的食材信息。"
        }
    }

    func selectAll() {
        for index in missingItems.indices { missingItems[index].isSelected = true }
    }

    func deselectAll() {
        for index in missingItems.indices { missingItems[index].isSelected = false }
    }

    @discardableResult
    func importSelectedItems(into kitchenStore: KitchenStore) -> Int {
        let selected = missingItems.filter(\.isSelected)
        guard !selected.isEmpty else { return 0 }

        let additions = selected.map { item -> KitchenShoppingItem in
            var quantity = (item.missingQuantity ?? item.requiredQuantity ?? 1)
            quantity = quantity > 0 ? quantity : 1
            let unit = item.unit?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "适量"
            return KitchenShoppingItem(
                name: item.displayName,
                quantity: quantity,
                unit: unit,
                source: sourceLabel
            )
        }
        kitchenStore.addShoppingItems(additions)

        let selectedIDs = Set(selected.map(\.id))
        missingItems.removeAll { selectedIDs.contains($0.id) }
        hasImported = true
        return selected.count
    }

    private var sourceLabel: String {
        switch source {
        case .recipe: return "菜谱"
        case .todayPlans: return "今日计划"
        case .weeklyPlan: return "本周菜单"
        case .selectedRecipes: return "菜谱"
        case .none: return "手动添加"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Confirmation view

struct ShoppingListGenerationView: View {
    @EnvironmentObject private var kitchenStore: KitchenStore
    @EnvironmentObject private var recipeStore: RecipeStore
    @EnvironmentObject private var navigationStore: AppNavigationStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = ShoppingListGenerationStore()
    @AppStorage("shoppingIncludesSeasonings") private var includeSeasonings = false
    let source: ShoppingGenerationSource

    var body: some View {
        List {
            Section("概览") {
                LabeledContent("菜谱", value: "\(store.recipeCount) 道")
                LabeledContent("所需食材", value: "\(store.missingItems.count + store.coveredItems.count) 项")
                LabeledContent("已有库存", value: "\(store.coveredItems.count) 项")
                LabeledContent("需要购买", value: "\(store.missingItems.count) 项")
                Toggle("包含调料", isOn: $includeSeasonings)
            }

            if !store.missingItems.isEmpty {
                Section {
                    ForEach($store.missingItems) { $item in
                        requirementRow($item)
                    }
                } header: {
                    HStack {
                        Text("需要购买")
                        Spacer()
                        Button(store.selectedCount == store.missingItems.count ? "取消全选" : "全选") {
                            if store.selectedCount == store.missingItems.count {
                                store.deselectAll()
                            } else {
                                store.selectAll()
                            }
                        }
                        .font(.caption)
                        .textCase(nil)
                    }
                }
            }

            if !store.coveredItems.isEmpty {
                DisclosureGroup("库存已覆盖（\(store.coveredItems.count)）") {
                    ForEach(store.coveredItems) { item in
                        HStack {
                            Text(item.displayName)
                            Spacer()
                            Text(coverageText(item)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if store.missingItems.isEmpty && store.coveredItems.isEmpty {
                ContentUnavailableView(
                    "没有可生成的购物清单",
                    systemImage: "cart",
                    description: Text(store.errorMessage ?? "这道菜谱没有可识别的食材。")
                )
            }
        }
        .navigationTitle("生成购物清单")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !store.missingItems.isEmpty {
                Button("加入买菜清单（\(store.selectedCount)）") {
                    let count = store.importSelectedItems(into: kitchenStore)
                    guard count > 0 else { return }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    navigationStore.selectedTab = .shopping
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primary)
                .disabled(store.selectedCount == 0)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
        .task(id: includeSeasonings) {
            store.generate(
                source: source,
                kitchenStore: kitchenStore,
                recipeStore: recipeStore,
                includeSeasonings: includeSeasonings
            )
        }
    }

    @ViewBuilder
    private func requirementRow(_ item: Binding<IngredientRequirement>) -> some View {
        Toggle(isOn: item.isSelected) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("食材名称", text: item.displayName)
                    .font(.subheadline.weight(.semibold))
                HStack {
                    TextField("数量", value: item.missingQuantity, format: .number)
                        .keyboardType(.decimalPad)
                        .frame(maxWidth: 80)
                    TextField(
                        "单位",
                        text: Binding(
                            get: { item.wrappedValue.unit ?? "" },
                            set: { item.wrappedValue.unit = $0.isEmpty ? nil : $0 }
                        )
                    )
                    .frame(maxWidth: 80)
                    Spacer()
                }
                if !item.wrappedValue.sourceRecipeNames.isEmpty {
                    Text("来自：\(item.wrappedValue.sourceRecipeNames.joined(separator: "、"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let warning = item.wrappedValue.warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func coverageText(_ item: IngredientRequirement) -> String {
        guard let required = item.requiredQuantity else { return "库存足够" }
        if let available = item.availableQuantity {
            return "需要 \(required.formatted()) · 现有 \(available.formatted()) \(item.unit ?? "")"
        }
        return "库存足够"
    }
}
