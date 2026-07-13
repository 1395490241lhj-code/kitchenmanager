import XCTest
@testable import KitchenManager

/// `IngredientNormalizer` only does two things: (1) strip a trailing
/// "<space><optional digits><English weight/volume/count unit>" suffix, and
/// (2) an exact (not substring) alias lookup on the lowercased result. These
/// tests are written against that actual behavior — not against rules the
/// module doesn't implement (see comments below for pairs the current code
/// does NOT alias together).
@MainActor
final class IngredientNormalizerTests: XCTestCase {

    // MARK: - Basic whitespace / trimming

    func test_normalizedName_trimsLeadingAndTrailingWhitespace() {
        XCTAssertEqual(IngredientNormalizer.normalizedName("  番茄  "), "番茄")
    }

    func test_normalizedName_trimsLeadingAndTrailingNewlines() {
        XCTAssertEqual(IngredientNormalizer.normalizedName("\n番茄\n"), "番茄")
    }

    func test_normalizedName_doesNotCollapseInternalWhitespace() {
        // Documented current behavior: only leading/trailing whitespace is
        // trimmed. There is no internal-whitespace-collapsing rule.
        XCTAssertEqual(IngredientNormalizer.normalizedName("番  茄"), "番  茄")
    }

    func test_normalizedName_doesNotStripFullWidthOrChineseParentheses() {
        // The trailing-suffix regex only recognizes English unit abbreviations
        // (g/kg/lb/oz/ml/l/ct/pcs/packs); Chinese units and parentheses are
        // not part of it, so a Chinese-annotated quantity in parentheses is
        // left completely intact by this module (quantity stripping for
        // Chinese units is IngredientParser's job, not IngredientNormalizer's).
        XCTAssertEqual(IngredientNormalizer.normalizedName("鸡胸肉（500克）"), "鸡胸肉（500克）")
    }

    // MARK: - Trailing quantity+unit stripped from the name (English units only)

    func test_normalizedName_stripsTrailingGramsSuffix() {
        XCTAssertEqual(IngredientNormalizer.normalizedName("Chicken Breast 500g"), "Chicken Breast")
    }

    func test_normalizedName_stripsTrailingKgSuffix_thenAppliesAlias() {
        XCTAssertEqual(IngredientNormalizer.normalizedName("Potatoes 2kg"), "土豆")
    }

    func test_normalizedName_stripsTrailingMlSuffix_thenAppliesAlias() {
        XCTAssertEqual(IngredientNormalizer.normalizedName("milk 250ml"), "牛奶")
    }

    func test_normalizedName_stripsTrailingPcsSuffix() {
        XCTAssertEqual(IngredientNormalizer.normalizedName("Eggs 6pcs"), "鸡蛋")
    }

    func test_normalizedName_withoutSpaceBeforeUnit_doesNotStripSuffix() {
        // The regex requires `\s+` before the optional digits/unit — a glued
        // suffix like "500g" with no preceding space is not matched.
        XCTAssertEqual(IngredientNormalizer.normalizedName("Potatoes500g"), "Potatoes500g")
    }

    // MARK: - Case insensitivity for alias lookup

    func test_normalizedName_aliasLookupIsCaseInsensitive() {
        XCTAssertEqual(IngredientNormalizer.normalizedName("TOMATO"), "番茄")
        XCTAssertEqual(IngredientNormalizer.normalizedName("Tomato"), "番茄")
        XCTAssertEqual(IngredientNormalizer.normalizedName("tomato"), "番茄")
    }

    // MARK: - Actual supported aliases

    func test_normalizedName_xihongshi_aliasesToFanQie() {
        XCTAssertEqual(IngredientNormalizer.normalizedName("西红柿"), "番茄")
    }

    func test_normalizedName_xiaocong_aliasesToCong() {
        XCTAssertEqual(IngredientNormalizer.normalizedName("小葱"), "葱")
    }

    func test_normalizedName_qingcong_aliasesToCong() {
        XCTAssertEqual(IngredientNormalizer.normalizedName("青葱"), "葱")
    }

    func test_normalizedName_zhuJiaoRou_aliasesToZhuRouMo() {
        XCTAssertEqual(IngredientNormalizer.normalizedName("猪绞肉"), "猪肉末")
    }

    func test_normalizedName_englishEggVariants_aliasToJiDan() {
        XCTAssertEqual(IngredientNormalizer.normalizedName("egg"), "鸡蛋")
        XCTAssertEqual(IngredientNormalizer.normalizedName("eggs"), "鸡蛋")
        XCTAssertEqual(IngredientNormalizer.normalizedName("large eggs"), "鸡蛋")
    }

    func test_normalizedName_tofu_aliasesToDoufu() {
        XCTAssertEqual(IngredientNormalizer.normalizedName("tofu"), "豆腐")
    }

    func test_normalizedName_gingerAndGarlic_englishAliases() {
        XCTAssertEqual(IngredientNormalizer.normalizedName("ginger"), "姜")
        XCTAssertEqual(IngredientNormalizer.normalizedName("garlic"), "蒜")
    }

    // MARK: - Pairs the user asked about that are NOT aliased in current code
    // (documented, not invented — verifying the module's real scope)

