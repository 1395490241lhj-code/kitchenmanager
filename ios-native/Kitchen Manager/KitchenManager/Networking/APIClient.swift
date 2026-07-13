import Foundation

/// Centralized HTTP client. Every existing service that used to call
/// `URLSession.shared` directly (`AIChatService`, `LinkExtractService`,
/// `AIRecipeParseService`, `RecipeService`) now goes through this instead.
///
/// An `actor` rather than a plain struct/class because it wraps a shared
/// `URLSession`; actor isolation makes it safe to share one instance
/// (`.shared`) across concurrent callers without any of them being able to
/// mutate its configuration.
actor APIClient {
    /// Base client using the app's single real backend. Holds no business
    /// state — just a session, base URL, and default timeout — so it is
    /// safe to share and does not need to be mocked away in tests the way a
    /// stateful singleton would.
    static let shared = APIClient()

    private let session: URLSession
    private let environment: APIEnvironment
    private let defaultTimeout: TimeInterval

    init(
        environment: APIEnvironment = .current,
        session: URLSession = .shared,
        defaultTimeout: TimeInterval = 60
    ) {
        self.environment = environment
        self.session = session
        self.defaultTimeout = defaultTimeout
    }

    /// Sends a request and decodes the JSON response body.
    func send<Response: Decodable>(
        _ endpoint: APIEndpoint,
        responseType: Response.Type = Response.self,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> Response {
        let data = try await sendRaw(endpoint)
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decodingFailed(error)
        }
    }

    /// Sends a request that returns no meaningful body (e.g. a bare 204/200).
    func sendExpectingEmptyResponse(_ endpoint: APIEndpoint) async throws {
        _ = try await sendRaw(endpoint)
    }

    /// Sends a request and returns the raw response bytes, letting the
    /// caller decode however it needs to (several existing services try
    /// more than one decode shape on the same payload).
    func sendRaw(_ endpoint: APIEndpoint) async throws -> Data {
        let request = try buildRequest(for: endpoint)
        return try await perform(request, method: endpoint.method, path: endpoint.path)
    }

    /// Sends a multipart/form-data upload. Not used by any current service —
    /// kept ready for a future endpoint that needs true multipart rather
    /// than the base64-in-JSON approach every current image upload uses.
    func upload(_ endpoint: APIEndpoint, multipart: MultipartFormData) async throws -> Data {
        var request = try buildRequest(for: endpoint)
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = multipart.encode()
        return try await perform(request, method: endpoint.method, path: endpoint.path)
    }

    private func buildRequest(for endpoint: APIEndpoint) throws -> URLRequest {
        let base = endpoint.baseURLOverride ?? environment.baseURL
        guard var components = URLComponents(
            url: base.appending(path: endpoint.path),
            resolvingAgainstBaseURL: false
        ) else {
            throw APIError.invalidURL
        }
        if !endpoint.queryItems.isEmpty {
            components.queryItems = endpoint.queryItems
        }
        guard let url = components.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.timeoutInterval = endpoint.timeout ?? defaultTimeout
        for (field, value) in endpoint.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = endpoint.body
        return request
    }

    private func perform(_ request: URLRequest, method: HTTPMethod, path: String) async throws -> Data {
        #if DEBUG
        let start = Date()
        #endif

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                throw APIError.cancelled
            case .timedOut:
                throw APIError.timeout
            default:
                throw APIError.transport(error.localizedDescription)
            }
        } catch is CancellationError {
            throw APIError.cancelled
        } catch {
            throw APIError.transport(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        #if DEBUG
        // Method, path, and status only — never headers, body, or query
        // values, since those can carry recipe/receipt content.
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        print("[APIClient] \(method.rawValue) \(path) -> \(httpResponse.statusCode) (\(elapsedMs)ms)")
        #endif

        guard 200..<300 ~= httpResponse.statusCode else {
            let payload = try? JSONDecoder().decode(APIErrorResponse.self, from: data)
            throw APIError.server(status: httpResponse.statusCode, payload: payload)
        }

        return data
    }
}
