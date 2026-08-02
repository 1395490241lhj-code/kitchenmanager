import Foundation

/// UI-5B2B-B2A: pure, SwiftUI-free presentation mapping for the merge preview
/// summary, the read-only resolved-results grouping, and the confirmation copy.
///
/// Everything here reads `InventoryMergePlan`/`InventoryMergeCandidate` and
/// returns value types. Nothing mutates a plan, candidate, or session, and
/// nothing touches a controller, persistence, the signed-in auth state, the
/// network, or a mutation path. The model's own computed properties are deliberately left
/// alone — the counts this phase corrects are derived here instead, so
/// `readyToUpload`/`confirmMerge` semantics stay byte-identical.

// MARK: - Candidate predicates

/// The predicates the summary and grouping are defined in terms of, kept in one
/// place so the preview, the review screen, and the tests cannot drift apart.
///
/// `needsDecision` (`conflictReason != nil && userChoice == nil`) comes from the
/// model and is reused verbatim.
nonisolated enum InventoryMergeCandidatePredicate {
    static func willCreate(_ c: InventoryMergeCandidate) -> Bool {
        c.action == .create && !c.needsDecision
    }
    static func willUpdate(_ c: InventoryMergeCandidate) -> Bool {
        c.action == .update && !c.needsDecision
    }
    static func keptRemote(_ c: InventoryMergeCandidate) -> Bool {
        c.conflictReason != nil && c.userChoice == .keepRemote
    }
    static func skippedThisTime(_ c: InventoryMergeCandidate) -> Bool {
        c.conflictReason != nil && c.userChoice == .skip
    }
    static func stillNeedsDecision(_ c: InventoryMergeCandidate) -> Bool {
        c.needsDecision
    }
    /// Nothing to do: an exact match, never a user-chosen skip. A deferred
    /// conflict also carries `action == .skip`, so the `conflictReason == nil`
    /// half is what keeps 本次跳过 out of 无需处理.
    static func nothingToDo(_ c: InventoryMergeCandidate) -> Bool {
        c.action == .skip && c.conflictReason == nil
    }
    /// What `confirmMerge` would actually upload. Mirrors `readyToUpload`'s
    /// create/update members without redefining or altering it — the plan's own
    /// property remains the single source of truth for the upload itself.
    static func uploadable(_ c: InventoryMergeCandidate) -> Bool {
        (c.action == .create || c.action == .update) && !c.needsDecision
    }
    /// A conflict the user has already decided, in any of the four ways.
    static func resolvedConflict(_ c: InventoryMergeCandidate) -> Bool {
        c.conflictReason != nil && c.userChoice != nil
    }
}

// MARK: - Summary

nonisolated struct InventoryMergeSummaryPresentation: Equatable {
    let willCreate: Int
    let willUpdate: Int
    let keptRemote: Int
    let skippedThisTime: Int
    let stillNeedsDecision: Int
    let nothingToDo: Int

    /// How many entries a confirm would actually upload right now.
    var uploadableCount: Int { willCreate + willUpdate }
    /// Recorded decisions, including 本次跳过 — see `resolvedSummaryText`, which
    /// states that inclusion rather than leaving the number to be misread.
    var resolvedCount: Int { keptRemote + skippedThisTime + resolvedUploadableCount }
    /// Resolved conflicts that will upload (keepLocal, or keepBoth's fork).
    let resolvedUploadableCount: Int

    static func make(plan: InventoryMergePlan) -> InventoryMergeSummaryPresentation {
        let c = plan.candidates
        return InventoryMergeSummaryPresentation(
            willCreate: c.filter(InventoryMergeCandidatePredicate.willCreate).count,
            willUpdate: c.filter(InventoryMergeCandidatePredicate.willUpdate).count,
            keptRemote: c.filter(InventoryMergeCandidatePredicate.keptRemote).count,
            skippedThisTime: c.filter(InventoryMergeCandidatePredicate.skippedThisTime).count,
            stillNeedsDecision: c.filter(InventoryMergeCandidatePredicate.stillNeedsDecision).count,
            nothingToDo: c.filter(InventoryMergeCandidatePredicate.nothingToDo).count,
            resolvedUploadableCount: c.filter {
                InventoryMergeCandidatePredicate.resolvedConflict($0)
                    && InventoryMergeCandidatePredicate.uploadable($0)
            }.count
        )
    }

    /// Entry-row subtitle for the read-only review screen. States only how many
    /// choices are recorded — never whether they have been uploaded, which
    /// depends on the session's own history rather than on the plan.
    var resolvedSummaryText: String {
        skippedThisTime > 0
            ? "已处理 \(resolvedCount) 条，其中 \(skippedThisTime) 条本次跳过"
            : "已处理 \(resolvedCount) 条"
    }
}

