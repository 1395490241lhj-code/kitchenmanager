import Foundation
import SwiftData

/// Phase 2B-4: whether a (user, household) inventory *workspace* has moved
/// past "some items happen to have SyncMetadata" into an explicit, durable
/// state where ordinary CRUD is expected to stage mutations. Never inferred
/// from "does any SyncMetadata row exist" — that would conflate one merged
/// item with the whole workspace being sync-aware, and would not survive a
/// sign-out/sign-in as a different user on the same device.
nonisolated enum InventorySyncEnrollmentStatus: String, Codable, Sendable {
    /// No merge has ever completed for this (user, household); no other
    /// explicit enable step has happened either. Every CRUD stays local-only.
    case notEnrolled
    /// Local Guest inventory exists but the merge that would enroll this
    /// workspace has not been confirmed yet. Still local-only.
    case mergeRequired
    /// A Guest merge has completed (or the workspace was explicitly enabled
    /// with no Guest data to merge) — ordinary CRUD may stage mutations,
    /// subject to `INVENTORY_SYNC_ENABLED` and per-item eligibility.
    case enrolled
    /// Enrolled, but temporarily suspended (reserved for future use — no
    /// code path sets this in Phase 2B-4; included so `revoked`/`paused`
    /// don't need a second schema migration later).
    case paused
    /// Enrollment was explicitly revoked. Reserved for future use.
    case revoked

    var allowsMutationStaging: Bool { self == .enrolled }
}

nonisolated struct InventorySyncEnrollment: Equatable, Sendable {
    let userId: UUID
    let householdId: UUID
    var status: InventorySyncEnrollmentStatus
    var enrolledAt: Date?
    var mergeSessionId: UUID?
    let schemaVersion: Int
    var updatedAt: Date

    static let currentSchemaVersion = 1

    var uniqueKey: String { Self.uniqueKey(userId: userId, householdId: householdId) }

    static func uniqueKey(userId: UUID, householdId: UUID) -> String {
        "\(userId.uuidString.lowercased()):\(householdId.uuidString.lowercased())"
    }

    static func notEnrolled(userId: UUID, householdId: UUID) -> InventorySyncEnrollment {
        InventorySyncEnrollment(
            userId: userId, householdId: householdId, status: .notEnrolled,
            enrolledAt: nil, mergeSessionId: nil, schemaVersion: currentSchemaVersion, updatedAt: Date()
        )
    }
}

@Model
final class InventorySyncEnrollmentRecord {
    @Attribute(.unique) var uniqueKey: String
    var userId: UUID
    var householdId: UUID
    var statusRawValue: String
    var enrolledAt: Date?
    var mergeSessionId: UUID?
    var schemaVersion: Int
    var updatedAt: Date

    init(enrollment: InventorySyncEnrollment) {
        uniqueKey = enrollment.uniqueKey
        userId = enrollment.userId
        householdId = enrollment.householdId
        statusRawValue = enrollment.status.rawValue
        enrolledAt = enrollment.enrolledAt
        mergeSessionId = enrollment.mergeSessionId
        schemaVersion = enrollment.schemaVersion
        updatedAt = enrollment.updatedAt
    }

    func update(from enrollment: InventorySyncEnrollment) {
        statusRawValue = enrollment.status.rawValue
        enrolledAt = enrollment.enrolledAt
        mergeSessionId = enrollment.mergeSessionId
        updatedAt = enrollment.updatedAt
    }

    var value: InventorySyncEnrollment? {
        guard let status = InventorySyncEnrollmentStatus(rawValue: statusRawValue) else { return nil }
        return InventorySyncEnrollment(
            userId: userId, householdId: householdId, status: status,
            enrolledAt: enrolledAt, mergeSessionId: mergeSessionId,
            schemaVersion: schemaVersion, updatedAt: updatedAt
        )
    }
}
