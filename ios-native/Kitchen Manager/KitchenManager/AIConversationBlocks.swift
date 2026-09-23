import SwiftUI

struct MessageRowView: View {
    let message: AIConversationMessage
    @EnvironmentObject private var controller: AIConversationController

    /// The activity this row may show, or nil. Only a turn state that is really
    /// running may show activity. A row can stay persisted as `.streaming`
    /// while the runtime turn is `.idle` — when stop-time persistence of
    /// `.cancelled` fails, or when launch recovery of interrupted messages
    /// fails — and then there is nothing truthful to show: no phase is
    /// synthesized.
    static func activityPhase(
        for message: AIConversationMessage,
        turnState: AIConversationTurnState
    ) -> KitchenAIActivityPhase? {
        guard message.state == .streaming else { return nil }
        return turnState.aiActivityPhase
    }

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(message.plainTextSummary)
                    .font(.body)
                    .foregroundStyle(KitchenTheme.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(KitchenTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.leading, 32)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(message.contentBlocks) { block in
                    ContentBlockView(block: block)
                }
                if let phase = Self.activityPhase(for: message, turnState: controller.turnState) {
                    KitchenAIStatus(phase: phase, message: phase.statusText, presentation: .conversation)
                        .font(.footnote)
                        .padding(.top, 4)
                }
                if message.state == .cancelled {
                    // Derived from the persisted message state, so it survives
                    // leaving, reopening and relaunch exactly as the partial
                    // text above it does. Neutral by design: the member chose
                    // to stop, nothing failed, so it borrows none of the error
                    // treatment and stays inside this turn rather than
                    // becoming page-level chrome.
                    HStack(spacing: 6) {
                        Image(systemName: "stop.circle")
                            .font(.footnote)
                        Text("已停止")
                            .font(.footnote.weight(.medium))
                    }
                    .foregroundStyle(KitchenTheme.textSecondary)
                    .padding(.top, 4)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("回复已在完成前被停止")
                    .accessibilityIdentifier("kitchenAI.turn.stopped")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 16)
        }
    }
}

struct ContentBlockView: View {
    let block: AIContentBlock

    var body: some View {
        switch block {
        case let .text(textBlock):
            AITextBlockView(block: textBlock)
        case let .recipe(recipeBlock):
            AIRecipeBlockView(block: recipeBlock)
        case let .plannerPreview(previewBlock):
            AIPlannerPreviewBlockView(block: previewBlock)
        case let .contextResult(resultBlock):
            AIContextResultBlockView(block: resultBlock)
        case let .actionStatus(statusBlock):
            AIActionStatusBlockView(block: statusBlock)
        case let .error(errorBlock):
            AIErrorBlockView(block: errorBlock)
        }
    }
}

struct AITextBlockView: View {
    let block: AITextBlock

