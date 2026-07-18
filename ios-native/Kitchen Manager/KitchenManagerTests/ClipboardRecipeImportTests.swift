import XCTest
@testable import KitchenManager

final class ClipboardRecipeImportTests: XCTestCase {
    func testProbableURLShowsPromptOnlyAfterSuccessfulPatternResult() {
        var state = ClipboardPromptSessionState()

        XCTAssertTrue(state.beginDetection(changeCount: 10, isAppActive: true, isPresentationBlocked: false))
        XCTAssertFalse(state.shouldShowPrompt(isAppActive: true, isPresentationBlocked: false))
        state.finishDetection(
            changeCount: 10,
            latestChangeCount: 10,
            probableWebURL: true,
            isAppActive: true,
            isPresentationBlocked: false
        )

        XCTAssertTrue(state.shouldShowPrompt(isAppActive: true, isPresentationBlocked: false))
    }

    func testNoProbableURLAndDetectionErrorRemainSilent() {
        for result in [false, nil] as [Bool?] {
            var state = ClipboardPromptSessionState()
            XCTAssertTrue(state.beginDetection(changeCount: 11, isAppActive: true, isPresentationBlocked: false))
            state.finishDetection(
                changeCount: 11,
                latestChangeCount: 11,
                probableWebURL: result,
                isAppActive: true,
                isPresentationBlocked: false
            )
            XCTAssertFalse(state.shouldShowPrompt(isAppActive: true, isPresentationBlocked: false))
            XCTAssertFalse(state.beginDetection(changeCount: 11, isAppActive: true, isPresentationBlocked: false))
        }
    }

    func testInactiveAppAndPendingShareDoNotStartDetection() {
        var state = ClipboardPromptSessionState()

        XCTAssertFalse(state.beginDetection(changeCount: 12, isAppActive: false, isPresentationBlocked: false))
        XCTAssertFalse(state.beginDetection(changeCount: 12, isAppActive: true, isPresentationBlocked: true))
        XCTAssertNil(state.evaluatedChangeCount)
    }

    func testResultIsIgnoredWhenAppBecomesInactiveOrClipboardVersionChanges() {
        var state = ClipboardPromptSessionState()
        XCTAssertTrue(state.beginDetection(changeCount: 13, isAppActive: true, isPresentationBlocked: false))
        state.finishDetection(
            changeCount: 13,
            latestChangeCount: 14,
            probableWebURL: true,
            isAppActive: true,
            isPresentationBlocked: false
        )
        XCTAssertFalse(state.shouldShowPrompt(isAppActive: true, isPresentationBlocked: false))

        state.cancelDetection()
        XCTAssertTrue(state.beginDetection(changeCount: 14, isAppActive: true, isPresentationBlocked: false))
        state.finishDetection(
            changeCount: 14,
            latestChangeCount: 14,
            probableWebURL: true,
            isAppActive: false,
            isPresentationBlocked: false
        )
        XCTAssertFalse(state.shouldShowPrompt(isAppActive: false, isPresentationBlocked: false))
    }

    func testSameChangeCountIsEvaluatedOnceAndNewVersionCanPrompt() {
        var state = detectedState(changeCount: 20)

        XCTAssertFalse(state.beginDetection(changeCount: 20, isAppActive: true, isPresentationBlocked: false))
        XCTAssertTrue(state.beginDetection(changeCount: 21, isAppActive: true, isPresentationBlocked: false))
        state.finishDetection(
            changeCount: 21,
            latestChangeCount: 21,
            probableWebURL: true,
            isAppActive: true,
            isPresentationBlocked: false
        )
        XCTAssertTrue(state.shouldShowPrompt(isAppActive: true, isPresentationBlocked: false))
    }

    func testIgnoreSuppressesOnlyCurrentVersionWithoutReadingOrHandlingIt() {
        var state = detectedState(changeCount: 30)

        state.ignore(changeCount: 30)

        XCTAssertEqual(state.ignoredChangeCount, 30)
        XCTAssertNil(state.handledChangeCount)
        XCTAssertFalse(state.shouldShowPrompt(isAppActive: true, isPresentationBlocked: false))
        XCTAssertFalse(state.beginDetection(changeCount: 30, isAppActive: true, isPresentationBlocked: false))
        XCTAssertTrue(state.beginDetection(changeCount: 31, isAppActive: true, isPresentationBlocked: false))
    }

    func testHandledVersionDoesNotReappearAfterDismissOrForeground() {
        var state = detectedState(changeCount: 40)

        state.markHandled(changeCount: 40)

        XCTAssertFalse(state.shouldShowPrompt(isAppActive: true, isPresentationBlocked: false))
        XCTAssertFalse(state.beginDetection(changeCount: 40, isAppActive: true, isPresentationBlocked: false))
        XCTAssertTrue(state.beginDetection(changeCount: 41, isAppActive: true, isPresentationBlocked: false))
    }

    func testPresentationPolicyGivesPendingShareAndActiveSheetPriority() {
        XCTAssertTrue(ClipboardImportPresentationPolicy.isBlocked(hasPendingShare: true, hasActiveSheet: false))
        XCTAssertTrue(ClipboardImportPresentationPolicy.isBlocked(hasPendingShare: false, hasActiveSheet: true))
        XCTAssertTrue(ClipboardImportPresentationPolicy.isBlocked(hasPendingShare: true, hasActiveSheet: true))
        XCTAssertFalse(ClipboardImportPresentationPolicy.isBlocked(hasPendingShare: false, hasActiveSheet: false))
    }

    func testPureHTTPAndHTTPSURLsCreateAutoStartHandoffs() {
        XCTAssertEqual(
            ClipboardRecipeImportURL.makeHandoff(from: "https://example.com/recipe"),
            .init(urlText: "https://example.com/recipe")
        )
        XCTAssertEqual(
            ClipboardRecipeImportURL.makeHandoff(from: "http://example.com/recipe"),
            .init(urlText: "http://example.com/recipe")
        )
        XCTAssertEqual(ClipboardRecipeImportURL.makeHandoff(from: "https://example.com")?.autoStart, true)
    }

    func testXiaohongshuAndMultilineTextUseFirstExistingHTTPURLParserMatch() {
        let xiaohongshu = """
        打开小红书查看笔记
        http://xhslink.com/abcd
        复制本条信息，打开【小红书】查看
        """
        XCTAssertEqual(
            ClipboardRecipeImportURL.makeHandoff(from: xiaohongshu)?.urlText,
            "http://xhslink.com/abcd"
        )

        let multiline = "说明\nhttps://first.example/one\nhttps://second.example/two"
        XCTAssertEqual(
            ClipboardRecipeImportURL.makeHandoff(from: multiline)?.urlText,
            "https://first.example/one"
        )
    }

    func testInvalidAndNonHTTPContentNeverCreatesImportHandoff() {
        for input in [
            "只有普通文字",
            "file:///tmp/recipe.txt",
            "javascript:alert(1)",
            "kitchenmanager://recipe/1"
        ] {
            XCTAssertNil(ClipboardRecipeImportURL.makeHandoff(from: input), input)
        }
    }

    private func detectedState(changeCount: Int) -> ClipboardPromptSessionState {
        var state = ClipboardPromptSessionState()
        XCTAssertTrue(state.beginDetection(changeCount: changeCount, isAppActive: true, isPresentationBlocked: false))
        state.finishDetection(
            changeCount: changeCount,
            latestChangeCount: changeCount,
            probableWebURL: true,
            isAppActive: true,
            isPresentationBlocked: false
        )
        return state
    }
}
