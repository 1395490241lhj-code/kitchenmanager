import XCTest
@testable import KitchenManager

final class SharedImportQueueTests: XCTestCase {
    private var tempDirectory: URL!
    private var queue: SharedImportQueue!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedImportQueueTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        queue = SharedImportQueue(directoryURL: tempDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        queue = nil
        super.tearDown()
    }

    private func makeRequest(
        url: String? = nil,
        text: String? = nil,
        createdAt: Date = Date()
    ) -> SharedImportRequest {
        SharedImportRequest(
            createdAt: createdAt,
            source: url != nil ? .sharedURL : .sharedText,
            url: url.flatMap(URL.init(string:)),
            text: text,
            originalHostBundleIdentifier: nil
        )
    }

    // MARK: - Basic enqueue / read

    func test_enqueue_thenPeekAll_returnsTheRequest() throws {
        let request = makeRequest(url: "https://example.com/a")
        XCTAssertTrue(try queue.enqueue(request))
        XCTAssertEqual(queue.peekAll(), [request])
    }

    func test_emptyQueue_peekAllReturnsEmptyArray() {
        XCTAssertEqual(queue.peekAll(), [])
    }

    // MARK: - FIFO ordering

    func test_multipleEnqueues_preserveFIFOOrder() throws {
        let first = makeRequest(url: "https://example.com/1")
        let second = makeRequest(url: "https://example.com/2")
        let third = makeRequest(url: "https://example.com/3")

        try queue.enqueue(first)
        try queue.enqueue(second)
        try queue.enqueue(third)

        XCTAssertEqual(queue.peekAll().map(\.id), [first.id, second.id, third.id])
    }

    // MARK: - remove

    func test_remove_deletesOnlyTheMatchingRequest() throws {
        let first = makeRequest(url: "https://example.com/1")
        let second = makeRequest(url: "https://example.com/2")
        try queue.enqueue(first)
        try queue.enqueue(second)

        queue.remove(id: first.id)

        XCTAssertEqual(queue.peekAll(), [second])
    }

    func test_remove_unknownID_isANoOp() throws {
        let request = makeRequest(url: "https://example.com/1")
        try queue.enqueue(request)

        queue.remove(id: UUID())

        XCTAssertEqual(queue.peekAll(), [request])
    }

    func test_removeAll_clearsQueue() throws {
        try queue.enqueue(makeRequest(url: "https://example.com/1"))
        try queue.enqueue(makeRequest(url: "https://example.com/2"))

        queue.removeAll()

        XCTAssertEqual(queue.peekAll(), [])
    }

    // MARK: - Duplicate URL handling

    func test_duplicateURL_withinWindow_isNotAddedTwice() throws {
        let now = Date()
        let first = makeRequest(url: "https://example.com/same", createdAt: now)
        let duplicate = makeRequest(url: "https://example.com/same", createdAt: now.addingTimeInterval(5))

        XCTAssertTrue(try queue.enqueue(first))
        XCTAssertFalse(try queue.enqueue(duplicate))
        XCTAssertEqual(queue.peekAll().count, 1)
    }

    func test_sameURL_outsideDuplicateWindow_isAddedAgain() throws {
        let now = Date()
        let first = makeRequest(url: "https://example.com/same", createdAt: now)
        let later = makeRequest(
            url: "https://example.com/same",
            createdAt: now.addingTimeInterval(SharedImportQueue.duplicateWindow + 1)
        )

        XCTAssertTrue(try queue.enqueue(first))
        XCTAssertTrue(try queue.enqueue(later))
        XCTAssertEqual(queue.peekAll().count, 2)
    }

    func test_differentURLs_areBothAdded() throws {
        try queue.enqueue(makeRequest(url: "https://example.com/1"))
        try queue.enqueue(makeRequest(url: "https://example.com/2"))
        XCTAssertEqual(queue.peekAll().count, 2)
    }

    // MARK: - Max queue size

    func test_queueFull_throwsAndPreservesExistingRequests() throws {
        for index in 0..<SharedImportQueue.maxQueueSize {
            try queue.enqueue(makeRequest(url: "https://example.com/\(index)"))
        }
        XCTAssertEqual(queue.peekAll().count, SharedImportQueue.maxQueueSize)

        XCTAssertThrowsError(try queue.enqueue(makeRequest(url: "https://example.com/overflow"))) { error in
            XCTAssertEqual(error as? SharedImportQueue.QueueError, .queueFull)
        }
        // The attempted overflow must not have silently evicted an existing,
        // not-yet-handled request.
        XCTAssertEqual(queue.peekAll().count, SharedImportQueue.maxQueueSize)
    }

    // MARK: - Corrupted file recovery

    func test_corruptedQueueFile_isTreatedAsEmpty_andDoesNotCrash() throws {
        let fileURL = tempDirectory.appendingPathComponent("shared_import_queue.json")
        try Data("{ this is not valid json".utf8).write(to: fileURL)

        XCTAssertEqual(queue.peekAll(), [])
    }

    func test_afterCorruptedFileRecovery_queueIsUsableAgain() throws {
        let fileURL = tempDirectory.appendingPathComponent("shared_import_queue.json")
        try Data("garbage".utf8).write(to: fileURL)
        _ = queue.peekAll() // triggers recovery

        let request = makeRequest(url: "https://example.com/after-recovery")
        XCTAssertTrue(try queue.enqueue(request))
        XCTAssertEqual(queue.peekAll(), [request])
    }

    // MARK: - Schema version filtering

    func test_requestWithMismatchedSchemaVersion_isFilteredOutOnRead() throws {
        let mismatched = SharedImportRequest(
            source: .sharedURL,
            url: URL(string: "https://example.com/old"),
            text: nil,
            originalHostBundleIdentifier: nil,
            schemaVersion: SharedImportRequest.currentSchemaVersion + 1
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode([mismatched])
        let fileURL = tempDirectory.appendingPathComponent("shared_import_queue.json")
        try data.write(to: fileURL)

        XCTAssertEqual(queue.peekAll(), [])
    }

    // MARK: - App Group unavailable

    func test_appGroupQueue_returnsNil_whenContainerUnavailable() {
        let result = SharedImportQueue.appGroupQueue(appGroupIdentifier: "group.does.not.exist.\(UUID().uuidString)")
        XCTAssertNil(result)
    }

    // MARK: - Preserved-before-acknowledgement semantics

    func test_requestRemainsQueued_untilExplicitlyRemoved() throws {
        let request = makeRequest(text: "未处理的纯文字分享")
        try queue.enqueue(request)

        // Simulate the host app reading the queue without acknowledging yet.
        XCTAssertEqual(queue.peekAll(), [request])
        XCTAssertEqual(queue.peekAll(), [request], "a second read must not consume the request")
    }
}
