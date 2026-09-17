import Foundation
import Synchronization
import XCTest

/// Sends headers and one line, leaving the body open until the test explicitly
/// attempts late delivery. No callback thread is blocked while awaiting cancel.
final class MockStreamingURLProtocol: URLProtocol {
    final class Scenario: Sendable {
        let bodyOpened = XCTestExpectation(description: "headers and first line sent; body open")
        let stopped = XCTestExpectation(description: "URLProtocol stopLoading observed")
        private struct State {
            var producer: MockStreamingURLProtocol?
            var stopCount = 0
            var lateDeliveryAttempted = false
        }
        private let state = Mutex(State())

        fileprivate func opened(_ producer: MockStreamingURLProtocol) {
            state.withLock { $0.producer = producer }
            bodyOpened.fulfill()
        }

        fileprivate func didStop() {
            state.withLock { $0.stopCount += 1 }
            stopped.fulfill()
        }

        var stopLoadingCallCount: Int { state.withLock { $0.stopCount } }
        var lateDeliveryAttempted: Bool { state.withLock { $0.lateDeliveryAttempted } }

        func deliverLateBytesAndFinish() throws {
            let producer = try XCTUnwrap(state.withLock { value in
                value.stopCount > 0 ? value.producer : nil
            }, "late delivery requires an observed stopLoading")
            let client = try XCTUnwrap(producer.client)
            // Deliberately call the client even though URLSession stopped us.
            client.urlProtocol(producer, didLoad: Data("late\n".utf8))
            state.withLock { $0.lateDeliveryAttempted = true }
            client.urlProtocolDidFinishLoading(producer)
        }
    }

    // A unique request path owns each scenario, including concurrent test runs.
    private static let scenarios = Mutex<[String: Scenario]>([:])

    static func install(_ scenario: Scenario, path: String) {
        scenarios.withLock { $0[path] = scenario }
    }

    static func reset(path: String) {
        scenarios.withLock { _ = $0.removeValue(forKey: path) }
    }

    private var scenario: Scenario? {
        Self.scenarios.withLock { $0[request.url?.path ?? ""] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let scenario, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200,
                                            httpVersion: "HTTP/1.1",
                                            headerFields: ["Content-Type": "text/event-stream"])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("first\n".utf8))
        scenario.opened(self)
        // Return without finishing: URLSession must remain able to call stopLoading.
    }

    override func stopLoading() {
        scenario?.didStop()
    }
}

extension URLSession {
    static func streamingMocked() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockStreamingURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
