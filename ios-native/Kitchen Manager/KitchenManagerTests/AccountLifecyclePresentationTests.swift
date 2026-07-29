import XCTest
@testable import KitchenManager

#if DEBUG

@MainActor
final class AccountLifecyclePresentationTests: XCTestCase {
    func testOwnerFixturePresentsOwnerSummary() {
        let fixture = AccountLifecycleFixture.owner
        XCTAssertEqual(fixture.account.user.displayName, "厨房主人")
        XCTAssertEqual(fixture.account.households.first?.role, "owner")
        XCTAssertEqual(fixture.account.households.first?.roleTitle, "所有者")
    }

    func testMemberFixturePresentsMemberSummary() {
        let fixture = AccountLifecycleFixture.member
        XCTAssertEqual(fixture.account.user.displayName, "家庭成员")
        XCTAssertEqual(fixture.account.households.first?.role, "member")
        XCTAssertEqual(fixture.account.households.first?.roleTitle, "成员")
    }

    func testLoadingAndAccountErrorFixturesRemainDistinct() async throws {
        let loading = AccountLifecycleFixtureAccountService(fixture: .loading)
        let error = AccountLifecycleFixtureAccountService(fixture: .accountError)

        let loadingTask = Task { @MainActor in
            try await loading.currentAccount(accessToken: "fixture")
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(loadingTask.isCancelled)
        loadingTask.cancel()

        do {
            _ = try await error.currentAccount(accessToken: "fixture")
            XCTFail("account error fixture must fail without a network request")
        } catch {
            XCTAssertEqual(error as? AccountServiceError, .temporarilyUnavailable)
        }
    }

    func testSyncFixtureCopySeparatesIdleCompletedAndError() {
        XCTAssertEqual(AccountLifecycleFixture.syncIdle.syncTitle, "尚未开启")
        XCTAssertEqual(AccountLifecycleFixture.syncCompleted.syncTitle, "已同步")
        XCTAssertEqual(AccountLifecycleFixture.syncError.syncTitle, "同步遇到问题，可重试")
        XCTAssertNil(AccountLifecycleFixture.syncIdle.syncDetail)
        XCTAssertNotNil(AccountLifecycleFixture.syncError.syncDetail)
    }

    func testSignOutFailureIsLocalAndNeverClearsFixtureSessionByItself() async {
        let service = AccountLifecycleFixtureAuthService(fixture: .signOutFailure)
        do {
            try await service.signOut()
            XCTFail("fixture sign-out must simulate a safe failure")
        } catch {
            XCTAssertEqual(error as? AuthenticationError, .unavailable)
        }
        XCTAssertEqual(service.fixture.session.user.email, "fixture@example.com")
    }
}

#endif
