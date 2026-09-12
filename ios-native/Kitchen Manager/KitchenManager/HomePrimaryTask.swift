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
/// `nonisolated` because it is a payload-free presentation enum with no state
/// of any kind. Under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` an unannotated
/// declaration is implicitly `@MainActor`, which made its *synthesized*
/// `Equatable` conformance an isolated conformance — unusable from a nonisolated
/// `XCTAssertEqual`, and an error in the Swift 6 language mode. Enums carrying a
/// raw value (see `HomeAttentionItem.Kind`) avoid this because their `==` comes
/// from the stdlib's nonisolated `RawRepresentable` conformance instead.
nonisolated enum HomePrimaryTaskKind: Equatable {
    /// Tonight is already settled outside the household. There is no task.
    case eatOut
    /// A Special Plan (聚餐) is scheduled for today. Home names it and hands
    /// its navigation to Planner (D-042); it owns no detail surface itself.
    case specialPlanToday
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
    /// The concrete event the primary task names, when one exists. Home uses
    /// it only to route 查看聚餐 through Planner navigation (D-042); it owns no
    /// detail surface itself.
    let specialPlanID: UUID?
    /// Plans that exist but are *not* the primary task, still pending. Home
    /// must not offer a prominent 开始准备 alongside a contradicting primary
    /// task — 今晚外食 and 开始准备番茄炒蛋 cannot both be the page's headline
    /// claim. Since D-042 this is a fact stated in Today Context, never a
    /// second planning route; see `otherPlansLine`.
    let secondaryPlanCount: Int
    /// Every ordinary plan today, used only to word `otherPlansLine`.
    let totalPlanCount: Int
    /// Today event facts for the context lines, decided once in `resolve`
    /// alongside everything else. Private so the memberwise shape the tests
    /// and call sites already use stays unchanged.
    private let event: SpecialPlan?
    private let eventTime: String?

    /// Decision mode: the full recommendation card is the primary content.
    var isDecisionMode: Bool { kind == .recipeRecommendation }

    /// Execution mode keeps recommendation reachable, but only as a light link.
    /// The capability is never removed — only its weight.
    var showsRecommendationLink: Bool { kind == .planExecution }

    /// D-042 / FR-011: when another task owns the primary position, the
    /// ordinary plans are reported as non-interactive context. Nil when none
    /// exist or when the plans *are* the primary task. Never the misleading
    /// 今日计划已全部完成 — a Special Plan may still be pending.
    var otherPlansLine: String? {
        guard kind == .mealPrepBoard || kind == .eatOut || kind == .specialPlanToday,
              totalPlanCount > 0 else { return nil }
        return secondaryPlanCount > 0
            ? "今天另有 \(totalPlanCount) 道计划"
            : "今天另有 \(totalPlanCount) 道计划 · 已完成"
    }

    /// D-042 / FR-011: the mirrored fact for the inverse day — a prep or
    /// eat-out task owns the primary position and today Special Plan is
    /// reduced to one non-interactive line. Built here so Home only renders
    /// a ready-made string, the way `otherPlansLine` already works.
    var specialPlanLine: String? {
        guard kind == .mealPrepBoard || kind == .eatOut,
              let event, let eventTime else { return nil }
        // Same owner copy ruling as the primary detail: completion is a
        // suffix on the factual context, never a replacement.
        let completed = !event.dishes.isEmpty && event.dishes.allSatisfy(\.isCooked)
        return "今天有聚餐 · \(eventTime) \(event.title)\(completed ? " · 已完成" : "")"
    }
}

