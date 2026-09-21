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

    func testActiveActivityPhaseFallback() {
        XCTAssertEqual(AIConversationTurnState.streaming.activeActivityPhase, .composing)
        XCTAssertEqual(AIConversationTurnState.idle.activeActivityPhase, .composing)
    }
}
