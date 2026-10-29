import Foundation

nonisolated enum PreparedLifecycleAction: Equatable { case beginThaw, completeThaw, markCooked }

nonisolated struct PreparedExpiryReview: Equatable {
    let action: PreparedLifecycleAction
    let existingExpiryDate: Date
    let selectedExpiryDate: Date
    let explicitlyEdited: Bool
}

nonisolated struct PreparedLifecycleIntent: Equatable {
    let action: PreparedLifecycleAction
    let eventAt: Date
    let calendar: Calendar
    let expiryReview: PreparedExpiryReview
}

nonisolated struct PreparedLifecycleChange: Equatable {
    let state: PreparedComponentState
    let storage: PreparedStorage
    let lifecycle: PreparedLifecycle
    let expiryDate: Date
}

/// Deterministic proposals only. The caller owns the captured event/calendar,
/// reviewed expiry and eventual atomic save; this engine owns no clock/store.
/// MainActor isolation matches the existing advisory expiry helper.
enum PreparedLifecycleTransition {
    static func defaultExpiryDate(action: PreparedLifecycleAction,
        state: PreparedComponentState, existingExpiryDate: Date,
        eventAt: Date, calendar: Calendar) throws -> Date {
        guard existingExpiryDate.timeIntervalSinceReferenceDate.isFinite,
              eventAt.timeIntervalSinceReferenceDate.isFinite else {
            throw PreparedLifecycleError.invalidEventTime
        }
        guard action != .completeThaw else { return existingExpiryDate }
        let targetState: PreparedComponentState = action == .markCooked ? .cooked : state
        let seed = PreparedComponentExpirySuggestion.suggestedExpiryDate(
            state: targetState, storage: .refrigerated, preparedAt: eventAt, calendar: calendar)
        guard seed.timeIntervalSinceReferenceDate.isFinite else {
            throw PreparedLifecycleError.invalidEventTime
        }
        return min(existingExpiryDate, seed)
    }

    static func propose(state: PreparedComponentState, storage: PreparedStorage,
        lifecycle: PreparedLifecycle?, expiryDate: Date,
        intent: PreparedLifecycleIntent) throws -> PreparedLifecycleChange {
        try lifecycle?.validate(state: state, storage: storage)
        let review = intent.expiryReview
        guard intent.eventAt.timeIntervalSinceReferenceDate.isFinite,
              expiryDate.timeIntervalSinceReferenceDate.isFinite,
              review.existingExpiryDate.timeIntervalSinceReferenceDate.isFinite,
              review.selectedExpiryDate.timeIntervalSinceReferenceDate.isFinite else {
            throw PreparedLifecycleError.invalidEventTime
        }
        guard review.action == intent.action, review.existingExpiryDate == expiryDate else {
            throw PreparedLifecycleError.invalidExpiryReview
        }

        let phase = lifecycle?.thawPhase ?? .inactive
        let nextState: PreparedComponentState
        let nextLifecycle: PreparedLifecycle
        switch intent.action {
        case .beginThaw:
            guard storage == .frozen, phase == .inactive else {
                throw PreparedLifecycleError.invalidTransition
            }
            try requireEvent(intent.eventAt, notBefore: lifecycle?.cookedAt)
            nextState = state
            nextLifecycle = PreparedLifecycle(version: 1, thawPhase: .thawing,
                thawStartedAt: intent.eventAt, thawCompletedAt: nil, cookedAt: lifecycle?.cookedAt)
        case .completeThaw:
            guard storage == .refrigerated, phase == .thawing, let started = lifecycle?.thawStartedAt else {
                throw PreparedLifecycleError.invalidTransition
            }
            try requireEvent(intent.eventAt, notBefore: started)
            try requireEvent(intent.eventAt, notBefore: lifecycle?.cookedAt)
            nextState = state
            nextLifecycle = PreparedLifecycle(version: 1, thawPhase: .inactive,
                thawStartedAt: started, thawCompletedAt: intent.eventAt, cookedAt: lifecycle?.cookedAt)
        case .markCooked:
            guard state == .prepped, storage == .refrigerated, phase == .inactive else {
                throw PreparedLifecycleError.invalidTransition
            }
            try requireEvent(intent.eventAt, notBefore: lifecycle?.thawCompletedAt)
            nextState = .cooked
            nextLifecycle = PreparedLifecycle(version: 1, thawPhase: .inactive,
                thawStartedAt: lifecycle?.thawStartedAt, thawCompletedAt: lifecycle?.thawCompletedAt,
                cookedAt: intent.eventAt)
        }

        let defaultDate = try defaultExpiryDate(action: intent.action, state: state,
            existingExpiryDate: expiryDate, eventAt: intent.eventAt, calendar: intent.calendar)
        guard review.explicitlyEdited || review.selectedExpiryDate == defaultDate else {
            throw PreparedLifecycleError.invalidExpiryReview
        }
        try nextLifecycle.validate(state: nextState, storage: .refrigerated)
        return PreparedLifecycleChange(state: nextState, storage: .refrigerated,
            lifecycle: nextLifecycle, expiryDate: review.selectedExpiryDate)
    }

    private static func requireEvent(_ event: Date, notBefore recorded: Date?) throws {
        if let recorded, event < recorded { throw PreparedLifecycleError.invalidEventTime }
    }
}
