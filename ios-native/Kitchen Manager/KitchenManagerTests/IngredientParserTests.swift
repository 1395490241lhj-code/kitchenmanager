import XCTest
@testable import KitchenManager

/// Every expectation below was verified against the real production parser
/// (via a standalone script run before writing this file, then re-verified
/// after two small bug fixes — see the "Bugs found" section) rather than
/// hand-derived, since the branching in `IngredientParser` is intricate
/// enough that hand-tracing is unreliable.
@MainActor
final class IngredientParserTests: XCTestCase {

    // MARK: - Explicit "name quantity unit" formats

    func test_nameSpaceQuantityGluedUnit() {
        let p = IngredientParser.parse("鸡胸肉 500g")
        XCTAssertEqual(p.displayName, "鸡胸肉")
        XCTAssertEqual(p.quantity, 500)
        XCTAssertEqual(p.unit, "g")
    }

    func test_nameSpaceQuantitySpaceUnit() {
        let p = IngredientParser.parse("鸡胸肉 500 g")
        XCTAssertEqual(p.displayName, "鸡胸肉")
        XCTAssertEqual(p.quantity, 500)
        XCTAssertEqual(p.unit, "g")
    }

    func test_eggsCountFormat() {
        let p = IngredientParser.parse("鸡蛋 2个")
        XCTAssertEqual(p.displayName, "鸡蛋")
        XCTAssertEqual(p.quantity, 2)
        XCTAssertEqual(p.unit, "个")
    }

    func test_milkMilliliters() {
        let p = IngredientParser.parse("牛奶 250ml")
        XCTAssertEqual(p.displayName, "牛奶")
        XCTAssertEqual(p.quantity, 250)
        XCTAssertEqual(p.unit, "ml")
    }

