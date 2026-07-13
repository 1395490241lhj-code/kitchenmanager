import Foundation

enum RecipeLibraryMode: String, CaseIterable, Identifiable {
    case curated
    case full

    var id: String { rawValue }
    var title: String { self == .curated ? "精简日常菜谱库" : "完整菜谱库" }
    var filename: String { self == .curated ? "sichuan-recipes.curated.json" : "sichuan-recipes.json" }
}

struct RecipePackResponse: Decodable {
    let recipes: [RemoteRecipe]
    let recipeIngredients: [String: [RemoteIngredient]]

    enum CodingKeys: String, CodingKey {
        case recipes
        case recipeIngredients = "recipe_ingredients"
    }
}

struct RemoteRecipe: Decodable {
    let id: String
    let name: String
    let method: String?
    let tags: [String]?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case title
        case method
        case steps
        case tags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )

        if let stringID = try? container.decode(
            String.self,
            forKey: .id
        ) {
            id = stringID
        } else if let integerID = try? container.decode(
            Int.self,
            forKey: .id
        ) {
            id = String(integerID)
        } else {
            id = UUID().uuidString
        }

        name =
            (try? container.decode(String.self, forKey: .name))
            ?? (try? container.decode(String.self, forKey: .title))
            ?? "未命名菜谱"

        if let text = try? container.decode(
            String.self,
            forKey: .method
        ) {
            method = text
        } else if let steps = try? container.decode(
            [String].self,
            forKey: .steps
        ) {
            method = steps.joined(separator: "\n")
        } else {
            method = nil
        }

        tags = try? container.decode(
            [String].self,
            forKey: .tags
        )
    }
}

struct RemoteIngredient: Decodable {
    let item: String
    let qty: String?
    let unit: String?

    enum CodingKeys: String, CodingKey {
        case item
        case name
        case qty
        case quantity
        case unit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )

        item =
            (try? container.decode(String.self, forKey: .item))
            ?? (try? container.decode(String.self, forKey: .name))
            ?? "未知食材"

        qty =
            (try? container.decode(String.self, forKey: .qty))
            ?? (try? container.decode(String.self, forKey: .quantity))

        unit = try? container.decode(
            String.self,
            forKey: .unit
        )
    }
}

struct RecipeService {
    var apiClient: APIClient = .shared

    func fetchRecipes(mode: RecipeLibraryMode = .curated) async throws -> [Recipe] {
        let endpoint = APIEndpoint.get(
            path: "data/\(mode.filename)",
            timeout: 60
        )

        let data: Data
        do {
            data = try await apiClient.sendRaw(endpoint)
        } catch let error as APIError {
            switch error {
            case .server(let status, _), .httpStatus(let status):
                throw RecipeAPIError.httpStatus(status)
            default:
                throw RecipeAPIError.invalidResponse
            }
        }

        let pack: RecipePackResponse

        do {
            pack = try JSONDecoder().decode(
                RecipePackResponse.self,
                from: data
            )
        } catch {
            throw RecipeAPIError.decoding(error)
        }

        let recipes = pack.recipes.map { remoteRecipe in
            let remoteIngredients =
                pack.recipeIngredients[remoteRecipe.id] ?? []

            let ingredients = remoteIngredients.map {
                ingredient in

                let quantity = [
                    ingredient.qty,
                    ingredient.unit
                ]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")

                return quantity.isEmpty
                    ? ingredient.item
                    : "\(ingredient.item) \(quantity)"
            }

            let classified = RecipeIngredientClassifier.classify(
                ingredients,
                recipeTitle: remoteRecipe.name
            )
            return Recipe(
                id: remoteRecipe.id,
                title: remoteRecipe.name,
                cookingTime: nil,
                difficulty: nil,
                tags: remoteRecipe.tags ?? [],
                ingredients: classified.ingredients,
                seasonings: classified.seasonings,
                steps: splitMethod(remoteRecipe.method)
            )
        }

        guard !recipes.isEmpty else {
            throw RecipeAPIError.emptyData
        }

        return recipes
    }

    private func splitMethod(_ method: String?) -> [String] {
        guard let method else {
            return ["该菜谱暂时没有详细步骤。"]
        }

        let trimmed = method.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !trimmed.isEmpty else {
            return ["该菜谱暂时没有详细步骤。"]
        }

        let newlineSteps = trimmed
            .components(separatedBy: .newlines)
            .map(cleanStep)
            .filter { !$0.isEmpty }

        if newlineSteps.count > 1 {
            return newlineSteps
        }

        let sentenceSteps = trimmed
            .components(
                separatedBy: CharacterSet(
                    charactersIn: "。；;"
                )
            )
            .map(cleanStep)
            .filter { !$0.isEmpty }

        return sentenceSteps.isEmpty ? [trimmed] : sentenceSteps
    }

    private func cleanStep(_ step: String) -> String {
        step
            .replacingOccurrences(
                of: #"^\s*\d+\s*[\.、\)]\s*"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum RecipeAPIError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case emptyData
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器返回了无效响应。"

        case .httpStatus(let statusCode):
            return "服务器请求失败，状态码：\(statusCode)。"

        case .emptyData:
            return "服务器返回的菜谱列表为空。"

        case .decoding(let error):
            return "菜谱解析失败：\(error.localizedDescription)"
        }
    }
}
