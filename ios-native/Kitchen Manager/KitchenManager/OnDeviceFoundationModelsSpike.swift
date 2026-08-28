#if DEBUG
import Foundation
import FoundationModels
import SwiftUI

@Generable
private struct FoundationModelsSpikeResponse {
    @Guide(description: "推荐 2 到 3 道菜", .count(2...3))
    var recipes: [FoundationModelsSpikeRecipe]
}

@Generable
private struct FoundationModelsSpikeRecipe {
    @Guide(description: "简短菜名")
    var name: String

    @Guide(description: "这道菜会使用的现有库存食材")
    var existingIngredients: [String]

    @Guide(description: "库存中没有、需要另备的食材；不缺则为空数组")
    var missingIngredients: [String]

    @Guide(description: "一句简短推荐理由")
    var reason: String
}

private struct FoundationModelsSpikeBenchmarkCase: Identifiable {
    let id: String
    let title: String
    let inventory: [String]
    let expiring: [String]
    let dietaryRestriction: String?
    let focus: String
    let offlineCandidate: Bool
}

private struct FoundationModelsSpikeValidatedRecipe {
    let name: String
    let existingIngredients: [String]
    let missingIngredients: [String]
    let reason: String
}

private struct FoundationModelsSpikeValidation {
    let recipes: [FoundationModelsSpikeValidatedRecipe]
    let validRawClaims: Int
    let rawClaims: Int
    let removedUsed: [String]
    let removedMissing: [String]
    let expiringUsed: Int
    let expiringCount: Int

    var summary: String {
        let correctness = rawClaims == 0 ? "n/a" : "\(validRawClaims)/\(rawClaims)"
        return "raw 库存判断正确 \(correctness)；移除错误 used：\(Self.list(removedUsed))；移除错误 missing：\(Self.list(removedMissing))；覆盖临期 \(expiringUsed)/\(expiringCount)"
    }

    private static func list(_ values: [String]) -> String {
        values.isEmpty ? "无" : values.joined(separator: "、")
    }
}

private struct FoundationModelsSpikeRun {
    var appleRaw = "尚未运行"
    var appleValidated = "尚未运行"
    var appleValidation = "尚未运行"
    var appleLatency: TimeInterval?
    var geminiOutput = "尚未运行"
    var geminiLatency: TimeInterval?
}

