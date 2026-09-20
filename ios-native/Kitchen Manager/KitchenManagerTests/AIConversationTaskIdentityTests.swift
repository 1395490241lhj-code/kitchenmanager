import XCTest
@testable import KitchenManager

/// The task header is only worth having if its labels stay true for an old
/// conversation as well as a fresh one, so the branches are pinned here rather
/// than only through the workspace UI.
@MainActor
final class AIConversationTaskIdentityTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_758_326_400)

    private func conversation(
        lifecycle: AIConversationLifecycleType,
        createdAt: Date,
        anchorDate: Date? = nil,
        title: String = "新对话"
    ) -> AIConversation {
        AIConversation(
            createdAt: createdAt,
            title: title,
            lifecycleType: lifecycle,
            entryAffinity: AIConversationAffinity(lifecycleType: lifecycle),
            lastActivityAt: createdAt,
            activeUntil: createdAt.addingTimeInterval(48 * 3600),
            anchorDate: anchorDate
        )
    }

    func testADraftKeepsTheProductNameAndStatesNoTask() {
        let identity = AIConversationTaskIdentity(conversation: nil, isPersisted: false, now: now, calendar: calendar)
        XCTAssertEqual(identity.navigationTitle, "Kitchen AI")
        XCTAssertTrue(identity.contextLine.isEmpty, "a draft owns no task yet")
    }

    func testAnUnpersistedDraftDoesNotBorrowItsConversationTitle() {
        let draft = conversation(lifecycle: .dailyMeal, createdAt: now, title: "不应出现")
        let identity = AIConversationTaskIdentity(conversation: draft, isPersisted: false, now: now, calendar: calendar)
        XCTAssertEqual(identity.navigationTitle, "Kitchen AI")
    }

    func testAPersistedConversationUsesItsOwnTitleAndNeverInventsOne() {
        let saved = conversation(lifecycle: .dailyMeal, createdAt: now, title: "用临期菠菜做晚饭")
        let identity = AIConversationTaskIdentity(conversation: saved, isPersisted: true, now: now, calendar: calendar)
        XCTAssertEqual(identity.navigationTitle, "用临期菠菜做晚饭")
    }

    func testTodaysHomeConversationReadsAsToday() {
        let today = conversation(lifecycle: .dailyMeal, createdAt: now)
        let identity = AIConversationTaskIdentity(conversation: today, isPersisted: true, now: now, calendar: calendar)
        XCTAssertEqual(identity.contextLine, "今天")
    }

    /// The whole reason the daily label is computed rather than constant: a
    /// Home conversation from last week is not about today.
    func testAnOlderHomeConversationNamesItsOwnDayInsteadOfClaimingToday() {
        let earlier = calendar.date(byAdding: .day, value: -4, to: now)!
        let old = conversation(lifecycle: .dailyMeal, createdAt: earlier)
        let identity = AIConversationTaskIdentity(conversation: old, isPersisted: true, now: now, calendar: calendar)
        XCTAssertFalse(identity.contextLine.contains("今天"), "got \(identity.contextLine)")
        XCTAssertTrue(identity.contextLine.contains("月"), "got \(identity.contextLine)")
    }

    func testCurrentPlanningWeekReadsAsThisWeekAndCarriesItsRange() {
        let planning = conversation(lifecycle: .weeklyPlanning, createdAt: now, anchorDate: now)
        let identity = AIConversationTaskIdentity(conversation: planning, isPersisted: true, now: now, calendar: calendar)
        XCTAssertTrue(identity.contextLine.hasPrefix("本周计划"), "got \(identity.contextLine)")
        XCTAssertTrue(identity.contextLine.contains(" · "), "the week anchor must be present")
    }

    func testAnotherWeekDoesNotClaimToBeThisWeek() {
        let other = calendar.date(byAdding: .day, value: -21, to: now)!
        let planning = conversation(lifecycle: .weeklyPlanning, createdAt: other, anchorDate: other)
        let identity = AIConversationTaskIdentity(conversation: planning, isPersisted: true, now: now, calendar: calendar)
        XCTAssertTrue(identity.contextLine.hasPrefix("一周计划"), "got \(identity.contextLine)")
    }

    func testAMissingAnchorLeavesNoDanglingSeparator() {
        let planning = conversation(lifecycle: .weeklyPlanning, createdAt: now, anchorDate: nil)
        let identity = AIConversationTaskIdentity(conversation: planning, isPersisted: true, now: now, calendar: calendar)
        XCTAssertEqual(identity.contextLine, "一周计划")
        XCTAssertFalse(identity.contextLine.contains("·"))
    }

    func testSpecialPlanCarriesItsEventDay() {
        let event = calendar.date(byAdding: .day, value: 2, to: now)!
        let special = conversation(lifecycle: .specialPlan, createdAt: now, anchorDate: event)
        let identity = AIConversationTaskIdentity(conversation: special, isPersisted: true, now: now, calendar: calendar)
        XCTAssertTrue(identity.contextLine.hasPrefix("聚餐计划"), "got \(identity.contextLine)")
        XCTAssertTrue(identity.contextLine.contains("月"), "got \(identity.contextLine)")
    }

    func testGeneralConversationStatesAPlainKitchenTaskWithoutAnchor() {
        let general = conversation(lifecycle: .general, createdAt: now)
        let identity = AIConversationTaskIdentity(conversation: general, isPersisted: true, now: now, calendar: calendar)
        XCTAssertEqual(identity.contextLine, "厨房对话")
    }
}
