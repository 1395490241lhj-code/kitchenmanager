import XCTest
@testable import KitchenManager

final class KitchenAIActivityIndicatorTests: XCTestCase {

    func testEveryKitchenAIPhaseMapsToAnOrbDesign() {
        for phase in KitchenAIActivityPhase.allCases {
            let indicator = KitchenAIActivityIndicator(phase: phase, size: .small)
            XCTAssertFalse(phase.accessibilityLabel.isEmpty)
            _ = indicator
        }
    }

    func testSizesMapCorrectly() {
        XCTAssertEqual(KitchenAIActivitySize.small.points, 20)
        XCTAssertEqual(KitchenAIActivitySize.regular.points, 64)
    }

    func testTurnStateMappingToActivityPhase() {
        XCTAssertEqual(AIConversationTurnState.preparingContext.aiActivityPhase, .searching)
        XCTAssertEqual(AIConversationTurnState.requesting.aiActivityPhase, .waiting)
        XCTAssertEqual(AIConversationTurnState.streaming.aiActivityPhase, .composing)
        XCTAssertEqual(AIConversationTurnState.toolRequested.aiActivityPhase, .toolCall)
        XCTAssertEqual(AIConversationTurnState.executing.aiActivityPhase, .toolCall)

        XCTAssertNil(AIConversationTurnState.idle.aiActivityPhase)
        XCTAssertNil(AIConversationTurnState.awaitingConfirmation.aiActivityPhase)
        XCTAssertNil(AIConversationTurnState.completed.aiActivityPhase)
        XCTAssertNil(AIConversationTurnState.cancelled.aiActivityPhase)
        XCTAssertNil(AIConversationTurnState.failed.aiActivityPhase)
    }

    /// Every phase a real turn state can produce says what the app knows, not
    /// what a model might be doing internally.
    func testObservablePhasesDescribeWhatTheAppKnows() {
        XCTAssertEqual(KitchenAIActivityPhase.searching.statusText, "正在准备相关信息…")
        XCTAssertEqual(KitchenAIActivityPhase.waiting.statusText, "正在等待 AI 回复…")
        XCTAssertEqual(KitchenAIActivityPhase.toolCall.statusText, "正在处理相关操作…")
        XCTAssertEqual(KitchenAIActivityPhase.composing.statusText, "正在生成回复…")

        let observable = Set([
            AIConversationTurnState.preparingContext, .requesting, .streaming, .toolRequested, .executing
        ].compactMap(\.aiActivityPhase))
        XCTAssertEqual(observable, [.searching, .waiting, .toolCall, .composing])
        for phase in observable {
            XCTAssertFalse(phase.statusText.contains("思考"), "\(phase) has no reasoning signal")
            XCTAssertEqual(phase.accessibilityLabel, phase.statusText)
        }
    }
}
