import XCTest
@testable import KitchenManager

@MainActor
final class InventoryExpirySuggestionTests: XCTestCase {
    /// A fixed reference date (2026-01-01 00:00:00 UTC) — every test computes
    /// its expected date relative to this, never to `Date()`.
    private var fixedDate: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
    }

    private func expectedDate(daysAfterFixed days: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(byAdding: .day, value: days, to: fixedDate)!
    }

    private func assertDays(
        _ name: String,
        category: String? = nil,
        equals expectedDays: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let result = InventoryExpirySuggestion.suggestedExpiryDate(for: name, category: category, from: fixedDate)
        guard let result else {
            return XCTFail("expected \(name) to suggest \(expectedDays) days, got nil", file: file, line: line)
        }
        let diff = Calendar.current.dateComponents([.day], from: fixedDate, to: result).day
        XCTAssertEqual(diff, expectedDays, "for \(name)", file: file, line: line)
    }

    private func assertNil(_ name: String, category: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(
            InventoryExpirySuggestion.suggestedExpiryDate(for: name, category: category, from: fixedDate),
            "expected \(name) to suggest nil",
            file: file,
            line: line
        )
    }

    // MARK: - Meat: 3 days

    func test_meat_zhuRou() { assertDays("猪肉", equals: 3) }
    func test_meat_niuRou() { assertDays("牛肉", equals: 3) }
    func test_meat_jiXiongRou() { assertDays("鸡胸肉", equals: 3) }
    func test_meat_jiTuiRou() { assertDays("鸡腿肉", equals: 3) }
    func test_meat_paiGu() { assertDays("排骨", equals: 3) }

    // MARK: - Seafood: 2 days

    func test_seafood_yu() { assertDays("鱼", equals: 2) }
    func test_seafood_sanWenYu() { assertDays("三文鱼", equals: 2) }
    func test_seafood_xia() { assertDays("虾", equals: 2) }
    func test_seafood_pangXie() { assertDays("螃蟹", equals: 2) }

    // MARK: - Vegetables / fruit

    func test_vegetable_boCai_leafy5Days() { assertDays("菠菜", equals: 5) }
    func test_vegetable_shengCai_leafy5Days() { assertDays("生菜", equals: 5) }
    func test_vegetable_xiLanHua_fresh7Days() { assertDays("西兰花", equals: 7) }
    func test_vegetable_fanQie_fresh7Days() { assertDays("番茄", equals: 7) }
    func test_fruit_xiangJiao_7Days() { assertDays("香蕉", equals: 7) }
    func test_fruit_caoMei_7Days() { assertDays("草莓", equals: 7) }

    // MARK: - Dairy / egg / tofu

    func test_dairy_niuNai_7Days() { assertDays("牛奶", equals: 7) }
    func test_dairy_suanNai_7Days() { assertDays("酸奶", equals: 7) }
    func test_egg_jiDan_21Days() { assertDays("鸡蛋", equals: 21) }
    func test_tofu_doufu_5Days() { assertDays("豆腐", equals: 5) }
    func test_tofu_doufuGan_5Days() { assertDays("豆干", equals: 5) }

    // MARK: - Frozen: 90 days, by name keyword or by category

    func test_frozen_lengDongRou_byName() { assertDays("冷冻肉", equals: 90) }
    func test_frozen_lengDongYu_byName() { assertDays("冷冻鱼", equals: 90) }
    func test_frozen_suDongShuCai_byNameKeyword() { assertDays("速冻蔬菜", equals: 90) }

    func test_frozen_categoryContainsLengDong_overridesToNinetyDays() {
        // A plain vegetable name would normally suggest 7 days, but a
        // category containing "冷冻" takes priority.
        assertDays("西兰花", category: "冷冻蔬菜区", equals: 90)
    }

    // MARK: - Shelf-stable staples: now finite, long defaults (Part 4 rule change — no more nil)

    func test_shelfStable_daMi_180Days() { assertDays("大米", equals: 180) }
    func test_shelfStable_mianFen_180Days() { assertDays("面粉", equals: 180) }
    func test_shelfStable_shiYongYou_180Days() { assertDays("食用油", equals: 180) }
    func test_shelfStable_jiangYou_365Days() { assertDays("酱油", equals: 365) }
    func test_shelfStable_cu_365Days() { assertDays("醋", equals: 365) }
    func test_shelfStable_yiMian_180Days() { assertDays("意面", equals: 180) }
    func test_shelfStable_kaFeiDou_180Days() { assertDays("咖啡豆", equals: 180) }
    func test_shelfStable_yan_365Days() { assertDays("盐", equals: 365) }
    func test_shelfStable_tang_365Days() { assertDays("糖", equals: 365) }
    func test_shelfStable_ganHuo_180Days() { assertDays("干货", equals: 180) }
    func test_shelfStable_guanTou_365Days() { assertDays("罐头", equals: 365) }
    func test_shelfStable_chaYe_180Days() { assertDays("茶叶", equals: 180) }

    // MARK: - New categories introduced in this pass

    func test_bread_mianBao_5Days() { assertDays("面包", equals: 5) }
    func test_deli_shuShi_3Days() { assertDays("熟食", equals: 3) }
    func test_curedMeat_huoTui_7Days() { assertDays("火腿", equals: 7) }
    func test_curedMeat_xiangChang_7Days() { assertDays("香肠", equals: 7) }
    func test_openedSauce_doubanjiang_90Days() { assertDays("豆瓣酱", equals: 90) }

    // MARK: - False-merge guards: condiments must not match meat/seafood day counts

    func test_condiment_niuRouJiang_is90Days_notThreeDaysLikeMeat() { assertDays("牛肉酱", equals: 90) }
    func test_condiment_yuLu_is365Days_notTwoDaysLikeSeafood() { assertDays("鱼露", equals: 365) }
    func test_condiment_xiaJiang_is90Days_notTwoDaysLikeSeafood() { assertDays("虾酱", equals: 90) }
    func test_condiment_haoYou_is365Days_notTwoDaysLikeSeafood() { assertDays("蚝油", equals: 365) }
    func test_condiment_douBanJiang_is90Days_notThreeDaysLikeMeat() { assertDays("豆瓣酱", equals: 90) }
    func test_condiment_huoGuoDiLiao_is90Days() { assertDays("火锅底料", equals: 90) }

    // MARK: - Category priority

    func test_category_containingChangBei_alwaysReturnsNil_evenForMeat() {
        assertNil("猪肉", category: "常备")
    }

    func test_category_frozen_takesPriorityOverMeatNameKeyword() {
        // "猪肉" alone would suggest 3 days; a "冷冻" category must win.
        assertDays("猪肉", category: "冷冻食品", equals: 90)
    }

    func test_shelfStableGuard_checkedBeforeMeatSeafoodKeywords() {
        // "牛肉酱"/"鱼露"/"虾酱" contain "牛肉"/"鱼"/"虾" as substrings and
        // would false-positive into the meat/seafood buckets if the
        // condiment guards weren't checked first — this is the specific
        // ordering the production code's comment calls out. They must not
        // equal the meat (3) or seafood (2) day counts.
        XCTAssertNotEqual(InventoryExpirySuggestion.suggestedExpiryDate(for: "牛肉酱", from: fixedDate), expectedDate(daysAfterFixed: 3))
        XCTAssertNotEqual(InventoryExpirySuggestion.suggestedExpiryDate(for: "鱼露", from: fixedDate), expectedDate(daysAfterFixed: 2))
        XCTAssertNotEqual(InventoryExpirySuggestion.suggestedExpiryDate(for: "虾酱", from: fixedDate), expectedDate(daysAfterFixed: 2))
    }

    // MARK: - Unknown ingredient: conservative 7-day default (Part 4 rule change — no more nil)

    func test_unknownIngredient_defaultsToSevenDays() {
        assertDays("某种从未见过的食材XYZ", equals: 7)
    }

    // MARK: - Date accuracy against a fixed creationDate

    func test_dateAccuracy_jiDan21Days_fromFixedDate() {
        let result = InventoryExpirySuggestion.suggestedExpiryDate(for: "鸡蛋", from: fixedDate)
        XCTAssertEqual(result, expectedDate(daysAfterFixed: 21))
    }

    func test_dateAccuracy_jiuCaiHua5Days_fromFixedDate() {
        let result = InventoryExpirySuggestion.suggestedExpiryDate(for: "韭菜花", from: fixedDate)
        XCTAssertEqual(result, expectedDate(daysAfterFixed: 5))
    }

    // MARK: - Name normalization is applied before matching

    func test_nameWithEnglishAlias_isNormalizedBeforeMatching() {
        // IngredientNormalizer aliases "milk" -> "牛奶" before this module's
        // keyword matching runs, so the English name still lands in the
        // dairy (7-day) bucket rather than falling through to nil.
        assertDays("milk", equals: 7)
    }
}
