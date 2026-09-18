import SwiftUI

struct AIConversationView: View {
    let entryContext: AIConversationEntryContext

    @EnvironmentObject private var controller: AIConversationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hasOpenedEntryContext = false
    @State private var showingHistorySheet = false
    @State private var showingContextSheet = false
    @State private var showingRenameAlert = false
    @State private var renameText = ""
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            if let error = controller.localErrorMessage {
                LocalErrorBanner(message: error) {
                    controller.dismissLocalError()
                }
            }

            if controller.messages.isEmpty {
                EmptyWorkspaceView { starter in
                    controller.draftText = starter
                } onOpenHistory: {
                    showingHistorySheet = true
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(controller.messages) { message in
                                MessageRowView(message: message)
                                    .id(message.id)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id("conversationBottomAnchor")
                        }
                        .padding(.horizontal, KitchenTheme.pageGutter)
                        .padding(.vertical, KitchenTheme.modulePadding)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: controller.messages.count) { _, _ in
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: controller.turnState) { _, _ in
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: controller.contentRevision) { _, _ in
                        scrollToBottom(proxy: proxy)
                    }
                }
            }
        }
        .onAppear {
            if !hasOpenedEntryContext {
                controller.open(entryContext: entryContext)
                hasOpenedEntryContext = true
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposerContainerView(
                onTapChips: { showingContextSheet = true },
                onReactivate: {
                    if let id = controller.currentConversation?.id {
                        controller.reactivate(id: id)
                    }
                }
            )
        }
        .background(KitchenTheme.canvas)
        .navigationTitle("Kitchen AI")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        controller.newConversation(entryContext: entryContext)
                    } label: {
                        Label("新建对话", systemImage: "square.and.pencil")
                    }

                    Button {
                        showingHistorySheet = true
                    } label: {
                        Label("历史记录", systemImage: "clock")
                    }

                    Divider()

                    Button {
                        renameText = controller.currentConversation?.title ?? ""
                        showingRenameAlert = true
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    .disabled(!controller.isPersisted)

                    Button {
                        let isPinned = controller.currentConversation?.isPinned ?? false
                        controller.setPinned(!isPinned)
                    } label: {
                        let isPinned = controller.currentConversation?.isPinned ?? false
                        Label(isPinned ? "取消置顶" : "置顶", systemImage: isPinned ? "pin.slash" : "pin")
                    }
                    .disabled(!controller.isPersisted)

                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    .disabled(!controller.isPersisted)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                        .foregroundStyle(KitchenTheme.textPrimary)
                        .frame(minWidth: KitchenTheme.controlHeight, minHeight: KitchenTheme.controlHeight)
                }
                .accessibilityIdentifier("kitchenAI.overflowMenu")
            }
        }
        .sheet(isPresented: $showingHistorySheet) {
            AIConversationHistoryView(hostEntryContext: entryContext)
        }
        .sheet(isPresented: $showingContextSheet) {
            ContextExclusionSheet()
        }
        .alert("重命名对话", isPresented: $showingRenameAlert) {
            TextField("输入新标题", text: $renameText)
                .accessibilityIdentifier("kitchenAI.rename.input")
            Button("取消", role: .cancel) {}
            Button("确定") {
                controller.rename(renameText)
            }
            .accessibilityIdentifier("kitchenAI.rename.confirm")
        }
        .confirmationDialog("确定删除该对话？", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let id = controller.currentConversation?.id {
                    controller.delete(id: id)
                    if controller.currentConversation == nil {
                        controller.newConversation(entryContext: entryContext)
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后将清除当前对话的所有历史记录，已应用的厨房数据不受影响。")
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, id: AnyHashable = "conversationBottomAnchor") {
        if reduceMotion || controller.isGenerating {
            proxy.scrollTo(id, anchor: .bottom)
        } else {
            withAnimation(KitchenMotion.quick) {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }
}

// MARK: - Empty State

struct EmptyWorkspaceView: View {
    @EnvironmentObject private var controller: AIConversationController
    let onSelectStarter: (String) -> Void
    let onOpenHistory: () -> Void

    private var starters: [String] {
        switch controller.activeEntryContext {
        case .home:
            return [
                "用快过期的食材做饭",
                "今晚想吃清淡一点",
                "看看现在能做什么",
                "帮我补一道菜"
            ]
        case .planner:
            return [
                "调整这周菜单",
                "帮我减少重复菜",
                "周六聚餐怎么安排",
                "看看哪天准备最轻松"
            ]
        }
    }

    private var hasOtherActiveConversations: Bool {
        controller.history.contains { !$0.isExpired(now: Date()) && $0.id != controller.currentConversation?.id }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "fork.knife")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(KitchenTheme.cookingGreen)
                        .accessibilityHidden(true)

                    Text(controller.activeEntryContext == .home ? "从现有食材开始" : "一起把菜单理顺")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(KitchenTheme.textPrimary)

                    Text(controller.activeEntryContext == .home ? "结合库存与今晚计划，找一道合适的菜。" : "结合本周安排，逐项调整菜单。")
                        .font(.subheadline)
                        .foregroundStyle(KitchenTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("快速开始")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(KitchenTheme.textSecondary)
                        .padding(.leading, 4)

                    VStack(spacing: 8) {
                        ForEach(starters, id: \.self) { starter in
                            Button {
                                onSelectStarter(starter)
                            } label: {
                                HStack {
                                    Text(starter)
                                        .font(.subheadline)
                                        .foregroundStyle(KitchenTheme.textPrimary)
                                    Spacer()
                                    Image(systemName: "arrow.up.left")
                                        .font(.caption2)
                                        .foregroundStyle(KitchenTheme.textSecondary)
                                        .accessibilityHidden(true)
                                }
                                .padding(.horizontal, 16)
                                .frame(minHeight: KitchenTheme.controlHeight)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("kitchenAI.starter.\(starter)")

                            if starter != starters.last {
                                Divider()
                                    .padding(.leading, 16)
                            }
                        }
                    }
                    .background(KitchenTheme.surface, in: RoundedRectangle(cornerRadius: KitchenTheme.compactRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: KitchenTheme.compactRadius, style: .continuous)
                            .stroke(KitchenTheme.separator.opacity(KitchenTheme.borderOpacity), lineWidth: 1)
                    )
                }
                .padding(.horizontal, KitchenTheme.pageGutter)

                if hasOtherActiveConversations {
                    Button(action: onOpenHistory) {
                        HStack(spacing: 4) {
                            Text("继续其他活跃对话")
                            Image(systemName: "chevron.right")
                        }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(KitchenTheme.cookingGreen)
                        .frame(minHeight: KitchenTheme.controlHeight)
                        .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("kitchenAI.continueOtherConversations")
                    .padding(.top, 8)
                }
            }
            .padding(.vertical, 32)
            .frame(minHeight: 560)
        }
    }
}

// MARK: - Composer & Context Chips

struct ComposerContainerView: View {
    @EnvironmentObject private var controller: AIConversationController
    let onTapChips: () -> Void
    let onReactivate: () -> Void

    var isReactivationRequired: Bool {
        controller.currentConversationRequiresReactivation
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .background(KitchenTheme.separator)

            VStack(spacing: 8) {
                if isReactivationRequired {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("此对话已过期")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(KitchenTheme.textPrimary)
                            Text("聊天记录已归档，点击即可继续使用最新厨房数据对话。")
                                .font(.caption)
                                .foregroundStyle(KitchenTheme.textSecondary)
                        }
                        Spacer()
                        Button("继续此对话", action: onReactivate)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .frame(minHeight: KitchenTheme.controlHeight)
                            .background(KitchenTheme.cookingFill, in: Capsule())
                            .contentShape(Capsule())
                            .accessibilityIdentifier("kitchenAI.reactivate")
                    }
                    .padding(12)
                    .background(KitchenTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: KitchenTheme.compactRadius, style: .continuous))
                    .padding(.horizontal, KitchenTheme.pageGutter)
                    .padding(.top, 8)
                } else {
                    ContextChipsStripView(onTap: onTapChips)
                        .padding(.horizontal, KitchenTheme.pageGutter)
                        .padding(.top, 6)

                    HStack(alignment: .bottom, spacing: 8) {
                        TextField("向 Kitchen AI 提问…", text: $controller.draftText, axis: .vertical)
                            .font(.body)
                            .lineLimit(1...5)
                            .frame(minHeight: KitchenTheme.controlHeight)
                            .padding(.horizontal, 12)
                            .background(KitchenTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(KitchenTheme.separator.opacity(KitchenTheme.borderOpacity), lineWidth: 1)
                            )
                            .accessibilityIdentifier("kitchenAI.composer")
                            .accessibilitySortPriority(2)

                        if controller.isGenerating {
                            Button {
                                controller.stop()
                            } label: {
                                Image(systemName: "stop.circle.fill")
                                    .font(.system(size: 32))
                                    .foregroundStyle(KitchenTheme.statusTerracotta)
                                    .frame(width: KitchenTheme.controlHeight, height: KitchenTheme.controlHeight)
                            }
                            .accessibilityLabel("停止生成")
                            .accessibilityIdentifier("kitchenAI.stop")
                            .accessibilitySortPriority(1)
                        } else {
                            Button {
                                controller.send()
                            } label: {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 32))
                                    .foregroundStyle(canSend ? KitchenTheme.cookingGreen : KitchenTheme.separator)
                                    .frame(width: KitchenTheme.controlHeight, height: KitchenTheme.controlHeight)
                            }
                            .disabled(!canSend)
                            .accessibilityLabel("发送消息")
                            .accessibilityIdentifier("kitchenAI.send")
                            .accessibilitySortPriority(1)
                        }
                    }
                    .padding(.horizontal, KitchenTheme.pageGutter)
                    .padding(.bottom, 8)
                }
            }
            .background(.regularMaterial)
        }
    }

    private var canSend: Bool {
        !controller.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && controller.canAcceptNewMessage
    }
}

