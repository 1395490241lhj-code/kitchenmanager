import XCTest
@testable import KitchenManager

/// The inventory-change reschedule must read the lead-time toggles with the same
/// defaults SettingsView shows. `@AppStorage` never writes its default, so a user
/// who only turned expiry reminders on has no stored lead-time keys at all.
final class ExpiryNotificationLeadTimeDefaultsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ExpiryNotificationLeadTimeDefaultsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testUntouchedTogglesUseTheSettingsScreenDefaults() {
        XCTAssertEqual(
            ExpiryNotificationLeadTime.enabled(in: defaults),
            [.oneDayBefore, .dayOf],
            "设置页显示「到期前 1 天」「当天」默认开启，库存变化后的重排不能把它们当成关闭"
        )
    }

    func testStoredChoicesWinOverTheDefaults() {
        defaults.set(false, forKey: "notifyLeadTime1Day")
        defaults.set(true, forKey: "notifyLeadTime3Day")
        defaults.set(false, forKey: "notifyLeadTimeDayOf")

        XCTAssertEqual(ExpiryNotificationLeadTime.enabled(in: defaults), [.threeDaysBefore])
    }

    func testStorageKeysMatchTheSettingsScreen() {
        XCTAssertEqual(ExpiryNotificationLeadTime.oneDayBefore.storageKey, "notifyLeadTime1Day")
        XCTAssertEqual(ExpiryNotificationLeadTime.threeDaysBefore.storageKey, "notifyLeadTime3Day")
        XCTAssertEqual(ExpiryNotificationLeadTime.dayOf.storageKey, "notifyLeadTimeDayOf")
    }
}
