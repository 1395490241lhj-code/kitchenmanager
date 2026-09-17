#if DEBUG
import Foundation

actor UITestAIConversationTransport: AIConversationRuntimeTransport {
    nonisolated func stream(
        _ request: AIConversationRuntimeRequest
    ) -> AsyncThrowingStream<AIConversationStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("这是本地测试回复。"))
            continuation.yield(.completed(finishReason: "stop"))
            continuation.finish()
        }
    }
}
#endif
