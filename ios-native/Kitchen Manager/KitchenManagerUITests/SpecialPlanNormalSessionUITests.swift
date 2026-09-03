import XCTest

/// One ordinary user session against the real production backend, at a real
/// user's pace: design a menu once, swap a single dish, save, come back to it.
/// Deliberately not a stress run — the point is to measure what a genuine
/// Special Plan actually costs and whether it holds together end to end.
///
/// This is a **live acceptance** suite, not a deterministic merge gate. It
/// talks to the production AI provider, so it can legitimately end in a
/// provider answer the app must not accept (`这次生成的菜品太少`, a timeout, a
/// malformed reply). Such a run is reported as `LIVE_PROVIDER_FAILURE` and
/// stops there — it is a true statement about the provider that day, not a
/// statement about the app, and it is never dressed up as a pass. What this
/// suite *does* gate is the app's half: navigation, the composer, a
/// replacement landing in the slot it was asked for, save, persistence, and
/// the shopping hand-off.
///
/// Every observation here goes through `SpecialPlanDraftObservation`: rows are
/// addressed by their own stable id and success is that id's title changing.
/// The previous version snapshotted whatever rows the lazy `List` happened to
/// have mounted and waited for that set to differ, which read a six-dish menu
/// as four and spent 120 s waiting on a replacement it could not see.
final class SpecialPlanNormalSessionUITests: XCTestCase {
    private typealias Draft = SpecialPlanDraftObservation

    private func openSeededPlan(in app: XCUIApplication) {
        // Home's own unconditional planner route — the same one a user takes,
        // and no longer dependent on today happening to have a plan.
        XCTAssertTrue(app.buttons["home.planner.link"].waitForExistence(timeout: 15))
        app.buttons["home.planner.link"].tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 10))
        let entry = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "planner.special.entry.")
        ).firstMatch
        XCTAssertTrue(Draft.scroll(to: entry, in: app), "seeded special plan row never became reachable")
        entry.tap()
        XCTAssertTrue(app.navigationBars["朋友聚餐"].waitForExistence(timeout: 10))
    }

    /// Records a provider outcome that ends the run. Loud, labelled, and never
    /// a pass — but also never mistaken for an app defect.
    private func failForLiveProvider(stage: String, message: String) {
        print("LIVE_PROVIDER_FAILURE stage=\(stage) error=\(message)")
        XCTFail("LIVE_PROVIDER_FAILURE at \(stage): \(message)")
    }

    func testNormalUserSessionEndToEnd() {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_SPECIAL_PLAN", "UITEST_SEED_SPECIAL_PLAN_EMPTY_MENU"]
        app.launch()
        openSeededPlan(in: app)

        // 1. Generate once, the way a user would. The result is *whether the
        //    app landed on a draft*, not how many rows are mounted.
        let generateStart = Date()
        app.buttons["planner.menu.generate"].tap()
        let generated = Draft.waitForGeneration(in: app, timeout: 120)
        let generateMs = Int(Date().timeIntervalSince(generateStart) * 1_000)
        let sample = Draft.mountedRows(in: app).map(\.title)
        print("E2E_GENERATE ms=\(generateMs) outcome=\(generated) mountedSample=\(sample.joined(separator: " | "))")

        switch generated {
        case .accepted:
            break
        case .liveProviderFailure(let message):
            failForLiveProvider(stage: "generate", message: message)
            return
        case .settledWithoutDraft:
            XCTFail("generation settled with neither a draft nor an error — that is an app defect, not a provider one")
            return
        case .timedOut:
            failForLiveProvider(stage: "generate", message: "no reply within 120 s")
            return
        }

        // 2. Swap exactly one dish and watch *that slot*. The top row is
        //    mounted by construction; a sibling is recorded so "the others
        //    survive" is checked against a row we actually know.
        guard let target = Draft.firstMountedRow(in: app) else {
            return XCTFail("accepted draft has no mounted row")
        }
        let sibling = Draft.mountedRows(in: app).first { $0.id != target.id }

        let replaceStart = Date()
        let replaced = Draft.replace(target, in: app, timeout: 120)
        let replaceMs = Int(Date().timeIntervalSince(replaceStart) * 1_000)
        print("E2E_REPLACE ms=\(replaceMs) outcome=\(replaced.outcome) slot=\(target.id) "
            + "before=\(target.title) after=\(replaced.newTitle ?? "-")")

        switch replaced.outcome {
        case .accepted:
            break
        case .liveProviderFailure(let message):
            failForLiveProvider(stage: "replace", message: message)
            return
        case .settledWithoutDraft, .timedOut:
            XCTFail("replacement gave neither a new title nor an error within 120 s for slot \(target.id)")
            return
        }
        guard let newTitle = replaced.newTitle else { return XCTFail("accepted replacement carried no title") }
        XCTAssertNotEqual(newTitle, target.title, "the targeted slot must show a different dish")
        XCTAssertTrue(
            Draft.titleElement(for: target.id, in: app).exists,
            "the replaced dish must keep its slot: the app preserves the row id across replacement"
        )
        if let sibling {
            let siblingNow = Draft.locateTitle(for: sibling.id, in: app)
            XCTAssertEqual(siblingNow?.label, sibling.title, "an untargeted dish must survive replacement untouched")
        }

        // 3. Save: only now may the draft become canonical recipes.
        let save = app.buttons["planner.menu.save"]
        XCTAssertTrue(Draft.scroll(to: save, in: app), "save action never became reachable")
        save.tap()
        XCTAssertTrue(
            app.buttons["planner.shopping.open"].waitForExistence(timeout: 20),
            "saving did not produce a canonical menu"
        )
        XCTAssertFalse(
            Draft.titleElement(for: target.id, in: app).exists,
            "the draft slot must be gone once the menu is canonical"
        )
        // What is known to be on the saved menu: the dish we put there, and
        // the one we watched survive. Enough to prove persistence without
        // pretending to know the whole list.
        let knownSaved = [newTitle] + (sibling.map { [$0.title] } ?? [])

        // 4. Back to the planner, then terminate and relaunch: the menu is
        //    persisted state, not view state.
        app.navigationBars["朋友聚餐"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = []   // no seeding: prove it came off disk
        app.launch()
        openSeededPlan(in: app)
        for name in knownSaved {
            let dish = app.staticTexts[name]
            XCTAssertTrue(Draft.scroll(to: dish, in: app), "\(name) did not survive a relaunch")
        }
        print("E2E_REOPEN survived=\(knownSaved.joined(separator: " | "))")

        // 5. Shopping preview reads the accepted recipes.
        let shopping = app.buttons["planner.shopping.open"]
        XCTAssertTrue(Draft.scroll(to: shopping, in: app), "shopping action never became reachable")
        shopping.tap()
        let addToList = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "加入买菜清单（")
        ).firstMatch
        XCTAssertTrue(addToList.waitForExistence(timeout: 30), "shopping preview never opened")
        print("E2E_SHOPPING action=\(addToList.label)")

        // 6. Confirming must switch to the shopping list without crashing —
        //    the regression that the earlier crash fix addressed.
        addToList.tap()
        let imported = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "shopping.section.")
        ).firstMatch
        XCTAssertTrue(imported.waitForExistence(timeout: 20), "confirming shopping crashed or stalled")
        print("E2E_SHOPPING_CONFIRMED ok=true")
    }
}
