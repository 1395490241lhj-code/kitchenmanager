import Foundation
import XCTest
@testable import KitchenManager

@MainActor
final class PreparedLifecycleTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 100)
    private let finish = Date(timeIntervalSinceReferenceDate: 200)

    private func object() -> [String: Any] {
        ["version": 1, "thawPhase": "thawing", "thawStartedAt": 100,
         "thawCompletedAt": NSNull(), "cookedAt": NSNull()]
    }

    private func decode(_ object: [String: Any]) throws -> PreparedLifecycle {
        try JSONDecoder().decode(PreparedLifecycle.self,
            from: JSONSerialization.data(withJSONObject: object))
    }

    private func value(phase: PreparedThawPhase = .inactive, start: Date? = nil,
                       completed: Date? = nil, cooked: Date? = nil,
                       version: Int = 1) -> PreparedLifecycle {
        PreparedLifecycle(version: version, thawPhase: phase, thawStartedAt: start,
                          thawCompletedAt: completed, cookedAt: cooked)
    }

    func testExactFiveKeyCodecAndExplicitUnknownDates() throws {
        let decoded = try decode(object())
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.thawPhase, .thawing)
        XCTAssertEqual(decoded.thawStartedAt, start)
        XCTAssertNil(decoded.thawCompletedAt)
        XCTAssertNil(decoded.cookedAt)
        let data = try JSONEncoder().encode(decoded)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(encoded.keys), Set(object().keys))
        XCTAssertTrue(encoded["thawCompletedAt"] is NSNull)
        XCTAssertTrue(encoded["cookedAt"] is NSNull)
        XCTAssertEqual(try JSONDecoder().decode(PreparedLifecycle.self, from: data), decoded)
        let cookOnly = value(cooked: start)
        let cookJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(cookOnly)) as? [String: Any])
        XCTAssertTrue(cookJSON["thawStartedAt"] is NSNull)
        XCTAssertTrue(cookJSON["thawCompletedAt"] is NSNull)
        XCTAssertEqual(cookJSON.count, 5)
    }

    func testMissingOrUnknownKeysAreRejected() throws {
        for key in object().keys {
            var bad = object(); bad.removeValue(forKey: key)
            XCTAssertThrowsError(try decode(bad), "missing \(key)")
        }
        for key in ["futureEvent", "State", "thawStartAt"] {
            var bad = object(); bad[key] = NSNull()
            XCTAssertThrowsError(try decode(bad), "unknown \(key)")
        }
    }

    func testMalformedVersionsPhasesAndDateTypesAreRejected() throws {
        let badFields: [(String, Any)] = [
            ("version", 0), ("version", 2), ("version", 1.5), ("version", true),
            ("version", "1"), ("version", NSNull()),
            ("thawPhase", "complete"), ("thawPhase", "THAWING"),
            ("thawPhase", 1), ("thawPhase", NSNull()),
            ("thawStartedAt", "100"), ("thawStartedAt", true),
            ("thawCompletedAt", []), ("cookedAt", [:])
        ]
        for (key, field) in badFields {
            var bad = object(); bad[key] = field
            XCTAssertThrowsError(try decode(bad), "\(key): \(field)")
        }
        for json in ["null", "[]", "{}", "not-json", "{\"version\":1"] {
            XCTAssertThrowsError(try JSONDecoder().decode(PreparedLifecycle.self, from: Data(json.utf8)))
        }
    }

    func testInvalidStructuralChronologyCannotDecodeOrEncode() throws {
        let invalid = [
            value(), value(start: start), value(completed: finish),
            value(start: finish, completed: start), value(phase: .thawing),
            value(phase: .thawing, start: start, completed: finish),
            value(cooked: start, version: 99)
        ]
        for candidate in invalid {
            XCTAssertThrowsError(try candidate.validate(state: .cooked, storage: .refrigerated))
            XCTAssertThrowsError(try JSONEncoder().encode(candidate))
        }
        var bad = object(); bad["thawPhase"] = "inactive"
        XCTAssertThrowsError(try decode(bad))
        bad["thawCompletedAt"] = 99
        XCTAssertThrowsError(try decode(bad))
    }

    func testContextualValidityAndCookedBeforeThaw() throws {
        let active = value(phase: .thawing, start: start)
        let completed = value(start: start, completed: finish)
        for state in [PreparedComponentState.prepped, .cooked] {
            XCTAssertNoThrow(try active.validate(state: state, storage: .refrigerated))
            XCTAssertNoThrow(try completed.validate(state: state, storage: .refrigerated))
            XCTAssertThrowsError(try active.validate(state: state, storage: .frozen))
            XCTAssertThrowsError(try completed.validate(state: state, storage: .frozen))
        }
        let cookOnly = value(cooked: start)
        XCTAssertNoThrow(try cookOnly.validate(state: .cooked, storage: .frozen))
        XCTAssertThrowsError(try cookOnly.validate(state: .prepped, storage: .refrigerated))
        for cookedAt in [Date(timeIntervalSinceReferenceDate: 50), finish, finish.addingTimeInterval(1)] {
            XCTAssertNoThrow(try value(start: start, completed: finish, cooked: cookedAt)
                .validate(state: .cooked, storage: .refrigerated))
        }
        let cookedBeforeThaw = value(phase: .thawing, start: start,
                                    cooked: Date(timeIntervalSinceReferenceDate: 50))
        XCTAssertNoThrow(try cookedBeforeThaw.validate(state: .cooked, storage: .refrigerated))
        XCTAssertNil(active.cookedAt, "cooked state must not manufacture a historical date")
    }

    func testEqualThawBoundaryIsValid() throws {
        XCTAssertNoThrow(try value(start: start, completed: start)
            .validate(state: .prepped, storage: .refrigerated))
        XCTAssertThrowsError(try value(start: start, completed: start.addingTimeInterval(-0.001))
            .validate(state: .prepped, storage: .refrigerated))
    }

    func testEveryNonfiniteTimestampIsRejected() {
        for number in [Double.nan, .infinity, -.infinity] {
            let invalidDate = Date(timeIntervalSinceReferenceDate: number)
            for candidate in [value(phase: .thawing, start: invalidDate),
                              value(start: start, completed: invalidDate),
                              value(cooked: invalidDate)] {
                XCTAssertThrowsError(try candidate.validate(state: .cooked, storage: .refrigerated))
                XCTAssertThrowsError(try JSONEncoder().encode(candidate))
            }
        }
    }
}