// MARK: - Conflict reason breakdown

/// Outstanding conflicts only. The shipped preview counted every candidate with
/// a matching `conflictReason` regardless of `userChoice`, so a partly-resolved
/// plan reported more work under 需要处理的冲突 than actually remained.
nonisolated struct InventoryMergeConflictReasonPresentation: Equatable {
    let reason: InventoryMergeConflictReason
    let title: String
    let count: Int

    static let orderedReasons: [InventoryMergeConflictReason] = [
        .quantityMismatch, .expiryMismatch, .metadataMismatch,
        .ambiguousDuplicate, .multipleRemoteCandidates
    ]

    static func title(for reason: InventoryMergeConflictReason) -> String {
        switch reason {
        case .quantityMismatch: "数量不同"
        case .expiryMismatch: "保质期不同"
        case .metadataMismatch: "常备食材设置不同"
        case .ambiguousDuplicate: "可能重复"
        case .multipleRemoteCandidates: "无法确定"
        }
    }

    /// Only unresolved candidates, and only non-empty rows.
    static func make(plan: InventoryMergePlan) -> [InventoryMergeConflictReasonPresentation] {
        orderedReasons.compactMap { reason in
            let count = plan.candidates.filter {
                $0.conflictReason == reason && $0.needsDecision
            }.count
            guard count > 0 else { return nil }
            return InventoryMergeConflictReasonPresentation(
                reason: reason, title: title(for: reason), count: count
            )
        }
    }
}

// MARK: - Resolved groups

nonisolated enum InventoryMergeCandidateGroup: String, CaseIterable, Equatable {
    case keptLocal
    case keptRemote
    case keptBoth
    case skipped

    /// Display order, fixed so the review screen never reorders between reads.
    static let orderedGroups: [InventoryMergeCandidateGroup] = [.keptLocal, .keptRemote, .keptBoth, .skipped]

    var title: String {
        switch self {
        case .keptLocal: "已选择保留本机"
        case .keptRemote: "已选择保留家庭"
        case .keptBoth: "已选择两条都保留"
        case .skipped: "本次跳过"
        }
    }

    /// The choice this group is defined by — a single optional value per
    /// candidate, which is what makes the partition non-overlapping.
    var choice: InventoryMergeConflictChoice {
        switch self {
        case .keptLocal: .keepLocal
        case .keptRemote: .keepRemote
        case .keptBoth: .keepBoth
        case .skipped: .skip
        }
    }

    /// The group a candidate belongs to, or `nil` when it is not a resolved
    /// conflict (unresolved, or never a conflict at all).
    static func group(for candidate: InventoryMergeCandidate) -> InventoryMergeCandidateGroup? {
        guard candidate.conflictReason != nil, let choice = candidate.userChoice else { return nil }
        return orderedGroups.first { $0.choice == choice }
    }
}

/// One resolved candidate as the review screen shows it — read-only: a name, the
/// choice that was recorded, what that choice will do, and the two values that
/// differed. No action, no edit entry.
nonisolated struct InventoryMergeResolvedCandidatePresentation: Equatable, Identifiable {
    let id: UUID
    let name: String
    let choiceTitle: String
    let consequence: String
    let localValue: String
    let remoteValue: String
    let reasonText: String

    /// Reuses the B1 consequence copy verbatim, so the review screen can never
    /// describe an outcome differently from the screen the choice was made on.
    static func make(candidate: InventoryMergeCandidate) -> InventoryMergeResolvedCandidatePresentation? {
        guard let choice = candidate.userChoice, let reason = candidate.conflictReason else { return nil }
        let choicePresentation = InventoryMergeConflictChoicePresentation.make(
            choice: choice,
            isSameRemoteRecord: candidate.remoteItemId == candidate.localItemId
        )
        return InventoryMergeResolvedCandidatePresentation(
            id: candidate.localItemId,
            name: candidate.name,
            choiceTitle: choicePresentation.title,
            consequence: choicePresentation.consequence,
            localValue: valueText(quantity: candidate.localQuantity, expiry: candidate.localExpiryDate, unit: candidate.unit),
            remoteValue: candidate.remoteQuantity.map {
                valueText(quantity: $0, expiry: candidate.remoteExpiryDate, unit: candidate.unit)
            } ?? "—",
            reasonText: reasonText(reason)
        )
    }

    static func valueText(quantity: Double, expiry: Date?, unit: String) -> String {
        var parts = [quantityText(quantity, unit)]
        if let expiry { parts.append(expiryText(expiry)) }
        return parts.joined(separator: " · ")
    }

    static func quantityText(_ quantity: Double, _ unit: String) -> String {
        let formatted = quantity.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", quantity)
            : String(format: "%.2f", quantity)
        return "\(formatted)\(unit)"
    }

    static func expiryText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return "到期 \(formatter.string(from: date))"
    }

    static func reasonText(_ reason: InventoryMergeConflictReason) -> String {
        switch reason {
        case .quantityMismatch: "本机与家庭的数量不同。"
        case .expiryMismatch: "本机与家庭的保质期不同。"
        case .metadataMismatch: "本机与家庭的常备食材设置（分类/阈值/补货量）不同。"
        case .ambiguousDuplicate: "家庭库存中有一条名称和单位相同的记录，无法确定是否为同一条。"
        case .multipleRemoteCandidates: "家庭库存中有多条名称和单位相同的记录，无法自动选择。"
        }
    }
}

