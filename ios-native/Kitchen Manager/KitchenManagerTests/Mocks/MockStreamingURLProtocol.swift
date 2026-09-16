import Foundation

/// A URLProtocol stub that delivers response headers immediately, then keeps
/// the HTTP body open behind an explicit gate until the test releases it.
/// Records when URLSession calls stopLoading, so a test can prove the
/// underlying producer work actually stopped - not just that the consumer
/// stopped observing.
final class MockStreamingURLProtocol: URLProtocol {
    struct Behavior {
        var statusCode = 200
        var headers: [String: String] = [:]
        /// Bytes sent immediately after headers, before the body gate opens.
        var initialChunk: Data?
    }

    // Recreated on every install so tests cannot inherit prior signals.
    static var openBody = DispatchSemaphore(value: 0)
    static var releaseBody = DispatchSemaphore(value: 0)
    static var stopLoadingObserved = DispatchSemaphore(value: 0)
    static var waitForBodyOpen = DispatchSemaphore(value: 0)

    private nonisolated(unsafe) static var behavior: Behavior?
    private nonisolated(unsafe) static var stopCount = 0
    private static let countLock = NSLock()

    static var stopLoadingCallCount: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return stopCount
    }

    static func install(_ b: Behavior) {
        countLock.lock()
        defer { countLock.unlock() }
        behavior = b
        stopCount = 0
        openBody = DispatchSemaphore(value: 0)
        releaseBody = DispatchSemaphore(value: 0)
        stopLoadingObserved = DispatchSemaphore(value: 0)
        waitForBodyOpen = DispatchSemaphore(value: 0)
    }

    static func reset() {
        install(Behavior())
        countLock.lock()
        behavior = nil
        countLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let b = Self.behavior ?? Behavior()
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: b.statusCode,
                                            httpVersion: "HTTP/1.1", headerFields: b.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        // HEADERS FIRST. This is the synchronisation point of the approved
        // Task 6 cancellation contract: the test may only cancel AFTER the
        // response headers have been delivered.
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let initial = b.initialChunk {
            client?.urlProtocol(self, didLoad: initial)
        }
        // Keep the body open behind a gate. The test opens the gate once the
        // consumer is iterating; teardown then either releases the body or
        // stopLoading tears the whole producer down.
        Self.waitForBodyOpen.signal()
        Self.openBody.wait()
        _ = Self.releaseBody.wait(timeout: .now() + 0.05)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.countLock.lock()
        Self.stopCount += 1
        Self.countLock.unlock()
        Self.stopLoadingObserved.signal()
        Self.releaseBody.signal()
        Self.openBody.signal()
    }
}

extension URLSession {
    /// A session that routes every request to MockStreamingURLProtocol.
    static func streamingMocked() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockStreamingURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

