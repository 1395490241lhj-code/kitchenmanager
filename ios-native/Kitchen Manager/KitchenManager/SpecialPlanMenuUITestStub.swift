#if DEBUG
import Foundation

// MARK: - UI-test AI stub
//
// A canned menu responder for XCUITest only. It is compiled out of release
// entirely (DEBUG-only file) and, inside DEBUG, only activates when the UI test
// harness passes an explicit UITEST_SPECIAL_PLAN_AI_* launch argument. A
// normal debug run never constructs it, so the real WeeklyMenuPlannerService
// stays on the production path.
//
// This exists because the menu flow's UI states (loading, draft, replace,
// error) are otherwise only reachable through a live network call, which a
// simulator test must not make.
struct SpecialPlanMenuUITestStub: SpecialPlanMenuRequesting {
    /// Launch argument that serves a canned menu.
    static let successArgument = "UITEST_SPECIAL_PLAN_AI_MENU"
    /// Launch argument that always fails, for the error-state test.
    static let failureArgument = "UITEST_SPECIAL_PLAN_AI_FAILURE"

    struct StubFailure: LocalizedError {
        var errorDescription: String? { "暂时无法生成菜单。请稍后重试，或调整人数与备注。" }
    }

    let shouldFail: Bool

    /// Returns a stub only when the UI test harness asked for one.
    static func make(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> SpecialPlanMenuUITestStub? {
        if arguments.contains(failureArgument) {
            return SpecialPlanMenuUITestStub(shouldFail: true)
        }
        if arguments.contains(successArgument) {
            return SpecialPlanMenuUITestStub(shouldFail: false)
        }
        return nil
    }

    func generatePlan(request: AIWeeklyMenuRequest) async throws -> AIWeeklyMenuResponse {
        // A visible, deterministic delay so the loading state is observable by
        // XCUITest, which needs longer than a render frame to query the tree.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if shouldFail { throw StubFailure() }
        return try Self.response(dishCount: request.dishesPerMeal)
    }

    /// Built through the real decoder so the stub cannot drift from the DTO the
    /// production path parses.
    private static func response(dishCount: Int) throws -> AIWeeklyMenuResponse {
        // A single-dish request is a targeted replacement; anything larger is a
        // full menu. Distinct names keep the replacement observable in the UI.
        let names = dishCount <= 1
            ? ["清蒸鲈鱼"]
            : ["红烧牛腩", "蒜蓉虾", "凉拌黄瓜"]
        let recipes: [[String: Any]] = names.map { name in
            [
                "name": name,
                "ingredients": ["主料 200 克", "配菜 1 份"],
                "steps": ["备料。", "烹制。", "装盘。"],
                "tags": ["聚餐"],
                "cookingTime": 30,
                "difficulty": "简单",
                "reason": "适合多人分享",
                "source": "ai",
                // The contracted base yield. A response omitting it is rejected
                // by generation, so the stub must state it like a real one.
                "baseServings": SpecialPlanMenuBounds.aiRecipeBaseServings
            ]
        }
        let payload: [String: Any] = [
            "days": [[
                "dayIndex": 0,
                "meals": [["mealIndex": 0, "title": "晚餐", "recipes": recipes]]
            ]],
            "shoppingItems": [],
            "warnings": []
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(AIWeeklyMenuResponse.self, from: data)
    }
}
#endif
