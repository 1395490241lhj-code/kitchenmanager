import XCTest
@testable import KitchenManager

@MainActor
final class AuthStoreTests: XCTestCase {
    private let user = AuthUser(id: UUID(), email: "cook@example.com")

    func test_initialState_isGuest() {
        let store = makeStore()
        XCTAssertEqual(store.status, .guest)
        XCTAssertEqual(store.activity, .idle)
    }

    func test_restoreWithoutSession_remainsGuest() async {
        let store = makeStore()
        await store.start()
        XCTAssertEqual(store.status, .guest)
    }

    func test_restoreSession_becomesSignedIn_andLoadsAccount() async {
        let session = makeSession()
        let auth = MockAuthService()
        auth.restoredSession = session
        let account = MockAccountService()
        account.result = .success(makeAccount())
        let store = AuthStore(authService: auth, accountService: account)
        await store.start()
        XCTAssertEqual(store.status, .signedIn(user))
        XCTAssertEqual(store.account?.user.id, user.id)
        XCTAssertEqual(account.receivedTokens, ["test-access-token"])
    }

    func test_restoreFailure_fallsBackToGuest() async {
        let auth = MockAuthService()
        auth.restoreError = AuthenticationError.unavailable
        let store = makeStore(auth: auth)
        await store.start()
        XCTAssertEqual(store.status, .guest)
        XCTAssertNotNil(store.errorMessage)
    }

    func test_signInSuccess_updatesSession() async {
        let auth = MockAuthService()
        auth.signInResult = .success(makeSession())
        let store = makeStore(auth: auth)
        let didSignIn = await store.signIn(email: "cook@example.com", password: "secret1")
        XCTAssertTrue(didSignIn)
        XCTAssertEqual(store.status, .signedIn(user))
    }

    func test_signInFailure_isFriendlyAndRemainsGuest() async {
        let auth = MockAuthService()
        auth.signInResult = .failure(AuthenticationError.invalidCredentials)
        let store = makeStore(auth: auth)
        let didSignIn = await store.signIn(email: "cook@example.com", password: "wrong")
        XCTAssertFalse(didSignIn)
        XCTAssertEqual(store.status, .guest)
        XCTAssertEqual(store.errorMessage, "邮箱或密码不正确。")
    }

    func test_signUpWithImmediateSession_signsIn() async {
        let auth = MockAuthService()
        auth.signUpResult = .success(.signedIn(makeSession()))
        let store = makeStore(auth: auth)
        let didSignUp = await store.signUp(email: "cook@example.com", password: "secret1")
        XCTAssertTrue(didSignUp)
        XCTAssertEqual(store.status, .signedIn(user))
    }

    func test_signUpRequiringConfirmation_staysGuestAndShowsEmail() async {
        let auth = MockAuthService()
        auth.signUpResult = .success(.confirmationRequired(email: "cook@example.com"))
        let store = makeStore(auth: auth)
        let didSignUp = await store.signUp(email: "cook@example.com", password: "secret1")
        XCTAssertFalse(didSignUp)
        XCTAssertEqual(store.status, .guest)
        XCTAssertEqual(store.confirmationEmail, "cook@example.com")
    }

    func test_signUpFailure_isFriendlyAndRemainsGuest() async {
        let auth = MockAuthService()
        auth.signUpResult = .failure(AuthenticationError.emailAlreadyRegistered)
        let store = makeStore(auth: auth)
        let didSignUp = await store.signUp(email: "cook@example.com", password: "secret1")
        XCTAssertFalse(didSignUp)
        XCTAssertEqual(store.status, .guest)
        XCTAssertEqual(store.errorMessage, "这个邮箱已经注册，可以直接登录。")
    }

    func test_signOut_returnsToGuest() async {
        let auth = MockAuthService()
        auth.restoredSession = makeSession()
        let store = makeStore(auth: auth)
        await store.start()
        await store.signOut()
        XCTAssertEqual(store.status, .guest)
        XCTAssertTrue(auth.didSignOut)
    }

