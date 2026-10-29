import XCTest
@testable import KitchenManager

@MainActor
final class PreparedLifecyclePresentationTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "America/Toronto")!; return value
    }
    func testDraftConfirmationRetryAndStaleRecheck() throws {
        let row = PreparedLifecycleBackupFixtures.row()
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        var draft = PreparedLifecycleFormDraft(expected: row, action: .beginThaw, at: at, calendar: calendar)
        XCTAssertNil(draft.confirmedIntent, "opening/cancelling creates no event")
        XCTAssertTrue(PreparedLifecyclePresentation.events(row).isEmpty)
        XCTAssertThrowsError(try draft.makeReviewedIntent(at: at, calendar: calendar))
        draft.expiryReviewed = true
        let intent = try draft.makeReviewedIntent(at: at, calendar: calendar)
        XCTAssertEqual(try draft.makeReviewedIntent(at: at.addingTimeInterval(86400), calendar: Calendar(identifier: .iso8601)), intent)
        var changed = row; changed.expiryDate = row.expiryDate.addingTimeInterval(-100)
        draft.recheck(changed)
        XCTAssertNil(draft.confirmedIntent); XCTAssertFalse(draft.expiryReviewed)
        XCTAssertEqual(draft.expected, changed)
        XCTAssertThrowsError(try draft.makeReviewedIntent(at: at, calendar: calendar))
        draft.expiryReviewed = true
        XCTAssertEqual(try draft.makeReviewedIntent(at: at, calendar: calendar).expiryReview.existingExpiryDate, changed.expiryDate)
    }
    func testAdvisoryExpiryAndScopedActionCopy() throws {
        var row = PreparedLifecycleBackupFixtures.row(); row.expiryDate = Date(timeIntervalSince1970: 2_000_000_000)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        var draft = PreparedLifecycleFormDraft(expected: row, action: .beginThaw, at: at, calendar: calendar)
        XCTAssertLessThanOrEqual(draft.expiryDate, row.expiryDate)
        XCTAssertEqual(PreparedLifecyclePresentation.actions(for: row), [.beginThaw])
        let chosen = row.expiryDate.addingTimeInterval(100)
        draft.selectExpiry(chosen); draft.expiryReviewed = true
        let intent = try draft.makeReviewedIntent(at: at, calendar: calendar)
        XCTAssertTrue(intent.expiryReview.explicitlyEdited); XCTAssertEqual(intent.expiryReview.selectedExpiryDate, chosen)
        let change = try PreparedLifecycleTransition.propose(state: row.state, storage: row.storage, lifecycle: row.lifecycle, expiryDate: row.expiryDate, intent: intent)
        var thaw = row; thaw.storage = change.storage; thaw.lifecycle = change.lifecycle
        XCTAssertEqual(PreparedLifecyclePresentation.status(thaw), "已备好 · 冷藏 · 解冻中")
        XCTAssertEqual(PreparedLifecyclePresentation.actions(for: thaw), [.completeThaw])
        XCTAssertEqual(PreparedLifecyclePresentation.events(thaw).count, 1)
        var complete = thaw; complete.lifecycle = PreparedLifecycle(version: 1, thawPhase: .inactive, thawStartedAt: at, thawCompletedAt: at, cookedAt: nil)
        XCTAssertFalse(PreparedLifecyclePresentation.status(complete).contains("已解冻"))
        XCTAssertEqual(PreparedLifecyclePresentation.actions(for: complete), [.markCooked])
        complete.state = .cooked
        XCTAssertTrue(PreparedLifecyclePresentation.actions(for: complete).isEmpty)
    }
    func testDateChangeInvalidatesConfirmationAndMidnightRequiresReviewAgain() throws {
        var row = PreparedLifecycleBackupFixtures.row(); row.expiryDate = Date(timeIntervalSince1970: 2_000_000_000)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        var draft = PreparedLifecycleFormDraft(expected: row, action: .beginThaw, at: at, calendar: calendar)
        draft.expiryReviewed = true
        XCTAssertThrowsError(try draft.makeReviewedIntent(at: at.addingTimeInterval(86400), calendar: calendar))
        XCTAssertFalse(draft.expiryReviewed); XCTAssertNil(draft.confirmedIntent)
        draft.expiryReviewed = true
        _ = try draft.makeReviewedIntent(at: at.addingTimeInterval(86400), calendar: calendar)
        draft.selectExpiry(row.expiryDate)
        XCTAssertNil(draft.confirmedIntent); XCTAssertFalse(draft.expiryReviewed)
    }
    func testSameDisplayedDefaultDateAllowsDelayedConfirmationAndStableRetry() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        for action in [PreparedLifecycleAction.beginThaw, .markCooked] {
            var row = PreparedLifecycleBackupFixtures.row(storage: action == .beginThaw ? .frozen : .refrigerated)
            row.expiryDate = at.addingTimeInterval(30 * 86400)
            var draft = PreparedLifecycleFormDraft(expected: row, action: action, at: at, calendar: calendar)
            let displayed = draft.expiryDate
            draft.expiryReviewed = true
            let intent = try? draft.makeReviewedIntent(at: at.addingTimeInterval(1), calendar: calendar)
            XCTAssertNotNil(intent, "reviewing a date must not require matching hidden seconds")
            guard let intent else { continue }
            XCTAssertTrue(calendar.isDate(displayed, inSameDayAs: intent.expiryReview.selectedExpiryDate))
            XCTAssertLessThanOrEqual(intent.expiryReview.selectedExpiryDate, row.expiryDate)
            XCTAssertFalse(intent.expiryReview.explicitlyEdited)
            XCTAssertEqual(intent.eventAt, at.addingTimeInterval(1))
            XCTAssertEqual(try draft.makeReviewedIntent(at: at.addingTimeInterval(2), calendar: Calendar(identifier: .iso8601)), intent)
        }
    }
}
