import Foundation

nonisolated enum PreparedPortionGroupingError: Error, Equatable {
    case invalidName
    case invalidMass
    case invalidPortionCount
    case insufficientMass
    case invalidGroupIDCount
    case duplicateID
    case arithmeticOverflow
    case invalidSplitCount
    case invalidAllocation
}

nonisolated struct PreparedSourceSnapshot: Hashable, Sendable {
    static let portionRange = 1...50

    let id: UUID
    let name: String
    let initialMassDecigrams: Int64
    let initialPortionCount: Int

    init(id: UUID, name: String, initialMassDecigrams: Int64, initialPortionCount: Int) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PreparedPortionGroupingError.invalidName }
        guard Self.portionRange.contains(initialPortionCount) else {
            throw PreparedPortionGroupingError.invalidPortionCount
        }
        guard initialMassDecigrams > 0 else { throw PreparedPortionGroupingError.invalidMass }
        guard initialMassDecigrams >= Int64(initialPortionCount) else {
            throw PreparedPortionGroupingError.insufficientMass
        }
        self.id = id
        self.name = name
        self.initialMassDecigrams = initialMassDecigrams
        self.initialPortionCount = initialPortionCount
    }
}

nonisolated struct PreparedAllocatedGroup: Identifiable, Hashable, Sendable {
    let id: UUID
    let sourceID: UUID
    let count: Int
    let massPerPortionDecigrams: Int64
    let totalMassDecigrams: Int64

    init(id: UUID, sourceID: UUID, count: Int, massPerPortionDecigrams: Int64) throws {
        guard id != sourceID else { throw PreparedPortionGroupingError.duplicateID }
        guard PreparedSourceSnapshot.portionRange.contains(count) else {
            throw PreparedPortionGroupingError.invalidPortionCount
        }
        guard massPerPortionDecigrams > 0 else { throw PreparedPortionGroupingError.invalidMass }
        let (total, overflow) = massPerPortionDecigrams.multipliedReportingOverflow(by: Int64(count))
        guard !overflow else { throw PreparedPortionGroupingError.arithmeticOverflow }
        self.id = id
        self.sourceID = sourceID
        self.count = count
        self.massPerPortionDecigrams = massPerPortionDecigrams
        totalMassDecigrams = total
    }
}

nonisolated struct PreparedAllocationPlan: Equatable, Sendable {
    let source: PreparedSourceSnapshot
    let groups: [PreparedAllocatedGroup]
    let totalMassDecigrams: Int64
    let portionCount: Int

    fileprivate init(source: PreparedSourceSnapshot, groups: [PreparedAllocatedGroup]) throws {
        var mass: Int64 = 0
        var count = 0
        for group in groups {
            let (nextMass, massOverflow) = mass.addingReportingOverflow(group.totalMassDecigrams)
            let (nextCount, countOverflow) = count.addingReportingOverflow(group.count)
            guard !massOverflow, !countOverflow else { throw PreparedPortionGroupingError.arithmeticOverflow }
            mass = nextMass
            count = nextCount
        }
        guard mass == source.initialMassDecigrams, count == source.initialPortionCount else {
            throw PreparedPortionGroupingError.invalidAllocation
        }
        self.source = source
        self.groups = groups
        totalMassDecigrams = mass
        portionCount = count
    }
}

/// Pure allocation only: no active Prepared model, persistence, formatting or ID generation.
nonisolated enum PreparedPortionAllocator {
    static func allocate(source: PreparedSourceSnapshot, groupIDs: [UUID]) throws -> PreparedAllocationPlan {
        let count = source.initialPortionCount
        let quotient = source.initialMassDecigrams / Int64(count)
        let remainder = Int(source.initialMassDecigrams % Int64(count))
        let groupCount = remainder == 0 ? 1 : 2
        guard groupIDs.count == groupCount else { throw PreparedPortionGroupingError.invalidGroupIDCount }
        guard Set(groupIDs).count == groupCount, !groupIDs.contains(source.id) else {
            throw PreparedPortionGroupingError.duplicateID
        }

        var groups: [PreparedAllocatedGroup] = []
        if remainder > 0 {
            // Do not compute q+1 for an exact Int64.max / 1 allocation.
            let (largerMass, overflow) = quotient.addingReportingOverflow(1)
            guard !overflow else { throw PreparedPortionGroupingError.arithmeticOverflow }
            groups.append(try PreparedAllocatedGroup(
                id: groupIDs[0], sourceID: source.id, count: remainder,
                massPerPortionDecigrams: largerMass
            ))
        }
        groups.append(try PreparedAllocatedGroup(
            id: groupIDs[groupCount - 1], sourceID: source.id, count: count - remainder,
            massPerPortionDecigrams: quotient
        ))
        return try PreparedAllocationPlan(source: source, groups: groups)
    }

    static func split(
        group: PreparedAllocatedGroup,
        taking: Int,
        newGroupID: UUID
    ) throws -> (remaining: PreparedAllocatedGroup, separated: PreparedAllocatedGroup) {
        guard (1..<group.count).contains(taking) else { throw PreparedPortionGroupingError.invalidSplitCount }
        guard newGroupID != group.id, newGroupID != group.sourceID else {
            throw PreparedPortionGroupingError.duplicateID
        }
        let remaining = try PreparedAllocatedGroup(
            id: group.id, sourceID: group.sourceID, count: group.count - taking,
            massPerPortionDecigrams: group.massPerPortionDecigrams
        )
        let separated = try PreparedAllocatedGroup(
            id: newGroupID, sourceID: group.sourceID, count: taking,
            massPerPortionDecigrams: group.massPerPortionDecigrams
        )
        return (remaining, separated)
    }
}
