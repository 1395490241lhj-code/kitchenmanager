import Foundation

enum PreparedPortionConsumptionFeedback {
    enum Context { case preparedList, meal }
    static func message(for previous: PreparedComponent, context: Context) -> String {
        if previous.grouping != nil {
            return previous.portionsRemaining > 1
                ? "这组还剩 \(previous.portionsRemaining - 1) 份"
                : "这组已用完"
        }
        return switch context {
        case .preparedList:
            previous.portionsRemaining > 1
                ? "已吃掉一份，还剩 \(previous.portionsRemaining - 1) 份"
                : "「\(previous.name)」已吃完，记录已移除"
        case .meal:
            previous.portionsRemaining > 1
                ? "已使用 1 份\(previous.name)，还剩 \(previous.portionsRemaining - 1) 份"
                : "\(previous.name)已用完"
        }
    }
}

nonisolated enum PreparedMassInputError: Error, LocalizedError {
    case invalid
    var errorDescription: String? { "请输入有效克数，最多保留一位小数（0.1g），不要填写单位。" }
}

nonisolated enum PreparedMassInput {
    static func parse(_ text: String) throws -> Int64? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let parts = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "." || $0 == "," })
        guard parts.count <= 2, parts.count == 1 ? !parts[0].isEmpty : parts[1].count == 1 else {
            throw PreparedMassInputError.invalid
        }
        let digits = String(parts[0]) + (parts.count == 2 ? String(parts[1]) : "0")
        var value: Int64 = 0
        for byte in digits.utf8 {
            guard (48...57).contains(byte) else { throw PreparedMassInputError.invalid }
            let (scaled, overflow) = value.multipliedReportingOverflow(by: 10)
            let (next, additionOverflow) = scaled.addingReportingOverflow(Int64(byte - 48))
            guard !overflow, !additionOverflow else { throw PreparedMassInputError.invalid }
            value = next
        }
        guard value > 0 else { throw PreparedMassInputError.invalid }
        return value
    }
    static func grams(_ decigrams: Int64) -> String {
        let fraction = decigrams % 10
        return "\(decigrams / 10)" + (fraction == 0 ? "" : ".\(fraction)") + "g"
    }
    static func spoken(_ decigrams: Int64) -> String { String(grams(decigrams).dropLast()) + "克" }
}

/// UI state owns two reserved group identities; only the required prefix is submitted.
struct PreparedComponentFormDraft {
    private(set) var expected: PreparedComponent?
    let legacyID: UUID
    let sourceID: UUID
    let reservedGroupIDs: [UUID]
    var name: String
    var massText = ""
    var portions: Int
    var state: PreparedComponentState
    var storage: PreparedStorage
    var preparedAt: Date
    var expiryDate: Date

