import XCTest
@testable import KitchenManager

/// The `AI 做菜` waiting state is only honest if the way out of it is real: a
/// cancelled whole-recipe request must leave the form, the draft and the busy
/// flag exactly as the member left them, and neither its late answer nor its
/// late failure may speak. These tests drive the store directly, so the
/// in-flight window is exact rather than timed.
@MainActor
final class AIRecipeGenerationWaitStateTests: XCTestCase {
    /// Holds every generator call open until the test answers it, and counts
    /// how many were ever started.
    private final class Gate {
        private var waiters: [CheckedContinuation<EditableRecipeDraft, Error>] = []
        private(set) var startedCount = 0
        var pendingCount: Int { waiters.count }

        func next() async throws -> EditableRecipeDraft {
            startedCount += 1
            return try await withCheckedThrowingContinuation { waiters.append($0) }
        }

        func complete(title: String) {
            guard !waiters.isEmpty else { return XCTFail("no request is waiting") }
            waiters.removeFirst().resume(returning: EditableRecipeDraft(
                title: title,
                ingredientsText: "鸡蛋\n番茄",
                stepsText: "鸡蛋打散备用\n同炒"
            ))
        }

        func fail(_ error: Error) {
            guard !waiters.isEmpty else { return XCTFail("no request is waiting") }
            waiters.removeFirst().resume(throwing: error)
        }
    }

    private struct Harness {
        let store: AIRecipeGeneratorStore
        let gate: Gate
    }

    private func makeHarness() -> Harness {
        let gate = Gate()
        let store = AIRecipeGeneratorStore(generateDraft: { _ in try await gate.next() })
        store.customIngredientsText = "鸡蛋"
        return Harness(store: store, gate: gate)
    }

    private func draft(_ title: String) -> EditableRecipeDraft {
        EditableRecipeDraft(
            title: title,
            ingredientsText: "鸡蛋\n番茄",
            stepsText: "鸡蛋打散备用\n同炒"
        )
    }

    private func startGenerating(_ h: Harness, regenerate: Bool = false) async -> Task<Bool, Never> {
        // Wait for *this* request to reach the gate. A previous cancelled
        // request may still be parked there, so a non-empty queue proves
        // nothing about the one just started.
        let before = h.gate.startedCount
        let task = Task { await h.store.generate(inventory: [], regenerate: regenerate) }
        while h.gate.startedCount == before { await Task.yield() }
        XCTAssertTrue(h.store.isGenerating)
        return task
    }

    /// The shape a cancelled transport really produces: the app's own cancel
    /// races the request, and what unwinds is often the chat client's
    /// catch-all rather than a `CancellationError`.
    private struct LateTransportFailure: Error {}

    // MARK: - Initial generation

    /// G2 — cancelling leaves every entered constraint alone and clears the
    /// busy state, with nothing to apologise for.
    func testCancellingInitialGenerationKeepsEveryEnteredConstraint() async throws {
        let h = makeHarness()
        h.store.customIngredientsText = "鸡蛋、番茄"
        h.store.servings = 5
        h.store.selectedFlavors = ["清淡", "快手"]
        h.store.cuisine = "川菜"
        h.store.maxCookingTime = 30
        h.store.excludedIngredientsText = "花生"
        h.store.additionalRequest = "适合带饭"
        let generation = await startGenerating(h)

        h.store.cancelGeneration()

        XCTAssertFalse(h.store.isGenerating, "the busy state clears immediately")
        XCTAssertNil(h.store.errorMessage, "cancellation is not a failure")
        XCTAssertEqual(h.store.customIngredientsText, "鸡蛋、番茄")
        XCTAssertEqual(h.store.servings, 5)
        XCTAssertEqual(h.store.selectedFlavors, ["清淡", "快手"])
        XCTAssertEqual(h.store.cuisine, "川菜")
        XCTAssertEqual(h.store.maxCookingTime, 30)
        XCTAssertEqual(h.store.excludedIngredientsText, "花生")
        XCTAssertEqual(h.store.additionalRequest, "适合带饭")

        h.gate.complete(title: "迟到的菜谱")
        let produced = await generation.value
        XCTAssertFalse(produced, "a cancelled run must not tell the screen to move on")
    }

    /// G3 — the late answer of a cancelled request installs nothing, so the
    /// screen has no reason to present a draft.
    func testLateSuccessAfterCancelInstallsNoDraft() async throws {
        let h = makeHarness()
        let generation = await startGenerating(h)

        h.store.cancelGeneration()
        h.gate.complete(title: "迟到的菜谱")
        let produced = await generation.value

        XCTAssertFalse(produced)
        XCTAssertNil(h.store.generatedDraft, "a cancelled generation never publishes its result")
        XCTAssertNil(h.store.errorMessage)
        XCTAssertFalse(h.store.isGenerating)
    }

