import XCTest
@testable import KitchenManager

final class InventorySyncPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testEnrollmentAndBasicStateCopy() {
        let notEnrolled = InventorySyncPresentation.make(state: .notEnrolled, now: now)
        XCTAssertEqual(notEnrolled.title, "尚未完成合并")
        XCTAssertNil(notEnrolled.actionTitle)

        let idle = InventorySyncPresentation.make(state: .idle, now: now)
        XCTAssertEqual(idle.title, "已同步")
        XCTAssertTrue(idle.actionEnabled)

        let completed = InventorySyncPresentation.make(state: .completed, now: now)
        XCTAssertEqual(completed.message, "最近一次库存同步已完成。")
        XCTAssertTrue(completed.showsAction)
    }

    func testPendingCountRemainsSecondaryAndActionIsAvailable() {
        let presentation = InventorySyncPresentation.make(state: .pending(count: 7), now: now)
        XCTAssertEqual(presentation.title, "待同步")
        XCTAssertEqual(presentation.pendingCount, 7)
        XCTAssertTrue(presentation.message.contains("7"))
        XCTAssertTrue(presentation.actionEnabled)
    }

    func testSyncingOfflineAndGenericErrorAreRecoverableWithoutSuccessCopy() {
        let syncing = InventorySyncPresentation.make(state: .syncing, now: now)
        XCTAssertFalse(syncing.actionEnabled)

        let offline = InventorySyncPresentation.make(state: .offline, now: now)
        XCTAssertEqual(offline.title, "暂时离线")
        XCTAssertTrue(offline.actionEnabled)

        let error = InventorySyncPresentation.make(state: .error, now: now)
        XCTAssertEqual(error.title, "同步遇到问题")
        XCTAssertFalse(error.title.contains("已同步"))
        XCTAssertTrue(error.actionEnabled)
    }

    func testRateLimitDisablesDuringWindowAndEnablesAfterExpiry() {
        let active = InventorySyncPresentation.make(
            state: .rateLimited(retryAfter: now.addingTimeInterval(12)), now: now
        )
        XCTAssertEqual(active.title, "请稍后重试")
        XCTAssertFalse(active.actionEnabled)
        XCTAssertTrue(active.message.contains("12"))

        let expired = InventorySyncPresentation.make(
            state: .rateLimited(retryAfter: now.addingTimeInterval(-1)), now: now
        )
        XCTAssertEqual(expired.title, "可以重试")
        XCTAssertTrue(expired.actionEnabled)
    }

    func testUpgradeAndNoHouseholdHaveNoSyncAction() {
        let upgrade = InventorySyncPresentation.make(state: .upgradeRequired, now: now)
        XCTAssertEqual(upgrade.title, "需要更新 App")
        XCTAssertFalse(upgrade.showsAction)

        let noHousehold = InventorySyncPresentation.make(state: .noHousehold, now: now)
        XCTAssertEqual(noHousehold.title, "没有可同步的家庭")
        XCTAssertFalse(noHousehold.showsAction)
    }

    func testDetailCanExplainRecoverableErrorWithoutChangingState() {
        let presentation = InventorySyncPresentation.make(
            state: .error, now: now, detail: "当前使用本机数据，稍后可重试。"
        )
        XCTAssertEqual(presentation.detail, "当前使用本机数据，稍后可重试。")
        XCTAssertEqual(presentation.state, .error)
    }
}