    func test_accountFailure_doesNotForceLogout() async {
        let auth = MockAuthService()
        auth.signInResult = .success(makeSession())
        let account = MockAccountService()
        account.result = .failure(AccountServiceError.temporarilyUnavailable)
        let store = AuthStore(authService: auth, accountService: account)
        _ = await store.signIn(email: "cook@example.com", password: "secret1")
        XCTAssertEqual(store.status, .signedIn(user))
        XCTAssertNotNil(store.accountMessage)
    }

    func test_authStateSignedOut_clearsSession() async {
        let auth = MockAuthService()
        auth.restoredSession = makeSession()
        let store = makeStore(auth: auth)
        await store.start()
        auth.emit(.signedOut)
        let didSignOut = await waitUntil { store.status == .guest }
        XCTAssertTrue(didSignOut)
    }

    func test_authStateSessionUpdate_replacesCurrentUser() async {
        let auth = MockAuthService()
        let store = makeStore(auth: auth)
        await store.start()
        let updated = AuthSession(
            user: AuthUser(id: UUID(), email: "new@example.com"),
            accessToken: "refreshed-token"
        )
        auth.emit(.sessionUpdated(updated))
        let didUpdate = await waitUntil { store.status == .signedIn(updated.user) }
        XCTAssertTrue(didUpdate)
    }

    func test_logoutDoesNotAlterKitchenStoreData() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let kitchen = KitchenStore(userDefaults: defaults)
        kitchen.addInventory(name: "鸡蛋", quantity: 2, unit: "个", expiryDate: nil)
        let auth = MockAuthService()
        auth.restoredSession = makeSession()
        let store = makeStore(auth: auth)
        await store.start()
        await store.signOut()
        XCTAssertEqual(kitchen.inventory.first?.name, "鸡蛋")
        XCTAssertEqual(kitchen.inventory.first?.quantity, 2)
    }

    private func makeSession() -> AuthSession { AuthSession(user: user, accessToken: "test-access-token") }
    private func makeAccount() -> CurrentAccount {
        CurrentAccount(user: .init(id: user.id, email: user.email, displayName: "Cook"), households: [])
    }
    private func makeStore() -> AuthStore { makeStore(auth: MockAuthService()) }
    private func makeStore(auth: MockAuthService) -> AuthStore {
        let account = MockAccountService()
        account.result = .success(makeAccount())
        return AuthStore(authService: auth, accountService: account)
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<50 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}

@MainActor
private final class MockAuthService: AuthService {
    var restoredSession: AuthSession?
    var restoreError: Error?
    var signInResult: Result<AuthSession, Error> = .failure(AuthenticationError.unavailable)
    var signUpResult: Result<SignUpOutcome, Error> = .failure(AuthenticationError.unavailable)
    var didSignOut = false
    private let continuation: AsyncStream<AuthStateChange>.Continuation
    let authStateChanges: AsyncStream<AuthStateChange>

    init() {
        let stream = AsyncStream.makeStream(of: AuthStateChange.self)
        authStateChanges = stream.stream
        continuation = stream.continuation
    }
    func restoreSession() async throws -> AuthSession? {
        if let restoreError { throw restoreError }
        return restoredSession
    }
    func signUp(email: String, password: String) async throws -> SignUpOutcome { try signUpResult.get() }
    func signIn(email: String, password: String) async throws -> AuthSession { try signInResult.get() }
    func signOut() async throws { didSignOut = true }
    func emit(_ change: AuthStateChange) { continuation.yield(change) }
}

@MainActor
private final class MockAccountService: AccountService {
    var result: Result<CurrentAccount, Error> = .failure(AccountServiceError.temporarilyUnavailable)
    var receivedTokens: [String] = []
    func currentAccount(accessToken: String) async throws -> CurrentAccount {
        receivedTokens.append(accessToken)
        return try result.get()
    }
}
