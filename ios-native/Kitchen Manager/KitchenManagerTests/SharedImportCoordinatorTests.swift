import XCTest
@testable import KitchenManager

@MainActor
final class SharedImportCoordinatorTests: XCTestCase {
    private var tempDirectory: URL!
    private var queue: SharedImportQueue!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedImportCoordinatorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        queue = SharedImportQueue(directoryURL: tempDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        queue = nil
        super.tearDown()
    }

    private func makeRequest(url: String? = nil, text: String? = nil) -> SharedImportRequest {
        SharedImportRequest(
            source: url != nil ? (text != nil ? .sharedTextAndURL : .sharedURL) : .sharedText,
            url: url.flatMap(URL.init(string:)),
            text: text,
            originalHostBundleIdentifier: nil
        )
    }

    // MARK: - No pending request

    func test_noQueuedRequests_refreshLeavesNil() {
        let coordinator = SharedImportCoordinator(queue: queue)
        coordinator.refresh(isAnotherImportFlowPresented: false)
        XCTAssertNil(coordinator.pendingRequest)
    }

    func test_queueUnavailable_refreshLeavesNil() {
        let coordinator = SharedImportCoordinator(queue: nil)
        coordinator.refresh(isAnotherImportFlowPresented: false)
        XCTAssertNil(coordinator.pendingRequest)
        XCTAssertFalse(coordinator.isQueueAvailable)
    }

    // MARK: - One URL request

    func test_oneQueuedURLRequest_surfacesOnRefresh() throws {
        let request = makeRequest(url: "https://example.com/recipe")
        try queue.enqueue(request)

        let coordinator = SharedImportCoordinator(queue: queue)
        coordinator.refresh(isAnotherImportFlowPresented: false)

        XCTAssertEqual(coordinator.pendingRequest, request)
    }

    // MARK: - One text-with-URL request
    //
    // Phase 1 dropped support for bare text with no URL (see "Legacy/invalid
    // (no-URL) request handling" below) — the "text" case that can actually
    // reach the coordinator always carries a URL alongside it.

    func test_oneQueuedTextAndURLRequest_surfacesOnRefresh() throws {
        let request = makeRequest(url: "https://example.com/recipe", text: "看这个菜谱")
        try queue.enqueue(request)

        let coordinator = SharedImportCoordinator(queue: queue)
        coordinator.refresh(isAnotherImportFlowPresented: false)

        XCTAssertEqual(coordinator.pendingRequest, request)
        XCTAssertEqual(
            SharedImportCoordinator.prefillText(for: request),
            "看这个菜谱\nhttps://example.com/recipe"
        )
    }

    // MARK: - Multiple requests processed in order

    func test_multipleQueuedRequests_surfacesOldestFirst_thenNextAfterHandoff() throws {
        let first = makeRequest(url: "https://example.com/1")
        let second = makeRequest(url: "https://example.com/2")
        try queue.enqueue(first)
        try queue.enqueue(second)

        let coordinator = SharedImportCoordinator(queue: queue)
        coordinator.refresh(isAnotherImportFlowPresented: false)
        XCTAssertEqual(coordinator.pendingRequest, first)

        coordinator.markHandedOff(first)
        XCTAssertNil(coordinator.pendingRequest)

        coordinator.refresh(isAnotherImportFlowPresented: false)
        XCTAssertEqual(coordinator.pendingRequest, second)
    }

    // MARK: - Existing modal blocks duplicate presentation

    func test_anotherModalPresented_refreshDoesNotSurfaceRequest() throws {
        try queue.enqueue(makeRequest(url: "https://example.com/1"))

        let coordinator = SharedImportCoordinator(queue: queue)
        coordinator.refresh(isAnotherImportFlowPresented: true)

        XCTAssertNil(coordinator.pendingRequest)
    }

    // MARK: - Successful handoff removes request

