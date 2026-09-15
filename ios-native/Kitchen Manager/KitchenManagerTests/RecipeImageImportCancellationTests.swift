import XCTest
import UIKit
@testable import KitchenManager

/// Recognition tells the truth while it waits, and stopping it is silent: the
/// picture stays, nothing is written, and an answer that arrives after the stop
/// can no longer land.
@MainActor
final class RecipeImageImportCancellationTests: XCTestCase {
    /// Holds a recognition open so cancellation happens while the request is
    /// genuinely suspended.
    @MainActor
    private final class ExtractionGate {
        private var waiters: [CheckedContinuation<RecipeImageExtractionResult, Error>] = []
        var pendingCount: Int { waiters.count }

        func next() async throws -> RecipeImageExtractionResult {
            try await withCheckedThrowingContinuation { waiters.append($0) }
        }

        func finish(with result: RecipeImageExtractionResult) {
            guard !waiters.isEmpty else { return XCTFail("no recognition is waiting") }
            waiters.removeFirst().resume(returning: result)
        }

        func fail(_ error: Error) {
            guard !waiters.isEmpty else { return XCTFail("no recognition is waiting") }
            waiters.removeFirst().resume(throwing: error)
        }
    }

    private func sampleResult(title: String = "识别出的菜谱") -> RecipeImageExtractionResult {
        RecipeImageExtractionResult(
            draft: EditableRecipeDraft(id: "image-import-test", title: title),
            warnings: [],
            rawText: nil
        )
    }

    private func sampleImage() -> UIImage {
        let size = CGSize(width: 400, height: 400)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            context.fill(CGRect(x: 40, y: 40, width: 320, height: 40))
        }
    }

    /// Returns a store whose picture is selected and prepared, ready to recognise.
    private func makeReadyStore(gate: ExtractionGate) async -> RecipeImageImportStore {
        let store = RecipeImageImportStore(extract: { _ in try await gate.next() })
        store.setImage(sampleImage())
        var spins = 0
        while store.isPreparingImage && spins < 10_000 {
            await Task.yield()
            spins += 1
        }
        XCTAssertTrue(store.canRecognize, "the picture never finished preparing")
        return store
    }

    private func startRecognition(_ store: RecipeImageImportStore, gate: ExtractionGate) async {
        store.recognize()
        var spins = 0
        while gate.pendingCount == 0 && spins < 10_000 {
            await Task.yield()
            spins += 1
        }
        XCTAssertTrue(store.isRecognizing, "recognition did not start")
    }

    // I1 — the waiting state says only what the client knows, and the stop is
    // offered next to it. The staged story it used to tell is gone with its enum.
    func testWaitingStateIsOneTruthfulSentenceWithAStop() async {
        let gate = ExtractionGate()
        let store = await makeReadyStore(gate: gate)
        await startRecognition(store, gate: gate)

        XCTAssertEqual(RecipeImageImportView.recognizingStatus, "正在识别菜谱…")
        XCTAssertEqual(RecipeImageImportView.cancelRecognitionLabel, "取消识别")
        XCTAssertTrue(store.isRecognizing, "the busy flag is what the status row renders from")

        for invented in ["正在上传图片", "正在识别文字", "正在整理食材和步骤", "正在生成预览"] {
            XCTAssertNotEqual(RecipeImageImportView.recognizingStatus, invented)
        }
    }

    // I2 — stop and stay.
    func testCancellingRecognitionKeepsThePictureAndStaysSilent() async {
        let gate = ExtractionGate()
        let store = await makeReadyStore(gate: gate)
        await startRecognition(store, gate: gate)

        store.cancel()

        XCTAssertFalse(store.isRecognizing, "the busy state ends immediately")
        XCTAssertNil(store.errorMessage, "stopping on purpose is not a failure")
        XCTAssertNil(store.draft)
        XCTAssertNotNil(store.image, "the selected picture stays")
        XCTAssertTrue(store.canRecognize, "and it can be recognised again")
    }

    // I3 — a late answer cannot install anything.
    func testResultArrivingAfterCancellationIsDropped() async {
        let gate = ExtractionGate()
        let store = await makeReadyStore(gate: gate)
        await startRecognition(store, gate: gate)

        store.cancel()
        gate.finish(with: sampleResult())
        await Task.yield()
        await Task.yield()

        XCTAssertNil(store.draft, "a cancelled recognition must not install a draft")
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isRecognizing)
    }

    // I3b — and neither can a late failure, so the stop stays silent.
    func testFailureArrivingAfterCancellationShowsNoError() async {
        let gate = ExtractionGate()
        let store = await makeReadyStore(gate: gate)
        await startRecognition(store, gate: gate)

        store.cancel()
        // The chat client collapses a cancelled transport into this, so it is
        // what a cancelled recognition usually races against.
        gate.fail(AIChatServiceError.unavailable)
        await Task.yield()
        await Task.yield()

        XCTAssertNil(store.errorMessage, "a cancelled recognition never reports a failure")
        XCTAssertNil(store.draft)
    }

    // I4 — leaving the screen is the other way out. The view calls the same
    // `cancel()` from `onDisappear`, so this is that path: stop, no error, and
    // nothing lands afterwards.
    func testLeavingTheScreenStopsRecognitionSilently() async {
        let gate = ExtractionGate()
        let store = await makeReadyStore(gate: gate)
        await startRecognition(store, gate: gate)

        store.cancel() // what .onDisappear does
        gate.finish(with: sampleResult())
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(store.isRecognizing)
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.draft)
    }

    // Retry after a stop is a deliberate act, and it works.
    func testRecognitionCanBeStartedAgainAfterCancelling() async {
        let gate = ExtractionGate()
        let store = await makeReadyStore(gate: gate)
        await startRecognition(store, gate: gate)

        store.cancel()
        XCTAssertNil(store.draft)

        // The cancelled request unwinds, the way a cancelled URLSession call
        // does, so the gate is empty again before the deliberate retry.
        gate.fail(CancellationError())
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(gate.pendingCount, 0)

        await startRecognition(store, gate: gate)
        gate.finish(with: sampleResult(title: "第二次识别"))
        var spins = 0
        while store.isRecognizing && spins < 10_000 {
            await Task.yield()
            spins += 1
        }

        XCTAssertEqual(store.draft?.title, "第二次识别", "an explicit retry installs its own result")
        XCTAssertNil(store.errorMessage)
    }

    // Success is unchanged: the draft arrives exactly as before.
    func testSuccessfulRecognitionInstallsTheDraft() async {
        let gate = ExtractionGate()
        let store = await makeReadyStore(gate: gate)
        await startRecognition(store, gate: gate)

        gate.finish(with: sampleResult())
        var spins = 0
        while store.isRecognizing && spins < 10_000 {
            await Task.yield()
            spins += 1
        }

        XCTAssertEqual(store.draft?.title, "识别出的菜谱")
        XCTAssertFalse(store.isRecognizing)
        XCTAssertNil(store.errorMessage)
    }
}