    var body: some View {
        Text(block.text)
            .font(.body)
            .lineSpacing(5)
            .foregroundStyle(KitchenTheme.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AIRecipeBlockView: View {
    let block: AIRecipeBlock
    @EnvironmentObject private var recipeStore: RecipeStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var displayRecipe: Recipe {
        if !block.isTransient, let live = recipeStore.recipe(id: block.recipe.id) {
            return live
        }
        return block.recipe
    }

    var isLiveRecipe: Bool {
        !block.isTransient && recipeStore.recipe(id: block.recipe.id) != nil
    }

    @ViewBuilder
    private var destinationDetailView: some View {
        if isLiveRecipe {
            RecipeDetailView(recipe: displayRecipe)
        } else {
            AIRecipeSnapshotDetailView(recipe: displayRecipe, reason: block.reason, isTransient: block.isTransient)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let reason = block.reason, !reason.isEmpty {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(KitchenTheme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                // Side by side at ordinary sizes; stacked at accessibility
                // sizes so neither the title nor the metadata is squeezed
                // into a narrow column beside its neighbour.
                let titleLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
                titleLayout {
                    Text(displayRecipe.title)
                        .font(.headline)
                        .foregroundStyle(KitchenTheme.textPrimary)
                    if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                    if block.isTransient {
                        Text("AI 推荐草稿")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(KitchenTheme.filterSurface, in: Capsule())
                            .foregroundStyle(KitchenTheme.textSecondary)
                    }
                }

                let metadataLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                    : AnyLayout(HStackLayout(spacing: 12))
                metadataLayout {
                    // cookingTime is optional: nil means unknown, so the metadata
                    // is omitted rather than rendered as Swift's debug description.
                    if let cookingTime = displayRecipe.cookingTime {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .accessibilityHidden(true)
                            Text("\(cookingTime) 分钟")
                        }
                    }
                    if let difficulty = displayRecipe.difficulty, !difficulty.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "chart.bar")
                                .accessibilityHidden(true)
                            Text(difficulty)
                        }
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "basket")
                            .accessibilityHidden(true)
                        Text("\(displayRecipe.ingredients.count) 种食材")
                    }
                }
                .font(.caption)
                .foregroundStyle(KitchenTheme.textSecondary)

                if !displayRecipe.ingredients.isEmpty {
                    Text(displayRecipe.ingredients.prefix(4).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(KitchenTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(KitchenTheme.modulePadding)
            // The domain card owns the transcript width, so a short draft
            // recipe never collapses to its intrinsic content width.
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(KitchenTheme.surface, in: RoundedRectangle(cornerRadius: KitchenTheme.functionalRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: KitchenTheme.functionalRadius, style: .continuous)
                    .stroke(KitchenTheme.separator.opacity(KitchenTheme.borderOpacity), lineWidth: 1)
            )

            NavigationLink(destination: destinationDetailView) {
                HStack {
                    Text("查看菜谱")
                        .font(.subheadline.weight(.medium))
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                }
                .frame(minHeight: KitchenTheme.controlHeight)
                .foregroundStyle(KitchenTheme.cookingGreen)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("kitchenAI.recipe.view.\(displayRecipe.id)")
        }
    }
}

struct AIPlannerPreviewBlockView: View {
    let block: AIPlannerPreviewBlock
    @EnvironmentObject private var controller: AIConversationController
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var isActionPending: Bool {
        guard let pendingID = block.pendingActionID,
              let prepared = controller.preparedAction else { return false }
        return pendingID == prepared.id
    }

    var body: some View {
        // One quiet functional module: the pending mutation's name and its
        // before → after changes read as rows inside it, never as cards inside
        // a card. Apply stays outside and below as the one filled control.
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.clock")
                        .foregroundStyle(KitchenTheme.cookingGreen)
                        .accessibilityHidden(true)
                    Text(block.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KitchenTheme.textPrimary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(block.changes.enumerated()), id: \.element.id) { index, change in
                        if index > 0 { Divider() }
                        changeRow(change)
                    }
                }
            }
            .padding(KitchenTheme.modulePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The surface fill without the recipe card's outline: visible
            // containment in Light, still quieter than a real domain object.
            .background(KitchenTheme.surface, in: RoundedRectangle(cornerRadius: KitchenTheme.functionalRadius, style: .continuous))

            if isActionPending {
                Button {
                    controller.confirmPreparedAction()
                } label: {
                    HStack {
                        Image(systemName: "checkmark")
                        Text(block.changes.count > 1 ? "应用 \(block.changes.count) 项修改" : "应用修改")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: KitchenTheme.controlHeight)
                    .background(KitchenTheme.cookingFill, in: RoundedRectangle(cornerRadius: KitchenTheme.compactRadius, style: .continuous))
                }
                .accessibilityIdentifier("kitchenAI.planner.apply")
            }
        }
    }

    /// Side by side at ordinary sizes; stacked with a downward arrow at
    /// accessibility sizes, where two columns would squeeze both values.
    @ViewBuilder
    private func changeRow(_ change: AIPlannerChangeRow) -> some View {
        let before = VStack(alignment: .leading, spacing: 2) {
            Text("原有")
                .font(.caption2)
                .foregroundStyle(KitchenTheme.textSecondary)
            Text(change.before)
                .font(.subheadline)
                .foregroundStyle(KitchenTheme.textSecondary)
                .strikethrough(color: KitchenTheme.separator)
        }
        let after = VStack(alignment: .leading, spacing: 2) {
            Text("修改为")
                .font(.caption2)
                .foregroundStyle(KitchenTheme.cookingGreen)
            Text(change.after)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(KitchenTheme.textPrimary)
        }
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                before
                Image(systemName: "arrow.down")
                    .font(.caption)
                    .foregroundStyle(KitchenTheme.cookingGreen)
                    .accessibilityHidden(true)
                after
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .top, spacing: 12) {
                before.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(KitchenTheme.cookingGreen)
                    .padding(.top, 14)
                    .accessibilityHidden(true)
                after.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct AIContextResultBlockView: View {
    let block: AIContextResultBlock
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Provenance supporting the answer: open on the canvas, at footnote
        // weight, so it never competes with a recipe, a pending change or
        // Apply. Values lead their labels.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(KitchenTheme.textSecondary)
                    .accessibilityHidden(true)
                Text(block.title)
                    .foregroundStyle(KitchenTheme.textSecondary)
            }
            .font(.footnote.weight(.semibold))

            VStack(alignment: .leading, spacing: dynamicTypeSize.isAccessibilitySize ? 8 : 4) {
                ForEach(block.rows) { row in
                    // Label → trailing value at ordinary sizes; stacked and
                    // leading-aligned at accessibility sizes, where two
                    // columns would squeeze or truncate the pair.
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.label)
                                .foregroundStyle(KitchenTheme.textSecondary)
                            Text(row.detail)
                                .foregroundStyle(KitchenTheme.textPrimary)
                        }
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.label)
                                .foregroundStyle(KitchenTheme.textSecondary)
                            Spacer(minLength: 12)
                            Text(row.detail)
                                .foregroundStyle(KitchenTheme.textPrimary)
                                .multilineTextAlignment(.trailing)
                        }
                        .font(.footnote)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Context provenance between prose") {
    VStack(alignment: .leading, spacing: 12) {
        AITextBlockView(block: .init(text: "冰箱里的青椒明天到期，今晚可以先用掉。"))
        AIContextResultBlockView(block: .init(title: "快过期", rows: [
            .init(label: "青椒", detail: "明天"),
            .init(label: "鸡蛋", detail: "4 个")
        ]))
        AITextBlockView(block: .init(text: "推荐做一道青椒炒蛋。"))
    }
    .padding(KitchenTheme.pageGutter)
    .background(KitchenTheme.canvas)
}

#Preview("Context provenance — Dark") {
    AIContextResultBlockView(block: .init(title: "快过期", rows: [
        .init(label: "青椒", detail: "明天"),
        .init(label: "鸡蛋", detail: "4 个")
    ]))
    .padding(KitchenTheme.pageGutter)
    .background(KitchenTheme.canvas)
    .preferredColorScheme(.dark)
}

