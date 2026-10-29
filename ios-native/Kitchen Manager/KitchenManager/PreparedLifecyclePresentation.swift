import Foundation

extension PreparedLifecycleAction {
    var title: String {
        switch self {
        case .beginThaw: "开始解冻"
        case .completeThaw: "解冻完成"
        case .markCooked: "标为做熟"
        }
    }
    var key: String {
        switch self {
        case .beginThaw: "beginThaw"
        case .completeThaw: "completeThaw"
        case .markCooked: "markCooked"
        }
    }
}

enum PreparedLifecyclePresentation {
    static func actions(for row: PreparedComponent) -> [PreparedLifecycleAction] {
        guard (try? PreparedComponentCollectionValidator.validate([row])) != nil else { return [] }
        if row.storage == .frozen { return [.beginThaw] }
        if row.lifecycle?.thawPhase == .thawing { return [.completeThaw] }
        return row.state == .prepped ? [.markCooked] : []
    }
    static func status(_ row: PreparedComponent) -> String {
        "\(row.state.title) · \(row.storage.title)" + (row.lifecycle?.thawPhase == .thawing ? " · 解冻中" : "")
    }
    static func events(_ row: PreparedComponent) -> [String] {
        [("开始解冻记录", row.lifecycle?.thawStartedAt), ("解冻完成记录", row.lifecycle?.thawCompletedAt),
         ("做熟记录", row.lifecycle?.cookedAt)].compactMap { title, date in
            date.map { "\(title)：\($0.formatted(date: .abbreviated, time: .shortened))" }
        }
    }
}

/// A review is not an event. Only explicit confirmation captures an intent;
/// unchanged save retries reuse it, including its calendar and event time.
struct PreparedLifecycleFormDraft: Identifiable {
    var id: UUID { expected.id }
    private(set) var expected: PreparedComponent
    let action: PreparedLifecycleAction
    private(set) var confirmedIntent: PreparedLifecycleIntent?
    private(set) var expiryDate: Date
    private(set) var explicitlyEdited = false
    var expiryReviewed = false

    init(expected: PreparedComponent, action: PreparedLifecycleAction,
         at: Date = Date(), calendar: Calendar = .current) {
        self.expected = expected; self.action = action
        expiryDate = (try? PreparedLifecycleTransition.defaultExpiryDate(action: action, state: expected.state,
            existingExpiryDate: expected.expiryDate, eventAt: at, calendar: calendar)) ?? expected.expiryDate
    }
    mutating func selectExpiry(_ date: Date) {
        guard date != expiryDate else { return }
        expiryDate = date; explicitlyEdited = true; confirmedIntent = nil; expiryReviewed = false
    }
    mutating func makeReviewedIntent(at: Date, calendar: Calendar) throws -> PreparedLifecycleIntent {
        guard expiryReviewed else { throw PreparedLifecycleError.invalidExpiryReview }
        if let confirmedIntent { return confirmedIntent }
        let defaultDate = try PreparedLifecycleTransition.defaultExpiryDate(action: action, state: expected.state,
            existingExpiryDate: expected.expiryDate, eventAt: at, calendar: calendar)
        if !explicitlyEdited && expiryDate != defaultDate {
            let sameDisplayedDay = calendar.isDate(expiryDate, inSameDayAs: defaultDate)
            expiryDate = defaultDate
            if !sameDisplayedDay {
                expiryReviewed = false
                throw PreparedLifecycleError.invalidExpiryReview
            }
        }
        let intent = PreparedLifecycleIntent(action: action, eventAt: at, calendar: calendar,
            expiryReview: PreparedExpiryReview(action: action, existingExpiryDate: expected.expiryDate,
                selectedExpiryDate: expiryDate, explicitlyEdited: explicitlyEdited))
        _ = try PreparedLifecycleTransition.propose(state: expected.state, storage: expected.storage,
            lifecycle: expected.lifecycle, expiryDate: expected.expiryDate, intent: intent)
        confirmedIntent = intent
        return intent
    }
    mutating func recheck(_ current: PreparedComponent) {
        expected = current; confirmedIntent = nil; expiryReviewed = false
        if !explicitlyEdited { expiryDate = min(expiryDate, current.expiryDate) }
    }
}