    /// G4 — and its late failure stays silent. The existing safety test covers
    /// a `CancellationError`; this covers the shape the transport actually
    /// produces, which reaches the ownership guard instead.
    func testLateFailureAfterCancelSurfacesNoError() async throws {
        let h = makeHarness()
        let generation = await startGenerating(h)

        h.store.cancelGeneration()
        h.gate.fail(LateTransportFailure())
        let produced = await generation.value

        XCTAssertFalse(produced)
        XCTAssertNil(h.store.errorMessage, "a cancelled request may not raise an alert behind the member")
        XCTAssertNil(h.store.generatedDraft)
        XCTAssertFalse(h.store.isGenerating, "the busy state stays cleared")
    }

    /// G5 — cancelling does not poison the next attempt, and the abandoned
    /// request cannot overwrite what the new one produced.
    func testExplicitRetryAfterCancelInstallsOnlyTheNewResult() async throws {
        let h = makeHarness()
        let first = await startGenerating(h)
        h.store.cancelGeneration()
        let retry = await startGenerating(h)

        // The abandoned request is first in the queue, so it answers first.
        h.gate.complete(title: "迟到的菜谱")
        _ = await first.value
        XCTAssertNil(h.store.generatedDraft, "the abandoned request installs nothing")
        XCTAssertTrue(h.store.isGenerating, "and it does not clear the retry's busy state")

        h.gate.complete(title: "新菜谱")
        let produced = await retry.value
        XCTAssertTrue(produced)
        XCTAssertEqual(h.store.generatedDraft?.title, "新菜谱",
                       "only the request the member actually started installs a draft")
        XCTAssertNil(h.store.errorMessage)
        XCTAssertFalse(h.store.isGenerating)
    }

    /// G6 — a second whole-recipe generation cannot start while one is running.
    func testInitialGenerationCannotStartASecondConcurrentRequest() async throws {
        let h = makeHarness()
        let generation = await startGenerating(h)

        let second = await h.store.generate(inventory: [])
        XCTAssertFalse(second, "the repeated tap is refused")
        XCTAssertEqual(h.gate.startedCount, 1, "only one invocation ever exists")
        XCTAssertEqual(h.gate.pendingCount, 1)

        h.gate.complete(title: "菜谱")
        let produced = await generation.value
        XCTAssertTrue(produced, "the original request is unharmed")
    }

    /// G7 — a succeeding request lets go of the busy state and of its own
    /// ownership *before* it reports success, so the transition that success
    /// triggers cannot take the result back. Pushing 确认菜谱 fires the
    /// generator's `onDisappear`, which cancels generation; that cancel has to
    /// land on nothing. This is ordering, not luck — the guarantee lives in
    /// `finishRequest` running ahead of the `return true`, so assert the state
    /// the caller actually observes at the moment it is told to move on.
    func testInitialSuccessIsFinishedBeforeItReportsSuccess() async throws {
        let h = makeHarness()
        let generation = await startGenerating(h)

        h.gate.complete(title: "番茄炒蛋")
        let produced = await generation.value
        XCTAssertTrue(produced)

        // What the screen sees the instant it is told to present the draft.
        XCTAssertFalse(h.store.isGenerating, "a finished request must not still be marked busy")

        // The push's own cleanup, run against that state.
        h.store.cancelGeneration()

        XCTAssertEqual(h.store.generatedDraft?.title, "番茄炒蛋",
                       "the transition must not cancel the result it exists to present")
        XCTAssertNil(h.store.errorMessage, "a completed generation has nothing to apologise for")
        XCTAssertFalse(h.store.isGenerating)

        // Ownership really was released, not merely hidden: the generator is
        // usable again rather than wedged behind a request that never ended.
        let next = await startGenerating(h)
        h.gate.complete(title: "第二道菜")
        let again = await next.value
        XCTAssertTrue(again, "a store that finished cleanly can generate again")
        XCTAssertEqual(h.store.generatedDraft?.title, "第二道菜")
    }

    // MARK: - Regeneration

    /// R2 / R5 — cancelling a regeneration preserves the existing draft, and
    /// the cancelled answer cannot replace it afterwards.
    func testCancellingRegenerationPreservesTheExistingDraft() async throws {
        let h = makeHarness()
        h.store.generatedDraft = draft("草稿 A")
        let regeneration = await startGenerating(h, regenerate: true)

        h.store.cancelGeneration()
        XCTAssertFalse(h.store.isGenerating, "the waiting state is gone")
        XCTAssertEqual(h.store.generatedDraft?.title, "草稿 A")

        h.gate.complete(title: "草稿 B")
        let produced = await regeneration.value
        XCTAssertFalse(produced)
        XCTAssertEqual(h.store.generatedDraft?.title, "草稿 A", "a cancelled result replaces nothing")
        XCTAssertNil(h.store.errorMessage, "cancellation shows nothing")
    }

