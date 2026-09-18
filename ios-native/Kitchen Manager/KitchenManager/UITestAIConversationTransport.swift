#if DEBUG
import Foundation
import Combine

@MainActor
final class UITestConversationObservation: ObservableObject {
    static let shared = UITestConversationObservation()
    @Published var requests = 0
}

actor UITestAIConversationTransport: AIConversationRuntimeTransport {
    private var requestCount = 0

    nonisolated func stream(
        _ request: AIConversationRuntimeRequest
    ) -> AsyncThrowingStream<AIConversationStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.handleStream(request: request, continuation: continuation)
            }
        }
    }

    private func handleStream(
        request: AIConversationRuntimeRequest,
        continuation: AsyncThrowingStream<AIConversationStreamEvent, Error>.Continuation
    ) async {
        requestCount += 1
        await MainActor.run { UITestConversationObservation.shared.requests += 1 }
        let args = ProcessInfo.processInfo.arguments
        if AIConversationAcceptanceFixture.scenario == "D" {
            let planID = AIConversationAcceptanceFixture.specialPlanID.uuidString
            if let result = request.messages.last(where: {
                $0.role == .tool && $0.toolCallID == "acceptance-d-special"
            })?.content {
                let ids = AIConversationAcceptanceFixture.spicyDishIDs.map(\.uuidString)
                if ids.allSatisfy({ result.contains($0) }) && result.contains("麻辣豆腐") && result.contains("辣子鸡") {
                    let arguments = """
                    {"planID":"\(planID)","changes":[{"dishID":"\(ids[0])","replacement":{"recipeID":"acceptance-tofu","title":"清蒸豆腐"}},{"dishID":"\(ids[1])","replacement":{"recipeID":"acceptance-spinach","title":"清炒菠菜"}}]}
                    """
                    continuation.yield(.toolCall(id: "acceptance-d-replace", name: "propose_special_plan_changes", arguments: Data(arguments.utf8)))
                }
            } else if let result = request.messages.last(where: {
                $0.role == .tool && $0.toolCallID == "acceptance-d-week"
            })?.content, result.contains(planID) {
                continuation.yield(.toolCall(id: "acceptance-d-special", name: "read_special_plan", arguments: Data("{\"planID\":\"\(planID)\"}".utf8)))
            } else {
                let transcript = request.messages.compactMap(\.content).joined(separator: "\n")
                let pattern = #""weekStart"\s*:\s*"([0-9]{4}-[0-9]{2}-[0-9]{2})"#
                if let range = transcript.range(of: pattern, options: .regularExpression),
                   let dateRange = transcript[range].range(of: #"[0-9]{4}-[0-9]{2}-[0-9]{2}"#, options: .regularExpression) {
                    continuation.yield(.toolCall(id: "acceptance-d-week", name: "read_planner_week", arguments: Data("{\"weekStart\":\"\(transcript[dateRange])\"}".utf8)))
                }
            }
            continuation.yield(.completed(finishReason: "stop"))
            continuation.finish()
            return
        }
        if AIConversationAcceptanceFixture.scenario == "C" {
            if let result = request.messages.last(where: {
                $0.role == .tool && $0.toolCallID == "acceptance-c-inventory"
            })?.content {
                let json = (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any]
                let available = (json?["available"] as? [[String: Any]]) ?? []
                let hasFreshSpinach = available.contains(where: {
                    ($0["name"] as? String) == "新鲜菠菜"
                        && ($0["quantity"] as? Double) == 2.0
                        && ($0["unit"] as? String) == "把"
                })
                let hasOldPotato = available.contains(where: {
                    let name = ($0["name"] as? String) ?? ""
                    return name.contains("旧土豆") || name.contains("土豆")
                })
                if hasFreshSpinach && !hasOldPotato {
                    continuation.yield(.textDelta("当前库存有新鲜菠菜 2 把。"))
                }
            } else {
                continuation.yield(.toolCall(id: "acceptance-c-inventory", name: "read_inventory", arguments: Data("{}".utf8)))
            }
            continuation.yield(.completed(finishReason: "stop"))
            continuation.finish()
            return
        }
        if AIConversationAcceptanceFixture.scenario == "B" {
            if let result = request.messages.last(where: {
                $0.role == .tool && $0.toolCallID == "acceptance-b-week"
            })?.content, result.contains(AIConversationAcceptanceFixture.mealID.uuidString), result.contains("香辣鸡丁") {
                let arguments = """
                {"planID":"\(AIConversationAcceptanceFixture.mealID.uuidString)","replacement":{"recipeID":"acceptance-tofu","title":"清蒸豆腐"}}
                """
                continuation.yield(.toolCall(id: "acceptance-b-replace", name: "propose_replace_planned_meal", arguments: Data(arguments.utf8)))
            } else {
                let pattern = #""weekStart"\s*:\s*"([0-9]{4}-[0-9]{2}-[0-9]{2})"#
                let transcript = request.messages.compactMap(\.content).joined(separator: "\n")
                guard let range = transcript.range(of: pattern, options: .regularExpression),
                      let dateRange = transcript[range].range(of: #"[0-9]{4}-[0-9]{2}-[0-9]{2}"#, options: .regularExpression) else {
                    continuation.finish()
                    return
                }
                let arguments = "{\"weekStart\":\"\(transcript[dateRange])\"}"
                continuation.yield(.toolCall(id: "acceptance-b-week", name: "read_planner_week", arguments: Data(arguments.utf8)))
            }
            continuation.yield(.completed(finishReason: "stop"))
            continuation.finish()
            return
        }
        if AIConversationAcceptanceFixture.scenario == "A" {
            let content = request.messages.last(where: { $0.role == .user })?.content ?? ""
            let user = (try? JSONDecoder().decode([String: String].self, from: Data(content.utf8)))?["message"] ?? content
            if user == "第二个加入今晚。" {
                continuation.yield(.toolCall(id: "acceptance-a-add", name: "propose_add_recipe_to_tonight",
                    arguments: Data(#"{"recipe":{"recipeID":"acceptance-tofu","title":"清蒸豆腐"}}"#.utf8)))
            } else if let result = request.messages.last(where: {
                $0.role == .tool && $0.toolCallID == "acceptance-a-inventory"
            })?.content, result.contains("新鲜菠菜") {
                continuation.yield(.toolCall(id: "acceptance-a-first", name: "present_recipe_card",
                    arguments: Data(#"{"recipe":{"recipeID":"acceptance-spinach","title":"清炒菠菜"}}"#.utf8)))
                continuation.yield(.toolCall(id: "acceptance-a-second", name: "present_recipe_card",
                    arguments: Data(#"{"recipe":{"recipeID":"acceptance-tofu","title":"清蒸豆腐"}}"#.utf8)))
            } else {
                continuation.yield(.toolCall(id: "acceptance-a-inventory", name: "read_inventory", arguments: Data("{}".utf8)))
            }
            continuation.yield(.completed(finishReason: "stop"))
            continuation.finish()
            return
        }

        if args.contains("UITEST_AI_CONVERSATION_SCRIPT_STREAM_STOP") {
            continuation.yield(.textDelta("正在逐步为您生成长篇建议第一部分内容…"))
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled {
                continuation.finish()
                return
            }
            continuation.yield(.textDelta("第二部分内容。"))
            continuation.yield(.completed(finishReason: "stop"))
            continuation.finish()
            return
        }

        if args.contains("UITEST_AI_CONVERSATION_SCRIPT_LONG_STREAM") {
            var longText = "为您详细规划整周备餐与制作流程：\n\n"
            for i in 1...14 {
                longText += "步骤 \(i)：准备当日所需主料与副料，进行必要清洗与改刀分类存放，保持台面整洁高效。\n\n"
            }
            continuation.yield(.textDelta(longText))
            try? await Task.sleep(nanoseconds: 300_000_000)
            continuation.yield(.textDelta("【长文本结尾标记：TAIL_MARKER_LONG_STREAM_ACTIVE】全部步骤规划完毕。"))
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled {
                continuation.finish()
                return
            }
            continuation.yield(.completed(finishReason: "stop"))
            continuation.finish()
            return
        }

        if args.contains("UITEST_AI_CONVERSATION_SCRIPT_ERROR") {
            if requestCount == 1 {
                continuation.yield(.error(code: "service_unavailable", message: "暂时无法连接服务，请重试。"))
                continuation.finish()
                return
            } else {
                continuation.yield(.textDelta("重试成功，已为您生成回复。"))
                continuation.yield(.completed(finishReason: "stop"))
                continuation.finish()
                return
            }
        }

        if args.contains("UITEST_AI_CONVERSATION_SCRIPT_TWO_RECIPES") {
            continuation.yield(.textDelta("为您挑选了以下两道菜：\n"))
            let rec1Args = """
            {"recipe":{"recipeID":"rec-garlic-greens","title":"蒜蓉上海青","reason":"今晚快速做菜"}}
            """
            let rec2Args = """
            {"recipe":{"title":"家常豆腐","ingredients":[{"item":"北豆腐","qty":"1","unit":"块"}],"steps":["煎豆腐","调味"],"reason":"高蛋白家常菜"}}
            """
            continuation.yield(.toolCall(id: "c-rec-1", name: "present_recipe_card", arguments: Data(rec1Args.utf8)))
            continuation.yield(.toolCall(id: "c-rec-2", name: "present_recipe_card", arguments: Data(rec2Args.utf8)))
            continuation.yield(.completed(finishReason: "stop"))
            continuation.finish()
            return
        }

        if args.contains("UITEST_AI_CONVERSATION_SCRIPT_PLANNER_PREVIEW") {
            var targetPlanID = "99999999-9999-9999-9999-999999999999"
            for msg in request.messages {
                if let content = msg.content,
                   let regex = try? NSRegularExpression(pattern: #""planID":"([0-9a-fA-F-]+)""#),
                   let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
                   let range = Range(match.range(at: 1), in: content) {
                    targetPlanID = String(content[range])
                    break
                }
            }

            continuation.yield(.textDelta("为您准备了以下计划修改：\n"))
            let planArgs = """
            {"planID":"\(targetPlanID)","replacement":{"title":"清蒸鲈鱼","ingredients":[{"item":"鲈鱼"}],"steps":["蒸鱼"]}}
            """
            continuation.yield(.toolCall(id: "c-plan-1", name: "propose_replace_planned_meal", arguments: Data(planArgs.utf8)))
            continuation.yield(.completed(finishReason: "stop"))
            continuation.finish()
            return
        }

        // Default text reply
        continuation.yield(.textDelta("这是本地测试回复。"))
        continuation.yield(.completed(finishReason: "stop"))
        continuation.finish()
    }
}
#endif
