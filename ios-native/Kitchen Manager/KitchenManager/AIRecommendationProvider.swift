import Foundation
import FoundationModels
import SwiftUI

enum AIRecommendationProvider: String, CaseIterable, Identifiable {
    static let storageKey = "aiRecommendationProvider"
    static let defaultProvider: Self = .gemini

    case gemini
    case groq
    case apple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gemini: "Gemini"
        case .groq: "Groq"
        case .apple: "Apple Intelligence / 设备端"
        }
    }

    static func selected(in userDefaults: UserDefaults = .standard) -> Self {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("DEBUG_AI_PROVIDER_APPLE") { return .apple }
        if arguments.contains("DEBUG_AI_PROVIDER_GEMINI") { return .gemini }
        #endif
        guard let rawValue = userDefaults.string(forKey: storageKey),
              let provider = Self(rawValue: rawValue) else {
            return defaultProvider
        }
        return provider
    }
}

struct AIRecommendationProviderSettingsRow: View {
    @AppStorage(AIRecommendationProvider.storageKey)
    private var providerRawValue = AIRecommendationProvider.defaultProvider.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("菜谱推荐模型", selection: $providerRawValue) {
                ForEach(AIRecommendationProvider.allCases) { provider in
                    Text(provider.title)
                        .tag(provider.rawValue)
                        .disabled(provider == .apple && !AppleFoundationModelCandidateGenerator.isAvailable)
                }
            }
            .accessibilityIdentifier("settings.aiRecommendationProvider.picker")

            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: ChromeMetrics.minimumRowHeight)
    }

    private var statusText: String {
        if providerRawValue == AIRecommendationProvider.apple.rawValue {
            return AppleFoundationModelCandidateGenerator.availabilityText
                + "；仅生成菜谱灵感，不用于可靠执行过敏或严格忌口。"
        }
        return "Gemini 为默认；Groq 沿用现有云端请求路径。"
    }
}

struct AppleRecipeCandidate: Equatable {
    let name: String
    let requiredIngredients: [String]
}

protocol AppleRecipeCandidateGenerating {
    func generateCandidates(
        query: String,
        inventory: [String],
        expiringIngredients: [String],
        preferences: [String],
        excludedRecipeNames: [String],
        count: Int
    ) async throws -> [AppleRecipeCandidate]
}

enum AppleRecommendationError: LocalizedError {
    case unavailable(String)
    case strictRestrictionUnsupported
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            "Apple Intelligence 当前不可用：\(detail)"
        case .strictRestrictionUnsupported:
            "设备端推荐不能可靠执行过敏或严格忌口，请改用 Gemini 或 Groq。"
        case .invalidResponse:
            "设备端模型没有返回可用的菜谱候选。"
        }
    }
}

@Generable
private struct AppleGeneratedRecommendationResponse {
    @Guide(description: "一到八道不重复的菜谱候选", .count(1...8))
    var recipes: [AppleGeneratedRecipeCandidate]
}

@Generable
private struct AppleGeneratedRecipeCandidate {
    @Guide(description: "简短、真实的菜名")
    var name: String

    @Guide(description: "完成这道菜需要的核心食材；只列需求，不判断库存是否已有")
    var requiredIngredients: [String]
}

struct AppleFoundationModelCandidateGenerator: AppleRecipeCandidateGenerating {
    static var isAvailable: Bool {
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        return false
    }

    static var availabilityText: String {
        guard #available(iOS 26.0, *) else { return "需要 iOS 26 或更高版本" }
        switch SystemLanguageModel.default.availability {
        case .available:
            return "Apple Intelligence 已可用，推荐在设备端生成"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence 尚未开启"
        case .unavailable(.modelNotReady):
            return "设备端模型尚未准备好"
        case .unavailable(.deviceNotEligible):
            return "此设备不支持 Apple Intelligence"
        case .unavailable:
            return "Apple Intelligence 当前不可用"
        }
    }