    /// R3 — an edit made while a regeneration was waiting survives cancelling
    /// it. The draft on screen is live state, not a snapshot to roll back to.
    func testEditDuringRegenerationSurvivesCancellation() async throws {
        let h = makeHarness()
        h.store.generatedDraft = draft("草稿 A")
        let regeneration = await startGenerating(h, regenerate: true)

        h.store.generatedDraft?.title = "我改过的标题"
        h.store.generatedDraft?.tipsText = "少放盐"

        h.store.cancelGeneration()
        h.gate.complete(title: "草稿 B")
        _ = await regeneration.value

        XCTAssertEqual(h.store.generatedDraft?.title, "我改过的标题", "cancellation must not undo the edit")
        XCTAssertEqual(h.store.generatedDraft?.tipsText, "少放盐")
    }

    /// R4 — the same rule for failure. A request that threw wrote nothing, so
    /// it has nothing to undo; restoring the copy taken before the await would
    /// silently drop the edit made while it ran. The safe sentence still shows.
    func testEditDuringRegenerationSurvivesFailure() async throws {
        let h = makeHarness()
        h.store.generatedDraft = draft("草稿 A")
        let regeneration = await startGenerating(h, regenerate: true)

        h.store.generatedDraft?.title = "我改过的标题"
        h.gate.fail(AIChatServiceError.unavailable)
        let produced = await regeneration.value

        XCTAssertFalse(produced)
        XCTAssertEqual(h.store.generatedDraft?.title, "我改过的标题",
                       "a failed regeneration must not roll the edit back")
        XCTAssertEqual(h.store.errorMessage,
                       AIRecipeGeneratorStore.generationErrorMessage(for: AIChatServiceError.unavailable),
                       "the existing safe wording is untouched")
        XCTAssertFalse(h.store.isGenerating)
    }

    /// R6 — a successful whole-recipe regeneration replaces the draft
    /// wholesale. This is the sealed product rule; only cancel and failure
    /// preserve the live draft, and nothing here is a merge.
    func testSuccessfulRegenerationReplacesTheDraftWholesale() async throws {
        let h = makeHarness()
        h.store.generatedDraft = draft("草稿 A")
        h.store.generatedDraft?.tipsText = "这条备注属于旧草稿"
        let regeneration = await startGenerating(h, regenerate: true)

        h.gate.complete(title: "草稿 B")
        let produced = await regeneration.value
        XCTAssertTrue(produced)

        XCTAssertEqual(h.store.generatedDraft?.title, "草稿 B", "the new recipe replaces the old one")
        XCTAssertEqual(h.store.generatedDraft?.tipsText, "", "no merge: the old draft's fields do not carry over")
        XCTAssertFalse(h.store.hasSavedCurrentDraft, "a fresh draft has not been saved")
        XCTAssertFalse(h.store.hasAddedCurrentDraftToPlan)
        XCTAssertFalse(h.store.isGenerating)
    }

    /// R7 — no second whole-recipe request while one is running.
    func testRegenerationCannotStartASecondConcurrentRequest() async throws {
        let h = makeHarness()
        h.store.generatedDraft = draft("草稿 A")
        let regeneration = await startGenerating(h, regenerate: true)

        let second = await h.store.generate(inventory: [], regenerate: true)
        XCTAssertFalse(second, "the repeated action is refused")
        XCTAssertEqual(h.gate.startedCount, 1, "only one invocation ever exists")

        h.gate.complete(title: "草稿 B")
        let produced = await regeneration.value
        XCTAssertTrue(produced, "the original request is unharmed")
    }

    /// R8 — cancelling a regeneration leaves the next one free to succeed.
    func testRegenerationCanBeRetriedAfterCancellation() async throws {
        let h = makeHarness()
        h.store.generatedDraft = draft("草稿 A")
        let first = await startGenerating(h, regenerate: true)
        h.store.cancelGeneration()
        h.gate.complete(title: "被取消的结果")
        _ = await first.value
        XCTAssertEqual(h.store.generatedDraft?.title, "草稿 A")

        let retry = await startGenerating(h, regenerate: true)
        h.gate.complete(title: "草稿 C")
        let produced = await retry.value
        XCTAssertTrue(produced)

        XCTAssertEqual(h.store.generatedDraft?.title, "草稿 C")
        XCTAssertNil(h.store.errorMessage)
        XCTAssertFalse(h.store.isGenerating)
    }
}
