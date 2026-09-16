import Foundation
import Combine

struct InventoryIngredientPayload: Encodable {
    let name: String
    let quantity: Double
    let unit: String
    let remainingDays: Int?
}

struct AIGenerateRecipeRequest: Encodable {
    let ingredients: [String]
    let inventoryIngredients: [InventoryIngredientPayload]
    let servings: Int
    let flavors: [String]
    let cuisine: String?
    let maxCookingTime: Int?
    let excludedIngredients: [String]
    let additionalRequest: String?
    let excludedRecipeNames: [String]
}

private struct AIGeneratedRecipeEnvelope: Decodable {
    let recipe: AIGeneratedRecipeDTO
}

struct AIGeneratedRecipeDTO: Decodable {
    let name: String
    let servings: Int?
    let cookingTime: Int?
    let difficulty: String?
    let tags: [String]
    let ingredients: [AIGeneratedIngredientDTO]
    let seasonings: [AIGeneratedIngredientDTO]
    let steps: [String]
    let tips: [String]
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case name, title, servings, cookingTime, cooking_time, difficulty
        case tags, ingredients, seasonings, steps, method, tips, reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name))
            ?? (try? container.decode(String.self, forKey: .title))
            ?? ""
        servings = Self.decodeInt(container, keys: [.servings])
        cookingTime = Self.decodeInt(container, keys: [.cookingTime, .cooking_time])
        difficulty = try? container.decode(String.self, forKey: .difficulty)
        tags = (try? container.decode([String].self, forKey: .tags)) ?? []
        ingredients = (try? container.decode([AIGeneratedIngredientDTO].self, forKey: .ingredients)) ?? []
        seasonings = (try? container.decode([AIGeneratedIngredientDTO].self, forKey: .seasonings)) ?? []
        tips = (try? container.decode([String].self, forKey: .tips)) ?? []
        reason = try? container.decode(String.self, forKey: .reason)

        if let value = try? container.decode([String].self, forKey: .steps) {
            steps = value
        } else if let value = try? container.decode([String].self, forKey: .method) {
            steps = value
        } else if let value = try? container.decode(String.self, forKey: .method) {
            steps = value.components(separatedBy: .newlines)
        } else {
            steps = []
        }
    }

    private static func decodeInt(
        _ container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> Int? {
        for key in keys {
            if let value = try? container.decode(Int.self, forKey: key) {
                return value
            }
            if let value = try? container.decode(String.self, forKey: key),
               let number = Int(value.filter(\.isNumber)) {
                return number
            }
        }
        return nil
    }
}

struct AIGeneratedIngredientDTO: Decodable {
    let name: String
    let quantity: String?
    let unit: String?

