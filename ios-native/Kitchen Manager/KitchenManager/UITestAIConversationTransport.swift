#if DEBUG
import Foundation

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
        let args = ProcessInfo.processInfo.arguments

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
