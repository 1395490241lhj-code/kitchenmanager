import Combine
import Foundation

/// Bridges `SharedImportQueue` (written by the Share Extension) into the
/// main app's existing Smart Import flow. Doesn't parse, save, or introduce
/// a second import UI — it only decides *when* to surface a pending request
/// and hands its content to the existing `ImportRecipeView` prefill.
///
/// ## Request lifecycle
///
/// Every transition below is written to the App Group queue file, not held
/// in memory, so it survives a relaunch:
///
/// | State | Set by | Auto-presented? | Auto-started? |
/// |---|---|---|---|
/// | `.pending` | the Share Extension enqueueing | yes, once | yes |
/// | `.deferred` | user chose "稍后处理" / closed the sheet | no | no |
/// | `.failed` | `maxAutoRetryCount` import failures | no | no |
/// | removed | successful save, or explicit "删除此次导入" | — | — |
/// | removed | age-based pruning (`SharedImportQueue.maxRequestAge`) | — | — |
///
/// Before this lifecycle existed, dismissing the sheet only snoozed the
/// request **in memory**; the request stayed `pending` on disk and was
/// re-presented *and re-imported* on every subsequent launch, forever.
@MainActor
final class SharedImportCoordinator: ObservableObject {
    /// After this many failures a request stops auto-presenting. The user
    /// can still retry it explicitly — it just can't loop on its own.
    static let maxAutoRetryCount = 2

    @Published private(set) var pendingRequest: SharedImportRequest?
    /// Requests the user deferred or that exhausted automatic retries.
    /// Surfaced so an explicit entry point can offer them again; never
    /// auto-presented.
    @Published private(set) var deferredRequests: [SharedImportRequest] = []

    private let queue: SharedImportQueue?
    /// Requests already surfaced during *this* session. Purely a
    /// presentation guard so a `scenePhase` bounce doesn't re-present the
    /// same sheet mid-session — it is **not** the mechanism that stops
    /// re-presentation across launches. That is the persisted status.
    private var presentedThisSession: Set<UUID> = []

    init(queue: SharedImportQueue?) {
        self.queue = queue
    }

    var isQueueAvailable: Bool { queue != nil }

    /// Re-checks the on-disk queue for the oldest request that is still
    /// eligible for automatic presentation. Safe to call from `scenePhase`
    /// becoming `.active`, app launch, or returning from the share flow.
    ///
    /// Prunes, in order:
    /// 1. requests with no URL (`!hasRequiredURL`) — legacy/invalid data the
    ///    current pipeline can never complete;
    /// 2. requests older than `SharedImportQueue.maxRequestAge` — generic
    ///    age-based cleanup of anything the user never finished.
    ///
    /// Then presents only a `.pending` request under the retry cap. A
    /// `.deferred` or `.failed` request is left on disk and reported through
    /// `deferredRequests` instead of being forced back onto the screen.
    func refresh(isAnotherImportFlowPresented: Bool) {
        guard let queue else { return }

        for unsupported in queue.peekAll() where !unsupported.hasRequiredURL {
            queue.remove(id: unsupported.id)
            presentedThisSession.remove(unsupported.id)
        }
        for expiredID in queue.pruneExpired() {
            presentedThisSession.remove(expiredID)
        }

        let all = queue.peekAll()
        deferredRequests = all.filter(Self.isDeferredOrExhausted)

        guard !isAnotherImportFlowPresented else { return }
        guard pendingRequest == nil else { return }

        pendingRequest = all.first { request in
            request.status == .pending
                && request.failureCount < Self.maxAutoRetryCount
                && !presentedThisSession.contains(request.id)
        }
        if let pendingRequest {
            presentedThisSession.insert(pendingRequest.id)
        }
    }

