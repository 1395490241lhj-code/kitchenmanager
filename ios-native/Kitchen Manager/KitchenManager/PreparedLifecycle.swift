import Foundation

nonisolated enum PreparedThawPhase: String, Codable { case inactive, thawing }

nonisolated enum PreparedLifecycleError: Error, Equatable {
    case unsupportedVersion(Int)
    case invalidMetadata
    case invalidTransition
    case invalidEventTime
    case invalidExpiryReview
}

/// Explicit events for one Prepared group. Absence of this value means unknown
/// history; inactive never means that food is ready or safe to eat.
nonisolated struct PreparedLifecycle: Hashable, Codable {
    static let currentVersion = 1
    let version: Int
    let thawPhase: PreparedThawPhase
    let thawStartedAt: Date?
    let thawCompletedAt: Date?
    let cookedAt: Date?

    init(version: Int, thawPhase: PreparedThawPhase, thawStartedAt: Date?,
         thawCompletedAt: Date?, cookedAt: Date?) {
        self.version = version
        self.thawPhase = thawPhase
        self.thawStartedAt = thawStartedAt
        self.thawCompletedAt = thawCompletedAt
        self.cookedAt = cookedAt
    }

    func validate(state: PreparedComponentState, storage: PreparedStorage) throws {
        try validateStructure()
        if thawStartedAt != nil || thawCompletedAt != nil {
            guard storage == .refrigerated else { throw PreparedLifecycleError.invalidMetadata }
        }
        if cookedAt != nil {
            guard state == .cooked else { throw PreparedLifecycleError.invalidMetadata }
        }
    }

    private func validateStructure() throws {
        guard version == Self.currentVersion else {
            throw PreparedLifecycleError.unsupportedVersion(version)
        }
        guard [thawStartedAt, thawCompletedAt, cookedAt].compactMap({ $0 })
            .allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
            throw PreparedLifecycleError.invalidEventTime
        }
        switch thawPhase {
        case .thawing:
            guard thawStartedAt != nil, thawCompletedAt == nil else {
                throw PreparedLifecycleError.invalidMetadata
            }
        case .inactive:
            if let started = thawStartedAt {
                guard let completed = thawCompletedAt, completed >= started else {
                    throw PreparedLifecycleError.invalidMetadata
                }
            } else if thawCompletedAt != nil {
                throw PreparedLifecycleError.invalidMetadata
            }
            guard thawStartedAt != nil || cookedAt != nil else {
                throw PreparedLifecycleError.invalidMetadata
            }
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, thawPhase, thawStartedAt, thawCompletedAt, cookedAt
    }

    /// A known-key container hides unknown keys, so inspect an unrestricted one
    /// before decoding. All five fields are required, including nullable dates.
    private struct FieldKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: FieldKey.self)
        guard Set(fields.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw PreparedLifecycleError.invalidMetadata
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        thawPhase = try c.decode(PreparedThawPhase.self, forKey: .thawPhase)
        thawStartedAt = try c.decodeIfPresent(Date.self, forKey: .thawStartedAt)
        thawCompletedAt = try c.decodeIfPresent(Date.self, forKey: .thawCompletedAt)
        cookedAt = try c.decodeIfPresent(Date.self, forKey: .cookedAt)
        try validateStructure()
    }

    func encode(to encoder: Encoder) throws {
        try validateStructure()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(thawPhase, forKey: .thawPhase)
        for (key, date) in [(CodingKeys.thawStartedAt, thawStartedAt),
                            (.thawCompletedAt, thawCompletedAt), (.cookedAt, cookedAt)] {
            if let date { try c.encode(date, forKey: key) }
            else { try c.encodeNil(forKey: key) }
        }
    }
}
