import SwiftUI

struct AIConversationHistoryView: View {
    let hostEntryContext: AIConversationEntryContext

    @EnvironmentObject private var controller: AIConversationController
    @Environment(\.dismiss) private var dismiss

    @State private var conversationToRename: AIConversation?
    @State private var newTitleText = ""
    @State private var showingRenameAlert = false
    @State private var conversationToDelete: AIConversation?
    @State private var showingDeleteConfirmation = false
    /// Presentation clock. Refreshed once at each upcoming continuity boundary
    /// so a sheet left open never keeps a row under 最近 after it archived.
    @State private var presentationNow = Date()

    private var pinnedConversations: [AIConversation] {
        controller.history.filter { $0.isPinned }
    }

    private var recentConversations: [AIConversation] {
        controller.history.filter { !$0.isPinned && !$0.isExpired(now: presentationNow) }
    }

    private var archivedConversations: [AIConversation] {
        controller.history.filter { !$0.isPinned && $0.isExpired(now: presentationNow) }
    }

    /// The next moment any loaded row would change group.
    private var nextBoundary: Date? {
        recentConversations.map(\.activeUntil).min()
    }

    var body: some View {
        NavigationStack {
            List {
                if !pinnedConversations.isEmpty {
                    Section {
                        ForEach(pinnedConversations) { conv in
                            ConversationHistoryRow(conversation: conv, now: presentationNow) {
                                select(conv)
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    controller.setPinned(id: conv.id, isPinned: false)
                                } label: {
                                    Label("取消置顶", systemImage: "pin.slash")
                                }
                                .tint(KitchenTheme.textSecondary)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    conversationToDelete = conv
                                    showingDeleteConfirmation = true
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                Button {
                                    conversationToRename = conv
                                    newTitleText = conv.title
                                    showingRenameAlert = true
                                } label: {
                                    Label("重命名", systemImage: "pencil")
                                }
                                .tint(KitchenTheme.cookingGreen)
                            }
                        }
                    } header: {
                        Text("置顶")
                            .accessibilityIdentifier("kitchenAI.history.section.pinned")
                    }
                }

                if !recentConversations.isEmpty {
                    Section {
                        ForEach(recentConversations) { conv in
                            ConversationHistoryRow(conversation: conv, now: presentationNow) {
                                select(conv)
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    controller.setPinned(id: conv.id, isPinned: true)
                                } label: {
                                    Label("置顶", systemImage: "pin")
                                }
                                .tint(KitchenTheme.cookingGreen)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    conversationToDelete = conv
                                    showingDeleteConfirmation = true
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                Button {
                                    conversationToRename = conv
                                    newTitleText = conv.title
                                    showingRenameAlert = true
                                } label: {
                                    Label("重命名", systemImage: "pencil")
                                }
                                .tint(KitchenTheme.cookingGreen)
                            }
                        }
                    } header: {
                        Text("最近")
                            .accessibilityIdentifier("kitchenAI.history.section.recent")
                    }
                }

                if !archivedConversations.isEmpty {
                    Section {
                        ForEach(archivedConversations) { conv in
                            ConversationHistoryRow(conversation: conv, now: presentationNow) {
                                select(conv)
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    controller.setPinned(id: conv.id, isPinned: true)
                                } label: {
                                    Label("置顶", systemImage: "pin")
                                }
                                .tint(KitchenTheme.cookingGreen)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    conversationToDelete = conv
                                    showingDeleteConfirmation = true
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                Button {
                                    conversationToRename = conv
                                    newTitleText = conv.title
                                    showingRenameAlert = true
                                } label: {
                                    Label("重命名", systemImage: "pencil")
                                }
                                .tint(KitchenTheme.cookingGreen)
                            }
                        }
                    } header: {
                        Text(AIConversationLifetimePresentation.archived)
                            .accessibilityIdentifier("kitchenAI.history.section.archived")
                    }
                }
            }
            .navigationTitle("历史记录")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: nextBoundary) {
                guard let nextBoundary else { return }
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(nextBoundary.timeIntervalSince(Date()), 0) * 1_000_000_000) + 50_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                // Recomputes the groups; nextBoundary moves on and the task
                // reschedules itself to the following row, if any.
                presentationNow = Date()
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                    .font(.body.weight(.medium))
                    .foregroundStyle(KitchenTheme.cookingGreen)
                }
            }
            .alert("重命名对话", isPresented: $showingRenameAlert) {
                TextField("输入新标题", text: $newTitleText)
                    .accessibilityIdentifier("kitchenAI.rename.input")
                Button("取消", role: .cancel) {}
                Button("确定") {
                    if let conv = conversationToRename {
                        controller.rename(id: conv.id, newTitle: newTitleText)
                    }
                }
                .accessibilityIdentifier("kitchenAI.rename.confirm")
            }
            .confirmationDialog("确定删除该对话？", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let conv = conversationToDelete {
                        let wasCurrent = controller.currentConversation?.id == conv.id
                        controller.delete(id: conv.id)
                        if wasCurrent && controller.currentConversation == nil {
                            controller.newConversation(entryContext: hostEntryContext)
                        }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("删除后该对话的聊天记录将被清除，但已应用的厨房数据不受影响。")
            }
        }
    }

    private func select(_ conversation: AIConversation) {
        controller.openConversation(id: conversation.id)
        dismiss()
    }
}

