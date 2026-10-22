import XCTest
@testable import KitchenManager

/// RECIPES_LOGIC-10 / PERSISTENCE_LIFECYCLE-5: a shared link that failed or
/// was already imported came back on every launch and started a network
/// import by itself, and nothing in the app could remove it, so 20 of them
/// broke sharing. 不再导入 removes one, and a share already shown and closed
/// waits for 开始识别 instead of auto-starting.
@MainActor
final class SharedImportStuckRequestTests: XCTestCase {
    private var directory: URL!
    private var queue: SharedImportQueue!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SharedImportStuck-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        queue = SharedImportQueue(directoryURL: directory)
        defaults = UserDefaults(suiteName: UUID().uuidString)!
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func request(_ path: String) -> SharedImportRequest {
        SharedImportRequest(source: .sharedURL, url: URL(string: "https://example.com/\(path)"), text: nil,
                            originalHostBundleIdentifier: nil)
    }

    private func launch() -> SharedImportCoordinator {
        let coordinator = SharedImportCoordinator(queue: queue, defaults: defaults)
        coordinator.refresh(isAnotherImportFlowPresented: false)
        return coordinator
    }

    func testANewShareStartsReadingByItself() throws {
        let share = request("new")
        try queue.enqueue(share)
        XCTAssertTrue(launch().shouldAutoStart(share))
    }

    func testAShareClosedOnceDoesNotAutoStartOnTheNextLaunch() throws {
        let share = request("failed")
        try queue.enqueue(share)
        launch().snooze(share)

        let next = launch()
        XCTAssertEqual(next.pendingRequest, share, "still kept, never silently dropped")
        XCTAssertFalse(next.shouldAutoStart(share), "no network import by itself on every launch")
    }

    func testDiscardingRemovesItForGoodAndFreesTheQueue() throws {
        let stuck = request("stuck")
        let waiting = request("waiting")
        try queue.enqueue(stuck)
        try queue.enqueue(waiting)
        let first = launch()
        XCTAssertEqual(first.pendingRequest, stuck)

        first.discard(stuck)

        XCTAssertEqual(queue.peekAll(), [waiting])
        XCTAssertEqual(launch().pendingRequest, waiting)
    }

    func testShownMarkersOfRequestsThatLeftTheQueueAreForgotten() throws {
        let share = request("gone")
        try queue.enqueue(share)
        launch().snooze(share)
        queue.remove(id: share.id)

        _ = launch()
        XCTAssertEqual(defaults.stringArray(forKey: SharedImportCoordinator.shownRequestIDsKey) ?? [], [])
    }
}
