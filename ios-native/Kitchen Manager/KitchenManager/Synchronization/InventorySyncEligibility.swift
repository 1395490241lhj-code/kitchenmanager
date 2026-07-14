import Foundation

/// Phase 2B-4: the single, centralized place that decides whether an
/// ordinary Inventory CRUD operation is allowed to stage a `PendingMutation`.
/// Pure and stateless — every input is passed in explicitly, nothing is
/// re-derived here, so this is trivially unit-testable and must never be
/// duplicated inline in a View or a CRUD method.
nonisolated enum InventoryMutationIntent: Equatable, Sendable {
    case create
    case update
    case delete
}

nonisolated enum InventorySyncEligibilityResult: Equatable, Sendable {
    /// Not eligible — proceed local-only, exactly like today. Carries the
    /// reason only for diagnostics/tests; the UI never surfaces this text
    /// as an error (it's the ordinary, expected Guest-only path).
    case localOnly(reason: LocalOnlyReason)
    /// Eligible — stage a mutation using this baseVersion (nil means "no
    /// remote knowledge yet, use zero" — the create case).
    case eligible(baseVersion: SyncCursorValue?)
    /// The entity's metadata is already `.conflicted` — never silently
    /// stage over an unresolved conflict.
    case blockedByConflict
    /// The entity already has a pending delete staged — refuse to silently
    /// resurrect it via an ordinary update (section 十: forbidden this phase).
    case blockedByPendingDelete
    /// Phase 2B-5: the pending-mutation queue for this scope is already at
    /// its configured cap, and this would be a genuinely *new* pending
    /// mutation (not a coalesce into an already-queued one) — refused so the
    /// queue can never grow unbounded. Never applies to a `.delete` (never
    /// dropped) or to any mutation that would coalesce into an existing row.
    case blockedByQueueFull

    nonisolated enum LocalOnlyReason: Equatable, Sendable {
        case featureDisabled
        case notSignedIn
        case noHousehold
        case notEnrolled
        case noExistingMetadata
    }
}

/// Result of staging a CRUD-originated mutation through
/// `SyncPersistenceProtocol.stageInventoryMutation`. `.cancelled` is the
/// create+delete case (section 十一): the item was never sent remotely, so
/// deleting it locally before the next sync means there is nothing to send
/// at all — the pending mutation and its metadata are removed entirely,
/// never staged as a delete.
nonisolated enum InventoryMutationStagingOutcome: Equatable, Sendable {
    case staged(mutationId: UUID)
    case cancelled
}

nonisolated enum InventorySyncEligibility {
    static func evaluate(
        isFeatureEnabled: Bool,
        userId: UUID?,
        householdId: UUID?,
        enrollment: InventorySyncEnrollment?,
        existingMetadata: SyncMetadata?,
        intent: InventoryMutationIntent,
        hasExistingPendingMutationForEntity: Bool = false,
        currentPendingCount: Int = 0,
        maxPendingMutations: Int = InventorySyncDogfoodConfiguration.defaultMaxPendingMutations
    ) -> InventorySyncEligibilityResult {
        guard isFeatureEnabled else { return .localOnly(reason: .featureDisabled) }
        guard userId != nil else { return .localOnly(reason: .notSignedIn) }
        guard let householdId else { return .localOnly(reason: .noHousehold) }
        guard let enrollment, enrollment.householdId == householdId, enrollment.status.allowsMutationStaging else {
            return .localOnly(reason: .notEnrolled)
        }

        // Scope/ownership check: metadata (if any) must belong to the exact
        // same household this call is operating in. Different household or
        // different scope type is never treated as "existing" — that would
        // let one household's item continue syncing under another.
        let scopedMetadata = existingMetadata.flatMap { metadata -> SyncMetadata? in
            metadata.scope.type == .household && metadata.scope.id == householdId ? metadata : nil
        }

        if let scopedMetadata {
            if scopedMetadata.state == .conflicted { return .blockedByConflict }
            if scopedMetadata.state == .pendingDelete, intent != .delete { return .blockedByPendingDelete }
        }

        // Queue cap: only ever blocks a genuinely *new* pending mutation
        // (nothing already staged for this entity) and never a delete —
        // deletes must never be dropped, and coalescing into an existing
        // row never grows the queue, so it's always allowed through.
        if !hasExistingPendingMutationForEntity, intent != .delete, currentPendingCount >= maxPendingMutations {
            return .blockedByQueueFull
        }

        switch intent {
        case .create:
            // A brand-new local item created while enrolled is eligible even
            // though it has no existing metadata yet — that's the expected
            // "locally-created synced-scope inventory" case (section 七/C).
            return .eligible(baseVersion: nil)
        case .update, .delete:
            // An update/delete on an item this device never staged/learned
            // about remotely stays local-only — only items with their own
            // household-scoped metadata (created via this enrollment, or
            // already merged) are eligible. This is what keeps Guest-only
            // items (created before enrollment, or with the feature
            // re-disabled and re-enabled) from suddenly syncing.
            guard let scopedMetadata else { return .localOnly(reason: .noExistingMetadata) }
            return .eligible(baseVersion: scopedMetadata.remoteVersion)
        }
    }
}
