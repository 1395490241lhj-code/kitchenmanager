import Foundation

struct LinkExtractResult {
    let title: String
    let text: String
    let rawJSON: String
    let recipe: AIParsedRecipe?
    let originalURL: String
    let canonicalURL: String
    let sourceTitle: String?
    let sourceAuthor: String?
    let warnings: [String]
    let usedTranscript: Bool
    let usedOCR: Bool
}

struct AIParseResponse: Decodable {
    let recipe: AIParsedRecipe?
    let content: String?
}

struct AIParsedRecipe: Decodable {
    let name: String
    let tags: [String]?
    let ingredients: [AIRecipeItem]?
    let seasonings: [AIRecipeItem]?
    let method: [String]?
    let warnings: [String]?

    enum CodingKeys: String, CodingKey {
        case name, title, tags, ingredients, seasonings, method, steps, warnings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name))
            ?? (try? container.decode(String.self, forKey: .title))
            ?? "未命名菜谱"
        tags = try? container.decode([String].self, forKey: .tags)
        ingredients = try? container.decode([AIRecipeItem].self, forKey: .ingredients)
        seasonings = try? container.decode([AIRecipeItem].self, forKey: .seasonings)
        method = (try? container.decode([String].self, forKey: .method))
            ?? (try? container.decode([String].self, forKey: .steps))
        warnings = try? container.decode([String].self, forKey: .warnings)
    }
}

struct AIRecipeItem: Decodable, Identifiable {
    let name: String
    let quantity: String?
    let unit: String?

    var id: String { [name, quantity ?? "", unit ?? ""].joined(separator: "|") }

    var displayText: String {
        [name, quantity, unit]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    enum CodingKeys: String, CodingKey {
        case name, item, quantity, qty, amount, unit
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let value = try? container.decode(String.self) {
            name = value
            quantity = nil
            unit = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name))
            ?? (try? container.decode(String.self, forKey: .item))
            ?? "未命名食材"
        quantity = (try? container.decode(String.self, forKey: .quantity))
            ?? (try? container.decode(String.self, forKey: .qty))
            ?? (try? container.decode(String.self, forKey: .amount))
        unit = try? container.decode(String.self, forKey: .unit)
    }
}

struct LinkExtractService {
    var apiClient: APIClient = .shared

    func extract(from input: String) async throws -> LinkExtractResult {
        let sourceURL = try Self.firstHTTPURL(in: input)
        let endpoint = try APIEndpoint.json(
            path: "/api/recipe-import-from-url",
            body: RecipeURLImportRequest(url: sourceURL.absoluteString),
            timeout: 210
        )

        let data: Data
        do {
            data = try await apiClient.sendRaw(endpoint)
        } catch let error as APIError {
            switch error {
            case .server(let status, let payload):
#if DEBUG
                print("[RecipeImport] status=\(status) code=\(payload?.code ?? "unknown") detail=\(payload?.detail ?? payload?.error ?? "")")
#endif
                throw LinkExtractError.server(
                    code: payload?.code ?? "unknown",
                    status: status
                )
            default:
                throw LinkExtractError.invalidResponse
            }
        }

        guard let responseBody = try? JSONDecoder().decode(RecipeURLImportResponse.self, from: data) else {
            throw LinkExtractError.invalidJSON
        }
        let recipe = responseBody.recipe ?? responseBody.decodedContentRecipe
        let diagnostics = responseBody.diagnostics
        let canonicalURL = diagnostics?.canonicalURL.nilIfBlank
            ?? diagnostics?.finalURL.nilIfBlank
            ?? sourceURL.absoluteString
        let warnings = Array(Set(
            (recipe?.warnings ?? [])
                + (diagnostics?.warnings ?? [])
                + (responseBody.mediaDiagnostics?.warnings ?? [])
        )).sorted()

        return LinkExtractResult(
            title: recipe?.name ?? diagnostics?.sourceTitle ?? "已读取菜谱来源",
            text: diagnostics?.cleanedTextPreview ?? "页面与媒体内容已完成整理。",
            rawJSON: "",
            recipe: recipe,
            originalURL: diagnostics?.url.nilIfBlank ?? sourceURL.absoluteString,
            canonicalURL: canonicalURL,
            sourceTitle: diagnostics?.sourceTitle?.nilIfBlank,
            sourceAuthor: diagnostics?.sourceAuthor?.nilIfBlank,
            warnings: warnings,
            usedTranscript: diagnostics?.hasTranscript == true,
            usedOCR: diagnostics?.hasOCRText == true
        )
    }

    static func firstHTTPURL(in input: String) throws -> URL {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LinkExtractError.emptyInput }
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in detector.matches(in: text, options: [], range: range) {
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { continue }
            return url
        }
        throw LinkExtractError.invalidURL
    }
}

