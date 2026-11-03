import SwiftUI
import XCTest
@testable import KitchenManager

/// INV-2: quantity boxes built on `TextField(value:format:)` committed only on
/// return or focus loss, and the decimal pad has no return key, so tapping 保存
/// straight after typing saved the old amount. `DecimalQuantityField` writes
/// the amount through on every keystroke; these pin what each keystroke writes.
@MainActor
final class DecimalQuantityFieldTests: XCTestCase {
    func testTheFieldShowsAnAmountWithoutGroupingOrTrailingZeros() {
        XCTAssertEqual(DecimalQuantityField.text(for: 2), "2")
        XCTAssertEqual(DecimalQuantityField.text(for: 0.5), "0.5")
        XCTAssertEqual(DecimalQuantityField.text(for: 1500), "1500",
                       "a grouped 1,500 would read back as 1.5")
        XCTAssertEqual(DecimalQuantityField.text(for: nil), "")
    }

    func testEachKeystrokeWritesTheTypedAmount() {
        let two = DecimalQuantityField.Shown(amount: 2)
        XCTAssertEqual(DecimalQuantityField.quantity(afterTyping: "2.5", shown: two, whenUnreadable: nil), 2.5)
        XCTAssertEqual(DecimalQuantityField.quantity(afterTyping: "0,5", shown: two, whenUnreadable: nil), 0.5)
        XCTAssertEqual(DecimalQuantityField.quantity(afterTyping: "0.", shown: .init(amount: nil), whenUnreadable: nil), 0)
        XCTAssertNil(DecimalQuantityField.quantity(afterTyping: "", shown: two, whenUnreadable: nil))
        XCTAssertNil(DecimalQuantityField.quantity(afterTyping: "半", shown: two, whenUnreadable: nil))
    }

    func testShowingAnAmountDoesNotRoundIt() {
        let shown = DecimalQuantityField.Shown(amount: 0.125)
        XCTAssertNotEqual(shown.text, "0.125", "precondition: the box shows fewer digits than it holds")
        XCTAssertEqual(DecimalQuantityField.quantity(afterTyping: shown.text, shown: shown, whenUnreadable: nil), 0.125,
                       "the box's own rendering of 0.125 must not write the rounded amount back")
    }

    /// The keep-as-is rule is for text the box wrote itself, not for text the
    /// member typed: 2.345 backspaced to 2.34 must write 2.34, though the box
    /// would show 2.345 as 2.34.
    func testDeletingADigitOfATypedAmountWritesWhatIsLeft() {
        let shown = DecimalQuantityField.Shown(amount: 2)
        XCTAssertEqual(DecimalQuantityField.quantity(afterTyping: "2.345", shown: shown, whenUnreadable: nil), 2.345)
        XCTAssertEqual(DecimalQuantityField.quantity(afterTyping: "2.34", shown: shown, whenUnreadable: nil), 2.34,
                       "框里是 2.34，存的也必须是 2.34")
    }

    /// Once the member edits the box, its own rendering no longer stands for
    /// the hidden amount: 0.125 shown as 0.12, backspaced to 0.1 and retyped
    /// as 0.12, is 0.12.
    func testRetypingTheShownTextAfterEditingWritesWhatIsTyped() {
        var shown: DecimalQuantityField.Shown? = .init(amount: 0.125)
        var stored: Double? = 0.125
        func type(_ typed: String) {
            stored = DecimalQuantityField.quantity(afterTyping: typed, shown: shown, whenUnreadable: nil)
            shown = DecimalQuantityField.shown(shown, afterTyping: typed)
        }

        type("0.1")
        XCTAssertEqual(stored, 0.1)
        type("0.12")
        XCTAssertEqual(stored, 0.12, "框里是 0.12，存的也必须是 0.12")
    }

    /// F1: backspacing 12 passes through 1. A required box that ends up empty
    /// or unreadable goes back to the amount it had when editing began, never
    /// to a half-deleted number the member did not mean and cannot see.
    func testAClearedRequiredAmountGoesBackToTheAmountBeforeEditing() {
        var stored = 12.0
        let required = DecimalQuantityField.keepingLastValue(Binding(get: { stored }, set: { stored = $0 }))
        let beforeEditing = required.wrappedValue
        let shown = DecimalQuantityField.Shown(amount: beforeEditing)
        func type(_ typed: String) {
            required.wrappedValue = DecimalQuantityField.quantity(
                afterTyping: typed, shown: shown, whenUnreadable: beforeEditing
            )
        }

        type("1")
        XCTAssertEqual(stored, 1, "a readable box writes what it shows")
        type("")
        XCTAssertEqual(stored, 12, "清空后保存的是原来的 12，不是删到一半的 1")
        XCTAssertNil(DecimalQuantityField.textAfterOutsideChange(to: stored, shown: "", whenUnreadable: beforeEditing),
                     "going back to 12 must not refill the box the member is clearing")
        type("-1")
        XCTAssertEqual(stored, 12)
        type("8")
        XCTAssertEqual(stored, 8, "typing a new amount after clearing still writes it")
    }

    /// With nothing to go back to, a required amount ignores the empty write.
    func testARequiredAmountIgnoresAnEmptyWrite() {
        var stored = 3.0
        let required = DecimalQuantityField.keepingLastValue(Binding(get: { stored }, set: { stored = $0 }))

        required.wrappedValue = nil
        XCTAssertEqual(stored, 3)
    }

    /// An amount set from outside the box — a picked batch, a regenerated
    /// list — replaces the text; the box's own writes leave what is typed alone.
    func testAnOutsideChangeReplacesTheTextButTypingIsLeftAlone() {
        XCTAssertEqual(DecimalQuantityField.textAfterOutsideChange(to: 4, shown: "0", whenUnreadable: nil), "4")
        XCTAssertEqual(DecimalQuantityField.textAfterOutsideChange(to: nil, shown: "2", whenUnreadable: nil), "")
        XCTAssertNil(DecimalQuantityField.textAfterOutsideChange(to: 0, shown: "0.", whenUnreadable: nil))
        XCTAssertNil(DecimalQuantityField.textAfterOutsideChange(to: 1.5, shown: "1,5", whenUnreadable: nil))
        XCTAssertNil(DecimalQuantityField.textAfterOutsideChange(to: nil, shown: "", whenUnreadable: nil))
        XCTAssertEqual(DecimalQuantityField.textAfterOutsideChange(to: 4, shown: "", whenUnreadable: 12), "4",
                       "a picked batch still fills a cleared box")
    }
}
