import XCTest
@testable import KitchenManager

/// Shared setup for every networking test: a fresh `APIClient` wired to a
/// `URLSession` that only ever talks to `MockURLProtocol`, and a guaranteed
/// `MockURLProtocol.reset()` after every test so no stub or captured request
/// can leak into the next one (tests must not depend on run order or on each
/// other's mock state).
class NetworkTestCase: XCTestCase {
    var apiClient: APIClient!

    override func setUp() {
        super.setUp()
        apiClient = APIClient(environment: .production, session: .mocked(), defaultTimeout: 60)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        apiClient = nil
        super.tearDown()
    }

    /// The one real backend host every endpoint must resolve to.
    let expectedHost = "kitchenmanager-b8px.onrender.com"
}
