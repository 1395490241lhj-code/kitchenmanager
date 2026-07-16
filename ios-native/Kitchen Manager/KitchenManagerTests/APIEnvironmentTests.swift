import XCTest
@testable import KitchenManager

/// Phase 2C-3: environment safety-guard tests for `APIEnvironment`. There is
/// currently only one real backend host (see `APIEnvironment`'s own doc
/// comment) — these tests cover what is actually checkable today: the
/// current build's resolved case, its safe non-secret label, and the
/// loopback-in-Release guard. They do not assert a fabricated production
/// URL/key, since none exists in this repository.
final class APIEnvironmentTests: XCTestCase {
    func testDebugBuildResolvesToDevelopment() {
        // This test target always builds Debug — matches the app's own
        // #if DEBUG resolution in APIEnvironment.current.
        XCTAssertEqual(APIEnvironment.current, .development)
    }

    func testLabelIsSafeNonSecretText() {
        XCTAssertEqual(APIEnvironment.development.label, "development")
        XCTAssertEqual(APIEnvironment.production.label, "production")
        // The label must never itself be (or contain) the backend host.
        for environment in [APIEnvironment.development, .production] {
            XCTAssertFalse(environment.label.contains(environment.baseURL.host ?? "unreachable-sentinel"))
        }
    }

    func testDebugBuildIsAlwaysSafeRegardlessOfResolvedHost() {
        // This test target is always a Debug build, so both cases are
        // reported safe today — the guard only becomes restrictive in
        // Release (see APIEnvironment.isSafeForCurrentBuildConfiguration).
        XCTAssertTrue(APIEnvironment.development.isSafeForCurrentBuildConfiguration)
        XCTAssertTrue(APIEnvironment.production.isSafeForCurrentBuildConfiguration)
    }

    func testBothCasesResolveToAnAbsoluteHTTPSURLToday() {
        // Documents the current, deliberate single-backend topology (see
        // docs/SUPABASE_ENVIRONMENT_TOPOLOGY.md) — both cases share one real
        // host until a genuinely separate production backend exists.
        XCTAssertEqual(APIEnvironment.production.baseURL, APIEnvironment.development.baseURL)
        XCTAssertEqual(APIEnvironment.current.baseURL.scheme, "https")
    }

    func testNeitherCaseEverResolvesToLoopbackToday() {
        for environment in [APIEnvironment.development, .production] {
            let host = environment.baseURL.host ?? ""
            XCTAssertNotEqual(host, "127.0.0.1")
            XCTAssertNotEqual(host, "localhost")
        }
    }
}