    var displayText: String {
        [name, quantity, unit]
            .compactMap { value in
                value?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    enum CodingKeys: String, CodingKey {
        case name, item, quantity, qty, amount, unit
    }

    init(from decoder: Decoder) throws {
        if let singleValue = try? decoder.singleValueContainer(),
           let text = try? singleValue.decode(String.self) {
            name = text
            quantity = nil
            unit = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name))
            ?? (try? container.decode(String.self, forKey: .item))
            ?? ""
        quantity = (try? container.decode(String.self, forKey: .quantity))
            ?? (try? container.decode(String.self, forKey: .qty))
            ?? (try? container.decode(String.self, forKey: .amount))
            ?? Self.decodeNumericText(container, keys: [.quantity, .qty, .amount])
        unit = try? container.decode(String.self, forKey: .unit)
    }

    private static func decodeNumericText(
        _ container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> String? {
        for key in keys {
            if let value = try? container.decode(Int.self, forKey: key) {
                return String(value)
            }
            if let value = try? container.decode(Double.self, forKey: key) {
                return value.formatted(.number.precision(.fractionLength(0...2)))
            }
        }
        return nil
    }
}

struct AIGeneratedRecipeService {
    private let chatService = AIChatService()

    func generate(request: AIGenerateRecipeRequest) async throws -> EditableRecipeDraft {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let requestData = try encoder.encode(request)
        guard let requestJSON = String(data: requestData, encoding: .utf8) else {
            throw AIGeneratorError.invalidResponse
        }

        let prompt = """
        你是 Kitchen Manager 的家庭烹饪助手。根据下面的用户条件生成一道完整、真实、可执行的家庭菜谱。

        用户条件 JSON：
        \(requestJSON)

        要求：
        - 按 servings 调整用量。
        - 优先使用 inventoryIngredients，remainingDays 越小越优先使用。
        - 尽量使用 ingredients 中用户点名的食材，但不要为了用完库存制造不合理组合。
        - 严格避开 excludedIngredients。
        - 遵守 cuisine、flavors 和 maxCookingTime。
        - 菜名不得与 excludedRecipeNames 相同或高度相似。
        - ingredients 只列构成菜品主体的原材料，例如鸡肉、土豆、番茄、鸡蛋、猪肉、青椒。
        - seasonings 列腌制、调味、勾芡、炝锅、炸制及辅助烹饪材料；盐、糖、生抽、料酒、食用油、豆粉、淀粉、生粉、水淀粉、花椒、豆瓣酱、少许葱姜蒜、清水和高汤必须放在 seasonings，不能放 ingredients。
        - 步骤必须明确、可执行，3 到 8 步；不要在步骤文本前添加编号。
        - 只返回 JSON 对象，不要 Markdown、代码围栏或额外解释。

        严格 JSON 格式：
        {
          "recipe": {
            "name": "菜名",
            "servings": 2,
            "cookingTime": 30,
            "difficulty": "简单",
            "tags": ["家常菜", "清淡"],
            "ingredients": [
              {"name": "鸡胸肉", "quantity": "1", "unit": "块"}
            ],
            "seasonings": [
              {"name": "盐", "quantity": "1", "unit": "适量"}
            ],
            "steps": ["处理食材", "完成烹饪"],
            "tips": ["一条实用小贴士"],
            "reason": "为什么适合当前条件"
          }
        }
        """

        let content = try await chatService.request(
            prompt: prompt,
            taskType: "creative-recipe",
            timeout: 60
        )
        guard let data = content.data(using: .utf8) else {
            throw AIGeneratorError.invalidResponse
        }

        let decoder = JSONDecoder()
        let dto: AIGeneratedRecipeDTO
        if let envelope = try? decoder.decode(AIGeneratedRecipeEnvelope.self, from: data) {
            dto = envelope.recipe
        } else if let direct = try? decoder.decode(AIGeneratedRecipeDTO.self, from: data) {
            dto = direct
        } else {
            throw AIGeneratorError.invalidResponse
        }

        return try makeDraft(from: dto, fallbackServings: request.servings)
    }

    private func makeDraft(
        from dto: AIGeneratedRecipeDTO,
        fallbackServings: Int
    ) throws -> EditableRecipeDraft {
        let name = dto.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let ingredients = dto.ingredients
            .map(\.displayText)
            .filter { !$0.isEmpty }
        let steps = dto.steps
            .map(EditableRecipeDraft.cleanStep)
            .filter { !$0.isEmpty }
        guard !name.isEmpty, !ingredients.isEmpty, !steps.isEmpty else {
            throw AIGeneratorError.invalidResponse
        }

        return EditableRecipeDraft(
            title: name,
            // The user picked this headcount and the prompt is instructed to
            // write quantities for it ("按 servings 调整用量"), so the generated
            // quantities really do correspond to it — a genuine base yield, not
            // a placeholder. `validatedBaseServings` drops anything the model
            // returns outside the supported range instead of clamping it.
            baseServings: Recipe.validatedBaseServings(dto.servings ?? fallbackServings),
            cookingTime: dto.cookingTime,
            difficulty: dto.difficulty ?? "",
            tagsText: dto.tags.joined(separator: "，"),
            ingredientsText: ingredients.joined(separator: "\n"),
            seasoningsText: dto.seasonings
                .map(\.displayText)
                .filter { !$0.isEmpty }
                .joined(separator: "\n"),
            stepsText: steps.joined(separator: "\n"),
            tipsText: dto.tips
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        )
    }
}

enum AIGeneratorError: LocalizedError {
    case missingInput
    case invalidServings
    case allIngredientsExcluded
    case invalidResponse
    case noDraft
    case alreadySaved

    var errorDescription: String? {
        switch self {
        case .missingInput:
            return "请至少选择一种食材，或填写额外要求。"
        case .invalidServings:
            return "用餐人数需要在 1 到 12 人之间。"
        case .allIngredientsExcluded:
            return "所选食材都在忌口列表中，请调整后再试。"
        case .invalidResponse:
            return "AI 返回的菜谱无法识别，请重新生成。"
        case .noDraft:
            return "当前没有可以操作的菜谱。"
        case .alreadySaved:
            return "这份菜谱已经保存过了。"
        }
    }
}

@MainActor
final class AIRecipeGeneratorStore: ObservableObject {
    static let flavorOptions = ["清淡", "下饭", "酸辣", "香辣", "咸鲜", "甜口", "少油", "高蛋白", "快手"]
    static let cuisineOptions = ["不限", "川菜", "家常菜", "粤菜", "江浙菜", "西餐", "日式", "韩式", "东南亚"]

    @Published var selectedInventoryIDs: Set<InventoryItem.ID> = []
    @Published var customIngredientsText = ""
    @Published var servings = 2
    @Published var selectedFlavors: Set<String> = []
    @Published var maxCookingTime: Int?
    @Published var cuisine = "不限"
    @Published var excludedIngredientsText = ""
    @Published var additionalRequest = ""
    @Published private(set) var isGenerating = false
    @Published var generatedDraft: EditableRecipeDraft?
    @Published private(set) var hasSavedCurrentDraft = false
    @Published private(set) var hasAddedCurrentDraftToPlan = false
    @Published var errorMessage: String?

    /// The one network call this store makes. Injectable so a test can drive
    /// failure and cancellation deterministically; production wires the real
    /// service.
    private let generateDraft: (AIGenerateRecipeRequest) async throws -> EditableRecipeDraft
    private var generationTask: Task<EditableRecipeDraft, Error>?
    private var activeRequestID: UUID?
    private var didPrepareInventory = false

    init(generateDraft: ((AIGenerateRecipeRequest) async throws -> EditableRecipeDraft)? = nil) {
        if let generateDraft {
            self.generateDraft = generateDraft
            return
        }
        #if DEBUG
        if AIRecipeGenerationFixture.isEnabled {
            self.generateDraft = AIRecipeGenerationFixture.generate
            return
        }
        #endif
        let service = AIGeneratedRecipeService()
        self.generateDraft = { try await service.generate(request: $0) }
    }

    func prepareInventory(_ inventory: [InventoryItem]) {
        guard !didPrepareInventory else { return }
        didPrepareInventory = true
        selectedInventoryIDs = Set(
            inventory
                .filter { $0.isAvailable && ($0.remainingDays ?? 999) <= 3 }
                .map(\.id)
        )
    }

    func selectAllExpiring(_ inventory: [InventoryItem]) {
        selectedInventoryIDs.formUnion(
            inventory
                .filter { $0.isAvailable && ($0.remainingDays ?? 999) <= 3 }
                .map(\.id)
        )
    }

    func generate(inventory: [InventoryItem], regenerate: Bool = false) async -> Bool {
        guard !isGenerating else { return false }

        do {
            let request = try makeRequest(
                inventory: inventory,
                excludedRecipeNames: regenerate ? [generatedDraft?.title ?? ""] : []
            )
            cancelGeneration()
            let requestID = UUID()
            activeRequestID = requestID
            isGenerating = true
            errorMessage = nil
            let task = Task { try await self.generateDraft(request) }
            generationTask = task

            do {
                let draft = try await task.value
                guard activeRequestID == requestID, !Task.isCancelled else { return false }
                generatedDraft = draft
                hasSavedCurrentDraft = false
                hasAddedCurrentDraftToPlan = false
                finishRequest(requestID)
                return true
            } catch is CancellationError {
                return false
            } catch {
                guard activeRequestID == requestID else { return false }
                // A failed request wrote nothing, so there is nothing to undo.
                // The draft on screen stays editable while a regeneration runs,
                // so restoring the copy taken before the await would silently
                // throw away whatever the member changed meanwhile.
                reportGenerationFailure(error)
                finishRequest(requestID)
                return false
            }
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func currentRecipe() throws -> Recipe {
        guard let generatedDraft else { throw AIGeneratorError.noDraft }
        return try generatedDraft.makeRecipe()
    }

    func save(into recipeStore: RecipeStore) throws -> Recipe {
        guard !hasSavedCurrentDraft else { throw AIGeneratorError.alreadySaved }
        let recipe = try currentRecipe()
        try recipeStore.saveUserRecipe(recipe)
        hasSavedCurrentDraft = true
        return recipe
    }

    func addToPlan(_ kitchenStore: KitchenStore, recipe: Recipe? = nil) throws -> Recipe {
        let recipe = try recipe ?? currentRecipe()
        // Explicit provenance: the user chose this headcount in the generator's
        // own stepper and the prompt wrote quantities for it, so it is a real
        // target for this plan rather than an inherited default.
        kitchenStore.addPlan(recipe: recipe, plannedServings: generatedDraft?.baseServings ?? servings)
        hasAddedCurrentDraftToPlan = true
        return recipe
    }

    func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        activeRequestID = nil
        isGenerating = false
    }

    private func makeRequest(
        inventory: [InventoryItem],
        excludedRecipeNames: [String]
    ) throws -> AIGenerateRecipeRequest {
        guard 1...12 ~= servings else { throw AIGeneratorError.invalidServings }
        let selected = inventory.filter {
            $0.isAvailable && selectedInventoryIDs.contains($0.id)
        }
        let selectedNames = selected.map(\.name)
        let custom = Self.splitIngredientText(customIngredientsText)
            .filter { customName in
                !selectedNames.contains { $0.caseInsensitiveCompare(customName) == .orderedSame }
            }
        let ingredients = Self.unique(selectedNames + custom)
        let cleanAdditional = additionalRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ingredients.isEmpty || !cleanAdditional.isEmpty else {
            throw AIGeneratorError.missingInput
        }
        let excludedIngredients = Self.splitIngredientText(excludedIngredientsText)
        let excludedNames = Set(excludedIngredients.map { $0.lowercased() })
        if !ingredients.isEmpty,
           ingredients.allSatisfy({ excludedNames.contains($0.lowercased()) }),
           cleanAdditional.isEmpty {
            throw AIGeneratorError.allIngredientsExcluded
        }

        return AIGenerateRecipeRequest(
            ingredients: ingredients,
            inventoryIngredients: selected.map {
                InventoryIngredientPayload(
                    name: $0.name,
                    quantity: $0.quantity,
                    unit: $0.unit,
                    remainingDays: $0.remainingDays
                )
            },
            servings: servings,
            flavors: selectedFlavors.sorted(),
            cuisine: cuisine == "不限" ? nil : cuisine,
            maxCookingTime: maxCookingTime,
            excludedIngredients: excludedIngredients,
            additionalRequest: cleanAdditional.isEmpty ? nil : cleanAdditional,
            excludedRecipeNames: excludedRecipeNames.filter { !$0.isEmpty }
        )
    }

    private func finishRequest(_ requestID: UUID) {
        guard activeRequestID == requestID else { return }
        isGenerating = false
        generationTask = nil
        activeRequestID = nil
    }

    private func reportGenerationFailure(_ error: Error) {
#if DEBUG
        print("[AIRecipeGenerator] \(error)")
#endif
        errorMessage = Self.generationErrorMessage(for: error)
    }

    /// What a failed recipe generation is allowed to say. Only errors written
    /// for a member speak for themselves; anything else becomes this flow's own
    /// sentence, so no URLSession text, HTTP body or decoding detail reaches
    /// the alert.
    ///
    /// Unlike the weekly menu, this flow really is about one 菜谱, so the chat
    /// client's own recipe wording is correct here. `unavailable` stays out:
    /// it is the catch-all for everything the client did not recognise, and
    /// the flow's own sentence tells the member more.
    static func generationErrorMessage(for error: Error) -> String {
        let fallback = "请稍后重试，或者调整食材和要求。"
        switch error {
        case let generator as AIGeneratorError:
            return generator.localizedDescription
        case let chat as AIChatServiceError:
            switch chat {
            case .rateLimited, .invalidResponse, .emptyResponse:
                return chat.localizedDescription
            case .unavailable:
                return fallback
            }
        default:
            return fallback
        }
    }

    private static func splitIngredientText(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: " ,，、\n\t")
        return unique(
            text.components(separatedBy: separators)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            seen.insert(value.lowercased()).inserted
        }
    }
}

#if DEBUG
/// A stand-in for the recipe generator's network call: waits long enough for a
/// UI test to read the waiting state and cancel it on purpose, honours
/// cancellation exactly like the real request, then answers with one recipe.
/// Selected by the `UITEST_AI_STUB_GENERATION` launch argument only;
/// production always wires `AIGeneratedRecipeService`.
enum AIRecipeGenerationFixture {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("UITEST_AI_STUB_GENERATION")
    }

    static func generate(_ request: AIGenerateRecipeRequest) async throws -> EditableRecipeDraft {
        // Long enough that a test can read the waiting state, type into the
        // draft underneath it and cancel on purpose without the request
        // finishing mid-assertion.
        try await Task.sleep(for: .seconds(30))
        return EditableRecipeDraft(
            title: "测试生成菜谱",
            baseServings: request.servings,
            ingredientsText: "鸡蛋\n番茄",
            stepsText: "鸡蛋打散备用\n番茄切块后与鸡蛋同炒"
        )
    }
}
#endif