    /// Whether the importer should fire its network request by itself for
    /// this request. Only a genuinely new, never-failed request auto-starts;
    /// anything the user is deliberately re-opening waits for a manual tap.
    static func shouldAutoStart(_ request: SharedImportRequest) -> Bool {
        request.status == .pending && request.failureCount == 0
    }

    static func isDeferredOrExhausted(_ request: SharedImportRequest) -> Bool {
        request.status != .pending || request.failureCount >= maxAutoRetryCount
    }

    /// The existing Smart Import URL field only understands "a URL, or a
    /// blob of text that contains one" — this reproduces exactly that shape
    /// rather than inventing a second input model.
    ///
    /// Only ever called for a request that passed `refresh`'s
    /// `hasRequiredURL` gate, so `.sharedText` (no URL) does not occur in
    /// practice here — it's handled anyway for switch exhaustiveness.
    static func prefillText(for request: SharedImportRequest) -> String {
        switch request.source {
        case .sharedURL:
            return request.url?.absoluteString ?? ""
        case .sharedText:
            return request.text ?? ""
        case .sharedTextAndURL:
            guard let url = request.url else { return request.text ?? "" }
            guard let text = request.text, !text.isEmpty else { return url.absoluteString }
            return text.contains(url.absoluteString) ? text : "\(text)\n\(url.absoluteString)"
        }
    }

    /// Call once the existing import flow has actually saved the recipe.
    /// Only successful handoff removes the request from disk.
    func markHandedOff(_ request: SharedImportRequest) {
        queue?.remove(id: request.id)
        presentedThisSession.remove(request.id)
        clearIfCurrent(request)
        reloadDeferred()
    }

    /// "稍后处理" — the user is not abandoning the link, but they are done
    /// with it for now. The request stays queued and reachable through
    /// `deferredRequests`, and is **persisted** as `.deferred` so a relaunch
    /// does not shove it back on screen or re-run the AI import.
    func snooze(_ request: SharedImportRequest) {
        queue?.update(id: request.id) { $0.updating(status: .deferred) }
        clearIfCurrent(request)
        reloadDeferred()
    }

    /// "删除此次导入" — the user is abandoning the link. Removed from the
    /// on-disk queue; it can never surface again.
    func discard(_ request: SharedImportRequest) {
        queue?.remove(id: request.id)
        presentedThisSession.remove(request.id)
        clearIfCurrent(request)
        reloadDeferred()
    }

    /// Records an import failure. After `maxAutoRetryCount` failures the
    /// request is persisted as `.failed` and stops auto-presenting, so a
    /// permanently broken link can't spin forever on every launch. The user
    /// can still retry it explicitly via `resume`.
    func recordFailure(_ request: SharedImportRequest) {
        queue?.update(id: request.id) { current in
            let nextCount = current.failureCount + 1
            return current.updating(
                status: nextCount >= Self.maxAutoRetryCount ? .failed : current.status,
                failureCount: nextCount
            )
        }
        reloadDeferred()
    }

    /// Explicit user-driven "继续导入" / "重试导入" from the pending-shares
    /// list. Presents the request again **without** restoring `.pending`:
    /// the status is deliberately left `.deferred`/`.failed` so
    /// `shouldAutoStart` stays false and the user has to tap 开始导入
    /// themselves. Re-arming auto-start here would reintroduce exactly the
    /// "it recognizes by itself again" behavior this whole lifecycle exists
    /// to prevent.
    func resume(_ request: SharedImportRequest) {
        guard let queue else { return }
        guard let current = queue.peekAll().first(where: { $0.id == request.id }) else { return }
        presentedThisSession.insert(current.id)
        pendingRequest = current
    }

    private func reloadDeferred() {
        guard let queue else {
            deferredRequests = []
            return
        }
        deferredRequests = queue.peekAll().filter(Self.isDeferredOrExhausted)
    }

    private func clearIfCurrent(_ request: SharedImportRequest) {
        if pendingRequest?.id == request.id {
            pendingRequest = nil
        }
    }
}
