import XCTest
@testable import KitchenManager

/// Outcome copy, destination and undo availability are all derived from the
/// persisted action record. These pin the mapping so a wrong destination or a
/// stale "still undoable" line can never be produced from a record that says
/// otherwise.
final class AIActionOutcomePresentationTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_758_326_400)
    private let planID = UUID()

    private func record(_ type: AIActionType, status: AIActionStatus = .succeeded,
                        related: [String] = [], undoExpiresAt: Date? = nil,
                        withReceipt: Bool = true) -> AIConversationActionRecord {
        AIConversationActionRecord(
            conversationID: UUID(), turnID: UUID(), actionType: type, idempotencyKey: "k",
            status: status, relatedEntityIDs: related,
            undoReference: withReceipt ? .shoppingAdditions(before: [], after: []) : nil,
            undoExpiresAt: undoExpiresAt
        )
    }

    func testEveryActionTypeHasSpecificOutcomeCopyAndNoneSaysGenericDone() {
        for type in AIActionType.allCases {
            let title = AIActionOutcomePresentation.outcomeTitle(for: type)
            XCTAssertFalse(title.isEmpty)
            XCTAssertNotEqual(title, "操作已完成", "\(type) must name the real kitchen effect")
        }
        let titles = AIActionType.allCases.map(AIActionOutcomePresentation.outcomeTitle)
        XCTAssertEqual(Set(titles).count, titles.count, "outcomes must be distinguishable")
    }

    func testUndoneCopySaysReversedAndNamesTheSurface() {
        for type in AIActionType.allCases {
            let title = AIActionOutcomePresentation.undoneTitle(for: type)
            XCTAssertTrue(title.hasPrefix("已撤销"), "\(type): \(title)")
            XCTAssertTrue(title.contains("已恢复"), "\(type): \(title)")
        }
    }

    func testDestinationsFollowTheActionTypeAndItsStoredIDs() {
        XCTAssertEqual(AIActionOutcomePresentation.destination(for: record(.addRecipeToTonight)), .today)
        XCTAssertEqual(AIActionOutcomePresentation.destination(for: record(.addShoppingItems)), .shopping)
        XCTAssertEqual(AIActionOutcomePresentation.destination(for: record(.applyPlannerChanges)), .plannerWeek)
        XCTAssertEqual(
            AIActionOutcomePresentation.destination(for: record(.replacePlannedMeal, related: [planID.uuidString, "recipe"])),
            .plannedMeal(planID))
        XCTAssertEqual(
            AIActionOutcomePresentation.destination(for: record(.replaceSpecialPlanDishes, related: [planID.uuidString])),
            .specialPlan(planID))
    }

    func testAnUnparsableTargetFallsBackToTheSurfaceRootRatherThanGuessing() {
        XCTAssertEqual(
            AIActionOutcomePresentation.destination(for: record(.replacePlannedMeal, related: ["not-a-uuid"])),
            .plannerWeek)
    }

    func testFailedUndoneOrPendingRecordsNeverYieldADestination() {
        for status in [AIActionStatus.failed, .undone, .proposed, .awaitingConfirmation, .executing] {
            XCTAssertNil(AIActionOutcomePresentation.destination(for: record(.addShoppingItems, status: status)),
                         "status \(status) must not advertise a place to inspect a change that did not land")
        }
    }

    func testUndoAvailabilityNamesTheExpiryWhileItLiesAhead() {
        let expiry = now.addingTimeInterval(9 * 60)
        let copy = AIActionOutcomePresentation.undoAvailability(for: record(.addShoppingItems, undoExpiresAt: expiry), now: now)
        XCTAssertNotNil(copy)
        XCTAssertTrue(copy!.hasPrefix("可撤销至 "), copy!)
        XCTAssertTrue(copy!.contains(":"), "must carry a clock time: \(copy!)")
    }

    func testExpiredOrUndoneRecordsOfferNoUndoAvailability() {
        let past = now.addingTimeInterval(-1)
        XCTAssertNil(AIActionOutcomePresentation.undoAvailability(for: record(.addShoppingItems, undoExpiresAt: past), now: now))
        XCTAssertNil(AIActionOutcomePresentation.undoAvailability(for: record(.addShoppingItems, status: .undone, undoExpiresAt: now.addingTimeInterval(60)), now: now))
        XCTAssertNil(AIActionOutcomePresentation.undoAvailability(for: record(.addShoppingItems, undoExpiresAt: now.addingTimeInterval(60), withReceipt: false), now: now),
                     "no receipt means nothing deterministic to restore")
    }
}
