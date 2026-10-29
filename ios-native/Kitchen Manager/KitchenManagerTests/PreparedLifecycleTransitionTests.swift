import Foundation
import XCTest
@testable import KitchenManager

@MainActor
final class PreparedLifecycleTransitionTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 100)
    private let finish = Date(timeIntervalSinceReferenceDate: 200)
    private let event = Date(timeIntervalSinceReferenceDate: 300)
    private let expiry = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let actions: [PreparedLifecycleAction] = [.beginThaw, .completeThaw, .markCooked]

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func tracked(_ phase: PreparedThawPhase = .inactive,
                         cooked: Date? = nil) -> PreparedLifecycle {
        PreparedLifecycle(version: 1, thawPhase: phase, thawStartedAt: start,
                          thawCompletedAt: phase == .inactive ? finish : nil, cookedAt: cooked)
    }

    private func intent(_ action: PreparedLifecycleAction, state: PreparedComponentState,
                        date: Date? = nil, existing: Date? = nil, calendar: Calendar? = nil,
                        selected: Date? = nil, edited: Bool = false) throws -> PreparedLifecycleIntent {
        let date = date ?? event; let existing = existing ?? expiry; let calendar = calendar ?? utc
        let target = try selected ?? PreparedLifecycleTransition.defaultExpiryDate(
            action: action, state: state, existingExpiryDate: existing, eventAt: date, calendar: calendar)
        return PreparedLifecycleIntent(action: action, eventAt: date, calendar: calendar,
            expiryReview: PreparedExpiryReview(action: action, existingExpiryDate: existing,
                selectedExpiryDate: target, explicitlyEdited: edited))
    }

    private func propose(_ action: PreparedLifecycleAction, state: PreparedComponentState = .prepped,
                         storage: PreparedStorage = .refrigerated, lifecycle: PreparedLifecycle? = nil,
                         date: Date? = nil, existing: Date? = nil) throws -> PreparedLifecycleChange {
        try PreparedLifecycleTransition.propose(state: state, storage: storage,
            lifecycle: lifecycle, expiryDate: existing ?? expiry,
            intent: intent(action, state: state, date: date, existing: existing))
    }

    func testEveryStateStoragePhaseActionCell() throws {
        for state in [PreparedComponentState.prepped, .cooked] {
            // Nil and recorded inactive both exercise the refrigerated inactive cells.
            let rows: [(PreparedStorage, PreparedLifecycle?)] = [
                (.frozen, nil), (.refrigerated, nil),
                (.refrigerated, tracked()), (.refrigerated, tracked(.thawing))
            ]
            for (storage, lifecycle) in rows {
                for action in actions {
                    let allowed = (action == .beginThaw && storage == .frozen)
                        || (action == .completeThaw && lifecycle?.thawPhase == .thawing)
                        || (action == .markCooked && state == .prepped && storage == .refrigerated
                            && lifecycle?.thawPhase != .thawing)
                    let input = lifecycle
                    if allowed {
                        let result = try propose(action, state: state, storage: storage, lifecycle: lifecycle)
                        XCTAssertEqual(result.storage, .refrigerated)
                        XCTAssertEqual(result.state, action == .markCooked ? .cooked : state)
                        XCTAssertEqual(result.lifecycle.thawPhase, action == .beginThaw ? .thawing : .inactive)
                        XCTAssertNoThrow(try result.lifecycle.validate(state: result.state, storage: result.storage))
                    } else {
                        XCTAssertThrowsError(try propose(action, state: state, storage: storage, lifecycle: lifecycle),
                                             "\(state) / \(storage) / \(String(describing: lifecycle?.thawPhase)) / \(action)")
                    }
                    XCTAssertEqual(lifecycle, input, "proposal cannot change an input value")
                }
            }
        }
        // A frozen cooked record can retain an explicitly known pre-freeze cook event.
        let knownCook = PreparedLifecycle(version: 1, thawPhase: .inactive, thawStartedAt: nil,
            thawCompletedAt: nil, cookedAt: start)
        for action in actions {
            if action == .beginThaw {
                XCTAssertEqual(try propose(action, state: .cooked, storage: .frozen,
                    lifecycle: knownCook).lifecycle.cookedAt, start)
            } else {
                XCTAssertThrowsError(try propose(action, state: .cooked, storage: .frozen, lifecycle: knownCook))
            }
        }
    }

    func testFirstActionRecordsOnlyItsEvent() throws {
        let thaw = try propose(.beginThaw, storage: .frozen)
        XCTAssertEqual(thaw.lifecycle.thawStartedAt, event)
        XCTAssertNil(thaw.lifecycle.thawCompletedAt)
        XCTAssertNil(thaw.lifecycle.cookedAt)
        let alreadyCooked = try propose(.beginThaw, state: .cooked, storage: .frozen)
        XCTAssertEqual(alreadyCooked.state, .cooked)
        XCTAssertNil(alreadyCooked.lifecycle.cookedAt)
        let cook = try propose(.markCooked)
        XCTAssertNil(cook.lifecycle.thawStartedAt)
        XCTAssertNil(cook.lifecycle.thawCompletedAt)
        XCTAssertEqual(cook.lifecycle.cookedAt, event)
        XCTAssertThrowsError(try propose(.completeThaw))
    }

    func testCompletionAndCookingPreservePriorFacts() throws {
        let cookBeforeThaw = Date(timeIntervalSinceReferenceDate: 50)
        let old = tracked(.thawing, cooked: cookBeforeThaw)
        let completed = try propose(.completeThaw, state: .cooked, lifecycle: old)
        XCTAssertEqual(completed.lifecycle.thawStartedAt, start)
        XCTAssertEqual(completed.lifecycle.thawCompletedAt, event)
        XCTAssertEqual(completed.lifecycle.cookedAt, cookBeforeThaw)
        XCTAssertEqual(completed.expiryDate, expiry)
        let cooked = try propose(.markCooked, lifecycle: tracked())
        XCTAssertEqual(cooked.lifecycle.thawStartedAt, start)
        XCTAssertEqual(cooked.lifecycle.thawCompletedAt, finish)
        XCTAssertEqual(cooked.lifecycle.cookedAt, event)
    }

    func testEqualTimeBoundariesAndEarlierEvents() throws {
        XCTAssertNoThrow(try propose(.completeThaw, lifecycle: tracked(.thawing), date: start))
        XCTAssertThrowsError(try propose(.completeThaw, lifecycle: tracked(.thawing), date: start.addingTimeInterval(-1)))
        let cookedDuringThaw = tracked(.thawing, cooked: finish)
        XCTAssertThrowsError(try propose(.completeThaw, state: .cooked,
            lifecycle: cookedDuringThaw, date: finish.addingTimeInterval(-1)))
        XCTAssertNoThrow(try propose(.completeThaw, state: .cooked,
            lifecycle: cookedDuringThaw, date: finish))
        XCTAssertNoThrow(try propose(.markCooked, lifecycle: tracked(), date: finish))
        XCTAssertThrowsError(try propose(.markCooked, lifecycle: tracked(), date: finish.addingTimeInterval(-1)))
        let knownCook = PreparedLifecycle(version: 1, thawPhase: .inactive,
            thawStartedAt: nil, thawCompletedAt: nil, cookedAt: start)
        XCTAssertNoThrow(try propose(.beginThaw, state: .cooked, storage: .frozen, lifecycle: knownCook, date: start))
        XCTAssertThrowsError(try propose(.beginThaw, state: .cooked, storage: .frozen,
            lifecycle: knownCook, date: start.addingTimeInterval(-1)))
    }

    func testInvalidContextOrMetadataRejectsEveryAction() throws {
        let empty = PreparedLifecycle(version: 1, thawPhase: .inactive,
            thawStartedAt: nil, thawCompletedAt: nil, cookedAt: nil)
        let future = PreparedLifecycle(version: 2, thawPhase: .thawing,
            thawStartedAt: start, thawCompletedAt: nil, cookedAt: nil)
        let cases: [(PreparedComponentState, PreparedStorage, PreparedLifecycle)] = [
            (.prepped, .refrigerated, empty), (.prepped, .refrigerated, future),
            (.prepped, .frozen, tracked(.thawing)), (.cooked, .frozen, tracked()),
            (.prepped, .refrigerated, tracked(cooked: start))
        ]
        for (state, storage, lifecycle) in cases {
            for action in actions {
                XCTAssertThrowsError(try propose(action, state: state, storage: storage, lifecycle: lifecycle))
            }
        }
    }

    func testExpiryDefaultsAndReviewedExtensions() throws {
        XCTAssertEqual(try propose(.beginThaw, storage: .frozen).expiryDate, event.addingTimeInterval(2 * 86_400))
        XCTAssertEqual(try propose(.beginThaw, state: .cooked, storage: .frozen).expiryDate, event.addingTimeInterval(3 * 86_400))
        XCTAssertEqual(try propose(.markCooked).expiryDate, event.addingTimeInterval(3 * 86_400))
        for oldDate in [event.addingTimeInterval(-1), event, event.addingTimeInterval(100)] {
            XCTAssertEqual(try propose(.beginThaw, storage: .frozen, existing: oldDate).expiryDate, oldDate)
            XCTAssertEqual(try propose(.markCooked, existing: oldDate).expiryDate, oldDate)
        }
        let selected = expiry.addingTimeInterval(500)
        let confirmed = try intent(.markCooked, state: .prepped, selected: selected, edited: true)
        XCTAssertEqual(try PreparedLifecycleTransition.propose(state: .prepped, storage: .refrigerated,
            lifecycle: nil, expiryDate: expiry, intent: confirmed).expiryDate, selected)
        let unreviewed = try intent(.markCooked, state: .prepped, selected: selected)
        XCTAssertThrowsError(try PreparedLifecycleTransition.propose(state: .prepped, storage: .refrigerated,
            lifecycle: nil, expiryDate: expiry, intent: unreviewed))
    }

    func testExpiryReviewMustMatchActionAndExistingDate() throws {
        let valid = try intent(.markCooked, state: .prepped)
        for review in [
            PreparedExpiryReview(action: .beginThaw, existingExpiryDate: expiry,
                selectedExpiryDate: valid.expiryReview.selectedExpiryDate, explicitlyEdited: false),
            PreparedExpiryReview(action: .markCooked, existingExpiryDate: expiry.addingTimeInterval(1),
                selectedExpiryDate: valid.expiryReview.selectedExpiryDate, explicitlyEdited: true),
            PreparedExpiryReview(action: .markCooked, existingExpiryDate: expiry,
                selectedExpiryDate: event, explicitlyEdited: false)
        ] {
            let bad = PreparedLifecycleIntent(action: .markCooked, eventAt: event, calendar: utc, expiryReview: review)
            XCTAssertThrowsError(try PreparedLifecycleTransition.propose(state: .prepped, storage: .refrigerated,
                lifecycle: nil, expiryDate: expiry, intent: bad))
        }
    }

    func testNonfiniteEventExpiryAndSelectedDateReject() throws {
        for number in [Double.nan, .infinity, -.infinity] {
            let badDate = Date(timeIntervalSinceReferenceDate: number)
            // Build directly so proposal validation, not the default-date helper, is exercised.
            for (at, existing, selected) in [
                (badDate, expiry, event), (event, badDate, event), (event, expiry, badDate)
            ] {
                let bad = PreparedLifecycleIntent(action: .markCooked, eventAt: at, calendar: utc,
                    expiryReview: PreparedExpiryReview(action: .markCooked, existingExpiryDate: existing,
                        selectedExpiryDate: selected, explicitlyEdited: true))
                XCTAssertThrowsError(try PreparedLifecycleTransition.propose(state: .prepped,
                    storage: .refrigerated, lifecycle: nil, expiryDate: existing, intent: bad))
            }
        }
    }

    func testFixedTorontoDSTVersusUTCExpectedDatesAndRetry() throws {
        let formatter = ISO8601DateFormatter()
        func date(_ value: String) throws -> Date { try XCTUnwrap(formatter.date(from: value)) }
        var toronto = Calendar(identifier: .gregorian)
        toronto.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        let at = try date("2026-10-31T16:00:00Z")
        let later = try date("2026-11-20T17:00:00Z")
        let frozenIntent = try intent(.beginThaw, state: .prepped, date: at, existing: later, calendar: toronto)
        let first = try PreparedLifecycleTransition.propose(state: .prepped, storage: .frozen,
            lifecycle: nil, expiryDate: later, intent: frozenIntent)
        XCTAssertEqual(first.expiryDate, try date("2026-11-02T17:00:00Z"))
        XCTAssertEqual(first.lifecycle.thawStartedAt, at)
        XCTAssertEqual(try PreparedLifecycleTransition.defaultExpiryDate(action: .beginThaw, state: .cooked,
            existingExpiryDate: later, eventAt: at, calendar: toronto), try date("2026-11-03T17:00:00Z"))
        XCTAssertEqual(try PreparedLifecycleTransition.defaultExpiryDate(action: .markCooked, state: .prepped,
            existingExpiryDate: later, eventAt: at, calendar: toronto), try date("2026-11-03T17:00:00Z"))
        var externalCalendar = toronto
        externalCalendar.timeZone = utc.timeZone
        XCTAssertEqual(try PreparedLifecycleTransition.defaultExpiryDate(action: .beginThaw, state: .prepped,
            existingExpiryDate: later, eventAt: at, calendar: externalCalendar), try date("2026-11-02T16:00:00Z"))
        // A later proposed event/calendar differs, but unchanged retry keeps its captured intent.
        let laterIntent = try intent(.beginThaw, state: .prepped, date: at.addingTimeInterval(86_400),
                                     existing: later, calendar: externalCalendar)
        XCTAssertNotEqual(frozenIntent, laterIntent)
        for _ in 0..<3 {
            XCTAssertEqual(try PreparedLifecycleTransition.propose(state: .prepped, storage: .frozen,
                lifecycle: nil, expiryDate: later, intent: frozenIntent), first)
        }
    }

    func testExplicitCompletionIsRequiredAndRepeatedActionsReject() throws {
        let thaw = try propose(.beginThaw, storage: .frozen)
        XCTAssertEqual(thaw.lifecycle.thawPhase, .thawing)
        XCTAssertThrowsError(try propose(.markCooked, lifecycle: thaw.lifecycle))
        XCTAssertThrowsError(try propose(.beginThaw, lifecycle: thaw.lifecycle))
        let complete = try propose(.completeThaw, lifecycle: thaw.lifecycle, date: event)
        XCTAssertThrowsError(try propose(.completeThaw, lifecycle: complete.lifecycle))
        let cooked = try propose(.markCooked, lifecycle: complete.lifecycle, date: event)
        XCTAssertThrowsError(try propose(.markCooked, state: .cooked, lifecycle: cooked.lifecycle))
        XCTAssertEqual(cooked.lifecycle.thawStartedAt, event)
        XCTAssertEqual(cooked.lifecycle.thawCompletedAt, event)
        XCTAssertEqual(cooked.lifecycle.cookedAt, event)
    }
}
