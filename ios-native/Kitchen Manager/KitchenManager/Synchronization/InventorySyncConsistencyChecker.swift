import Foundation

/// Phase 2B-5: a pure, read-only consistency checker over already-fetched
/// sync state. Never writes anything, never auto-fixes anything — every
/// finding is returned as a redacted `InventorySyncConsistencyIssue` for the
/// caller (dogfood diagnostics, or a test) to display/assert on. Used
/// exactly like `InventorySyncEligibility`: a stateless function, not an
/// object with hidden state, so it's trivially unit-testable.
nonisolated enum InventorySyncConsistencyChecker {
    static func check(
        localInventoryIds: Set<UUID>,
        allMetadata: [SyncMetadata],
        allPendingMutations: [PendingMutation],
        enrollment: InventorySyncEnrollment?,
        expectedUserId: UUID?,
        expectedHouseholdId: UUID?,
        activeMergeSession: GuestMergeSession?,
        previousCursorValue: SyncCursorValue?,
        currentCursorValue: SyncCursorValue?
    ) -> [InventorySyncConsistencyIssue] {
        var issues: [InventorySyncConsistencyIssue] = []
        let metadataByEntity = Dictionary(uniqueKeysWithValues: allMetadata.map { ($0.entityId, $0) })
        var pendingByEntity: [UUID: [PendingMutation]] = [:]
        for mutation in allPendingMutations {
            pendingByEntity[mutation.entityId, default: []].append(mutation)
        }

        for metadata in allMetadata {
            let isVisibleLocally = localInventoryIds.contains(metadata.entityId)

            // 1. synced/pending metadata pointing at a record that no
            // longer exists locally, without ever having staged a delete.
            if !isVisibleLocally, metadata.deletedAt == nil, metadata.state != .pendingDelete {
                issues.append(InventorySyncConsistencyIssue(code: .orphanMetadataNoInventoryRecord, shortId: InventorySyncConsistencyIssue.short(metadata.entityId)))
            }

            // 2. metadata's own scope disagrees with the current enrollment's household.
            if let enrollment, metadata.scope.type == .household, metadata.scope.id != enrollment.householdId {
                issues.append(InventorySyncConsistencyIssue(code: .metadataScopeEnrollmentMismatch, shortId: InventorySyncConsistencyIssue.short(metadata.entityId)))
            }

            // 6. an update/delete-in-progress item with no known remote version at all.
            if (metadata.state == .pendingUpdate || metadata.state == .pendingDelete), metadata.remoteVersion == nil {
                issues.append(InventorySyncConsistencyIssue(code: .updateOrDeletePendingMissingRemoteVersion, shortId: InventorySyncConsistencyIssue.short(metadata.entityId)))
            }

            // 7. conflicted metadata with no corresponding pending mutation at all.
            if metadata.state == .conflicted, (pendingByEntity[metadata.entityId] ?? []).isEmpty {
                issues.append(InventorySyncConsistencyIssue(code: .conflictedMetadataMissingPendingMutation, shortId: InventorySyncConsistencyIssue.short(metadata.entityId)))
            }

            // 8. a tombstone (staged delete, or already deletedAt) that is
            // somehow still visible in the local inventory list.
            if (metadata.state == .pendingDelete || metadata.deletedAt != nil), isVisibleLocally {
                issues.append(InventorySyncConsistencyIssue(code: .tombstoneConflictsWithVisibleLocalRecord, shortId: InventorySyncConsistencyIssue.short(metadata.entityId)))
            }

            // 14. a Guest-only workspace (no/irrelevant enrollment) that
            // somehow still has a household-bound, non-terminal metadata row.
            if isVisibleLocally, metadata.state != .synced, metadata.state != .failed,
               (enrollment == nil || !enrollment!.status.allowsMutationStaging) {
                issues.append(InventorySyncConsistencyIssue(code: .guestOnlyItemBoundToHousehold, shortId: InventorySyncConsistencyIssue.short(metadata.entityId)))
            }
        }

        for (entityId, mutations) in pendingByEntity {
            let active = mutations.filter { $0.status == .pending || $0.status == .inFlight || $0.status == .failed }

            // 3. a pending mutation with no metadata row for its entity at all.
            if metadataByEntity[entityId] == nil {
                issues.append(InventorySyncConsistencyIssue(code: .orphanPendingMutationNoMetadata, shortId: InventorySyncConsistencyIssue.short(entityId)))
            }

            // 4. a pending mutation whose scope disagrees with its own entity's metadata scope.
            if let metadata = metadataByEntity[entityId] {
                if mutations.contains(where: { $0.scope != metadata.scope }) {
                    issues.append(InventorySyncConsistencyIssue(code: .pendingMutationScopeMismatch, shortId: InventorySyncConsistencyIssue.short(entityId)))
                }
                // 5. a create-in-progress mutation whose baseVersion isn't zero.
                if metadata.state == .pendingCreate,
                   mutations.contains(where: { $0.operation == .upsert && $0.baseVersion != .zero }) {
                    issues.append(InventorySyncConsistencyIssue(code: .createPendingWithNonZeroBaseVersion, shortId: InventorySyncConsistencyIssue.short(entityId)))
                }
            }

            // 9. more than one currently-active mutation for the same entity
            // — coalescing should always keep this at exactly one.
            if active.count > 1 {
                issues.append(InventorySyncConsistencyIssue(code: .multiplePendingMutationsForSameEntity, shortId: InventorySyncConsistencyIssue.short(entityId)))
            }
        }

        // 10. duplicate forkedLocalItemId across the active session's own candidates.
        if let plan = activeMergeSession?.plan {
            let forkIds = plan.candidates.compactMap(\.forkedLocalItemId)
            if Set(forkIds).count != forkIds.count {
                issues.append(InventorySyncConsistencyIssue(code: .duplicateForkId, shortId: nil))
            }
        }

        // 11. an active, non-terminal session in a status that requires a
        // plan, but has none.
        if let session = activeMergeSession {
            let requiresPlan: Set<GuestMergeSessionStatus> = [.previewReady, .awaitingConfirmation, .conflict, .preparing, .uploading, .rollbackPending]
            if requiresPlan.contains(session.status), session.plan == nil {
                issues.append(InventorySyncConsistencyIssue(code: .mergeSessionMissingPlan, shortId: nil))
            }
        }

        // 12. the fetched enrollment doesn't actually match the caller's
        // asserted (userId, householdId) — a defensive self-check.
        if let enrollment, let expectedUserId, let expectedHouseholdId,
           enrollment.userId != expectedUserId || enrollment.householdId != expectedHouseholdId {
            issues.append(InventorySyncConsistencyIssue(code: .enrollmentUserHouseholdMismatch, shortId: nil))
        }

        // 13. the cursor moved backwards since the last known value. Skipped
        // (not a false positive, genuinely not checkable) when no baseline
        // was supplied.
        if let previousCursorValue, let currentCursorValue, currentCursorValue < previousCursorValue {
            issues.append(InventorySyncConsistencyIssue(code: .cursorRegressed, shortId: nil))
        }

        return issues
    }
}