    init(existing: PreparedComponent? = nil) {
        expected = existing
        legacyID = existing?.id ?? UUID()
        sourceID = existing?.grouping?.source.id ?? UUID()
        reservedGroupIDs = [UUID(), UUID()]
        name = existing?.name ?? ""
        portions = existing?.portionsRemaining ?? 4
        state = existing?.state ?? .cooked
        storage = existing?.storage ?? .refrigerated
        preparedAt = existing?.preparedAt ?? Date()
        expiryDate = existing?.expiryDate ?? PreparedComponentExpirySuggestion.suggestedExpiryDate(
            state: state, storage: storage, preparedAt: preparedAt)
    }
    func measuredDraft() throws -> PreparedSourceDraft? {
        guard PreparedComponent.portionRange.contains(portions) else { throw PreparedPortionGroupingError.invalidPortionCount }
        let mass = try PreparedMassInput.parse(massText)
        guard expected == nil else {
            guard mass == nil else { throw PreparedMassInputError.invalid }
            return nil // Editing never converts a legacy row or rewrites grouped mass.
        }
        guard let mass else { return nil }
        let source = try PreparedSourceSnapshot(id: sourceID, name: name, initialMassDecigrams: mass, initialPortionCount: portions)
        let buckets = source.initialMassDecigrams % Int64(portions) == 0 ? 1 : 2
        return PreparedSourceDraft(sourceID: sourceID, groupIDs: Array(reservedGroupIDs.prefix(buckets)),
            name: name, massDecigrams: mass, portionCount: portions, state: state, storage: storage,
            preparedAt: preparedAt, expiryDate: expiryDate)
    }
    func allocation() throws -> PreparedAllocationPlan? {
        guard let draft = try measuredDraft() else { return nil }
        let source = try PreparedSourceSnapshot(id: draft.sourceID, name: draft.name,
            initialMassDecigrams: draft.massDecigrams, initialPortionCount: draft.portionCount)
        return try PreparedPortionAllocator.allocate(source: source, groupIDs: draft.groupIDs)
    }
    var validationMessage: String? {
        do { _ = try allocation() }
        catch let error as PreparedMassInputError { return error.localizedDescription }
        catch PreparedPortionGroupingError.insufficientMass { return "总重量不足以分成这些整份，每份至少需要0.1g。" }
        catch PreparedPortionGroupingError.invalidName { return "请填写备餐名称。" }
        catch { return "份数须为1到50的整数，请核对重量和份数。" }
        return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "请填写备餐名称。" : nil
    }
    func save(in store: KitchenStore) -> Result<[PreparedComponent], PreparedComponentMutationError> {
        guard !store.isPreparedComponentUnavailable else { return .failure(.unavailable) }
        do {
            if let measured = try measuredDraft() { return store.addPreparedSource(draft: measured) }
            let row = PreparedComponent(id: legacyID, name: name, portionsRemaining: portions,
                state: state, storage: storage, preparedAt: preparedAt, expiryDate: expiryDate,
                grouping: expected?.grouping)
            return (expected == nil ? store.addPreparedComponent(row)
                : store.updatePreparedComponent(row, expected: expected)).map { [$0] }
        } catch { return .failure(.invalidComponent) }
    }
    /// Explicit user recheck keeps entered corrections and adopts live protected fields.
    mutating func acceptCurrent(_ current: PreparedComponent) -> Bool {
        guard let previous = expected, previous.id == current.id else { return false }
        if current.grouping != nil || portions == previous.portionsRemaining { portions = current.portionsRemaining }
        if current.grouping != nil || state == previous.state { state = current.state }
        if current.grouping != nil || storage == previous.storage { storage = current.storage }
        expected = current
        return true
    }
}

struct PreparedSourceSection: Identifiable {
    let id: UUID
    let source: PreparedSourceSnapshot?
    var components: [PreparedComponent]
    let batchNumber: Int?
    var remainingMassDecigrams: Int64? {
        guard source != nil else { return nil }
        var total: Int64 = 0
        for component in components {
            guard let grouping = component.grouping else { return nil }
            let (mass, overflow) = grouping.massPerPortionDecigrams.multipliedReportingOverflow(by: Int64(component.portionsRemaining))
            let (next, sumOverflow) = total.addingReportingOverflow(mass)
            guard !overflow, !sumOverflow else { return nil }
            total = next
        }
        return total
    }
    var remainingPortionCount: Int { components.reduce(0) { $0 + $1.portionsRemaining } }
    static func make(_ components: [PreparedComponent]) throws -> [Self] {
        try PreparedComponentCollectionValidator.validate(components)
        var sections: [Self] = []
        var positions: [UUID: Int] = [:]
        var batchNumber = 0
        for component in components {
            if let source = component.grouping?.source {
                if let position = positions[source.id] { sections[position].components.append(component) }
                else {
                    batchNumber += 1
                    positions[source.id] = sections.count
                    sections.append(Self(id: source.id, source: source, components: [component], batchNumber: batchNumber))
                }
            } else { sections.append(Self(id: component.id, source: nil, components: [component], batchNumber: nil)) }
        }
        return sections
    }
    func groupLabel(for component: PreparedComponent) -> String {
        guard let batchNumber, let index = components.firstIndex(where: { $0.id == component.id }) else { return "按份记录" }
        return "第\(batchNumber)批 · 第\(index + 1)组"
    }
}
