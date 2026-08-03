import Foundation
import SwiftUI

#if DEBUG

/// UI-5B2B-B2B: pure value mapping behind the cold-relaunch acceptance probes.
///
/// SwiftUI-free so every state it can report is unit-testable without running a
/// UI test. Crucially, each probe always produces a value — `state=waiting`,
/// `state=missing-plan`, `state=missing-candidate` — so a UI test never has to
/// interpret "element not found", which is what made the previous dynamic
/// `uitest.forkIdentity-<uuid>` marker useless when it disappeared.
nonisolated enum RestartUITestProbePresentation {
    /// Fixed identifiers. Values change; identifiers never do.
    enum Identifier {
        static let mode = "uitest.restart.mode"
        static let fixtureState = "uitest.restart.fixtureState"
        static let inventory = "uitest.restart.inventory"
        static let previewOrigin = "uitest.restart.previewOrigin"
        static let session = "uitest.restart.session"
        static let forkIdentity = "uitest.restart.forkIdentity"
        static let mutationCount = "uitest.restart.mutationCount"
    }

    static func mode(_ mode: AccountLifecycleSummaryFixture.RestartLaunchMode) -> String {
        switch mode {
        case .none: "none"
        case .seed: "seed"
        case .resume: "resume"
        }
    }

    /// Whether this launch wrote fixture data at all.
    static func fixtureState(_ mode: AccountLifecycleSummaryFixture.RestartLaunchMode) -> String {
        switch mode {
        case .none: "not-a-restart-launch"
        case .seed: "seeded"
        case .resume: "resume-no-seed"
        }
    }

    /// Ordered, lowercased local inventory ids, so two launches can be compared
    /// character for character.
    static func inventory(_ items: [InventoryItem]) -> String {
        guard !items.isEmpty else { return "state=empty" }
        let ids = items.map { $0.id.uuidString.lowercased() }.joined(separator: ",")
        return "count=\(items.count);ids=\(ids)"
    }

    static func previewOrigin(_ origin: String?) -> String {
        origin ?? "state=waiting"
    }

    static func session(_ session: GuestMergeSession?) -> String {
        guard let session else { return "state=waiting" }
        return "id=\(session.id.uuidString.lowercased())"
            + ";status=\(session.status.rawValue)"
            + ";confirmed=\(session.confirmedAt == nil ? "nil" : "set")"
            + ";uploaded=\(session.uploadedItemCount)"
            + ";created=\(session.createdEntityIds.count)"
    }

    /// The whole point of the probe: exact reserved/active fork identity for one
    /// canonical candidate, in a form two processes can compare literally.
    static func forkIdentity(plan: InventoryMergePlan?, candidateId: UUID) -> String {
        guard let plan else { return "state=missing-plan" }
        guard let candidate = plan.candidates.first(where: { $0.localItemId == candidateId }) else {
            return "state=missing-candidate"
        }
        return "state=ready"
            + ";candidate=\(candidate.localItemId.uuidString.lowercased())"
            + ";choice=\(candidate.userChoice?.rawValue ?? "nil")"
            + ";action=\(candidate.action.rawValue)"
            + ";reserved=\(candidate.forkedLocalItemId?.uuidString.lowercased() ?? "nil")"
            + ";active=\(candidate.activeForkedLocalItemId?.uuidString.lowercased() ?? "nil")"
    }

    /// `reads` is how many times the count has actually been re-read. A UI test
    /// asserting only `count=0` cannot tell a fresh zero from the first read
    /// left on screen, so the read tally is published alongside it: after an
    /// edit the tally must move, which is what proves the value was refetched.
    static func mutationCount(_ count: Int?, reads: Int = 0) -> String {
        guard let count else { return "state=waiting;reads=\(reads)" }
        return "count=\(count);reads=\(reads)"
    }

    /// Refresh key for the pending-mutation read.
    ///
    /// `.task(id:)` re-runs only when its id changes, so a key that misses an
    /// edit leaves a stale count on screen — and a stale `count=0` would let a
    /// regression that staged a mutation during a choice edit pass unnoticed,
    /// which is the one invariant the cold-relaunch test exists to protect.
    /// The candidate *count* was exactly such a key: every one of the four
    /// choices leaves it identical.
    ///
    /// Derived entirely from persisted merge state — never a random value,
    /// never a timer — so identical state always yields an identical key, and
    /// any recorded change (including a reservation that is retained but
    /// deactivated) yields a different one.
    static func mutationRefreshKey(session: GuestMergeSession?, plan: InventoryMergePlan?) -> String {
        var key = "session=" + (session.map { session in
            session.id.uuidString.lowercased()
                + ";status=\(session.status.rawValue)"
                + ";updated=\(session.updatedAt.timeIntervalSince1970)"
                + ";confirmed=\(session.confirmedAt.map { String($0.timeIntervalSince1970) } ?? "nil")"
                + ";uploaded=\(session.uploadedItemCount)"
                + ";created=\(session.createdEntityIds.count)"
        } ?? "nil")
        guard let plan else { return key + "|plan=nil" }
        key += "|count=\(plan.candidates.count)|"
        // Every candidate, in plan order: an edit to any one of them must move
        // the key, not just an edit to the canonical restart candidate.
        key += plan.candidates.map { candidate in
            candidate.localItemId.uuidString.lowercased()
                + ":" + (candidate.userChoice?.rawValue ?? "nil")
                + ":" + candidate.action.rawValue
                + ":" + (candidate.forkedLocalItemId?.uuidString.lowercased() ?? "nil")
                + ":" + (candidate.activeForkedLocalItemId?.uuidString.lowercased() ?? "nil")
        }.joined(separator: ",")
        return key
    }
}

