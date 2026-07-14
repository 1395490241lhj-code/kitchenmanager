import Foundation

nonisolated enum SyncRunOutcome: Equatable, Sendable {
    case disabled
    case paused(SyncError)
    case completed
    case alreadyRunning
    case failed(SyncError)
}

actor SyncCoordinator {
    private let configuration: SyncConfiguration
    private let persistence: any SyncPersistenceProtocol
    private let transport: any SyncTransport
    private let inventoryAdapter: InventorySyncAdapter
    private var runState: SyncRunState
    private var isRunning = false

    init(
        configuration: SyncConfiguration,
        persistence: any SyncPersistenceProtocol,
        transport: any SyncTransport
    ) {
        self.configuration = configuration
        self.persistence = persistence
        self.transport = transport
        inventoryAdapter = InventorySyncAdapter(persistence: persistence)
        runState = configuration.isEnabled ? .idle : .disabled
    }

    func state() -> SyncRunState { runState }

    /// Explicit test/manual boundary only. Phase 2A-3 deliberately has no call
    /// site in App startup, AuthStore, background tasks, or inventory screens.
    func runOnce(
        authentication: SyncAuthenticationContext?,
        scopes requestedScopes: Set<SyncScope>? = nil
    ) async -> SyncRunOutcome {
        guard configuration.isEnabled else {
            runState = .disabled
            return .disabled
        }
        guard !isRunning else { return .alreadyRunning }
        guard let authentication, authentication.isAuthenticated else {
            runState = .paused
            return .paused(.notAuthenticated)
        }

        isRunning = true
        defer { isRunning = false }
        do {
            runState = .preparing
            let bootstrap = try await transport.bootstrap()
            guard bootstrap.schemaVersion == 1,
                  bootstrap.user.id == authentication.userID else {
                throw SyncError.invalidConfiguration
            }
            let availableScopes = bootstrap.syncScopes
            guard !availableScopes.isEmpty else {
                runState = .paused
                return .paused(.forbidden)
            }

            let selectedScopes: [SyncScopeDescriptor]
            if let requestedScopes {
                selectedScopes = availableScopes.filter { requestedScopes.contains($0.scope) }
                guard selectedScopes.count == requestedScopes.count else {
                    runState = .paused
                    return .paused(.forbidden)
                }
            } else {
                selectedScopes = availableScopes
            }

            for descriptor in selectedScopes {
                try await push(scope: descriptor.scope)
                try await pull(scope: descriptor.scope)
            }
            runState = .idle
            return .completed
        } catch let error as SyncError {
            runState = error == .notAuthenticated ? .paused : .failed
            return error == .notAuthenticated ? .paused(error) : .failed(error)
        } catch {
            runState = .failed
            return .failed(.transport)
        }
    }

    private func push(scope: SyncScope) async throws {
        let pending = try await persistence.pendingMutations(
            scope: scope,
            maxAttempts: configuration.maxMutationAttempts
        )
        guard !pending.isEmpty else { return }
        guard pending.allSatisfy({ $0.entityType == .inventoryItem }) else {
            throw SyncError.unsupportedEntity
        }

        runState = .pushing
        let ids = pending.map(\.mutationId)
        let now = Date()
        try await persistence.markInFlight(
            ids: ids,
            attemptedAt: now,
            maxAttempts: configuration.maxMutationAttempts
        )
        do {
            let response = try await transport.sendMutations(
                scope: scope,
                mutations: try pending.map { try $0.asMutation() }
            )
            let expected = Set(ids)
            guard Set(response.results.map(\.mutationId)).isSubset(of: expected) else {
                throw SyncError.decoding
            }
            for result in response.results {
                try await persistence.resolvePending(result, resolvedAt: Date())
            }
            let resolved = Set(response.results.map(\.mutationId))
            let missing = ids.filter { !resolved.contains($0) }
            if !missing.isEmpty {
                try await persistence.markPendingFailed(
                    ids: missing,
                    code: "missing_mutation_result",
                    attemptedAt: Date(),
                    maxAttempts: configuration.maxMutationAttempts
                )
                throw SyncError.decoding
            }
        } catch {
            try? await persistence.markPendingFailed(
                ids: ids,
                code: Self.errorCode(error),
                attemptedAt: Date(),
                maxAttempts: configuration.maxMutationAttempts
            )
            throw error
        }
    }

    private func pull(scope: SyncScope) async throws {
        var current = try await persistence.cursor(for: scope).value
        var hasMore = true
        while hasMore {
            runState = .pulling
            let response = try await transport.fetchChanges(
                scope: scope,
                after: current,
                limit: configuration.pullLimit
            )
            guard response.scope == scope, response.cursor >= current else {
                throw SyncError.invalidCursor
            }
            guard response.changes.allSatisfy({ $0.entityType == .inventoryItem }) else {
                throw SyncError.unsupportedEntity
            }

            runState = .applying
            for change in response.changes {
                _ = try await inventoryAdapter.applyRemote(change, scope: scope)
            }
            try await persistence.advanceCursor(scope: scope, to: response.cursor, at: Date())
            current = response.cursor
            hasMore = response.hasMore
            if hasMore, response.changes.isEmpty { throw SyncError.invalidCursor }
        }
    }

    private static func errorCode(_ error: Error) -> String {
        if let syncError = error as? SyncError {
            return String(describing: syncError)
        }
        return "transport"
    }
}
