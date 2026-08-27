import Foundation

// MARK: - Home's one primary task (Home V2)
//
// Home V2 fixes the page at three layers: Today Context → one primary task →
// what else needs handling. This file owns the middle one, and nothing else.
//
// Presentation only, and a pure function. It reads facts the stores already
// publish and returns what the primary region should say. There is no Home
// "mode" store, nothing is persisted, and no business rule is decided here:
// which surface a day type maps to still belongs to `HomeRecommendationSlot`,
// and this type is built on top of that answer rather than replacing it.

/// What the primary region is showing. One case per genuinely different task —
/// not one case per view.
enum HomePrimaryTaskKind: Equatable {
    /// Tonight is already settled outside the household. There is no task.
    case eatOut
    /// A Today Plan exists and is the thing to do. Execution mode.
    case planExecution
    /// Nothing is decided yet, so Home proposes a recipe. Decision mode.
    case recipeRecommendation
    /// A quick day: Home proposes an assembly from what is already in.
    case quickMeal
    /// A prep day: Home shows what was put by and offers to record more.
    case mealPrepBoard
}

/// Everything the primary region needs, decided in one testable place.
struct HomePrimaryTask: Equatable {
    let kind: HomePrimaryTaskKind
    /// The heading. This — not the navigation title — is where Home's state is
    /// visible, which is why the navigation title can stay a stable 今天.
    let title: String
    /// The qualifier beside the heading: 还没决定 / 已完成 1/2 / 已安排外食.
    let detail: String?
    /// Plans that exist but are *not* the primary task. Home must still let the
    /// user reach them, and must not offer a prominent 开始准备 alongside a
    /// contradicting primary task — 今晚外食 and 开始准备番茄炒蛋 cannot both be
    /// the page's headline claim.
    let secondaryPlanCount: Int

    /// Decision mode: the full recommendation card is the primary content.
    var isDecisionMode: Bool { kind == .recipeRecommendation }

    /// Execution mode keeps recommendation reachable, but only as a light link.
    /// The capability is never removed — only its weight.
    var showsRecommendationLink: Bool { kind == .planExecution }
}

extension HomePrimaryTask {
    /// What 需要处理 should actually draw, given what the primary region is
    /// already showing.
    ///
    /// On a 备餐日 the board lists every batch with its own 建议…吃完 line, so a
    /// prepared row underneath would be the same fact twice on one screen —
    /// precisely what replacing the chips was meant to end. Every other day the
    /// board is not on screen, so those rows are the only place a batch going
    /// off is visible at all.
    ///
    /// The cap lives here too, so there is exactly one implementation of "show
    /// this many, then say how many are left".
    func needsAttention(
        from items: [HomeAttentionItem]
    ) -> (visible: [HomeAttentionItem], additional: Int) {
        let relevant = kind == .mealPrepBoard
            ? items.filter { $0.kind != .preparedExpiring }
            : items
        let visible = Array(relevant.prefix(HomeDashboardSummary.maximumVisibleAttentionItems))
        return (visible, max(0, relevant.count - visible.count))
    }

    /// Precedence, highest first. Each rule exists for a reason, and the order
    /// between them is the product decision:
    ///
    /// 1. **Dinner eaten out** beats every proposal and beats plan execution.
    ///    Proposing a meal for an evening the user has already settled is the
    ///    one thing Home must not do. It deliberately does *not* beat a prep
    ///    day: `DayType`'s axis is how much cooking happens (D-018), and a prep
    ///    day is a production day — eating out tonight does not undo the batches
    ///    made this afternoon, and 记一笔今天做的 contradicts nothing.
    /// 2. **A prep day** is about production, not about tonight's dinner.
    /// 3. **An existing Today Plan** beats any suggestion, on any day type. The
    ///    user already decided; a decision outranks a proposal. This is what
    ///    makes the decision → execution switch real rather than cosmetic, and
    ///    it is why a quick day with a plan shows the plan.
    /// 4. **A quick day** proposes an assembly.
    /// 5. Otherwise Home proposes a recipe.
    static func resolve(
        dayType: DayType,
        dinnerIntent: MealIntent,
        planState: HomeTodayPlanState,
        totalPlanCount: Int,
        completedPlanCount: Int
    ) -> HomePrimaryTask {
        let pendingPlanCount = max(0, totalPlanCount - completedPlanCount)

        if dayType == .mealPrep {
            return HomePrimaryTask(
                kind: .mealPrepBoard,
                title: "今天备的菜",
                detail: "先吃快到期的",
                secondaryPlanCount: pendingPlanCount
            )
        }

        if dinnerIntent == .eatOut {
            return HomePrimaryTask(
                kind: .eatOut,
                title: "今晚",
                detail: "已安排外食",
                secondaryPlanCount: pendingPlanCount
            )
        }

        if planState != .empty {
            return HomePrimaryTask(
                kind: .planExecution,
                title: "今天做这些",
                detail: "已完成 \(completedPlanCount)/\(totalPlanCount)",
                secondaryPlanCount: 0
            )
        }

        if dayType == .quick {
            return HomePrimaryTask(
                kind: .quickMeal,
                title: "今天怎么吃",
                detail: nil,
                secondaryPlanCount: 0
            )
        }

        // 做饭日 names the decision that is missing; 自由日 has no fixed plan to
        // be missing, so it asks the softer question instead of implying the
        // user is behind on something.
        return HomePrimaryTask(
            kind: .recipeRecommendation,
            title: dayType == .cooking ? "今天做什么" : "今天怎么吃",
            detail: dayType == .cooking ? "还没决定" : nil,
            secondaryPlanCount: 0
        )
    }
}