struct ConversationHistoryRow: View {
    let conversation: AIConversation
    let now: Date
    let onSelect: () -> Void
    @EnvironmentObject private var controller: AIConversationController
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var excerpt: String {
        if !conversation.summary.isEmpty {
            return conversation.summary
        }
        if let last = controller.lastMessageExcerpt(for: conversation.id) {
            return last
        }
        return "暂无消息"
    }

    private var isArchived: Bool {
        conversation.isExpired(now: now)
    }

    /// The app's user-facing dates are Simplified Chinese throughout; leaving
    /// this formatter on the device locale printed 11/14/23 inside an otherwise
    /// Chinese screen.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private var identity: AIConversationTaskIdentity {
        AIConversationTaskIdentity(conversation: conversation, isPersisted: true)
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                // Title and status share a line at ordinary sizes; at
                // accessibility sizes the status chip drops below, because
                // three competing items squeezed the title down to about one
                // character per line. The pin stays with the title so the row
                // still reads as one pinned task.
                let topLine = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                    : AnyLayout(HStackLayout())
                topLine {
                    HStack(spacing: 6) {
                        Text(conversation.title)
                            .font(.headline)
                            .foregroundStyle(KitchenTheme.textPrimary)
                        // Ordinary sizes keep the pin pushed to the trailing
                        // edge exactly as before; accessibility sizes tuck it
                        // beside the title, which now owns the full width.
                        if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                        if conversation.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(KitchenTheme.cookingGreen)
                        }
                    }
                    Text(AIConversationLifetimePresentation.status(for: conversation, now: now))
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isArchived ? KitchenTheme.filterSurface : KitchenTheme.cookingGreen.opacity(0.12), in: Capsule())
                        .foregroundStyle(isArchived ? KitchenTheme.textSecondary : KitchenTheme.cookingGreen)
                }

                Text(excerpt)
                    .font(.subheadline)
                    .foregroundStyle(KitchenTheme.textSecondary)
                    .lineLimit(2)

                // Which kitchen task this was, above when it last moved. A row
                // that only carried title, excerpt and a timestamp read as a
                // generic chat session rather than a task.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: identity.symbolName)
                        .font(.caption2)
                        .accessibilityHidden(true)
                    (Text(identity.contextLine)
                        .font(.caption.weight(.medium))
                    // NBSP keeps the separator attached to the surrounding metadata.
                    + Text("\u{00A0}·\u{00A0}")
                        .font(.caption2)
                    + Text(Self.dateFormatter.string(from: conversation.lastActivityAt))
                        .font(.caption2))
                    .accessibilityLabel("\(identity.contextLine)，\(Self.dateFormatter.string(from: conversation.lastActivityAt))")
                }
                .foregroundStyle(KitchenTheme.textSecondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                .padding(.top, 2)
            }
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("kitchenAI.history.row.\(conversation.id)")
    }
}
