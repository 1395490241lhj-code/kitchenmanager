import Foundation
import Combine

/// A second, independent guard for the one-off development smoke. Unlike
/// `SYNC_ENABLED`, this is never a product feature flag and is false in every
/// Release build even if a build setting is accidentally supplied.
nonisolated struct SyncSmokeConfiguration: Equatable, Sendable {
    let isSmokeEnabled: Bool
    let isDevelopmentBuild: Bool
    let isDevelopmentEnvironment: Bool

    init(
        isSmokeEnabled: Bool = false,
        isDevelopmentBuild: Bool = false,
        isDevelopmentEnvironment: Bool = false
    ) {
        self.isSmokeEnabled = isSmokeEnabled
        self.isDevelopmentBuild = isDevelopmentBuild
        self.isDevelopmentEnvironment = isDevelopmentEnvironment
    }

    var isAvailable: Bool {
        isSmokeEnabled && isDevelopmentBuild && isDevelopmentEnvironment
    }

    static func load(from bundle: Bundle = .main) -> SyncSmokeConfiguration {
        #if DEBUG
        let isDevelopmentBuild = true
        #else
        let isDevelopmentBuild = false
        #endif
        guard let rawValue = bundle.object(forInfoDictionaryKey: "KM_SYNC_SMOKE_ENABLED") else {
            return SyncSmokeConfiguration(isDevelopmentBuild: isDevelopmentBuild)
        }
        let normalized = String(describing: rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return SyncSmokeConfiguration(
            isSmokeEnabled: ["1", "true", "yes"].contains(normalized),
            isDevelopmentBuild: isDevelopmentBuild,
            isDevelopmentEnvironment: ((bundle.object(
                forInfoDictionaryKey: "KM_SYNC_SMOKE_ENVIRONMENT"
            ) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) == "development"
        )
    }
}

nonisolated enum SyncSmokeError: LocalizedError, Equatable, Sendable {
    case smokeDisabled
    case nonDevelopmentBuild
    case nonDevelopmentEnvironment
    case syncDisabled
    case notAuthenticated
    case missingDefaultHousehold
    case invalidBootstrap
    case unexpectedOutcome
    case validationFailed

    var errorDescription: String? {
        switch self {
        case .smokeDisabled: "Development sync smoke is disabled."
        case .nonDevelopmentBuild: "Development sync smoke is unavailable in this build."
        case .nonDevelopmentEnvironment: "Development sync smoke requires the explicit development environment setting."
        case .syncDisabled: "Sync must be enabled only for this development smoke run."
        case .notAuthenticated: "Sign in with the development test account before running smoke."
        case .missingDefaultHousehold: "The signed-in development account has no default household scope."
        case .invalidBootstrap: "The development sync bootstrap could not be verified."
        case .unexpectedOutcome: "The development sync smoke did not reach its expected state."
        case .validationFailed: "The development sync smoke validation failed."
        }
    }
}

nonisolated struct SyncSmokeReport: Equatable, Sendable {
    let createApplied: Bool
    let updateApplied: Bool
    let duplicateHandled: Bool
    let conflictRetained: Bool
    let softDeleteApplied: Bool
    let cursorAdvanced: Bool
    let finalPullWasIdempotent: Bool
}

#if DEBUG
@MainActor
final class AuthStoreSyncTokenProvider: SyncAccessTokenProviding {
    private weak var authStore: AuthStore?

    init(authStore: AuthStore) {
        self.authStore = authStore
    }

    func accessToken() async -> String? {
        await authStore?.developmentSyncSmokeSession()?.accessToken
    }
}

/// Explicitly invoked from the Debug-only developer section. The runner never
/// scans a repository: it stages exactly one newly generated, development
/// marked inventory item in the selected default household scope.
@MainActor
final class SyncSmokeRunner {
    private let configuration: SyncConfiguration
    private let smokeConfiguration: SyncSmokeConfiguration
    private let persistence: any SyncPersistenceProtocol
    private let transportFactory: @MainActor (any SyncAccessTokenProviding) -> any SyncTransport

    init(
        configuration: SyncConfiguration,
        smokeConfiguration: SyncSmokeConfiguration,
        persistence: any SyncPersistenceProtocol,
        transportFactory: @escaping @MainActor (any SyncAccessTokenProviding) -> any SyncTransport = { provider in
            ExpressSyncTransport(tokenProvider: provider)
        }
    ) {
        self.configuration = configuration
        self.smokeConfiguration = smokeConfiguration
        self.persistence = persistence
        self.transportFactory = transportFactory
    }

    func run(using authStore: AuthStore) async throws -> SyncSmokeReport {
        guard smokeConfiguration.isSmokeEnabled else { throw SyncSmokeError.smokeDisabled }
        guard smokeConfiguration.isDevelopmentBuild else { throw SyncSmokeError.nonDevelopmentBuild }
        guard smokeConfiguration.isDevelopmentEnvironment,
              APIEnvironment.current == .development else {
            throw SyncSmokeError.nonDevelopmentEnvironment
        }
        guard configuration.isEnabled else { throw SyncSmokeError.syncDisabled }
        guard let session = authStore.developmentSyncSmokeSession() else {
            throw SyncSmokeError.notAuthenticated
        }

        let provider = AuthStoreSyncTokenProvider(authStore: authStore)
        let transport = transportFactory(provider)
        let coordinator = SyncCoordinator(
            configuration: configuration,
            persistence: persistence,
            transport: transport
        )
        let authentication = SyncAuthenticationContext(userID: session.user.id, isAuthenticated: true)
        let bootstrap = try await transport.bootstrap()
        guard bootstrap.schemaVersion == 1, bootstrap.user.id == session.user.id else {
            throw SyncSmokeError.invalidBootstrap
        }
        guard let householdID = bootstrap.defaultHouseholdId,
              let descriptor = bootstrap.syncScopes.first(where: {
                  $0.type == .household && $0.id == householdID
              }) else {
            throw SyncSmokeError.missingDefaultHousehold
        }

        let scope = descriptor.scope
        let currentCursor = try await persistence.cursor(for: scope)
        guard currentCursor.value <= descriptor.cursor else { throw SyncSmokeError.invalidBootstrap }
        if currentCursor.value < descriptor.cursor {
            try await persistence.advanceCursor(scope: scope, to: descriptor.cursor, at: Date())
        }

        let shortMarker = String(UUID().uuidString.prefix(8)).lowercased()
        var item = InventoryItem(
            name: "__sync_smoke_inventory_\(shortMarker)",
            quantity: 2,
            unit: "个",
            expiryDate: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        let adapter = InventorySyncAdapter(persistence: persistence)
        var needsCleanup = false

        do {
            _ = try await adapter.stageUpsert(item: item, scope: scope)
            needsCleanup = true
            try await requireCompleted(await coordinator.runOnce(authentication: authentication, scopes: [scope]))
            let createdMetadata = try await requireMetadata(for: item.id, state: .synced, version: "1")
            guard try await persistence.inventoryItem(id: item.id) != nil,
                  try await pending(for: item.id, scope: scope).isEmpty else {
                throw SyncSmokeError.validationFailed
            }
            let createCursor = try await persistence.cursor(for: scope)
            guard createCursor.value > descriptor.cursor else { throw SyncSmokeError.validationFailed }

            item.quantity = 3
            item.updatedAt = Date()
            let updateID = try await adapter.stageUpsert(item: item, scope: scope)
            let originalUpdate = try await pending(for: item.id, scope: scope)
                .first(where: { $0.mutationId == updateID })
            guard let originalUpdate else { throw SyncSmokeError.validationFailed }
            try await requireCompleted(await coordinator.runOnce(authentication: authentication, scopes: [scope]))
            _ = try await requireMetadata(for: item.id, state: .synced, version: "2")
            let updateCursor = try await persistence.cursor(for: scope)
            guard updateCursor.value > createCursor.value else { throw SyncSmokeError.validationFailed }

            // Requeue the identical persisted mutation. The server must answer
            // duplicate without creating a version or change-feed increment.
            try await persistence.savePending(originalUpdate)
            try await requireCompleted(await coordinator.runOnce(authentication: authentication, scopes: [scope]))
            let duplicateMetadata = try await requireMetadata(for: item.id, state: .synced, version: "2")
            let duplicateCursor = try await persistence.cursor(for: scope)
            guard duplicateCursor.value == updateCursor.value,
                  try await pending(for: item.id, scope: scope).isEmpty else {
                throw SyncSmokeError.validationFailed
            }

            item.quantity = 4
            item.updatedAt = Date()
            let conflictID = try await adapter.stageSmokeUpsert(
                item: item,
                scope: scope,
                staleBaseVersion: try SyncCursorValue("1")
            )
            try await requireCompleted(await coordinator.runOnce(authentication: authentication, scopes: [scope]))
            let conflictMetadata = try await requireMetadata(for: item.id, state: .conflicted, version: "2")
            let conflictPending = try await persistence.pendingMutation(id: conflictID)
            guard conflictPending?.status == .conflict,
                  try await persistence.inventoryItem(id: item.id)?.quantity == 4 else {
                throw SyncSmokeError.validationFailed
            }

            // Conflict remains observable above. Only the marked smoke mutation
            // is explicitly discarded before a correctly versioned soft delete.
            try await persistence.discardPendingMutation(id: conflictID)
            try await persistence.saveMetadata(SyncMetadata(
                entityType: conflictMetadata.entityType,
                entityId: conflictMetadata.entityId,
                scope: conflictMetadata.scope,
                remoteVersion: conflictMetadata.remoteVersion,
                state: .synced,
                lastSyncedAt: conflictMetadata.lastSyncedAt,
                lastErrorCode: nil,
                lastErrorAt: nil,
                deletedAt: nil,
                updatedAt: Date()
            ))
            _ = try await adapter.stageDelete(entityId: item.id, scope: scope)
            try await requireCompleted(await coordinator.runOnce(authentication: authentication, scopes: [scope]))
            let deletedMetadata = try await requireMetadata(for: item.id, state: .synced, version: "3")
            let deleteCursor = try await persistence.cursor(for: scope)
            guard deletedMetadata.deletedAt != nil,
                  try await persistence.inventoryItem(id: item.id) == nil,
                  try await pending(for: item.id, scope: scope).isEmpty,
                  deleteCursor.value > duplicateCursor.value else {
                throw SyncSmokeError.validationFailed
            }

            try await requireCompleted(await coordinator.runOnce(authentication: authentication, scopes: [scope]))
            let finalCursor = try await persistence.cursor(for: scope)
            guard finalCursor.value == deleteCursor.value else { throw SyncSmokeError.validationFailed }
            needsCleanup = false
            _ = createdMetadata
            _ = duplicateMetadata
            return SyncSmokeReport(
                createApplied: true,
                updateApplied: true,
                duplicateHandled: true,
                conflictRetained: true,
                softDeleteApplied: true,
                cursorAdvanced: true,
                finalPullWasIdempotent: true
            )
        } catch {
            if needsCleanup {
                try? await cleanupMarkedItem(item.id, scope: scope, adapter: adapter, coordinator: coordinator, authentication: authentication)
            }
            throw error
        }
    }

    private func pending(for id: UUID, scope: SyncScope) async throws -> [PendingMutation] {
        try await persistence.pendingMutations(scope: scope, maxAttempts: configuration.maxMutationAttempts)
            .filter { $0.entityId == id }
    }

    private func requireMetadata(
        for id: UUID,
        state: EntitySyncState,
        version: String
    ) async throws -> SyncMetadata {
        guard let metadata = try await persistence.metadata(entityType: .inventoryItem, entityId: id),
              metadata.state == state,
              metadata.remoteVersion?.rawValue == version else {
            throw SyncSmokeError.validationFailed
        }
        return metadata
    }

    private func requireCompleted(_ outcome: SyncRunOutcome) async throws {
        guard outcome == .completed else { throw SyncSmokeError.unexpectedOutcome }
    }

    private func cleanupMarkedItem(
        _ itemID: UUID,
        scope: SyncScope,
        adapter: InventorySyncAdapter,
        coordinator: SyncCoordinator,
        authentication: SyncAuthenticationContext
    ) async throws {
        let pending = try await self.pending(for: itemID, scope: scope)
        for mutation in pending {
            try await persistence.discardPendingMutation(id: mutation.mutationId)
        }
        guard let metadata = try await persistence.metadata(entityType: .inventoryItem, entityId: itemID),
              let version = metadata.remoteVersion else { return }
        try await persistence.saveMetadata(SyncMetadata(
            entityType: metadata.entityType,
            entityId: metadata.entityId,
            scope: metadata.scope,
            remoteVersion: version,
            state: .synced,
            lastSyncedAt: metadata.lastSyncedAt,
            lastErrorCode: nil,
            lastErrorAt: nil,
            deletedAt: nil,
            updatedAt: Date()
        ))
        _ = try await adapter.stageDelete(entityId: itemID, scope: scope)
        _ = await coordinator.runOnce(authentication: authentication, scopes: [scope])
    }
}

@MainActor
final class SyncSmokeController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage: String?

    private let persistence: any SyncPersistenceProtocol

    init(persistence: any SyncPersistenceProtocol) {
        self.persistence = persistence
    }

    var isAvailable: Bool { SyncSmokeConfiguration.load().isAvailable }

    func run(
        authStore: AuthStore,
        kitchenStore: KitchenStore,
        recipeStore: RecipeStore
    ) async {
        guard !isRunning else { return }
        isRunning = true
        statusMessage = nil
        let before = GuestDataCounts(
            inventory: kitchenStore.inventory.count,
            shopping: kitchenStore.shoppingItems.count,
            plans: kitchenStore.plans.count,
            hasWeeklyPlan: kitchenStore.weeklyPlan != nil,
            userRecipes: recipeStore.userRecipes.count
        )
        defer { isRunning = false }

        do {
            let runner = SyncSmokeRunner(
                configuration: SyncConfiguration.load(),
                smokeConfiguration: SyncSmokeConfiguration.load(),
                persistence: persistence
            )
            _ = try await runner.run(using: authStore)
            let after = GuestDataCounts(
                inventory: kitchenStore.inventory.count,
                shopping: kitchenStore.shoppingItems.count,
                plans: kitchenStore.plans.count,
                hasWeeklyPlan: kitchenStore.weeklyPlan != nil,
                userRecipes: recipeStore.userRecipes.count
            )
            guard before == after else { throw SyncSmokeError.validationFailed }
            statusMessage = "Sync smoke passed. Guest data counts are unchanged."
        } catch {
            statusMessage = (error as? LocalizedError)?.errorDescription
                ?? "Development sync smoke failed."
        }
    }
}

private struct GuestDataCounts: Equatable {
    let inventory: Int
    let shopping: Int
    let plans: Int
    let hasWeeklyPlan: Bool
    let userRecipes: Int
}
#endif