    func test_waterDecimalLiters() {
        let p = IngredientParser.parse("水 1.5L")
        XCTAssertEqual(p.displayName, "水")
        XCTAssertEqual(p.quantity ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(p.unit, "l")
    }

    func test_gluedCompactChineseForm_liangGeJiDan() {
        XCTAssertEqual(IngredientParser.parse("鸡蛋2个").displayName, "鸡蛋")
        XCTAssertEqual(IngredientParser.parse("鸡蛋2个").quantity, 2)
    }

    func test_gluedCompactChineseForm_yiFenJiuCaiHua() {
        let p = IngredientParser.parse("韭菜花一份")
        XCTAssertEqual(p.displayName, "韭菜花")
        XCTAssertEqual(p.quantity, 1)
        XCTAssertEqual(p.unit, "份")
    }

    func test_milkOneBox() {
        let p = IngredientParser.parse("牛奶 1 盒")
        XCTAssertEqual(p.displayName, "牛奶")
        XCTAssertEqual(p.quantity, 1)
        XCTAssertEqual(p.unit, "盒")
    }

    // MARK: - Vague quantity words ("少许"/"适量") -> no numeric quantity, isVague = true

    func test_saltShaoXu_isVagueWithNoQuantity() {
        let p = IngredientParser.parse("盐 少许")
        XCTAssertEqual(p.displayName, "盐")
        XCTAssertNil(p.quantity)
        XCTAssertNil(p.unit)
        XCTAssertTrue(p.isVague)
    }

    func test_congShiLiang_isVagueWithNoQuantity() {
        let p = IngredientParser.parse("葱 适量")
        XCTAssertTrue(p.isVague)
        XCTAssertNil(p.quantity)
    }

    // MARK: - Chinese numeral words and compact glued quantifiers

    func test_liangGeJiDan_compactChineseNumeral() {
        let p = IngredientParser.parse("两个鸡蛋")
        XCTAssertEqual(p.displayName, "鸡蛋")
        XCTAssertEqual(p.quantity, 2)
        XCTAssertEqual(p.unit, "个")
    }

    func test_yiBaXiangCai_compactChineseNumeral() {
        let p = IngredientParser.parse("一把香菜")
        XCTAssertEqual(p.displayName, "香菜")
        XCTAssertEqual(p.quantity, 1)
        XCTAssertEqual(p.unit, "把")
    }

    func test_banJinZhuRou_halfJinChineseNumeral() {
        let p = IngredientParser.parse("半斤猪肉")
        XCTAssertEqual(p.displayName, "猪肉")
        XCTAssertEqual(p.quantity ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(p.unit, "斤")
    }

    // MARK: - Fractions (bug fixed — see comment on IngredientParser.splitTrailingQuantity)

    func test_fractionQuantity_withTrailingUnit() {
        let p = IngredientParser.parse("鸡胸肉 1/2 kg")
        XCTAssertEqual(p.displayName, "鸡胸肉")
        XCTAssertEqual(p.quantity ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(p.unit, "kg")
    }

    // MARK: - Colon separator (bug fixed — see comment on IngredientParser.splitTrailingQuantity)

    func test_colonSeparator_nameDoesNotRetainColon() {
        let p = IngredientParser.parse("鸡胸肉：500克")
        XCTAssertEqual(p.displayName, "鸡胸肉", "the '：' separator must not stick to the parsed name")
        XCTAssertEqual(p.quantity, 500)
        XCTAssertEqual(p.unit, "克")
    }

    // MARK: - Product codes with a digit glued to an ASCII letter are left intact

    func test_productCodeWithLetterAndDigit_isNotMisparsedAsAQuantity() {
        let p = IngredientParser.parse("维生素B2")
        XCTAssertEqual(p.displayName, "维生素B2")
        XCTAssertNil(p.quantity)
    }

    // MARK: - Formats not supported by the current parser (documented gaps, not invented fixes)

    func test_leadingGluedArabicQuantityAndChineseUnit_isNotCurrentlyParsed() {
        // "500克鸡胸肉" — a bare Arabic-digit quantity glued directly to a
        // Chinese unit and name, with no space and no Chinese numeral word —
        // has no matching branch in the current parser. This is a real gap,
        // but supporting it means adding a new parsing branch (not a small
        // fix), so it is left as-is and reported rather than silently patched.
        let p = IngredientParser.parse("500克鸡胸肉")
        XCTAssertNil(p.quantity, "documents the current gap — see final report")
        XCTAssertEqual(p.displayName, "500克鸡胸肉")
    }

    func test_parentheticalQuantity_isNotCurrentlyParsed() {
        // "鸡胸肉（500克）" — same category of gap as above.
        let p = IngredientParser.parse("鸡胸肉（500克）")
        XCTAssertNil(p.quantity, "documents the current gap — see final report")
        XCTAssertEqual(p.displayName, "鸡胸肉（500克）")
    }

    // MARK: - Abnormal input must never crash

    func test_emptyString_doesNotCrash_returnsEmptyName() {
        let p = IngredientParser.parse("")
        XCTAssertEqual(p.displayName, "")
        XCTAssertNil(p.quantity)
    }

    func test_onlyWhitespace_doesNotCrash() {
        let p = IngredientParser.parse("   ")
        XCTAssertNil(p.quantity)
    }

    func test_onlyUnit_noQuantityOrName_doesNotCrash() {
        let p = IngredientParser.parse("个")
        XCTAssertNil(p.quantity)
        XCTAssertEqual(p.displayName, "个")
    }

    func test_onlyNumber_noNameOrUnit_doesNotCrash() {
        let p = IngredientParser.parse("500")
        XCTAssertNil(p.quantity)
        XCTAssertEqual(p.displayName, "500")
    }

    func test_veryLargeNumber_doesNotCrash() {
        let p = IngredientParser.parse("999999999999")
        XCTAssertNil(p.quantity)
        XCTAssertEqual(p.displayName, "999999999999")
    }

    func test_negativeNumber_doesNotCrash_producesAStableResult() {
        // Current behavior treats the leading "-" as part of a leftover name
        // fragment rather than a sign — negative ingredient quantities are
        // not a meaningful real-world case, so this only asserts "does not
        // crash and is deterministic", not that the sign is preserved.
        let p = IngredientParser.parse("-5 个")
        XCTAssertEqual(p.quantity, 5)
        XCTAssertEqual(p.unit, "个")
    }

    func test_multipleNumbers_doesNotCrash_producesAStableResult() {
        let p = IngredientParser.parse("2 3 个")
        XCTAssertNotNil(p.quantity)
    }

    func test_multipleUnits_doesNotCrash_producesAStableResult() {
        let p = IngredientParser.parse("2 个 盒")
        XCTAssertNotNil(p.quantity)
    }

    // MARK: - Determinism

    func test_parse_isDeterministic_sameInputSameOutput() {
        let first = IngredientParser.parse("鸡胸肉 500g")
        let second = IngredientParser.parse("鸡胸肉 500g")
        XCTAssertEqual(first.displayName, second.displayName)
        XCTAssertEqual(first.quantity, second.quantity)
        XCTAssertEqual(first.unit, second.unit)
    }
}
