import Foundation

/// Intercepts every request made through a `URLSession` configured with
/// `protocolClasses = [MockURLProtocol.self]`, so `APIClient` tests never hit
/// the real network. One handler is installed per test (via
/// `MockURLProtocol.install(...)`) and must be removed in `tearDown` via
/// `MockURLProtocol.reset()` so tests never see each other's stubs.
final class MockURLProtocol: URLProtocol {
    struct Stub {
        var statusCode: Int = 200
        var headers: [String: String] = [:]
        var data: Data?
        var error: URLError?
        /// Simulated latency before responding. Kept short (well under a
        /// second) in every test that uses it — this is not a substitute for
        /// asserting the request's configured `timeoutInterval`.
        var delay: TimeInterval = 0
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> Stub)?
    private nonisolated(unsafe) static var requests: [URLRequest] = []

    /// Installs the handler used for every request until `reset()` is called.
    static func install(_ handler: @escaping @Sendable (URLRequest) throws -> Stub) {
        lock.lock()
        defer { lock.unlock() }
        Self.handler = handler
        requests = []
    }

    /// Every request seen since the last `install`/`reset`, in order.
    static func capturedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    /// Must be called from `tearDown` so no stub or captured request leaks
    /// into the next test.
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        handler = nil
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession sometimes hands the protocol a request whose `httpBody`
        // has been converted into an `httpBodyStream` instead (an internal
        // URLSession implementation detail, not something callers control).
        // Read the stream back into `httpBody` before capturing, so tests
        // that inspect `request.httpBody` see the actual bytes regardless of
        // which form URLSession chose to deliver.
        let normalizedRequest = Self.normalizingBody(of: request)

        Self.lock.lock()
        Self.requests.append(normalizedRequest)
        let currentHandler = Self.handler
        Self.lock.unlock()

        guard let currentHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let stub = try currentHandler(normalizedRequest)
            if stub.delay > 0 {
                Thread.sleep(forTimeInterval: stub.delay)
            }
            if let error = stub.error {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: stub.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: stub.headers
                  ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = stub.data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// Returns a copy of `request` guaranteed to expose its body via
    /// `httpBody`, reading `httpBodyStream` fully if that's the form
    /// URLSession chose to deliver it in.
    private static func normalizingBody(of request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else {
            return request
        }
        var normalized = request
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: bufferSize)
            if bytesRead <= 0 { break }
            data.append(buffer, count: bytesRead)
        }
        normalized.httpBody = data
        return normalized
    }
}

extension URLSession {
    /// A session that never touches the real network — every request is
    /// routed to `MockURLProtocol`.
    static func mocked() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