struct OnDeviceFoundationModelsSpikeView: View {
    private static let cases: [FoundationModelsSpikeBenchmarkCase] = [
        .init(
            id: "01-simple",
            title: "1. 简单家常库存",
            inventory: ["鸡蛋 6 个", "番茄 4 个", "嫩豆腐 1 盒", "青椒 2 个", "米饭", "蒜", "生抽"],
            expiring: ["番茄", "嫩豆腐"],
            dietaryRestriction: nil,
            focus: "推荐普通家常菜。",
            offlineCandidate: false
        ),
        .init(
            id: "02-expiring",
            title: "2. 多个临期食材",
            inventory: ["鸡腿 4 个", "香菇 1 盒", "菠菜 1 把", "胡萝卜 3 根", "姜", "蒜", "米饭", "生抽"],
            expiring: ["鸡腿", "香菇", "菠菜"],
            dietaryRestriction: nil,
            focus: "尽量在推荐中覆盖多个临期食材。",
            offlineCandidate: false
        ),
        .init(
            id: "03-key-missing",
            title: "3. 缺少关键食材",
            inventory: ["意大利面 1 包", "番茄 3 个", "洋葱 1 个", "蒜", "橄榄油"],
            expiring: ["番茄"],
            dietaryRestriction: nil,
            focus: "至少一道菜可以合理需要 1–2 样库存外的关键食材，并准确列为缺少。",
            offlineCandidate: false
        ),
        .init(
            id: "04-large",
            title: "4. 较多库存（39 项）",
            inventory: [
                "鸡蛋", "番茄", "嫩豆腐", "青椒", "鸡腿", "猪肉", "牛肉", "虾仁", "三文鱼", "白菜",
                "菠菜", "西兰花", "胡萝卜", "土豆", "洋葱", "香菇", "黄瓜", "茄子", "西葫芦", "玉米",
                "豌豆", "牛奶", "原味酸奶", "奶酪", "米饭", "面条", "意大利面", "面包", "燕麦片", "面粉",
                "蒜", "姜", "葱", "生抽", "醋", "盐", "糖", "食用油", "香油"
            ],
            expiring: ["三文鱼", "菠菜", "原味酸奶", "茄子"],
            dietaryRestriction: nil,
            focus: "从较多库存中做出克制、合理的组合，不必用完全部食材。",
            offlineCandidate: false
        ),
        .init(
            id: "05-awkward",
            title: "5. 不容易组合的库存",
            inventory: ["原味酸奶", "海苔", "苹果", "金枪鱼罐头", "冷冻豌豆", "燕麦片", "鸡蛋", "生抽"],
            expiring: ["原味酸奶", "苹果"],
            dietaryRestriction: nil,
            focus: "不要为了凑菜而制造不合理组合，可以把早餐或轻食作为一道推荐。",
            offlineCandidate: false
        ),
        .init(
            id: "06-vegan",
            title: "6. 饮食限制（纯素）",
            inventory: ["嫩豆腐", "西兰花", "鸡蛋", "牛奶", "蘑菇", "米饭", "蒜", "生抽"],
            expiring: ["嫩豆腐", "蘑菇"],
            dietaryRestriction: "纯素：不得使用鸡蛋、牛奶或任何动物性食材",
            focus: "库存里即使存在不符合限制的食材，也不得推荐使用。",
            offlineCandidate: false
        ),
        .init(
            id: "07-balanced",
            title: "7. 主食 + 蛋白质 + 蔬菜",
            inventory: ["米饭", "鸡胸肉", "西兰花", "胡萝卜", "鸡蛋", "蒜", "姜", "生抽"],
            expiring: ["鸡胸肉", "西兰花"],
            dietaryRestriction: nil,
            focus: "优先给出包含主食、蛋白质和蔬菜的完整一餐。",
            offlineCandidate: false
        ),
        .init(
            id: "08-offline",
            title: "8. 完全离线候选",
            inventory: ["土豆", "鹰嘴豆罐头", "白菜", "柠檬", "面包", "芝麻酱", "蒜", "盐"],
            expiring: ["白菜", "柠檬"],
            dietaryRestriction: nil,
            focus: "给出适合这些库存的简单做法；此 case 会额外在飞行模式复测 Apple Local。",
            offlineCandidate: true
        )
    ]

    @State private var selectedCaseID = Self.cases[0].id
    @State private var availability = "尚未读取"
    @State private var isAvailable = false
    @State private var contextSize: Int?
    @State private var cloudProvider = "尚未读取"
    @State private var runs: [String: FoundationModelsSpikeRun] = [:]
    @State private var isRunningApple = false
    @State private var isRunningCloud = false
    @State private var isRunningBatch = false

