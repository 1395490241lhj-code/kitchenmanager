import XCTest
@testable import KitchenManager

final class AuthConfigurationTests: XCTestCase {
    func test_validConfiguration_isAccepted() throws {
        let value = try AuthConfiguration.validate(
            urlString: "https://example.supabase.co",
            publishableKey: "sb_publishable_example"
        )
        XCTAssertEqual(value.supabaseURL.host, "example.supabase.co")
    }

    func test_missingValues_keepGuestModeAvailable() {
        XCTAssertThrowsError(try AuthConfiguration.validate(urlString: nil, publishableKey: nil)) { error in
            XCTAssertEqual(error as? AuthenticationError, .configuration("账号服务尚未配置，仍可继续使用游客模式。"))
        }
    }

    func test_nonHTTPSURL_isRejected() {
        XCTAssertThrowsError(try AuthConfiguration.validate(urlString: "http://example.test", publishableKey: "public"))
    }

    func test_placeholderValues_areRejected() {
        XCTAssertThrowsError(try AuthConfiguration.validate(urlString: "https://YOUR_PROJECT.supabase.co", publishableKey: "YOUR_KEY"))
    }

    func test_serviceRoleKey_isRejected() {
        XCTAssertThrowsError(try AuthConfiguration.validate(urlString: "https://example.supabase.co", publishableKey: "service_role_secret"))
    }
}