enum LinkExtractError: LocalizedError {
    case emptyInput
    case invalidEndpoint
    case invalidURL
    case invalidResponse
    case invalidJSON
    case server(code: String, status: Int)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "请先粘贴小红书或网页链接。"
        case .invalidEndpoint:
            return "后端接口地址无效。"
        case .invalidURL:
            return "无法生成链接抓取请求。"
        case .invalidResponse:
            return "服务器返回了无效响应。"
        case .invalidJSON:
            return "服务器返回的数据无法识别。"
        case .server(let code, _):
            switch code {
            case "invalid_url", "missing_url", "blocked_url":
                return "这个链接无效或不受支持，请检查后重试。"
            case "fetch_failed", "link_extract_failed":
                return "暂时无法访问这个页面，请稍后重试。"
            case "login_required", "blocked_by_captcha":
                return "这个内容需要登录或通过平台验证，暂时无法直接读取。"
            case "video_download_failed":
                return "视频下载失败，可以重试或改用包含正文的链接。"
            case "video_too_large":
                return "视频文件过大，暂时无法导入。"
            case "asr_failed":
                return "视频语音识别失败，请稍后重试。"
            case "ocr_failed":
                return "视频字幕识别失败，请稍后重试。"
            case "media_recognition_failed":
                return "暂时无法识别视频中的语音和字幕。"
            case "recipe_json_failed", "ai_parse_error", "json_validate_failed":
                return "内容已经读取，但 AI 暂时无法整理成完整菜谱。"
            case "rate_limited", "rate_limit_exceeded":
                return "导入请求较多，请稍后再试。"
            case "no_recipe_text":
                return "没有读取到足够的菜谱内容，请换一个公开链接。"
            default:
                return "菜谱导入暂时失败，请稍后重试。"
            }
        }
    }
}

private struct RecipeURLImportRequest: Encodable {
    let url: String
}

private struct RecipeURLImportResponse: Decodable {
    let recipe: AIParsedRecipe?
    let content: String?
    let diagnostics: RecipeImportDiagnostics?
    let mediaDiagnostics: RecipeMediaDiagnostics?

    var decodedContentRecipe: AIParsedRecipe? {
        guard let content else { return nil }
        let cleaned = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
        guard let data = cleaned.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AIParsedRecipe.self, from: data)
    }
}

private struct RecipeImportDiagnostics: Decodable {
    let url: String
    let finalURL: String
    let canonicalURL: String
    let sourceTitle: String?
    let sourceAuthor: String?
    let cleanedTextPreview: String?
    let hasTranscript: Bool
    let hasOCRText: Bool
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case url, warnings, sourceTitle, sourceAuthor, cleanedTextPreview, hasTranscript
        case finalURL = "finalUrl"
        case canonicalURL = "canonicalUrl"
        case hasOCRText = "hasOcrText"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        finalURL = try container.decodeIfPresent(String.self, forKey: .finalURL) ?? ""
        canonicalURL = try container.decodeIfPresent(String.self, forKey: .canonicalURL) ?? ""
        sourceTitle = try container.decodeIfPresent(String.self, forKey: .sourceTitle)
        sourceAuthor = try container.decodeIfPresent(String.self, forKey: .sourceAuthor)
        cleanedTextPreview = try container.decodeIfPresent(String.self, forKey: .cleanedTextPreview)
        hasTranscript = try container.decodeIfPresent(Bool.self, forKey: .hasTranscript) ?? false
        hasOCRText = try container.decodeIfPresent(Bool.self, forKey: .hasOCRText) ?? false
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }
}

private struct RecipeMediaDiagnostics: Decodable {
    let warnings: [String]
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

struct AIRecipeParseService {
    var apiClient: APIClient = .shared

    func parse(text: String) async throws -> AIParsedRecipe {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw AIRecipeParseError.emptyText
        }

        let payload: [String: Any] = [
            "text": trimmedText,
            "sourceType": "xiaohongshu"
        ]
        let endpoint = APIEndpoint.raw(
            path: "/api/ai-parse",
            body: try JSONSerialization.data(withJSONObject: payload),
            timeout: 120
        )

        let data: Data
        do {
            data = try await apiClient.sendRaw(endpoint)
        } catch let error as APIError {
            switch error {
            case .server(let status, let payload):
                let message = payload?.error
                    ?? payload?.message
                    ?? "AI 解析失败，状态码：\(status)"
                throw AIRecipeParseError.server(message)
            default:
                throw AIRecipeParseError.invalidResponse
            }
        }

        let decoder = JSONDecoder()
        if let directRecipe = try? decoder.decode(AIParsedRecipe.self, from: data) {
            return directRecipe
        }

        let responseBody = try decoder.decode(AIParseResponse.self, from: data)

        if let recipe = responseBody.recipe {
            return recipe
        }

        if let content = responseBody.content {
            let cleanedContent = content
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let contentData = cleanedContent.data(using: .utf8),
               let recipe = try? decoder.decode(AIParsedRecipe.self, from: contentData) {
                return recipe
            }
        }

        throw AIRecipeParseError.missingRecipe
    }
}

enum AIRecipeParseError: LocalizedError {
    case emptyText
    case invalidResponse
    case missingRecipe
    case server(String)

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "没有可供 AI 整理的菜谱内容。"
        case .invalidResponse:
            return "AI 服务返回了无效响应。"
        case .missingRecipe:
            return "AI 返回的数据中没有可识别的菜谱。"
        case .server(let message):
            return message
        }
    }
}