    var body: some View {
        List {
            Section("模型状态") {
                LabeledContent("availability", value: availability)
                LabeledContent("isAvailable", value: isAvailable ? "true" : "false")
                LabeledContent("contextSize", value: contextSize.map(String.init) ?? "当前 SDK 不支持")
                LabeledContent("当前 cloud provider", value: cloudProvider)
            }

            Section("Benchmark case") {
                Picker("用例", selection: $selectedCaseID) {
                    ForEach(Self.cases) { benchmarkCase in
                        Text(benchmarkCase.title).tag(benchmarkCase.id)
                    }
                }
                LabeledContent("库存", value: selectedCase.inventory.joined(separator: "、"))
                LabeledContent("临期", value: selectedCase.expiring.joined(separator: "、"))
                if let restriction = selectedCase.dietaryRestriction {
                    LabeledContent("饮食限制", value: restriction)
                }
                if selectedCase.offlineCandidate {
                    Text("完成在线 batch 后，开启飞行模式并单独重跑此 case。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("运行") {
                Button("运行所选 Apple Local", systemImage: "iphone") {
                    Task { await runApple(for: selectedCase) }
                }
                .disabled(isBusy || !isAvailable)

                Button("运行所选 Gemini", systemImage: "cloud") {
                    Task {
                        await refreshCloudProvider()
                        await runGemini(for: selectedCase)
                    }
                }
                .disabled(isBusy)

                Button("运行全部在线 Benchmark", systemImage: "play.fill") {
                    Task { await runOnlineBenchmark() }
                }
                .disabled(isBusy || !isAvailable)

                if isBusy { ProgressView() }
            }

            Section("Apple Local raw") {
                if let latency = selectedRun.appleLatency {
                    LabeledContent("延迟", value: milliseconds(latency))
                }
                Text(selectedRun.appleRaw).textSelection(.enabled)
            }

            Section("Apple Local + deterministic validation") {
                Text(selectedRun.appleValidation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(selectedRun.appleValidated).textSelection(.enabled)
            }

            Section("Gemini") {
                if let latency = selectedRun.geminiLatency {
                    LabeledContent("延迟", value: milliseconds(latency))
                }
                Text(selectedRun.geminiOutput).textSelection(.enabled)
            }
        }
        .navigationTitle("Foundation Models Phase 2")
        .task {
            Self.validationSelfCheck()
            refreshAvailability()
            await refreshCloudProvider()
        }
    }

    private var selectedCase: FoundationModelsSpikeBenchmarkCase {
        Self.cases.first { $0.id == selectedCaseID } ?? Self.cases[0]
    }

    private var selectedRun: FoundationModelsSpikeRun {
        runs[selectedCaseID] ?? FoundationModelsSpikeRun()
    }

    private var isBusy: Bool {
        isRunningApple || isRunningCloud || isRunningBatch
    }

    private func scenarioPrompt(for benchmarkCase: FoundationModelsSpikeBenchmarkCase) -> String {
        let restriction = benchmarkCase.dietaryRestriction.map { "\n饮食限制：\($0)。" } ?? ""
        return """
        当前库存：\(benchmarkCase.inventory.joined(separator: "、"))。
        临期食材：\(benchmarkCase.expiring.joined(separator: "、"))。\(restriction)
        推荐 2–3 道真实、合理的菜。每道菜必须列出会使用哪些现有库存食材、还缺什么食材，以及一句简短理由。优先使用临期食材，不要把库存中没有的食材说成已有。\(benchmarkCase.focus)
        """
    }

    private func refreshAvailability() {
        let model = SystemLanguageModel.default
        availability = Self.availabilityText(model.availability)
        isAvailable = model.isAvailable
        contextSize = model.contextSize
        print("[FoundationModelsSpike] availability=\(availability) isAvailable=\(isAvailable) contextSize=\(model.contextSize)")
    }

    private func runOnlineBenchmark() async {
        isRunningBatch = true
        defer { isRunningBatch = false }
        await refreshCloudProvider()
        guard cloudProvider == "gemini" else {
            print("[FoundationModelsSpike] online benchmark stopped: current provider=\(cloudProvider)")
            return
        }
        for benchmarkCase in Self.cases {
            selectedCaseID = benchmarkCase.id
            await runApple(for: benchmarkCase)
            await runGemini(for: benchmarkCase)
        }
        print("[FoundationModelsSpike] online benchmark complete")
    }

    private func runApple(for benchmarkCase: FoundationModelsSpikeBenchmarkCase) async {
        refreshAvailability()
        guard isAvailable else {
            updateRun(benchmarkCase.id) { $0.appleRaw = "未运行：\(availability)" }
            return
        }

        isRunningApple = true
        defer { isRunningApple = false }
        let started = Date()
        do {
            let session = LanguageModelSession(
                model: .default,
                instructions: "你是 Kitchen Manager 的本地菜谱推荐助手。严格依据用户给出的库存和饮食限制，不执行任何网络请求。"
            )
            let response = try await session.respond(
                to: scenarioPrompt(for: benchmarkCase),
                generating: FoundationModelsSpikeResponse.self
            )
            let elapsed = Date().timeIntervalSince(started)
            let raw = Self.text(response.content.recipes)
            let validation = Self.validate(response.content, for: benchmarkCase)
            let validated = Self.text(validation.recipes)
            updateRun(benchmarkCase.id) {
                $0.appleRaw = raw
                $0.appleValidated = validated
                $0.appleValidation = validation.summary
                $0.appleLatency = elapsed
            }
            print("[FoundationModelsSpike][\(benchmarkCase.id)][Apple raw][\(milliseconds(elapsed))]\n\(raw)")
            print("[FoundationModelsSpike][\(benchmarkCase.id)][Apple validated] \(validation.summary)\n\(validated)")
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            updateRun(benchmarkCase.id) {
                $0.appleRaw = "其他错误：\(error.localizedDescription)"
                $0.appleLatency = elapsed
            }
            print("[FoundationModelsSpike][\(benchmarkCase.id)] Apple failed after \(milliseconds(elapsed)): \(error)")
        }
    }

    private func refreshCloudProvider() async {
        do {
            let data = try await APIClient.shared.sendRaw(.get(path: "/api/ai-status", timeout: 15))
            let status = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            cloudProvider = status?["chatProvider"] as? String ?? "未知"
        } catch {
            cloudProvider = "读取失败"
            print("[FoundationModelsSpike] provider status failed: \(error)")
        }
    }

    private func runGemini(for benchmarkCase: FoundationModelsSpikeBenchmarkCase) async {
        guard cloudProvider == "gemini" else {
            updateRun(benchmarkCase.id) {
                $0.geminiOutput = "未运行：当前默认 provider 是 \(cloudProvider)，spike 不修改 provider 默认值。"
            }
            return
        }

        isRunningCloud = true
        defer { isRunningCloud = false }
        let started = Date()
        do {
            let result = try await AIChatService().requestDetailed(
                prompt: scenarioPrompt(for: benchmarkCase),
                taskType: "foundation-models-phase2-benchmark",
                timeout: 50
            )
            let elapsed = Date().timeIntervalSince(started)
            updateRun(benchmarkCase.id) {
                $0.geminiOutput = result.content
                $0.geminiLatency = elapsed
            }
            print("[FoundationModelsSpike][\(benchmarkCase.id)][Gemini][\(milliseconds(elapsed))]\n\(result.content)")
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            updateRun(benchmarkCase.id) {
                $0.geminiOutput = "请求失败：\(error.localizedDescription)"
                $0.geminiLatency = elapsed
            }
            print("[FoundationModelsSpike][\(benchmarkCase.id)] Gemini failed after \(milliseconds(elapsed)): \(error)")
        }
    }

    private func updateRun(_ id: String, _ update: (inout FoundationModelsSpikeRun) -> Void) {
        var run = runs[id] ?? FoundationModelsSpikeRun()
        update(&run)
        runs[id] = run
    }

    private func milliseconds(_ interval: TimeInterval) -> String {
        "\(Int(interval * 1_000)) ms"
    }

    private static func validate(
        _ response: FoundationModelsSpikeResponse,
        for benchmarkCase: FoundationModelsSpikeBenchmarkCase
    ) -> FoundationModelsSpikeValidation {
        let inventoryKeys = Set(benchmarkCase.inventory.map(ingredientKey).filter { !$0.isEmpty })
        let expiringKeys = Set(benchmarkCase.expiring.map(ingredientKey).filter { !$0.isEmpty })
        var validRawClaims = 0
        var rawClaims = 0
        var removedUsed: [String] = []
        var removedMissing: [String] = []
        var usedKeys = Set<String>()

        let recipes = response.recipes.map { recipe in
            rawClaims += recipe.existingIngredients.count + recipe.missingIngredients.count
            validRawClaims += recipe.existingIngredients.filter { inventoryKeys.contains(ingredientKey($0)) }.count
            validRawClaims += recipe.missingIngredients.filter { !inventoryKeys.contains(ingredientKey($0)) }.count

            let existing = filteredClaims(recipe.existingIngredients, inventoryKeys: inventoryKeys, mustExist: true)
            let missing = filteredClaims(recipe.missingIngredients, inventoryKeys: inventoryKeys, mustExist: false)
            removedUsed += recipe.existingIngredients.filter { !inventoryKeys.contains(ingredientKey($0)) }
            removedMissing += recipe.missingIngredients.filter { inventoryKeys.contains(ingredientKey($0)) }
            usedKeys.formUnion(existing.map(ingredientKey))
            return FoundationModelsSpikeValidatedRecipe(
                name: recipe.name,
                existingIngredients: existing,
                missingIngredients: missing,
                reason: recipe.reason
            )
        }

        return FoundationModelsSpikeValidation(
            recipes: recipes,
            validRawClaims: validRawClaims,
            rawClaims: rawClaims,
            removedUsed: unique(removedUsed),
            removedMissing: unique(removedMissing),
            expiringUsed: usedKeys.intersection(expiringKeys).count,
            expiringCount: expiringKeys.count
        )
    }

    private static func filteredClaims(
        _ values: [String],
        inventoryKeys: Set<String>,
        mustExist: Bool
    ) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            let key = ingredientKey(value)
            return !key.isEmpty
                && inventoryKeys.contains(key) == mustExist
                && seen.insert(key).inserted
        }
    }

    private static func ingredientKey(_ value: String) -> String {
        IngredientNormalizer.matchKey(IngredientParser.parse(value).displayName)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert(ingredientKey($0)).inserted }
    }