/// Renders every restart probe as a real, always-present, 1×1 accessibility
/// element. Never conditionally removed: when data is missing the *value* says
/// so, so a UI test reads a state instead of failing to find an element.
struct RestartUITestProbeView: View {
    @ObservedObject var controller: GuestMergeController
    @ObservedObject var kitchenStore: KitchenStore
    @State private var pendingMutationCount: Int?
    /// Incremented on every completed read, never reset — see `mutationCount`.
    @State private var mutationReadCount = 0

    private var mode: AccountLifecycleSummaryFixture.RestartLaunchMode {
        AccountLifecycleSummaryFixture.restartLaunchMode
    }

    var body: some View {
        VStack(spacing: 0) {
            probe(
                RestartUITestProbePresentation.Identifier.mode,
                "Restart mode",
                RestartUITestProbePresentation.mode(mode)
            )
            probe(
                RestartUITestProbePresentation.Identifier.fixtureState,
                "Restart fixture state",
                RestartUITestProbePresentation.fixtureState(mode)
            )
            probe(
                RestartUITestProbePresentation.Identifier.inventory,
                "Restart inventory",
                RestartUITestProbePresentation.inventory(kitchenStore.inventory)
            )
            probe(
                RestartUITestProbePresentation.Identifier.previewOrigin,
                "Restart preview origin",
                RestartUITestProbePresentation.previewOrigin(controller.uiTestPreviewOrigin?.rawValue)
            )
            probe(
                RestartUITestProbePresentation.Identifier.session,
                "Restart session",
                RestartUITestProbePresentation.session(controller.session)
            )
            probe(
                RestartUITestProbePresentation.Identifier.forkIdentity,
                "Restart fork identity",
                RestartUITestProbePresentation.forkIdentity(
                    plan: controller.plan,
                    candidateId: AccountLifecycleSummaryFixture.restartSameIDCandidateID
                )
            )
            probe(
                RestartUITestProbePresentation.Identifier.mutationCount,
                "Restart mutation count",
                RestartUITestProbePresentation.mutationCount(
                    pendingMutationCount, reads: mutationReadCount
                )
            )
        }
        .allowsHitTesting(false)
        // Keyed on the full merge state, not the candidate count: the count is
        // unchanged by every choice edit, so it left the first reading on
        // screen forever. Re-runs on first appearance and after each recorded
        // choice, so the displayed count is always a fresh read.
        .task(id: RestartUITestProbePresentation.mutationRefreshKey(
            session: controller.session, plan: controller.plan
        )) {
            let count = await controller.pendingInventoryCount(
                householdId: AccountLifecycleSummaryFixture.choiceEditingRestart.householdID
            )
            pendingMutationCount = count
            mutationReadCount += 1
        }
    }

    /// A real element with non-zero size and a tiny opacity: fully hidden views
    /// and `accessibilityHidden` ones are dropped from the accessibility tree.
    private func probe(_ identifier: String, _ label: String, _ value: String) -> some View {
        Text(" ")
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(label)
            .accessibilityValue(value)
    }
}

#endif