#Preview("Context provenance — AXXXL") {
    AIContextResultBlockView(block: .init(title: "快过期", rows: [
        .init(label: "青椒", detail: "明天"),
        .init(label: "鸡蛋", detail: "4 个")
    ]))
    .padding(KitchenTheme.pageGutter)
    .background(KitchenTheme.canvas)
    .dynamicTypeSize(.accessibility5)
}

struct AIActionStatusBlockView: View {
    let block: AIActionStatusBlock
    @EnvironmentObject private var controller: AIConversationController
    @EnvironmentObject private var navigationStore: AppNavigationStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var presentationNow = Date()

    /// The persisted record behind this block. Destination and undo expiry come
    /// from here, never from the block's cached fields, so a reopened
    /// transcript reads the same truth the domain holds.
    private var record: AIConversationActionRecord? {
        controller.actionRecord(id: block.actionID)
    }

    private var destination: AIActionOutcomePresentation.Destination? {
        guard !block.isFailure, let record else { return nil }
        return AIActionOutcomePresentation.destination(for: record)
    }

    /// Authoritative Undo availability: derived strictly from the current
    /// persisted record and `presentationNow`, never from cached `block.canUndo`.
    private var canUndoNow: Bool {
        guard let record, record.status == .succeeded else { return false }
        return record.canUndo(now: presentationNow)
    }

    private var undoAvailability: String? {
        guard canUndoNow, let record else { return nil }
        return AIActionOutcomePresentation.undoAvailability(for: record, now: presentationNow)
    }