nonisolated struct InventoryMergeCandidateGroupPresentation: Equatable, Identifiable {
    let group: InventoryMergeCandidateGroup
    let candidates: [InventoryMergeResolvedCandidatePresentation]

    var id: String { group.rawValue }
    var title: String { group.title }
    var count: Int { candidates.count }

    /// Non-empty groups only, in `orderedGroups` order, each preserving
    /// `plan.candidates` order (`filter` is order-preserving).
    static func make(plan: InventoryMergePlan) -> [InventoryMergeCandidateGroupPresentation] {
        InventoryMergeCandidateGroup.orderedGroups.compactMap { group in
            let members = plan.candidates
                .filter { InventoryMergeCandidateGroup.group(for: $0) == group }
                .compactMap(InventoryMergeResolvedCandidatePresentation.make)
            guard !members.isEmpty else { return nil }
            return InventoryMergeCandidateGroupPresentation(group: group, candidates: members)
        }
    }
}

// MARK: - Review footer

/// Footer copy for the read-only resolved review.
///
/// The plan alone cannot say whether a recorded choice has been uploaded. A
/// session that partially confirmed — uploading `readyToUpload`, parking in
/// `.conflict` with leftover conflicts, then returning to `.previewReady` once
/// the last one was resolved — carries a plan mixing already-uploaded choices
/// with newly-decided ones, and `InventoryMergeCandidate` records no per-item
/// upload state. So the copy never claims one, in either direction.
nonisolated struct InventoryMergeReviewFooterPresentation: Equatable {
    let text: String

    /// True once this session has confirmed at least once. Read-only inspection
    /// of two immutable session fields; never a controller or persistence call.
    static func hasUploadedAlready(session: GuestMergeSession) -> Bool {
        session.confirmedAt != nil || session.uploadedItemCount > 0
    }

    static func make(session: GuestMergeSession?) -> InventoryMergeReviewFooterPresentation {
        // Deliberately neutral in every case. Even before a first confirm the
        // wording avoids a per-item upload promise, so the sentence a user reads
        // does not change meaning underneath them once a partial confirm has
        // happened.
        InventoryMergeReviewFooterPresentation(
            text: "这里汇总本次会话中已经选择的处理方式，不代表各条目的当前上传状态。"
        )
    }
}

// MARK: - Editing availability

/// Whether recorded conflict choices may still be changed.
///
/// UI-5B2B-B2B allows editing a decision only while this session has provably
/// never attempted a write. Once a confirm has run, an edit could contradict a
/// remote create or update that already happened, and nothing in the app can
/// undo that — `InventoryMergeCandidate` keeps no per-item upload state to tell
/// which candidates were affected.
///
/// This drives presentation only. `GuestMergeController.resolveConflict`
/// enforces the same rule independently and is the final safety boundary: a
/// stale screen or a queued tap must fail closed there, not here.
nonisolated enum InventoryMergeChoiceEditingAvailability: Equatable {
    /// Before any confirm attempt — choices may be viewed and changed.
    case editable
    /// This session already confirmed at least once, so recorded choices are
    /// read-only even if the status later returned to `.previewReady`.
    case readOnlyAfterSyncStarted
    /// The session is in a status where the review is not an editing surface —
    /// mid-upload, terminal, or the post-partial `.conflict` root (whose
    /// unresolved candidates are still handled by the conflict flow itself).
    case unavailableForCurrentStatus

    var isEditable: Bool { self == .editable }

    static func make(session: GuestMergeSession?) -> InventoryMergeChoiceEditingAvailability {
        guard let session else { return .unavailableForCurrentStatus }
        // Checked before status: a partly-confirmed session can be back in
        // `.previewReady`, and it must not regain editing.
        if session.confirmedAt != nil
            || session.uploadedItemCount > 0
            || !session.createdEntityIds.isEmpty {
            return .readOnlyAfterSyncStarted
        }
        switch session.status {
        case .previewReady, .awaitingConfirmation:
            return .editable
        default:
            return .unavailableForCurrentStatus
        }
    }
}

