import Foundation

/// Describes one request. `APIClient` turns this into a `URLRequest`.
nonisolated struct APIEndpoint: Sendable {
    var path: String
    var method: HTTPMethod = .get
    var queryItems: [URLQueryItem] = []
    var headers: [String: String] = [:]
    var body: Data? = nil
    /// Overrides `APIClient`'s default timeout for this one request. Every
    /// migrated service keeps its own pre-existing timeout value this way
    /// (e.g. the 210s recipe-link-import timeout, the 50s default AI chat
    /// timeout).
    var timeout: TimeInterval? = nil
    /// Overrides the client's environment base URL. Not used by any current
    /// endpoint (all four hit the same backend) but kept for completeness.
    var baseURLOverride: URL? = nil

    /// Builds a JSON-body endpoint from any `Encodable` value.
    static func json<Body: Encodable>(
        path: String,
        method: HTTPMethod = .post,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Body,
        timeout: TimeInterval? = nil,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> APIEndpoint {
        var mergedHeaders = headers
        if mergedHeaders["Content-Type"] == nil {
            mergedHeaders["Content-Type"] = "application/json"
        }
        if mergedHeaders["Accept"] == nil {
            mergedHeaders["Accept"] = "application/json"
        }
        return APIEndpoint(
            path: path,
            method: method,
            queryItems: queryItems,
            headers: mergedHeaders,
            body: try encoder.encode(body),
            timeout: timeout
        )
    }

    /// Builds an endpoint from already-serialized request body bytes, for
    /// callers that construct their JSON some other way (e.g. via
    /// `JSONSerialization`) and must not risk producing different bytes than
    /// before by re-routing through `Encodable`.
    static func raw(
        path: String,
        method: HTTPMethod = .post,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data?,
        timeout: TimeInterval? = nil
    ) -> APIEndpoint {
        var mergedHeaders = headers
        if body != nil, mergedHeaders["Content-Type"] == nil {
            mergedHeaders["Content-Type"] = "application/json"
        }
        if mergedHeaders["Accept"] == nil {
            mergedHeaders["Accept"] = "application/json"
        }
        return APIEndpoint(
            path: path,
            method: method,
            queryItems: queryItems,
            headers: mergedHeaders,
            body: body,
            timeout: timeout
        )
    }

    /// Builds a body-less GET endpoint.
    static func get(
        path: String,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        timeout: TimeInterval? = nil
    ) -> APIEndpoint {
        var mergedHeaders = headers
        if mergedHeaders["Accept"] == nil {
            mergedHeaders["Accept"] = "application/json"
        }
        return APIEndpoint(
            path: path,
            method: .get,
            queryItems: queryItems,
            headers: mergedHeaders,
            timeout: timeout
        )
    }
}