    private static func validationSelfCheck() {
        let inventoryKeys = Set(["番茄 4 个", "蒜"].map(ingredientKey))
        assert(filteredClaims(["番茄", "牛肉"], inventoryKeys: inventoryKeys, mustExist: true) == ["番茄"])
        assert(filteredClaims(["蒜", "盐"], inventoryKeys: inventoryKeys, mustExist: false) == ["盐"])
    }

    private static func availabilityText(_ availability: SystemLanguageModel.Availability) -> String {
        switch availability {
        case .available:
            "available"
        case .unavailable(.appleIntelligenceNotEnabled):
            "unavailable: Apple Intelligence 未开启"
        case .unavailable(.modelNotReady):
            "unavailable: model not ready"
        case .unavailable(.deviceNotEligible):
            "unavailable: device not eligible"
        case .unavailable:
            "unavailable: 其他原因"
        }
    }

    private static func text(_ recipes: [FoundationModelsSpikeRecipe]) -> String {
        recipes.enumerated().map { index, recipe in
            recipeText(
                index: index,
                name: recipe.name,
                existingIngredients: recipe.existingIngredients,
                missingIngredients: recipe.missingIngredients,
                reason: recipe.reason
            )
        }.joined(separator: "\n\n")
    }

    private static func text(_ recipes: [FoundationModelsSpikeValidatedRecipe]) -> String {
        recipes.enumerated().map { index, recipe in
            recipeText(
                index: index,
                name: recipe.name,
                existingIngredients: recipe.existingIngredients,
                missingIngredients: recipe.missingIngredients,
                reason: recipe.reason
            )
        }.joined(separator: "\n\n")
    }

    private static func recipeText(
        index: Int,
        name: String,
        existingIngredients: [String],
        missingIngredients: [String],
        reason: String
    ) -> String {
        """
        \(index + 1). \(name)
        现有食材：\(existingIngredients.isEmpty ? "无" : existingIngredients.joined(separator: "、"))
        还缺：\(missingIngredients.isEmpty ? "无" : missingIngredients.joined(separator: "、"))
        理由：\(reason)
        """
    }
}
#endif