    func test_markHandedOff_removesFromQueueAndClearsPending() throws {
        let request = makeRequest(url: "https://example.com/1")
        try queue.enqueue(request)

        let coordinator = SharedImportCoordinator(queue: queue)
        coordinator.refresh(isAnotherImportFlowPresented: false)
        coordinator.markHandedOff(request)

        XCTAssertNil(coordinator.pendingRequest)
        XCTAssertEqual(queue.peekAll(), [])
    }

    // MARK: - Failed handoff preserves request

    func test_snoozeAfterFailure_preservesRequestOnDisk_butHidesItThisSession() throws {
        let request = makeRequest(url: "https://example.com/1")
        try queue.enqueue(request)

        let coordinator = SharedImportCoordinator(queue: queue)
        coordinator.refresh(isAnotherImportFlowPresented: false)
        coordinator.snooze(request)

        XCTAssertNil(coordinator.pendingRequest, "snoozed request should not stay presented")
        XCTAssertEqual(queue.peekAll(), [request], "snoozing must not delete the not-yet-imported request")

        // A repeated refresh in the same session must not resurrect it either.
        coordinator.refresh(isAnotherImportFlowPresented: false)
        XCTAssertNil(coordinator.pendingRequest)
    }

    func test_snoozedRequest_reappearsForANewCoordinatorInstance() throws {
        // Simulates "app relaunch": a fresh coordinator has no in-memory
        // snooze state, so the still-queued request resurfaces.
        let request = makeRequest(url: "https://example.com/1")
        try queue.enqueue(request)

        let firstLaunch = SharedImportCoordinator(queue: queue)
        firstLaunch.refresh(isAnotherImportFlowPresented: false)
        firstLaunch.snooze(request)

        let secondLaunch = SharedImportCoordinator(queue: queue)
        secondLaunch.refresh(isAnotherImportFlowPresented: false)

        XCTAssertEqual(secondLaunch.pendingRequest, request)
    }

    // MARK: - Explicit discard actually removes the request

    func test_discard_removesFromQueue() throws {
        let request = makeRequest(url: "https://example.com/1")
        try queue.enqueue(request)

        let coordinator = SharedImportCoordinator(queue: queue)
        coordinator.refresh(isAnotherImportFlowPresented: false)
        coordinator.discard(request)

        XCTAssertNil(coordinator.pendingRequest)
        XCTAssertEqual(queue.peekAll(), [])
    }

    // MARK: - Repeated scene-active does not duplicate presentation

    func test_repeatedRefreshWhileAlreadyPending_doesNotChangeIdentity() throws {
        let first = makeRequest(url: "https://example.com/1")
        let second = makeRequest(url: "https://example.com/2")
        try queue.enqueue(first)
        try queue.enqueue(second)

        let coordinator = SharedImportCoordinator(queue: queue)
        coordinator.refresh(isAnotherImportFlowPresented: false)
        XCTAssertEqual(coordinator.pendingRequest, first)

        // Simulate several more scenePhase-active events while the first
        // request is still being shown/handled — must stay on `first`.
        coordinator.refresh(isAnotherImportFlowPresented: false)
        coordinator.refresh(isAnotherImportFlowPresented: false)
        XCTAssertEqual(coordinator.pendingRequest, first)
    }

    // MARK: - Prefill text derivation reuses the existing Smart Import input shape

    func test_prefillText_urlOnly_isJustTheURL() {
        let request = makeRequest(url: "https://example.com/recipe")
        XCTAssertEqual(SharedImportCoordinator.prefillText(for: request), "https://example.com/recipe")
    }

    func test_prefillText_textAndURL_combinesBoth() {
        let request = SharedImportRequest(
            source: .sharedTextAndURL,
            url: URL(string: "https://example.com/recipe"),
            text: "看这个",
            originalHostBundleIdentifier: nil
        )
        XCTAssertEqual(SharedImportCoordinator.prefillText(for: request), "看这个\nhttps://example.com/recipe")
    }

    func test_prefillText_textAlreadyContainsURL_isNotDuplicated() {
        let request = SharedImportRequest(
            source: .sharedTextAndURL,
            url: URL(string: "https://example.com/recipe"),
            text: "看这个 https://example.com/recipe",
            originalHostBundleIdentifier: nil
        )
        XCTAssertEqual(SharedImportCoordinator.prefillText(for: request), "看这个 https://example.com/recipe")
    }

