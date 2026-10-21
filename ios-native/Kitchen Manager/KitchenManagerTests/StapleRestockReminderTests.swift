import XCTest
import UserNotifications
@testable import KitchenManager

/// PERSISTENCE_LIFECYCLE-7: staple restock reminders fired one second after an
/// in-app edit, while the app was in front, where iOS does not show them; and
/// the reminder toggles stayed on after notifications were turned off in iOS
/// Settings. Reminders now go out at the next 9:00, and a denied permission
/// shows the toggles off.
final class StapleRestockReminderTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testAnEveningRunOutIsRemindedTheNextMorning() {
        XCTAssertEqual(PantryRestockNotificationScheduler.nextReminderDate(after: date(19, 19, 30), calendar: calendar), date(20, 9))
    }

    func testAnEarlyMorningRunOutIsRemindedTheSameMorning() {
        XCTAssertEqual(PantryRestockNotificationScheduler.nextReminderDate(after: date(19, 7, 15), calendar: calendar), date(19, 9))
    }

    func testExactlyNineMovesToTheNextDay() {
        XCTAssertEqual(PantryRestockNotificationScheduler.nextReminderDate(after: date(19, 9), calendar: calendar), date(20, 9))
    }

    func testDeniedNotificationsShowTheTogglesOff() {
        XCTAssertFalse(ExpiryNotificationScheduler.isReminderEffectivelyOn(stored: true, authorization: .denied))
    }

    func testOtherwiseTheStoredChoiceShows() {
        XCTAssertTrue(ExpiryNotificationScheduler.isReminderEffectivelyOn(stored: true, authorization: .authorized))
        XCTAssertTrue(ExpiryNotificationScheduler.isReminderEffectivelyOn(stored: true, authorization: nil), "not read yet")
        XCTAssertFalse(ExpiryNotificationScheduler.isReminderEffectivelyOn(stored: false, authorization: .authorized))
    }
}
