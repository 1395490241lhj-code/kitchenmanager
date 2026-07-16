import Foundation

nonisolated protocol SyncAccessTokenProviding: Sendable {
    func accessToken() async -> String?
}

nonisolated protocol SyncTransport: Sendable {
    func bootstrap() async throws -> SyncBootstrapResponse
    func fetchChanges(scope: SyncScope, after cursor: SyncCursorValue, limit: Int) async throws -> SyncChangesResponse
    func sendMutations(scope: SyncScope, mutations: [SyncMutation]) async throws -> SyncMutationBatchResponse
}

actor ExpressSyncTransport: SyncTransport {
    private let client: APIClient
    private let tokenProvider: any SyncAccessTokenProviding

    init(client: APIClient = .shared, tokenProvider: any SyncAccessTokenProviding) {
        self.client = client
        self.tokenProvider = tokenProvider
    }

    func bootstrap() async throws -> SyncBootstrapResponse {
        try await send(.get(path: "api/sync/bootstrap", headers: try await requestHeaders()), as: SyncBootstrapResponse.self)
    }

    func fetchChanges(
        scope: SyncScope,
        after cursor: SyncCursorValue,
        limit: Int
    ) async throws -> SyncChangesResponse {
        let endpoint = APIEndpoint.get(
            path: "api/sync/changes",
            queryItems: [
                URLQueryItem(name: "scopeType", value: scope.type.rawValue),
                URLQueryItem(name: "scopeId", value: scope.id.uuidString.lowercased()),
                URLQueryItem(name: "cursor", value: cursor.rawValue),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "entityTypes", value: SyncEntityType.inventoryItem.rawValue)
            ],
            headers: try await requestHeaders()
        )
        return try await send(endpoint, as: SyncChangesResponse.self)
    }

    func sendMutations(scope: SyncScope, mutations: [SyncMutation]) async throws -> SyncMutationBatchResponse {
        let request = SyncMutationBatchRequest(scope: scope, mutations: mutations)
        let endpoint = try APIEndpoint.json(
            path: "api/sync/mutations",
            headers: try await requestHeaders(),
            body: request,
            encoder: SyncCoding.encoder()
        )
        return try await send(endpoint, as: SyncMutationBatchResponse.self)
    }

    /// Authorization + the Phase 2C-1 client-version headers, combined so
    /// every one of the three sync calls above carries both consistently —
    /// no View, AuthStore, or SwiftData model ever sees or stores these
    /// values; they exist only for the duration of building this one
    /// request's headers.
    private func requestHeaders() async throws -> [String: String] {
        guard let token = await tokenProvider.accessToken(), !token.isEmpty else {
            throw SyncError.notAuthenticated
        }
        var headers = ["Authorization": "Bearer \(token)"]
        for (field, value) in SyncClientVersionHeaders.current.headerFields {
            headers[field] = value
        }
        return headers
    }

    private func send<Response: Decodable & Sendable>(
        _ endpoint: APIEndpoint,
        as type: Response.Type
    ) async throws -> Response {
        do {
            return try await client.send(endpoint, responseType: type, decoder: SyncCoding.decoder())
        } catch let error as APIError {
            throw Self.map(error)
        } catch is DecodingError {
            throw SyncError.decoding
        } catch let error as SyncError {
            throw error
        } catch {
            throw SyncError.transport
        }
    }

    nonisolated private static func map(_ error: APIError) -> SyncError {
        switch error {
        case .unauthorized: return .unauthorized
        case .forbidden: return .forbidden
        case .decodingFailed: return .decoding
        case .server(let status, let payload):
            switch status {
            case 401: return .unauthorized
            case 403: return .forbidden
            case 409: return .conflict
            case 413: return .payloadTooLarge
            case 426: return .clientUpgradeRequired(minimumVersion: payload?.minimumVersion, minimumBuild: payload?.minimumBuild)
            case 429: return .rateLimited(retryAfterSeconds: payload?.retryAfterSeconds.map(TimeInterval.init))
            case 503: return .backendUnavailable
            default: return .transport
            }
        case .httpStatus(let status):
            switch status {
            case 401: return .unauthorized
            case 403: return .forbidden
            case 409: return .conflict
            case 413: return .payloadTooLarge
            case 426: return .clientUpgradeRequired(minimumVersion: nil, minimumBuild: nil)
            case 429: return .rateLimited(retryAfterSeconds: nil)
            case 503: return .backendUnavailable
            default: return .transport
            }
        case .timeout, .transport, .invalidResponse, .invalidURL, .cancelled,
             .notFound, .validation, .rateLimited:
            return .transport
        }
    }
}