    func test_jiXiong_andJiXiongRou_areNotAliasedTogether() {
        XCTAssertEqual(IngredientNormalizer.normalizedName("鸡胸"), "鸡胸")
        XCTAssertEqual(IngredientNormalizer.normalizedName("鸡胸肉"), "鸡胸肉")
        XCTAssertNotEqual(
            IngredientNormalizer.matchKey("鸡胸"),
            IngredientNormalizer.matchKey("鸡胸肉"),
            "no alias rule links 鸡胸 and 鸡胸肉 in the current code"
        )
    }

    func test_jiTui_andJiTuiRou_areNotAliasedTogether() {
        XCTAssertNotEqual(
            IngredientNormalizer.matchKey("鸡腿"),
            IngredientNormalizer.matchKey("鸡腿肉")
        )
    }

    func test_qingJiao_andCaiJiao_areNotAliasedTogether() {
        // No alias rule exists distinguishing/merging these two peppers.
        XCTAssertNotEqual(
            IngredientNormalizer.matchKey("青椒"),
            IngredientNormalizer.matchKey("彩椒")
        )
    }

    func test_zhuRouMo_andRouMo_areNotAliasedTogether() {
        // Only "猪绞肉" -> "猪肉末" is aliased; plain "肉末" has no rule
        // connecting it to "猪肉末".
        XCTAssertNotEqual(
            IngredientNormalizer.matchKey("猪肉末"),
            IngredientNormalizer.matchKey("肉末")
        )
    }

    func test_suan_andDaSuan_areNotAliasedTogether() {
        // Only the English "garlic" aliases to "蒜"; "大蒜" itself has no rule.
        XCTAssertNotEqual(
            IngredientNormalizer.matchKey("蒜"),
            IngredientNormalizer.matchKey("大蒜")
        )
    }

    // MARK: - False-merge guards: condiments must never collapse onto the base ingredient

    func test_niuRouJiang_isNotNormalizedToNiuRou() {
        XCTAssertEqual(IngredientNormalizer.normalizedName("牛肉酱"), "牛肉酱")
        XCTAssertNotEqual(
            IngredientNormalizer.matchKey("牛肉酱"),
            IngredientNormalizer.matchKey("牛肉")
        )
    }

    func test_yuLu_isNotNormalizedToYu() {
        XCTAssertEqual(IngredientNormalizer.normalizedName("鱼露"), "鱼露")
        XCTAssertNotEqual(
            IngredientNormalizer.matchKey("鱼露"),
            IngredientNormalizer.matchKey("鱼")
        )
    }

    func test_xiaJiang_isNotNormalizedToXia() {
        XCTAssertNotEqual(
            IngredientNormalizer.matchKey("虾酱"),
            IngredientNormalizer.matchKey("虾")
        )
    }

    func test_haoYou_isNotNormalizedToHaiXian() {
        XCTAssertNotEqual(
            IngredientNormalizer.matchKey("蚝油"),
            IngredientNormalizer.matchKey("海鲜")
        )
    }

    func test_jiJing_isNotNormalizedToJiRou() {
        XCTAssertNotEqual(
            IngredientNormalizer.matchKey("鸡精"),
            IngredientNormalizer.matchKey("鸡肉")
        )
    }

    func test_huoGuoDiLiao_isNotNormalizedToAnySingleSeasoning() {
        XCTAssertEqual(IngredientNormalizer.normalizedName("火锅底料"), "火锅底料")
    }

    // MARK: - normalizedUnit

    func test_normalizedUnit_trimsAndLowercases() {
        XCTAssertEqual(IngredientNormalizer.normalizedUnit("  Kg  "), "kg")
    }

    func test_normalizedUnit_emptyString_defaultsToFen() {
        XCTAssertEqual(IngredientNormalizer.normalizedUnit(""), "份")
        XCTAssertEqual(IngredientNormalizer.normalizedUnit("   "), "份")
    }

    func test_normalizedUnit_englishCountAliases() {
        XCTAssertEqual(IngredientNormalizer.normalizedUnit("piece"), "个")
        XCTAssertEqual(IngredientNormalizer.normalizedUnit("pieces"), "个")
        XCTAssertEqual(IngredientNormalizer.normalizedUnit("pcs"), "个")
        XCTAssertEqual(IngredientNormalizer.normalizedUnit("pc"), "个")
        XCTAssertEqual(IngredientNormalizer.normalizedUnit("pack"), "包")
        XCTAssertEqual(IngredientNormalizer.normalizedUnit("packs"), "包")
    }

    func test_normalizedUnit_gongjin_aliasesToQianke() {
        XCTAssertEqual(IngredientNormalizer.normalizedUnit("公斤"), "千克")
    }

    func test_normalizedUnit_unrecognizedUnit_passesThroughLowercased() {
        XCTAssertEqual(IngredientNormalizer.normalizedUnit("盒"), "盒")
    }

    // MARK: - matchKey

    func test_matchKey_stripsAllWhitespaceAndLowercases() {
        XCTAssertEqual(IngredientNormalizer.matchKey(" Tomato "), IngredientNormalizer.matchKey("番茄"))
    }

    func test_matchKey_isStableForSameNormalizedName() {
        XCTAssertEqual(IngredientNormalizer.matchKey("番茄"), IngredientNormalizer.matchKey("  番茄  "))
    }
}
