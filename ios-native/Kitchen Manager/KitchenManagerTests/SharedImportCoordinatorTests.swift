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
        XCTAssertEqual(queue.peekAll().count, 1, "snoozing must not delete the not-yet-imported request")
        XCTAssertEqual(queue.peekAll().first?.id, request.id)
        XCTAssertEqual(queue.peekAll().first?.status, .deferred, "「稍后处理」must be persisted, not in-memory only")

        // A repeated refresh in the same session must not resurrect it either.
        coordinator.refresh(isAnotherImportFlowPresented: false)
        XCTAssertNil(coordinator.pendingRequest)
    }

    /// Regression: the reported bug. A share the user closed used to be
    /// re-presented *and re-imported* on every single relaunch, because the
    /// snooze lived only in the coordinator's memory while the request
    /// stayed `pending` on disk.
    func test_snoozedRequest_doesNotReappearForANewCoordinatorInstance() throws {
        let request = makeRequest(url: "https://example.com/1")
        try queue.enqueue(request)

        let firstLaunch = SharedImportCoordinator(queue: queue)
        firstLaunch.refresh(isAnotherImportFlowPresented: false)
        firstLaunch.snooze(request)

        // Simulates repeated cold launches, not just one.
        for _ in 0..<3 {
            let relaunch = SharedImportCoordinator(queue: queue)
            relaunch.refresh(isAnotherImportFlowPresented: false)
            XCTAssertNil(relaunch.pendingRequest, "a deferred request must never auto-present again")
        }

        // It is deferred, not deleted — still reachable on purpose.
        XCTAssertEqual(queue.peekAll().count, 1)
        let relaunch = SharedImportCoordinator(queue: queue)
        relaunch.refresh(isAnotherImportFlowPresented: false)
        XCTAssertEqual(relaunch.deferredRequests.map(\.id), [request.id])
    }

    func test_deferredRequest_canBeResumedExplicitly_butDoesNotAutoStart() throws {
        let request = makeRequest(url: "https://example.com/1")
        try queue.enqueue(request)

        let firstLaunch = SharedImportCoordinator(queue: queue)
        firstLaunch.refresh(isAnotherImportFlowPresented: false)
        firstLaunch.snooze(request)

        let relaunch = SharedImportCoordinator(queue: queue)
        relaunch.refresh(isAnotherImportFlowPresented: false)
        let deferred = try XCTUnwrap(relaunch.deferredRequests.first)
        relaunch.resume(deferred)

        XCTAssertEqual(relaunch.pendingRequest?.id, request.id, "explicit resume must surface it again")
        XCTAssertFalse(
            SharedImportCoordinator.shouldAutoStart(try XCTUnwrap(relaunch.pendingRequest)),
            "surfacing it again must not restart recognition automatically"
        )
    }

    // MARK: - Deleted requests never come back

    func test_discardedRequest_doesNotReappearAfterRelaunch() throws {
        let request = makeRequest(url: "https://example.com/1")
        try queue.enqueue(request)

        let firstLaunch = SharedImportCoordinator(queue: queue)
        firstLaunch.refresh(isAnotherImportFlowPresented: false)
        firstLaunch.discard(request)

        XCTAssertTrue(queue.peekAll().isEmpty)

        let relaunch = SharedImportCoordinator(queue: queue)
        relaunch.refresh(isAnotherImportFlowPresented: false)
        XCTAssertNil(relaunch.pendingRequest)
        XCTAssertTrue(relaunch.deferredRequests.isEmpty)
    }

    func test_savedRequest_doesNotReappearAfterRelaunch() throws {
        let request = makeRequest(url: "https://example.com/1")
        try queue.enqueue(request)

        let firstLaunch = SharedImportCoordinator(queue: queue)
        firstLaunch.refresh(isAnotherImportFlowPresented: false)
        firstLaunch.markHandedOff(request)

        let relaunch = SharedImportCoordinator(queue: queue)
        relaunch.refresh(isAnotherImportFlowPresented: false)
        XCTAssertNil(relaunch.pendingRequest)
        XCTAssertTrue(queue.peekAll().isEmpty)
    }

    // MARK: - Failures do not retry forever

    func test_repeatedFailures_stopAutomaticPresentation() throws {
        let request = makeRequest(url: "https://example.com/broken")
        try queue.enqueue(request)

        // Each "launch" presents it once and the import fails.
        for _ in 0..<SharedImportCoordinator.maxAutoRetryCount {
            let launch = SharedImportCoordinator(queue: queue)
            launch.refresh(isAnotherImportFlowPresented: false)
            let presented = try XCTUnwrap(launch.pendingRequest)
            launch.recordFailure(presented)
        }

        let laterLaunch = SharedImportCoordinator(queue: queue)
        laterLaunch.refresh(isAnotherImportFlowPresented: false)
        XCTAssertNil(laterLaunch.pendingRequest, "a repeatedly failing link must stop auto-retrying")
        XCTAssertEqual(queue.peekAll().first?.status, .failed)
        XCTAssertEqual(laterLaunch.deferredRequests.map(\.id), [request.id], "still offered for an explicit retry/delete")
    }

    func test_firstFailure_stillAllowsOneMoreAutomaticAttempt() throws {
        let request = makeRequest(url: "https://example.com/flaky")
        try queue.enqueue(request)

        let firstLaunch = SharedImportCoordinator(queue: queue)
        firstLaunch.refresh(isAnotherImportFlowPresented: false)
        firstLaunch.recordFailure(try XCTUnwrap(firstLaunch.pendingRequest))

        let secondLaunch = SharedImportCoordinator(queue: queue)
        secondLaunch.refresh(isAnotherImportFlowPresented: false)
        XCTAssertEqual(secondLaunch.pendingRequest?.id, request.id)
        // ...but it no longer fires the network call by itself.
        XCTAssertFalse(SharedImportCoordinator.shouldAutoStart(try XCTUnwrap(secondLaunch.pendingRequest)))
    }

    // MARK: - Auto-start policy

    func test_autoStart_onlyForBrandNewPendingRequests() {
        let fresh = makeRequest(url: "https://example.com/1")
        XCTAssertTrue(SharedImportCoordinator.shouldAutoStart(fresh))
        XCTAssertFalse(SharedImportCoordinator.shouldAutoStart(fresh.updating(status: .deferred)))
        XCTAssertFalse(SharedImportCoordinator.shouldAutoStart(fresh.updating(status: .failed)))
        XCTAssertFalse(SharedImportCoordinator.shouldAutoStart(fresh.updating(failureCount: 1)))
    }

    // MARK: - Independent requests don't interfere

    func test_twoDifferentRequests_deferringOneDoesNotAffectTheOther() throws {
        let first = makeRequest(url: "https://example.com/1")
        let second = makeRequest(url: "https://example.com/2")
        try queue.enqueue(first)
        try queue.enqueue(second)

        let launch = SharedImportCoordinator(queue: queue)
        launch.refresh(isAnotherImportFlowPresented: false)
        launch.snooze(try XCTUnwrap(launch.pendingRequest))

        let relaunch = SharedImportCoordinator(queue: queue)
        relaunch.refresh(isAnotherImportFlowPresented: false)
        XCTAssertEqual(relaunch.pendingRequest?.id, second.id, "the untouched request must still surface")
        XCTAssertEqual(relaunch.deferredRequests.map(\.id), [first.id])
    }

    // MARK: - Pending-shares entry point backing state

    func test_deferredRequestsCount_dropsAfterDeletingOne() throws {
        let first = makeRequest(url: "https://example.com/1")
        let second = makeRequest(url: "https://example.com/2")
        try queue.enqueue(first)
        try queue.enqueue(second)

        let coordinator = SharedImportCoordinator(queue: queue)
        coordinator.refresh(isAnotherImportFlowPresented: false)
        coordinator.snooze(try XCTUnwrap(coordinator.pendingRequest))
        coordinator.refresh(isAnotherImportFlowPresented: false)
        coordinator.snooze(try XCTUnwrap(coordinator.pendingRequest))

        XCTAssertEqual(coordinator.deferredRequests.count, 2, "both deferred shares back the Home entry point")

        coordinator.discard(try XCTUnwrap(coordinator.deferredRequests.first))
        XCTAssertEqual(coordinator.deferredRequests.count, 1, "the entry point count must update immediately")

        coordinator.discard(try XCTUnwrap(coordinator.deferredRequests.first))
        XCTAssertTrue(coordinator.deferredRequests.isEmpty, "no pending shares means the Home row disappears")
        XCTAssertTrue(queue.peekAll().isEmpty)
    }

    func test_failedRequest_isListedAndCanBeRetriedManually_withoutAutoStart() throws {
        let request = makeRequest(url: "https://example.com/broken")
        try queue.enqueue(request)

        for _ in 0..<SharedImportCoordinator.maxAutoRetryCount {
            let launch = SharedImportCoordinator(queue: queue)
            launch.refresh(isAnotherImportFlowPresented: false)
            launch.recordFailure(try XCTUnwrap(launch.pendingRequest))
        }

        let coordinator = SharedImportCoordinator(queue: queue)
        coordinator.refresh(isAnotherImportFlowPresented: false)

        // Listed with a visible failed state...
        let failed = try XCTUnwrap(coordinator.deferredRequests.first)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.failureCount, SharedImportCoordinator.maxAutoRetryCount)
        // ...not auto-presented...
        XCTAssertNil(coordinator.pendingRequest)

        // ...but retryable by hand, and even then it does not auto-start.
        coordinator.resume(failed)
        let resumed = try XCTUnwrap(coordinator.pendingRequest)
        XCTAssertEqual(resumed.id, request.id)
        XCTAssertFalse(
            SharedImportCoordinator.shouldAutoStart(resumed),
            "a manual retry must wait for a deliberate tap, never fire on its own"
        )
    }

    func test_resumingFromTheList_neverAutoStartsADeferredRequest() throws {
        let request = makeRequest(url: "https://example.com/1")
        try queue.enqueue(request)

        let firstLaunch = SharedImportCoordinator(queue: queue)
        firstLaunch.refresh(isAnotherImportFlowPresented: false)
        firstLaunch.snooze(request)

        let coordinator = SharedImportCoordinator(queue: queue)
        coordinator.refresh(isAnotherImportFlowPresented: false)
        coordinator.resume(try XCTUnwrap(coordinator.deferredRequests.first))

        let resumed = try XCTUnwrap(coordinator.pendingRequest)
        XCTAssertEqual(resumed.id, request.id)
        XCTAssertFalse(
            SharedImportCoordinator.shouldAutoStart(resumed),
            "resuming from the list must never re-arm automatic recognition"
        )
        XCTAssertEqual(resumed.status, .deferred, "resume must not restore .pending")
    }

    /// Resuming must not turn a deferred request back into something a later
    /// cold launch would auto-present again.
    func test_resumedThenAbandonedRequest_stillDoesNotAutoPresentOnRelaunch() throws {
        let request = makeRequest(url: "https://example.com/1")
        try queue.enqueue(request)

        let firstLaunch = SharedImportCoordinator(queue: queue)
        firstLaunch.refresh(isAnotherImportFlowPresented: false)
        firstLaunch.snooze(request)

        let second = SharedImportCoordinator(queue: queue)
        second.refresh(isAnotherImportFlowPresented: false)
        second.resume(try XCTUnwrap(second.deferredRequests.first))
        second.snooze(try XCTUnwrap(second.pendingRequest))

        let relaunch = SharedImportCoordinator(queue: queue)
        relaunch.refresh(isAnotherImportFlowPresented: false)
        XCTAssertNil(relaunch.pendingRequest)
        XCTAssertEqual(relaunch.deferredRequests.map(\.id), [request.id])
    }

    // MARK: - Stale queue data ages out generically

    func test_requestOlderThanMaxAge_isPrunedOnRefresh() throws {
        let stale = SharedImportRequest(
            createdAt: Date().addingTimeInterval(-(SharedImportQueue.maxRequestAge + 60)),
            source: .sharedURL,
            url: URL(string: "https://example.com/very-old"),
            text: nil,
            originalHostBundleIdentifier: nil
        )
        let recent = makeRequest(url: "https://example.com/new")
        try queue.enqueue(stale)
        try queue.enqueue(recent)

        let coordinator = SharedImportCoordinator(queue: queue)
        coordinator.refresh(isAnotherImportFlowPresented: false)

        XCTAssertEqual(queue.peekAll().map(\.id), [recent.id], "only the stale entry ages out")
        XCTAssertEqual(coordinator.pendingRequest?.id, recent.id)
    }

    /// Models the reported leftover exactly: a single long-abandoned request
    /// written by the shipped build (no `status`/`failureCount` on disk).
    /// It must be removed *before* it can be presented — the user should
    /// never see it auto-open even once more, and must not have to reinstall.
    func test_legacyStaleRequest_isPrunedBeforeItCanEverBePresented() throws {
        let id = UUID()
        let legacyJSON = """
        [{
          "id": "\(id.uuidString)",
          "createdAt": \(Date().addingTimeInterval(-(SharedImportQueue.maxRequestAge + 86_400)).timeIntervalSince1970),
          "source": "sharedURL",
          "url": "https://example.com/long-abandoned-share",
          "schemaVersion": 1
        }]
        """
        try Data(legacyJSON.utf8).write(to: tempDirectory.appendingPathComponent("shared_import_queue.json"))

        let coordinator = SharedImportCoordinator(queue: queue)
        coordinator.refresh(isAnotherImportFlowPresented: false)

        XCTAssertNil(coordinator.pendingRequest, "a long-abandoned share must never be presented again")
        XCTAssertTrue(coordinator.deferredRequests.isEmpty)
        XCTAssertTrue(queue.peekAll().isEmpty, "and it must be gone from disk")
    }

    /// The under-14-days case: still presented once, and "删除此次导入"
    /// removes it permanently across relaunches.
    func test_recentLeftoverRequest_isDeletableForeverViaDiscard() throws {
        let recent = SharedImportRequest(
            createdAt: Date().addingTimeInterval(-3 * 24 * 60 * 60),
            source: .sharedURL,
            url: URL(string: "https://example.com/recent-leftover"),
            text: nil,
            originalHostBundleIdentifier: nil
        )
        try queue.enqueue(recent)

        let firstLaunch = SharedImportCoordinator(queue: queue)
        firstLaunch.refresh(isAnotherImportFlowPresented: false)
        XCTAssertEqual(firstLaunch.pendingRequest?.id, recent.id, "within the age limit it is still offered once")
        firstLaunch.discard(try XCTUnwrap(firstLaunch.pendingRequest))

        for _ in 0..<3 {
            let relaunch = SharedImportCoordinator(queue: queue)
            relaunch.refresh(isAnotherImportFlowPresented: false)
            XCTAssertNil(relaunch.pendingRequest)
            XCTAssertTrue(relaunch.deferredRequests.isEmpty)
        }
        XCTAssertTrue(queue.peekAll().isEmpty)
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