    // MARK: - Guest / auth independence
    //
    // SharedImportCoordinator never references AuthStore or any guest/auth
    // state, so "auth restoring" and "Guest vs signed-in" have no code path
    // that could erase or gate a pending request — these tests document
    // that invariant rather than exercising a nonexistent auth dependency.

    func test_coordinatorHasNoAuthDependency_pendingRequestSurvivesAcrossManyRefreshes() throws {
        let request = makeRequest(url: "https://example.com/recipe")
        try queue.enqueue(request)

        let coordinator = SharedImportCoordinator(queue: queue)
        for _ in 0..<5 {
            coordinator.refresh(isAnotherImportFlowPresented: false)
        }

        XCTAssertEqual(coordinator.pendingRequest, request)
    }

    // MARK: - Legacy/invalid (no-URL) request handling
    //
    // Phase 1 narrowed scope to URL-only content: `SharedImportRequestBuilder`
    // never produces a request without a URL. These tests simulate data that
    // could only be legacy/invalid (written by some other build, or a raw
    // queue file edited by hand) to prove the coordinator can't get stuck on
    // it, doesn't crash, and never lets it block a real, valid request.

    private func makeLegacyTextOnlyRequest(text: String = "旧版本遗留的纯文字请求") -> SharedImportRequest {
        SharedImportRequest(source: .sharedText, url: nil, text: text, originalHostBundleIdentifier: nil)
    }

    func test_legacyNoURLRequest_isNeverSurfaced() throws {
        try queue.enqueue(makeLegacyTextOnlyRequest())

        let coordinator = SharedImportCoordinator(queue: queue)
        coordinator.refresh(isAnotherImportFlowPresented: false)

        XCTAssertNil(coordinator.pendingRequest, "a URL-less request must never be presented to Smart Import")
    }

    func test_legacyNoURLRequest_isDiscardedFromQueue_onRefresh() throws {
        let legacy = makeLegacyTextOnlyRequest()
        try queue.enqueue(legacy)

        let coordinator = SharedImportCoordinator(queue: queue)
        coordinator.refresh(isAnotherImportFlowPresented: false)

        XCTAssertEqual(queue.peekAll(), [], "invalid legacy data should be pruned, not left to reappear forever")
    }

    func test_legacyNoURLRequest_doesNotBlockASubsequentValidURLRequest() throws {
        let legacy = makeLegacyTextOnlyRequest()
        let valid = makeRequest(url: "https://example.com/recipe")
        try queue.enqueue(legacy)
        try queue.enqueue(valid)

        let coordinator = SharedImportCoordinator(queue: queue)
        coordinator.refresh(isAnotherImportFlowPresented: false)

        XCTAssertEqual(coordinator.pendingRequest, valid)
        XCTAssertEqual(queue.peekAll(), [valid])
    }

    func test_repeatedRefreshWithOnlyLegacyRequests_doesNotLoopOrCrash() throws {
        try queue.enqueue(makeLegacyTextOnlyRequest(text: "第一条"))

        let coordinator = SharedImportCoordinator(queue: queue)
        for _ in 0..<5 {
            coordinator.refresh(isAnotherImportFlowPresented: false)
        }

        XCTAssertNil(coordinator.pendingRequest)
        XCTAssertEqual(queue.peekAll(), [])
    }

    func test_validURLRequest_isNeverDiscardedByLegacyPruning() throws {
        let valid = makeRequest(url: "https://example.com/still-valid")
        try queue.enqueue(valid)

        let coordinator = SharedImportCoordinator(queue: queue)
        coordinator.refresh(isAnotherImportFlowPresented: false)
        coordinator.refresh(isAnotherImportFlowPresented: false)

        XCTAssertEqual(coordinator.pendingRequest, valid)
        XCTAssertEqual(queue.peekAll(), [valid])
    }
}
