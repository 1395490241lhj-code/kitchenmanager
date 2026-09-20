import XCTest
@testable import KitchenManager

/// Retry wording is the only thing that tells the member what a retry will
/// do. The contract has two halves: the three renderable scopes carry
/// distinct, truthful copy even though they share one command, and `.action`
/// carries nothing at all, so no caller can render an action retry.
final class AIRetryScopePresentationTests: XCTestCase {

    private let renderable: [AIRetryScope] = [.generation, .contextRead, .interpretation]

    func testGenerationSaysItRegeneratesTheReply() {
        let p = AIRetryScopePresentation.retry(for: .generation)
        XCTAssertEqual(p?.title, "重新生成回复")
        XCTAssertEqual(p?.accessibilityLabel, "重新生成这条回复")
    }

    func testContextReadSaysItRereadsTheKitchenFirst() {
        let p = AIRetryScopePresentation.retry(for: .contextRead)
        XCTAssertEqual(p?.title, "重新读取厨房数据")
        XCTAssertEqual(p?.accessibilityLabel, "重新读取当前厨房数据后再回复")
    }

    /// Unreachable from production today, but the presentation must be ready
    /// and truthful if the orchestrator ever emits it.
    func testInterpretationSaysItReprocessesTheRequest() {
        let p = AIRetryScopePresentation.retry(for: .interpretation)
        XCTAssertEqual(p?.title, "重新处理请求")
        XCTAssertEqual(p?.accessibilityLabel, "重新处理这条请求")
    }

    /// The invariant that matters: there is no scoped action retry, so the
    /// presentation type refuses to describe one. A future caller that drops
    /// the view-level guard still cannot render an action retry button.
    func testActionHasNoRetryPresentationAtAll() {
        XCTAssertNil(AIRetryScopePresentation.retry(for: .action))
    }

    func testRenderableScopesAreDistinctAndNonEmpty() {
        let presentations = renderable.compactMap(AIRetryScopePresentation.retry)
        XCTAssertEqual(presentations.count, renderable.count, "every renderable scope must present")
        XCTAssertEqual(Set(presentations.map(\.title)).count, renderable.count, "titles must be distinct")
        XCTAssertEqual(Set(presentations.map(\.accessibilityLabel)).count, renderable.count, "labels must be distinct")
        XCTAssertTrue(presentations.allSatisfy { !$0.title.isEmpty && !$0.accessibilityLabel.isEmpty })
    }
}