    var body: some View {
        // Outcome → optional destination → undo availability. The outcome line
        // is the subject; the two controls stay secondary and never share its
        // weight. A status, not another card: it sits open on the canvas so a
        // completed change reads quieter than the pending one did.
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: block.isFailure ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(block.isFailure ? KitchenTheme.statusTerracotta : KitchenTheme.cookingGreen)
                    .accessibilityHidden(true)
                Text(block.message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(KitchenTheme.textPrimary)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("kitchenAI.action.outcome")

            if destination != nil || canUndoNow {
                // Side by side at ordinary sizes; stacked at accessibility
                // sizes, where two labels on one line wrap into each other.
                let controls = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                    : AnyLayout(HStackLayout(spacing: 16))
                controls {
                    if let destination {
                        Button {
                            open(destination)
                        } label: {
                            HStack(spacing: 4) {
                                Text(destination.label)
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(KitchenTheme.cookingGreen)
                            .frame(minHeight: KitchenTheme.controlHeight)
                        }
                        .accessibilityIdentifier(destination.accessibilityIdentifier)
                    }

                    if canUndoNow {
                        Button {
                            controller.undo(actionID: block.actionID)
                        } label: {
                            Text("撤销")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(KitchenTheme.textSecondary)
                                .frame(minHeight: KitchenTheme.controlHeight)
                        }
                        .accessibilityLabel(undoAvailability.map { "撤销这次改动，\($0)" } ?? "撤销这次改动")
                        .accessibilityIdentifier("kitchenAI.action.undo")
                    }

                    Spacer(minLength: 0)
                }
            }

            if let undoAvailability {
                Text(undoAvailability)
                    .font(.caption2)
                    .foregroundStyle(KitchenTheme.textSecondary)
                    .accessibilityIdentifier("kitchenAI.action.undoAvailability")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: record?.undoExpiresAt) {
            guard let expiry = record?.undoExpiresAt, canUndoNow else { return }
            let remaining = expiry.timeIntervalSince(Date())
            guard remaining > 0 else {
                presentationNow = Date()
                return
            }
            // Sleep until exactly the boundary to wake and trigger a single UI refresh.
            // Task cancellation must terminate immediately without falling through.
            do {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000) + 50_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            presentationNow = Date()
        }
    }

    /// Every case is an existing `AppNavigationStore` command. Today has no
    /// path of its own: the workspace is pushed on that tab's stack, so
    /// reaching Home means popping this screen and selecting the tab.
    private func open(_ destination: AIActionOutcomePresentation.Destination) {
        switch destination {
        case .today:
            navigationStore.selectedTab = .today
            dismiss()
        case let .plannedMeal(id):
            navigationStore.showPlanner([.plannedMeal(id)])
        case .plannerWeek:
            navigationStore.showPlanner()
        case let .specialPlan(id):
            navigationStore.showPlanner([.specialPlan(id)])
        case .shopping:
            navigationStore.showShopping()
        }
    }
}

/// User-facing wording for what a retry will actually do. Presentation only:
/// every renderable scope still invokes the one existing command,
/// `retryGeneration()`, which re-runs the turn from its stored input. The
/// wording differs because what the member cares about differs — whether the
/// model is asked again, the kitchen is re-read first, or the request is
/// re-prepared.
///
/// `.action` returns `nil` rather than a generic title. There is no scoped
/// action retry today and the error block must never offer one, so the type
/// itself refuses to describe that button: a caller cannot render an action
/// retry by accident because there is nothing to render.
nonisolated struct AIRetryScopePresentation: Equatable {
    let title: String
    let accessibilityLabel: String

    static func retry(for scope: AIRetryScope) -> AIRetryScopePresentation? {
        switch scope {
        case .generation:
            return .init(title: "重新生成回复", accessibilityLabel: "重新生成这条回复")
        case .contextRead:
            return .init(title: "重新读取厨房数据", accessibilityLabel: "重新读取当前厨房数据后再回复")
        case .interpretation:
            return .init(title: "重新处理请求", accessibilityLabel: "重新处理这条请求")
        case .action:
            return nil
        }
    }
}

struct AIErrorBlockView: View {
    let block: AIErrorBlock
    @EnvironmentObject private var controller: AIConversationController

    /// A button exists only when the controller can retry generation right now
    /// and the scope has a retry presentation at all. `.action` yields no
    /// presentation, so it stays structurally unable to render one.
    private var retryPresentation: AIRetryScopePresentation? {
        guard controller.canRetryGeneration, let scope = block.retry else { return nil }
        return AIRetryScopePresentation.retry(for: scope)
    }

    var body: some View {
        // An exceptional state carried by its terracotta symbol and plain
        // sentence rather than by an outlined card; retry stays a text action.
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(KitchenTheme.statusTerracotta)
                    .accessibilityHidden(true)
                Text(block.message)
                    .font(.subheadline)
                    .foregroundStyle(KitchenTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let retry = retryPresentation {
                Button {
                    controller.retryGeneration()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text(retry.title)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(KitchenTheme.cookingGreen)
                    .frame(minHeight: KitchenTheme.controlHeight)
                }
                .accessibilityLabel(retry.accessibilityLabel)
                .accessibilityIdentifier("kitchenAI.error.retry")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