extension HomePrimaryTask {
    /// A compact clock time for the Special Plan day: HH:mm. Calendar and
    /// time zone come from the supplied calendar on purpose — the same
    /// convention `PlannerProjection` and `SpecialPlanDetailView` already
    /// render with, and no new contract beyond it.
    private static func eventTimeText(
        _ date: Date,
        calendar: Calendar
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

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
    ///
    /// D-042 inserts one rule between the third and the fourth: a Special
    /// Plan scheduled for today — a concrete event the household is hosting
    /// today — outranks the ordinary plan it displaces for the day, the
    /// quick-day assembly, and a plain recommendation. It sits under both
    /// prep and eat-out because those two already answer the page question
    /// and reduce the event to a context fact. Same-day eligibility is a
    /// civil-day comparison on the supplied calendar; no meal slot is ever
    /// inferred from the clock time.
    static func resolve(
        dayType: DayType,
        dinnerIntent: MealIntent,
        planState: HomeTodayPlanState,
        totalPlanCount: Int,
        completedPlanCount: Int,
        specialPlans: [SpecialPlan] = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> HomePrimaryTask {
        let pendingPlanCount = max(0, totalPlanCount - completedPlanCount)
        // Today events only — civil-day comparison on the supplied calendar,
        // then earliest wins; equal timestamps fall back to model order, the
        // same stable order the store published array carries.
        let todayPlans = specialPlans
            .filter { calendar.isDate($0.scheduledAt, inSameDayAs: now) }
            .enumerated()
            .sorted { ($0.element.scheduledAt, $0.offset) < ($1.element.scheduledAt, $1.offset) }
            .map(\.element)

        let event = todayPlans.first
        let eventTime = event.map { Self.eventTimeText($0.scheduledAt, calendar: calendar) }

        if dayType == .mealPrep {
            return HomePrimaryTask(
                kind: .mealPrepBoard,
                title: "今天备的菜",
                detail: "先吃快到期的",
                specialPlanID: nil,
                secondaryPlanCount: pendingPlanCount,
                totalPlanCount: totalPlanCount,
                event: event,
                eventTime: eventTime
            )
        }

        if dinnerIntent == .eatOut {
            return HomePrimaryTask(
                kind: .eatOut,
                title: "今晚",
                detail: "已安排外食",
                specialPlanID: nil,
                secondaryPlanCount: pendingPlanCount,
                totalPlanCount: totalPlanCount,
                event: event,
                eventTime: eventTime
            )
        }

        if let event {
            let eventDetail: String
            // Owner copy ruling: the scheduled time already communicates
            // pending (no 待开始); later same-day events stay on Planner,
            // not in Home copy; completion is a suffix, not a replacement.
            let isCompleted = !event.dishes.isEmpty && event.dishes.allSatisfy(\.isCooked)
            var parts: [String] = []
            if let eventTime { parts.append(eventTime) }
            parts.append("\(event.peopleCount) 人")
            if isCompleted { parts.append("已完成") }
            eventDetail = parts.joined(separator: " · ")
            return HomePrimaryTask(
                kind: .specialPlanToday,
                title: event.title,
                detail: eventDetail,
                specialPlanID: event.id,
                secondaryPlanCount: pendingPlanCount,
                totalPlanCount: totalPlanCount,
                event: event,
                eventTime: eventTime
            )
        }

        if planState != .empty {
            return HomePrimaryTask(
                kind: .planExecution,
                title: "今天做这些",
                detail: "已完成 \(completedPlanCount)/\(totalPlanCount)",
                specialPlanID: nil,
                secondaryPlanCount: 0,
                totalPlanCount: totalPlanCount,
                event: nil,
                eventTime: nil
            )
        }

        if dayType == .quick {
            return HomePrimaryTask(
                kind: .quickMeal,
                title: "今天怎么吃",
                detail: nil,
                specialPlanID: nil,
                secondaryPlanCount: 0,
                totalPlanCount: 0,
                event: nil,
                eventTime: nil
            )
        }

        // 做饭日 names the decision that is missing; 自由日 has no fixed plan to
        // be missing, so it asks the softer question instead of implying the
        // user is behind on something.
        return HomePrimaryTask(
            kind: .recipeRecommendation,
            title: dayType == .cooking ? "今天做什么" : "今天怎么吃",
            detail: dayType == .cooking ? "还没决定" : nil,
            specialPlanID: nil,
            secondaryPlanCount: 0,
            totalPlanCount: 0,
            event: nil,
            eventTime: nil
        )
    }
}
