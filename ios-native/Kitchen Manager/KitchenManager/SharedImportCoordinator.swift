import Combine
import Foundation

/// Bridges `SharedImportQueue` (written by the Share Extension) into the
/// main app's existing Smart Import flow. Doesn't parse, save, or introduce
/// a second import UI — it only decides *when* to surface a pending request
/// and hands its content to the existing `ImportRecipeView` prefill.
@MainActor
final class SharedImportCoordinator: ObservableObject {
    @Published private(set) var pendingRequest: SharedImportRequest?

    private let queue: SharedImportQueue?
    /// Requests the user has seen and dismissed without completing an import
    /// in this app session. Kept in memory only: they remain in the on-disk
    /// queue (never silently dropped) and will resurface on the next launch
    /// or when the user explicitly retries.
    private var snoozedRequestIDs: Set<UUID> = []
    /// Requests the member has already been shown once and closed without
    /// saving. Kept across launches so such a request — typically one whose
    /// link could not be read or was already imported — no longer starts a
    /// network import by itself on every launch; it waits for 开始识别.
    /// Read lazily, never at launch.
    private let defaults: UserDefaults
    static let shownRequestIDsKey = "native_km_shared_import_shown_ids_v1"

    init(queue: SharedImportQueue?, defaults: UserDefaults = .standard) {
        self.queue = queue
        self.defaults = defaults
    }

    private var shownRequestIDs: Set<UUID> {
        get { Set((defaults.stringArray(forKey: Self.shownRequestIDsKey) ?? []).compactMap(UUID.init(uuidString:))) }
        set { defaults.set(newValue.map(\.uuidString).sorted(), forKey: Self.shownRequestIDsKey) }
    }

    /// Whether presenting this request should start reading its link by
    /// itself: only the first time it is shown.
    func shouldAutoStart(_ request: SharedImportRequest) -> Bool {
        !shownRequestIDs.contains(request.id)
    }

    var isQueueAvailable: Bool { queue != nil }

    /// Re-checks the on-disk queue for the oldest not-yet-snoozed,
    /// currently-supported request. Safe to call from `scenePhase` becoming
    /// `.active`, app launch, or returning from the share flow — it only
    /// ever sets `pendingRequest` when nothing is currently pending and no
    /// other modal import flow is occupying the screen, so repeated calls
    /// never produce duplicate presentations.
    ///
    /// Also prunes any queued request that lacks a URL
    /// (`!hasRequiredURL`). Phase 1 only ever *builds* URL-backed requests,
    /// so such a value can only be legacy/invalid data (e.g. from a
    /// different build) that the current import pipeline can never
    /// complete — it is discarded outright so it can neither loop the user
    /// through a doomed import nor block a later, valid request. Requests
    /// that do have a URL are never touched here except by explicit
    /// `markHandedOff`/`discard`.
    func refresh(isAnotherImportFlowPresented: Bool) {
        guard !isAnotherImportFlowPresented else { return }
        guard pendingRequest == nil else { return }
        guard let queue else { return }

        // One coordinated read per refresh. This used to read the queue
        // twice — once to prune, once to pick — and the second read was what
        // kept just-pruned entries out of `candidates`. With a single read,
        // `hasRequiredURL` has to be filtered explicitly instead, so a legacy
        // request without a URL still cannot become `pendingRequest`.
        let queued = queue.peekAll()

        for unsupported in queued where !unsupported.hasRequiredURL {
            queue.remove(id: unsupported.id)
            snoozedRequestIDs.remove(unsupported.id)
        }
        // Forget shown markers for requests that left the queue some other way.
        let queuedIDs = Set(queued.map(\.id))
        if !shownRequestIDs.isSubset(of: queuedIDs) {
            shownRequestIDs = shownRequestIDs.intersection(queuedIDs)
        }

        let candidates = queued.filter {
            $0.hasRequiredURL && !snoozedRequestIDs.contains($0.id)
        }
        pendingRequest = candidates.first
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
        snoozedRequestIDs.remove(request.id)
        shownRequestIDs.remove(request.id)
        clearIfCurrent(request)
    }

    /// The user closed the sheet without saving (or the import failed and
    /// they backed out). The request is preserved on disk — nothing here
    /// deletes unacknowledged work — but we won't re-present it again this
    /// session to avoid the sheet popping back up on every scene-active.
    func snooze(_ request: SharedImportRequest) {
        snoozedRequestIDs.insert(request.id)
        shownRequestIDs.insert(request.id)
        clearIfCurrent(request)
    }

    /// Explicit user-initiated "clear this" action, distinct from `snooze`:
    /// actually removes the request from the queue. Wired to 不再导入, so a
    /// share that cannot be imported no longer returns forever or fills the
    /// 20-item queue the Share Extension refuses new shares beyond.
    func discard(_ request: SharedImportRequest) {
        queue?.remove(id: request.id)
        snoozedRequestIDs.remove(request.id)
        shownRequestIDs.remove(request.id)
        clearIfCurrent(request)
    }

    private func clearIfCurrent(_ request: SharedImportRequest) {
        if pendingRequest?.id == request.id {
            pendingRequest = nil
        }
    }
}
