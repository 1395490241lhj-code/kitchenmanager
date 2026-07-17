import Foundation

@MainActor
protocol AccountDeletionService: AnyObject {
    func preview(accessToken: String) async throws -> AccountDeletionPreview
    func transferCandidates(accessToken: String, householdId: UUID) async throws -> [TransferCandidate]
    func transferOwnership(accessToken: String, householdId: UUID, newOwnerUserId: UUID) async throws
    func createReauthenticationProof(
        accessToken: String,
        confirmationVersion: String
    ) async throws -> AccountDeletionReauthenticationResult
    func confirmDeletion(
        accessToken: String,
        idempotencyKey: UUID,
        confirmationVersion: String,
        reauthenticationProof: String
    ) async throws -> AccountDeletionConfirmResult
}

@MainActor
final class APIAccountDeletionService: AccountDeletionService {
    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    private func mapError(_ error: Error) -> Error {
        guard case let APIError.server(_, payload) = error else {
            if case APIError.timeout = error { return AccountDeletionError.unavailable }
            return error
        }
        return AccountDeletionError(code: payload?.code)
    }

    func preview(accessToken: String) async throws -> AccountDeletionPreview {
        do {
            return try await client.send(
                .raw(path: "api/account/delete/preview", headers: ["Authorization": "Bearer \(accessToken)"], body: nil, timeout: 20)
            )
        } catch {
            throw mapError(error)
        }
    }

    func transferCandidates(accessToken: String, householdId: UUID) async throws -> [TransferCandidate] {
        do {
            let body = try JSONEncoder().encode(["householdId": householdId.uuidString.lowercased()])
            let response: TransferCandidatesResponse = try await client.send(
                .raw(
                    path: "api/account/list-transfer-candidates",
                    headers: ["Authorization": "Bearer \(accessToken)", "Content-Type": "application/json"],
                    body: body,
                    timeout: 20
                )
            )
            return response.members
        } catch {
            throw mapError(error)
        }
    }

    func transferOwnership(accessToken: String, householdId: UUID, newOwnerUserId: UUID) async throws {
        do {
            let body = try JSONEncoder().encode([
                "householdId": householdId.uuidString.lowercased(),
                "newOwnerUserId": newOwnerUserId.uuidString.lowercased()
            ])
            try await client.sendExpectingEmptyResponse(
                .raw(
                    path: "api/account/transfer-ownership",
                    headers: ["Authorization": "Bearer \(accessToken)", "Content-Type": "application/json"],
                    body: body,
                    timeout: 20
                )
            )
        } catch {
            throw mapError(error)
        }
    }

    func createReauthenticationProof(
        accessToken: String,
        confirmationVersion: String
    ) async throws -> AccountDeletionReauthenticationResult {
        do {
            let body = try JSONEncoder().encode(["confirmationVersion": confirmationVersion])
            return try await client.send(
                .raw(
                    path: "api/account/delete/reauthenticate",
                    headers: ["Authorization": "Bearer \(accessToken)", "Content-Type": "application/json"],
                    body: body,
                    timeout: 20
                )
            )
        } catch {
            throw mapError(error)
        }
    }

    func confirmDeletion(
        accessToken: String,
        idempotencyKey: UUID,
        confirmationVersion: String,
        reauthenticationProof: String
    ) async throws -> AccountDeletionConfirmResult {
        do {
            let body = try JSONEncoder().encode(ConfirmRequestBody(
                idempotencyKey: idempotencyKey.uuidString.lowercased(),
                confirmationVersion: confirmationVersion,
                reauthenticationProof: reauthenticationProof
            ))
            return try await client.send(
                .raw(
                    path: "api/account/delete/confirm",
                    headers: ["Authorization": "Bearer \(accessToken)", "Content-Type": "application/json"],
                    body: body,
                    timeout: 30
                )
            )
        } catch {
            throw mapError(error)
        }
    }

    nonisolated private struct TransferCandidatesResponse: Decodable { let members: [TransferCandidate] }
    nonisolated private struct ConfirmRequestBody: Encodable {
        let idempotencyKey: String
        let confirmationVersion: String
        let reauthenticationProof: String
    }
}

@MainActor
final class UnavailableAccountDeletionService: AccountDeletionService {
    func preview(accessToken: String) async throws -> AccountDeletionPreview { throw AccountDeletionError.unavailable }
    func transferCandidates(accessToken: String, householdId: UUID) async throws -> [TransferCandidate] { throw AccountDeletionError.unavailable }
    func transferOwnership(accessToken: String, householdId: UUID, newOwnerUserId: UUID) async throws { throw AccountDeletionError.unavailable }
    func createReauthenticationProof(accessToken: String, confirmationVersion: String) async throws -> AccountDeletionReauthenticationResult { throw AccountDeletionError.unavailable }
    func confirmDeletion(
        accessToken: String,
        idempotencyKey: UUID,
        confirmationVersion: String,
        reauthenticationProof: String
    ) async throws -> AccountDeletionConfirmResult { throw AccountDeletionError.unavailable }
}
