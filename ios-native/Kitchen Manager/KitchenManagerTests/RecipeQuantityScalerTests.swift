import XCTest
@testable import KitchenManager

/// `RecipeQuantityScaler` — the arithmetic behind base → target scaling.
///
/// The rule these tests protect: an unknown or unusable input returns `nil`,
/// never a quietly-successful 1.0. A scaler that treats "I do not know" as
/// "multiply by one" produces numbers that look computed but are not.
final class RecipeQuantityScalerTests: XCTestCase {
    // MARK: - Factor

    func testHalvingAndDoubling() {
        XCTAssertEqual(RecipeQuantityScaler.factor(baseServings: 4, targetServings: 2), 0.5)
        XCTAssertEqual(RecipeQuantityScaler.factor(baseServings: 2, targetServings: 4), 2.0)
    }

    func testEqualServingsIsExactlyOne() {
        XCTAssertEqual(RecipeQuantityScaler.factor(baseServings: 4, targetServings: 4), 1.0)
    }

    func testBaseFourToTargetSeven() {
        let factor = try? XCTUnwrap(RecipeQuantityScaler.factor(baseServings: 4, targetServings: 7))
        XCTAssertEqual(factor ?? 0, 1.75, accuracy: 0.0001)
    }

    func testUnknownBaseYieldsNoFactor() {
        XCTAssertNil(
            RecipeQuantityScaler.factor(baseServings: nil, targetServings: 4),
            "a recipe that never stated its yield cannot be scaled"
        )
    }

    func testUnknownTargetYieldsNoFactor() {
        XCTAssertNil(RecipeQuantityScaler.factor(baseServings: 4, targetServings: nil))
    }

    func testOutOfRangeServingsYieldNoFactor() {
        // Mirrors Recipe.validatedBaseServings: a value the app would refuse to
        // store must not be usable as a denominator either.
        for invalid in [0, -1, 13, 99] {
            XCTAssertNil(
                RecipeQuantityScaler.factor(baseServings: invalid, targetServings: 4),
                "base \(invalid) is out of range"
            )
            XCTAssertNil(
                RecipeQuantityScaler.factor(baseServings: 4, targetServings: invalid),
                "target \(invalid) is out of range"
            )
        }
    }

    func testEveryValidPairProducesAPositiveFactor() {
        for base in RecipeQuantityScaler.validServings {
            for target in RecipeQuantityScaler.validServings {
                let factor = RecipeQuantityScaler.factor(baseServings: base, targetServings: target)
                XCTAssertNotNil(factor, "\(base) -> \(target) must be scalable")
                XCTAssertGreaterThan(factor ?? 0, 0)
            }
        }
    }

    // MARK: - Scaling a quantity

    func testScalingHalvesAndDoubles() {
        XCTAssertEqual(RecipeQuantityScaler.scale(quantity: 500, baseServings: 4, targetServings: 2), 250)
        XCTAssertEqual(RecipeQuantityScaler.scale(quantity: 500, baseServings: 2, targetServings: 4), 1000)
    }

    func testScalingIsUnchangedAtEqualServings() {
        XCTAssertEqual(RecipeQuantityScaler.scale(quantity: 300, baseServings: 4, targetServings: 4), 300)
    }

    func testScalingReturnsNilWhenItCannotScale() {
        // Distinguishable from a successful no-op, which is the whole point.
        XCTAssertNil(RecipeQuantityScaler.scale(quantity: 500, baseServings: nil, targetServings: 2))
        XCTAssertNil(RecipeQuantityScaler.scale(quantity: 500, baseServings: 4, targetServings: nil))
        XCTAssertNil(RecipeQuantityScaler.scale(quantity: 500, baseServings: 0, targetServings: 2))
    }

    func testFractionalResultsAreNotPrematurelyRounded() {
        // Rounding belongs to display and shopping aggregation, each of which
        // rounds differently; rounding here would corrupt both.
        let scaled = try? XCTUnwrap(RecipeQuantityScaler.scale(quantity: 3, baseServings: 4, targetServings: 2))
        XCTAssertEqual(scaled ?? 0, 1.5, accuracy: 0.0001)
    }

    func testZeroQuantityStaysZero() {
        XCTAssertEqual(RecipeQuantityScaler.scale(quantity: 0, baseServings: 4, targetServings: 7), 0)
    }

    func testNonFiniteQuantityIsReturnedUnchanged() {
        XCTAssertTrue(RecipeQuantityScaler.scale(quantity: .nan, factor: 2).isNaN)
        XCTAssertEqual(RecipeQuantityScaler.scale(quantity: 5, factor: .infinity), 5)
    }

    func testScalingWithAKnownFactorMatchesTheServingsForm() {
        let factor = try? XCTUnwrap(RecipeQuantityScaler.factor(baseServings: 4, targetServings: 6))
        XCTAssertEqual(
            RecipeQuantityScaler.scale(quantity: 200, factor: factor ?? 1),
            RecipeQuantityScaler.scale(quantity: 200, baseServings: 4, targetServings: 6)
        )
    }

    func testRoundTripBackToBaseRestoresTheOriginal() {
        let up = try? XCTUnwrap(RecipeQuantityScaler.scale(quantity: 400, baseServings: 4, targetServings: 7))
        let down = try? XCTUnwrap(RecipeQuantityScaler.scale(quantity: up ?? 0, baseServings: 7, targetServings: 4))
        XCTAssertEqual(down ?? 0, 400, accuracy: 0.0001)
    }

    // MARK: - Boundary with the rest of the app

    func testScalerRangeMatchesTheRecipeModel() {
        // If Recipe ever widens its range, this must move with it rather than
        // silently refusing yields the app now stores.
        XCTAssertEqual(RecipeQuantityScaler.validServings, Recipe.validBaseServings)
    }

    func testALegacyRecipeCannotBeScaled() {
        let legacy = Recipe(
            id: "legacy", title: "回锅肉", cookingTime: nil, difficulty: nil,
            tags: [], ingredients: ["五花肉 300 克"], steps: ["炒"]
        )
        XCTAssertNil(legacy.baseServings)
        XCTAssertNil(
            RecipeQuantityScaler.scale(quantity: 300, baseServings: legacy.baseServings, targetServings: 2),
            "unknown yield must surface as unscalable, not as unchanged"
        )
    }

    func testARecipeWithAStatedYieldScales() {
        let recipe = Recipe(
            id: "known", title: "红烧肉", cookingTime: nil, difficulty: nil,
            tags: [], ingredients: ["五花肉 500 克"], steps: ["炖"], baseServings: 4
        )
        XCTAssertEqual(
            RecipeQuantityScaler.scale(quantity: 500, baseServings: recipe.baseServings, targetServings: 2),
            250
        )
    }
}