struct ContextChipsStripView: View {
    @EnvironmentObject private var controller: AIConversationController
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if controller.isGenerating {
                ForEach(Array(controller.actuallyUsedContextKinds).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { kind in
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.bold))
                        Text(kind.displayName)
                            .font(.caption2.weight(.medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(KitchenTheme.filterSurface, in: Capsule())
                    .foregroundStyle(KitchenTheme.textSecondary)
                }
            } else {
                Button(action: onTap) {
                    HStack(spacing: 6) {
                        ForEach(controller.likelyContextKinds, id: \.self) { kind in
                            let isExcluded = controller.nextTurnExcludedContexts.contains(kind)
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(isExcluded ? KitchenTheme.separator : KitchenTheme.cookingGreen)
                                    .frame(width: 6, height: 6)
                                Text(kind.displayName)
                                    .font(.caption2.weight(.medium))
                                    .strikethrough(isExcluded)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isExcluded ? KitchenTheme.filterSurface : KitchenTheme.cookingGreen.opacity(0.12), in: Capsule())
                            .foregroundStyle(isExcluded ? KitchenTheme.textSecondary : KitchenTheme.cookingGreen)
                        }

                        Image(systemName: "slider.horizontal.3")
                            .font(.caption2)
                            .foregroundStyle(KitchenTheme.textSecondary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: KitchenTheme.controlHeight)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("kitchenAI.contextChips")
                .accessibilityLabel(contextAccessibilityLabel)
                .accessibilitySortPriority(3)
            }
            Spacer()
        }
    }

