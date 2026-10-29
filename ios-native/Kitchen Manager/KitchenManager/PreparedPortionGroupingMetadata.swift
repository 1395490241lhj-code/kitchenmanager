import Foundation

nonisolated enum PreparedGroupingValidationError: Error, Equatable {
    case unsupportedVersion(Int)
    case duplicateID
    case inconsistentSource
    case invalidComponent
    case invalidAllocation
    case staleSnapshot
}

/// Versioned value stored inside the existing Prepared row, never a parent record.
nonisolated struct PreparedPortionGrouping: Hashable, Codable, Sendable {
    static let currentVersion = 1
    let version: Int
    let source: PreparedSourceSnapshot
    let massPerPortionDecigrams: Int64

    init(source: PreparedSourceSnapshot, massPerPortionDecigrams: Int64) throws {
        let q = source.initialMassDecigrams / Int64(source.initialPortionCount)
        let r = source.initialMassDecigrams % Int64(source.initialPortionCount)
        let (larger, overflow) = q.addingReportingOverflow(1)
        guard massPerPortionDecigrams == q || (r > 0 && !overflow && massPerPortionDecigrams == larger) else {
            throw PreparedGroupingValidationError.invalidAllocation
        }
        version = Self.currentVersion
        self.source = source
        self.massPerPortionDecigrams = massPerPortionDecigrams
    }

    /// A decoding DTO deliberately re-enters Slice 1's validated initializer.
    /// Synthesized decoding on the snapshot itself would bypass its invariants.
    private struct SourcePayload: Codable {
        let id: UUID
        let name: String
        let initialMassDecigrams: Int64
        let initialPortionCount: Int
        init(_ source: PreparedSourceSnapshot) {
            id = source.id
            name = source.name
            initialMassDecigrams = source.initialMassDecigrams
            initialPortionCount = source.initialPortionCount
        }
        func snapshot() throws -> PreparedSourceSnapshot {
            try PreparedSourceSnapshot(id: id, name: name, initialMassDecigrams: initialMassDecigrams,
                initialPortionCount: initialPortionCount)
        }
    }
    private enum CodingKeys: String, CodingKey { case version, source, massPerPortionDecigrams }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else { throw PreparedGroupingValidationError.unsupportedVersion(version) }
        try self.init(source: c.decode(SourcePayload.self, forKey: .source).snapshot(),
            massPerPortionDecigrams: c.decode(Int64.self, forKey: .massPerPortionDecigrams))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(SourcePayload(source), forKey: .source)
        try c.encode(massPerPortionDecigrams, forKey: .massPerPortionDecigrams)
    }
}

/// Validate a complete snapshot before publishing or changing any persisted row.
nonisolated enum PreparedComponentCollectionValidator {
    static func validate(_ components: [PreparedComponent]) throws {
        let ids = Set(components.map(\.id))
        guard ids.count == components.count else { throw PreparedGroupingValidationError.duplicateID }
        var sources: [UUID: PreparedSourceSnapshot] = [:]
        var buckets: [UUID: [Int64: Int]] = [:]
        var masses: [UUID: Int64] = [:]
        var counts: [UUID: Int] = [:]
        for component in components {
            guard !component.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  PreparedSourceSnapshot.portionRange.contains(component.portionsRemaining) else {
                throw PreparedGroupingValidationError.invalidComponent
            }
            guard let grouping = component.grouping else { continue }
            let source = grouping.source
            guard !ids.contains(source.id) else { throw PreparedGroupingValidationError.duplicateID }
            guard sources[source.id] == nil || sources[source.id] == source else {
                throw PreparedGroupingValidationError.inconsistentSource
            }
            sources[source.id] = source
            let group = try PreparedAllocatedGroup(id: component.id, sourceID: source.id,
                count: component.portionsRemaining, massPerPortionDecigrams: grouping.massPerPortionDecigrams)
            let (mass, massOverflow) = (masses[source.id] ?? 0).addingReportingOverflow(group.totalMassDecigrams)
            let (count, countOverflow) = (counts[source.id] ?? 0).addingReportingOverflow(group.count)
            guard !massOverflow, !countOverflow else { throw PreparedPortionGroupingError.arithmeticOverflow }
            guard mass <= source.initialMassDecigrams, count <= source.initialPortionCount else {
                throw PreparedGroupingValidationError.invalidAllocation
            }
            masses[source.id] = mass
            counts[source.id] = count
            let q = source.initialMassDecigrams / Int64(source.initialPortionCount)
            let r = Int(source.initialMassDecigrams % Int64(source.initialPortionCount))
            let capacity = group.massPerPortionDecigrams == q ? source.initialPortionCount - r : r
            let (bucketCount, overflow) = (buckets[source.id]?[group.massPerPortionDecigrams] ?? 0)
                .addingReportingOverflow(group.count)
            guard !overflow, bucketCount <= capacity else { throw PreparedGroupingValidationError.invalidAllocation }
            buckets[source.id, default: [:]][group.massPerPortionDecigrams] = bucketCount
        }
    }
}