    func generateCandidates(
        query: String,
        inventory: [String],
        expiringIngredients: [String],
        preferences: [String],
        excludedRecipeNames: [String],
        count: Int
    ) async throws -> [AppleRecipeCandidate] {
        guard #available(iOS 26.0, *) else {
            throw AppleRecommendationError.unavailable(Self.availabilityText)
        }
        guard !Self.containsStrictRestriction(query) else {
            throw AppleRecommendationError.strictRestrictionUnsupported
        }

        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw AppleRecommendationError.unavailable(Self.availabilityText)
        }

        let requestedCount = min(max(count, 1), 8)
        let session = LanguageModelSession(
            model: model,
            instructions: "你是家庭菜谱灵感助手。只提出菜名和所需核心食材，不判断库存、缺料、临期覆盖或营养事实。"
        )
        let response = try await session.respond(
            to: """
            生成 \(requestedCount) 道真实、合理、不重复的家庭菜谱候选。
            用户输入：\(query.isEmpty ? "没有指定" : query)
            可用于启发选菜的库存：\(inventory.isEmpty ? "暂无" : inventory.joined(separator: "、"))
            可优先考虑的临期食材名称：\(expiringIngredients.isEmpty ? "暂无" : expiringIngredients.joined(separator: "、"))
            一般偏好：\(preferences.isEmpty ? "暂无" : preferences.joined(separator: "、"))
            避开这些菜名：\(excludedRecipeNames.isEmpty ? "暂无" : excludedRecipeNames.joined(separator: "、"))
            只输出每道菜的菜名和完成它所需的核心食材。不要输出库存已有、仍缺、库存数量、临期覆盖或推荐理由。
            """,
            generating: AppleGeneratedRecommendationResponse.self
        )
        let candidates = response.content.recipes.map {
            AppleRecipeCandidate(name: $0.name, requiredIngredients: $0.requiredIngredients)
        }
        guard !candidates.isEmpty else { throw AppleRecommendationError.invalidResponse }
        return candidates
    }

    private static func containsStrictRestriction(_ query: String) -> Bool {
        ["过敏", "忌口", "不得", "不能吃", "不吃", "纯素", "无麸质", "allerg", "gluten-free"]
            .contains { query.localizedCaseInsensitiveContains($0) }
    }
}

struct AppleIngredientDerivation: Equatable {
    let available: [String]
    let missing: [String]
    let expiring: [String]
}

enum AppleRecommendationBuilder {
    static func makeRecommendations(
        candidates: [AppleRecipeCandidate],
        inventory: [String],
        expiringIngredients: [String],
        excludedRecipeNames: [String],
        count: Int
    ) -> [RecipeRecommendation] {
        let excluded = Set(excludedRecipeNames.map(normalizedRecipeName))
        var usedNames = Set<String>()

        return candidates.compactMap { candidate in
            let name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedName = normalizedRecipeName(name)
            let ingredients = uniqueIngredients(candidate.requiredIngredients)
            guard !name.isEmpty,
                  !ingredients.isEmpty,
                  !excluded.contains(normalizedName),
                  usedNames.insert(normalizedName).inserted else {
                return nil
            }

            let derivation = deriveIngredients(
                requiredIngredients: ingredients,
                inventory: inventory,
                expiringIngredients: expiringIngredients
            )
            let recipe = Recipe(
                id: "apple-\(normalizedName)",
                title: name,
                cookingTime: nil,
                difficulty: nil,
                tags: ["设备端灵感"],
                ingredients: ingredients,
                steps: ["设备端推荐仅提供菜名与所需食材，请按熟悉做法烹饪或另行查看完整菜谱。"]
            )
            return RecipeRecommendation(
                recipe: recipe,
                reason: deterministicReason(derivation),
                source: .ai
            )
        }
        .prefix(min(max(count, 1), 8))
        .map { $0 }
    }

    static func deriveIngredients(
        requiredIngredients: [String],
        inventory: [String],
        expiringIngredients: [String]
    ) -> AppleIngredientDerivation {
        let inventoryKeys = Set(inventory.map(ingredientKey).filter { !$0.isEmpty })
        let expiringKeys = Set(expiringIngredients.map(ingredientKey).filter { !$0.isEmpty })
        var available: [String] = []
        var missing: [String] = []
        var expiring: [String] = []

        for ingredient in uniqueIngredients(requiredIngredients) {
            let key = ingredientKey(ingredient)
            if inventoryKeys.contains(key) {
                available.append(ingredient)
                if expiringKeys.contains(key) { expiring.append(ingredient) }
            } else {
                missing.append(ingredient)
            }
        }
        return AppleIngredientDerivation(available: available, missing: missing, expiring: expiring)
    }

    private static func deterministicReason(_ derivation: AppleIngredientDerivation) -> String {
        var parts: [String] = []
        if !derivation.expiring.isEmpty {
            parts.append("可优先用到临期的\(names(derivation.expiring))")
        }
        if !derivation.available.isEmpty {
            parts.append("在库已有\(names(derivation.available))")
        }
        if !derivation.missing.isEmpty {
            parts.append("还缺\(names(derivation.missing))")
        }
        return parts.isEmpty ? "所需食材请逐项确认。" : parts.joined(separator: "；") + "。"
    }

    private static func ingredientKey(_ value: String) -> String {
        IngredientNormalizer.matchKey(IngredientParser.parse(value).displayName)
    }

    private static func uniqueIngredients(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = ingredientKey(trimmed)
            return !key.isEmpty && seen.insert(key).inserted ? trimmed : nil
        }
    }

    private static func normalizedRecipeName(_ value: String) -> String {
        value.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private static func names(_ values: [String]) -> String {
        values.map { IngredientParser.parse($0).displayName }.joined(separator: "、")
    }
}