    private var contextAccessibilityLabel: String {
        let included = controller.likelyContextKinds
            .filter { !controller.nextTurnExcludedContexts.contains($0) }
            .map(\.displayName)
            .joined(separator: "、")
        return included.isEmpty ? "编辑下一条消息上下文，未选择来源" : "编辑下一条消息上下文，已选\(included)"
    }
}

// MARK: - Context Exclusion Sheet

struct ContextExclusionSheet: View {
    @EnvironmentObject private var controller: AIConversationController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(controller.likelyContextKinds, id: \.self) { kind in
                        let isIncluded = !controller.nextTurnExcludedContexts.contains(kind)
                        Toggle(isOn: Binding(
                            get: { isIncluded },
                            set: { newValue in
                                if newValue {
                                    controller.nextTurnExcludedContexts.remove(kind)
                                } else {
                                    controller.nextTurnExcludedContexts.insert(kind)
                                }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.displayName)
                                    .font(.body)
                                    .foregroundStyle(KitchenTheme.textPrimary)
                                Text(description(for: kind))
                                    .font(.caption)
                                    .foregroundStyle(KitchenTheme.textSecondary)
                            }
                        }
                        .accessibilityIdentifier("kitchenAI.contextToggle.\(kind.rawValue)")
                    }
                } footer: {
                    Text("设置仅影响下一条消息，发送后将自动恢复全部实时读取。")
                        .font(.footnote)
                        .foregroundStyle(KitchenTheme.textSecondary)
                }
            }
            .navigationTitle("消息上下文")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                    .font(.body.weight(.medium))
                    .foregroundStyle(KitchenTheme.cookingGreen)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func description(for kind: AIContextKind) -> String {
        switch kind {
        case .inventory: return "当前可用库存与临期食材"
        case .tonightPlan: return "今晚计划安排的菜品"
        case .plannerWeek: return "本周整周用餐计划"
        case .specialPlan: return "当前聚焦的聚餐活动计划"
        case .recipe: return "菜谱库相关内容"
        }
    }
}

// MARK: - Local Error Banner

struct LocalErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(KitchenTheme.statusTerracotta)
            Text(message)
                .font(.footnote)
                .foregroundStyle(KitchenTheme.textPrimary)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(KitchenTheme.textSecondary)
                    .frame(minWidth: KitchenTheme.controlHeight, minHeight: KitchenTheme.controlHeight)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("关闭提示")
            .accessibilityIdentifier("kitchenAI.localError.dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(KitchenTheme.statusTerracotta.opacity(0.12), in: RoundedRectangle(cornerRadius: KitchenTheme.compactRadius, style: .continuous))
        .padding(.horizontal, KitchenTheme.pageGutter)
        .padding(.top, 4)
    }
}