// MARK: - Confirmation

/// Button title and supporting copy only. The action behind the button, and
/// everything `confirmMerge` writes, is untouched by this phase — including the
/// deliberate decision to keep confirm enabled when conflicts remain, which is
/// the existing partial-merge path.
nonisolated struct InventoryMergeConfirmationPresentation: Equatable {
    let buttonTitle: String
    let supportingCopy: String

    /// `session` is read only for its confirm history — two immutable fields.
    /// Once this session has confirmed once, the plan can no longer be described
    /// as a set of things that are all still about to happen, so the definite
    /// first-pass copy is replaced with continuation wording.
    static func make(
        summary: InventoryMergeSummaryPresentation,
        session: GuestMergeSession?
    ) -> InventoryMergeConfirmationPresentation {
        let unresolved = summary.stillNeedsDecision
        let uploadable = summary.uploadableCount

        if let session, InventoryMergeReviewFooterPresentation.hasUploadedAlready(session: session) {
            // This session already uploaded part of the plan. The plan does not
            // record which candidates those were, so no honest per-item
            // "remaining" count can be derived here — hence the conservative
            // wording rather than an invented number.
            // One sentence, identical whether or not conflicts remain: it claims
            // nothing about which individual entries have been uploaded, and
            // avoids implying this page can tell them apart.
            return InventoryMergeConfirmationPresentation(
                buttonTitle: "确认当前处理计划",
                supportingCopy: "当前页面汇总本次会话的整体计划，系统会根据当前同步状态继续处理。"
            )
        }

        if unresolved == 0 && uploadable == 0 {
            // Every conflict was kept-remote and/or skipped, so a confirm
            // uploads nothing. Saying 确认合并库存 here would imply the local
            // inventory is about to be sent.
            return InventoryMergeConfirmationPresentation(
                buttonTitle: "完成，不上传任何条目",
                supportingCopy: "本次不会上传任何库存；家庭和本机数据保持现在的样子。"
            )
        }
        if unresolved > 0 && uploadable == 0 {
            return InventoryMergeConfirmationPresentation(
                buttonTitle: "确认当前处理结果",
                supportingCopy: "目前没有可上传条目；确认后仍有 \(unresolved) 条冲突需要处理。"
            )
        }
        if unresolved > 0 {
            var copy = "还有 \(unresolved) 条待处理，本次不会上传这些条目。"
            let aside = deferredAside(summary: summary)
            if !aside.isEmpty { copy += aside }
            return InventoryMergeConfirmationPresentation(
                buttonTitle: "先合并其余 \(uploadable) 条",
                supportingCopy: copy
            )
        }
        return InventoryMergeConfirmationPresentation(
            buttonTitle: "确认合并库存",
            supportingCopy: uploadPlanCopy(summary: summary)
        )
    }

    /// "将新增 3 条、更新 1 条；1 条保留家庭内容，2 条本次跳过。" — only the
    /// non-zero parts appear.
    private static func uploadPlanCopy(summary: InventoryMergeSummaryPresentation) -> String {
        var uploads: [String] = []
        if summary.willCreate > 0 { uploads.append("计划新增 \(summary.willCreate) 条") }
        if summary.willUpdate > 0 { uploads.append("计划更新 \(summary.willUpdate) 条") }
        var copy = uploads.joined(separator: "、")
        let aside = deferredAside(summary: summary)
        copy += aside.isEmpty ? "。" : aside
        return copy
    }

    /// "；1 条保留家庭内容，2 条本次跳过。" or "" when neither applies.
    private static func deferredAside(summary: InventoryMergeSummaryPresentation) -> String {
        var parts: [String] = []
        if summary.keptRemote > 0 { parts.append("\(summary.keptRemote) 条保留家庭内容") }
        if summary.skippedThisTime > 0 { parts.append("\(summary.skippedThisTime) 条本次跳过") }
        guard !parts.isEmpty else { return "" }
        return "；" + parts.joined(separator: "，") + "。"
    }
}
