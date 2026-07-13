import Foundation

@MainActor
final class APIAccountService: AccountService {
    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func currentAccount(accessToken: String) async throws -> CurrentAccount {
        do {
            return try await client.send(
                .get(
                    path: "api/me",
                    headers: ["Authorization": "Bearer \(accessToken)"],
                    timeout: 30
                )
            )
        } catch let error as APIError {
            switch error {
            case .server(let status, _) where status == 401: throw AccountServiceError.unauthorized
            case .server(let status, _) where status == 403: throw AccountServiceError.forbidden
            case .decodingFailed: throw AccountServiceError.invalidResponse
            default: throw AccountServiceError.temporarilyUnavailable
            }
        } catch {
            throw AccountServiceError.temporarilyUnavailable
        }
    }
}
