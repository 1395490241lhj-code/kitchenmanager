import XCTest
@testable import KitchenManager

/// `UnitConverter` only converts within one physical dimension (weight in
/// grams, or volume in milliliters) — it never bridges weight/volume/count,
/// and counting units (个/盒/包/瓶/...) are never converted between each
/// other. lb/oz/cup/tbsp/tsp: only lb/oz are actually implemented in the
/// current table (verified by reading `weightUnitsToGrams`); cup/tbsp/tsp
/// have no entries, so those are tested as "not convertible", not skipped.
@MainActor
final class UnitConverterTests: XCTestCase {
    private func assertConversion(
        _ quantity: Double,
        from unit: String,
        to targetUnit: String,
        equals expected: Double,
        accuracy: Double = 0.0001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let result = UnitConverter.convert(quantity, from: unit, to: targetUnit) else {
            return XCTFail("expected \(quantity)\(unit) -> \(targetUnit) to convert, got nil", file: file, line: line)
        }
        XCTAssertEqual(result, expected, accuracy: accuracy, file: file, line: line)
    }

    // MARK: - Weight

    func test_kgToG() {
        assertConversion(1, from: "kg", to: "g", equals: 1000)
    }

    func test_gToKg() {
        assertConversion(1000, from: "g", to: "kg", equals: 1)
    }

    func test_keToG_chineseUnit() {
        assertConversion(1, from: "克", to: "g", equals: 1)
    }

    func test_qianKeToG_chineseUnit() {
        assertConversion(1, from: "千克", to: "g", equals: 1000)
    }

    func test_jinToG() {
        assertConversion(1, from: "斤", to: "g", equals: 500)
    }

    func test_liangToG() {
        assertConversion(1, from: "两", to: "g", equals: 50)
    }

    func test_lbToG_supportedByCurrentTable() {
        assertConversion(1, from: "lb", to: "g", equals: 453.592, accuracy: 0.001)
    }

    func test_ozToG_supportedByCurrentTable() {
        assertConversion(1, from: "oz", to: "g", equals: 28.3495, accuracy: 0.001)
    }

    func test_sameWeightUnit_returnsSameQuantity() {
        assertConversion(3.5, from: "g", to: "g", equals: 3.5)
        assertConversion(3.5, from: "kg", to: "kg", equals: 3.5)
    }

    // MARK: - Volume

    func test_lToMl() {
        assertConversion(1, from: "l", to: "ml", equals: 1000)
    }

    func test_mlToL() {
        assertConversion(1000, from: "ml", to: "l", equals: 1)
    }

    func test_shengToMl_chineseUnit() {
        assertConversion(1, from: "升", to: "ml", equals: 1000)
    }

    func test_haoshengToMl_chineseUnit() {
        assertConversion(1, from: "毫升", to: "ml", equals: 1)
    }

    func test_cupTbspTsp_areNotInCurrentConversionTable() {
        // Documented gap, not invented behavior: the current weight/volume
        // tables have no entries for cup/tbsp/tsp, so conversions involving
        // them return nil rather than a (fabricated) numeric result.
        XCTAssertNil(UnitConverter.convert(1, from: "cup", to: "ml"))
        XCTAssertNil(UnitConverter.convert(1, from: "tbsp", to: "ml"))
        XCTAssertNil(UnitConverter.convert(1, from: "tsp", to: "ml"))
    }

    // MARK: - Counting units: never auto-converted between each other

    func test_geToGe_sameUnit_isIdentity() {
        assertConversion(3, from: "个", to: "个", equals: 3)
    }

    func test_keToGe_isNotConvertible() {
        // "颗" -> "个" has no defined ratio in the current rules; this must
        // stay unconvertible rather than silently assumed to be 1:1.
        XCTAssertNil(UnitConverter.convert(1, from: "颗", to: "个"))
        XCTAssertFalse(UnitConverter.areConvertible("颗", "个"))
    }

    func test_boxBagBottle_areNeverConvertedBetweenEachOther() {
        XCTAssertNil(UnitConverter.convert(1, from: "盒", to: "袋"))
        XCTAssertNil(UnitConverter.convert(1, from: "袋", to: "瓶"))
        XCTAssertNil(UnitConverter.convert(1, from: "盒", to: "瓶"))
        XCTAssertFalse(UnitConverter.areConvertible("盒", "袋"))
    }

    // MARK: - Incompatible dimensions never cross-convert

    func test_gramsAndMilliliters_areNotConvertible() {
        XCTAssertNil(UnitConverter.convert(100, from: "g", to: "ml"))
        XCTAssertFalse(UnitConverter.areConvertible("g", "ml"))
    }

    func test_geAndGrams_areNotConvertible() {
        XCTAssertNil(UnitConverter.convert(1, from: "个", to: "g"))
        XCTAssertFalse(UnitConverter.areConvertible("个", "g"))
    }

    func test_boxAndMilliliters_areNotConvertible() {
        XCTAssertNil(UnitConverter.convert(1, from: "盒", to: "ml"))
    }

    func test_vagueUnitAndGrams_areNotConvertible() {
        XCTAssertNil(UnitConverter.convert(1, from: "少许", to: "g"))
    }

    func test_emptyUnit_isNotConvertible() {
        XCTAssertNil(UnitConverter.convert(1, from: "", to: "g"))
        XCTAssertFalse(UnitConverter.areConvertible("", "g"))
    }

    // MARK: - isWeightUnit / isVolumeUnit

    func test_isWeightUnit_recognizesKnownWeightUnits() {
        XCTAssertTrue(UnitConverter.isWeightUnit("kg"))
        XCTAssertTrue(UnitConverter.isWeightUnit("克"))
        XCTAssertFalse(UnitConverter.isWeightUnit("ml"))
        XCTAssertFalse(UnitConverter.isWeightUnit("个"))
    }

    func test_isVolumeUnit_recognizesKnownVolumeUnits() {
        XCTAssertTrue(UnitConverter.isVolumeUnit("ml"))
        XCTAssertTrue(UnitConverter.isVolumeUnit("升"))
        XCTAssertFalse(UnitConverter.isVolumeUnit("kg"))
    }

    // MARK: - Precision / edge values

    func test_convert_fractionalQuantity() {
        assertConversion(0.5, from: "kg", to: "g", equals: 500)
    }

    func test_convert_nonIntegerRatio_lbToG_hasFloatingPointTolerance() {
        assertConversion(2.2, from: "lb", to: "g", equals: 998.0, accuracy: 0.5)
    }

    func test_convert_zeroQuantity_returnsZero() {
        assertConversion(0, from: "kg", to: "g", equals: 0)
    }

    func test_convert_negativeQuantity_stillConvertsProportionally() {
        // UnitConverter itself does no clamping — negative inputs are the
        // caller's responsibility to prevent (KitchenStore does that at the
        // point of adding inventory). This documents the converter's own,
        // unclamped math.
        assertConversion(-2, from: "kg", to: "g", equals: -2000)
    }

    func test_convert_veryLargeQuantity() {
        assertConversion(1_000_000, from: "g", to: "kg", equals: 1000, accuracy: 0.01)
    }

    // MARK: - areConvertible symmetry

    func test_areConvertible_isSymmetric() {
        XCTAssertEqual(UnitConverter.areConvertible("kg", "g"), UnitConverter.areConvertible("g", "kg"))
        XCTAssertTrue(UnitConverter.areConvertible("kg", "g"))
    }

    func test_areConvertible_caseInsensitive() {
        XCTAssertTrue(UnitConverter.areConvertible("KG", "G"))
    }
}
