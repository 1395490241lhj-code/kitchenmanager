import XCTest

/// AI menu workspace states: empty -> generate -> draft -> replace -> save,
/// plus the shopping preview and the error path.
///
/// The AI transport is stubbed in-app by a DEBUG-only launch argument, so these
/// never make a network call and the menu content is deterministic.
final class SpecialPlanMenuUITests: XCTestCase {
    private func launchWithEmptyMenu(_ extra: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "UITEST_SEED_SPECIAL_PLAN",
            "UITEST_SEED_SPECIAL_PLAN_EMPTY_MENU"
        ] + extra
        app.launch()
        return app
    }

    private func openSeededPlanDetail(from app: XCUIApplication) {
        // The canonical route, which is also the only one: Planner is its own
        // tab, reachable in one tap on every day regardless of what today holds.
        let planTab = app.tabBars.buttons["计划"]
        XCTAssertTrue(planTab.waitForExistence(timeout: 10), "计划 tab missing")
        planTab.tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 5), "planner did not open")

        // Narrowed to buttons: the row is a NavigationLink. A descendants(.any)
        // predicate scan over the whole week view is slow enough to time out.
        let card = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "planner.special.entry.")
        ).firstMatch
        var attempts = 0
        while !card.exists && attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(card.waitForExistence(timeout: 5), "seeded special plan row missing")
        for _ in 0..<4 where !card.isHittable { app.swipeUp() }
        card.tap()
        XCTAssertTrue(app.navigationBars["朋友聚餐"].waitForExistence(timeout: 5))
    }

    private func draftRows(in app: XCUIApplication) -> XCUIElementQuery {
        // Leaf identifiers, one per draft dish title. A container-level id
        // would swallow the per-dish action buttons, so the title carries it.
        app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "planner.menu.draft.dish.")
        )
    }

    /// A six-dish menu pushes the actions below the fold of the lazy List,
    /// where they are absent from the AX tree until scrolled into view.
    @discardableResult
    private func scrollUntilExists(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        var remaining = 6
        while !element.exists && remaining > 0 {
            app.swipeUp()
            remaining -= 1
        }
        return element.waitForExistence(timeout: 5)
    }

    private func scrollUpUntilExists(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        var remaining = 6
        while !element.exists && remaining > 0 {
            app.swipeDown()
            remaining -= 1
        }
        return element.waitForExistence(timeout: 5)
    }

    private func tapSave(in app: XCUIApplication) {
        let save = app.buttons["planner.menu.save"]
        scrollUntilExists(save, in: app)
        save.tap()
    }


    /// Spec 20 + 21 + 22: an empty plan offers generation, shows a loading
    /// state, and lands on a draft.
    func testEmptyPlanGeneratesADraftMenu() {
        let app = launchWithEmptyMenu("UITEST_SPECIAL_PLAN_AI_MENU")
        openSeededPlanDetail(from: app)

        let generate = app.buttons["planner.menu.generate"]
        XCTAssertTrue(generate.waitForExistence(timeout: 5), "generate action missing on an empty menu")
        XCTAssertTrue(
            generate.label.contains("AI 帮我设计菜单"),
            "an empty plan must offer the design action, got: \(generate.label)"
        )
        generate.tap()

        // The stub delays deliberately so the loading row is observable.
        let loading = app.descendants(matching: .any)["planner.menu.generating"]
        XCTAssertTrue(loading.waitForExistence(timeout: 3), "loading state never appeared")

        XCTAssertTrue(
            app.staticTexts["红烧牛腩"].waitForExistence(timeout: 10),
            "draft menu never appeared"
        )
        // Six rows no longer fit one screen and a lazy List mounts only what
        // is visible, so the count is checked by scrolling to the last dish.
        XCTAssertTrue(scrollUntilExists(app.staticTexts["白灼菜心"], in: app), "the 7-person seed asks for six dishes; the sixth is missing")
        XCTAssertTrue(scrollUntilExists(app.buttons["planner.menu.save"], in: app), "save action missing on a draft")
    }

    /// Spec 23: replacing one dish changes only that dish.
    func testReplacingOneDraftDishLeavesTheOthers() {
        let app = launchWithEmptyMenu("UITEST_SPECIAL_PLAN_AI_MENU")
        openSeededPlanDetail(from: app)
        app.buttons["planner.menu.generate"].tap()
        XCTAssertTrue(app.staticTexts["红烧牛腩"].waitForExistence(timeout: 10))

        let replace = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "planner.menu.draft.replace.")
        ).firstMatch
        XCTAssertTrue(replace.waitForExistence(timeout: 5), "replace action missing")
        replace.tap()

        // The stub answers a single-dish request with 清蒸鲈鱼.
        XCTAssertTrue(
            app.staticTexts["清蒸鲈鱼"].waitForExistence(timeout: 10),
            "the replacement dish never appeared"
        )
        XCTAssertFalse(app.staticTexts["红烧牛腩"].exists, "the targeted dish should be gone")
        XCTAssertTrue(app.staticTexts["蒜蓉虾"].exists, "sibling dishes must be untouched")
        XCTAssertTrue(app.staticTexts["凉拌黄瓜"].exists, "sibling dishes must be untouched")
        XCTAssertTrue(scrollUntilExists(app.staticTexts["白灼菜心"], in: app), "replacement must not change the dish count")
    }

    /// Spec 24 + 25 + 26: saving turns the draft canonical, the菜单 survives
    /// leaving and reopening the detail, and the shopping preview opens.
    func testSavingTheMenuMakesItCanonicalAndOffersShopping() {
        let app = launchWithEmptyMenu("UITEST_SPECIAL_PLAN_AI_MENU")
        openSeededPlanDetail(from: app)
        app.buttons["planner.menu.generate"].tap()
        XCTAssertTrue(app.staticTexts["红烧牛腩"].waitForExistence(timeout: 10))

        tapSave(in: app)

        // The draft section is replaced by the canonical menu.
        XCTAssertTrue(
            scrollUntilExists(app.buttons["planner.shopping.open"], in: app),
            "shopping preview action missing after save"
        )
        XCTAssertEqual(draftRows(in: app).count, 0, "the draft must be cleared after saving")
        XCTAssertTrue(scrollUpUntilExists(app.staticTexts["红烧牛腩"], in: app), "saved dish missing from the canonical menu")

        // Leave and reopen: the menu is persisted, not view state.
        app.navigationBars["朋友聚餐"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 5))
        let card = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "planner.special.entry.")
        ).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        XCTAssertTrue(app.navigationBars["朋友聚餐"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["红烧牛腩"].waitForExistence(timeout: 5),
            "the saved menu must survive reopening the detail"
        )

        // No per-dish servings control anywhere on the saved menu.
        XCTAssertEqual(app.steppers.count, 0, "the rejected per-dish servings UI must not return")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "调整份量")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "本次份量")).firstMatch.exists)

        // The shopping preview reuses the existing generation screen. The stub
        // writes 主料 200 克 per dish; six dishes as written are 1200, never
        // 7-person maths.
        scrollUntilExists(app.buttons["planner.shopping.open"], in: app)
        app.buttons["planner.shopping.open"].tap()
        XCTAssertTrue(app.textFields["主料"].waitForExistence(timeout: 10), "shopping preview did not open")
        let quantities = app.textFields.allElementsBoundByIndex
            .compactMap { $0.value as? String }
            .map { $0.filter(\.isNumber) }
        XCTAssertTrue(quantities.contains("1200"), "as-written total expected; saw \(quantities)")

        let add = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "加入买菜清单（")
        ).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "shopping confirmation action missing")
        add.tap()
        let imported = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "shopping.section.")
        ).firstMatch
        XCTAssertTrue(
            imported.waitForExistence(timeout: 10),
            "confirming generated shopping items must switch tabs without crashing"
        )
    }

    /// Spec 27: a failed generation surfaces an error and keeps the saved menu.
    func testGenerationErrorKeepsTheExistingMenu() {
        // Seeded *with* its canonical two dishes, so the failure has something
        // to preserve.
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_SEED_SPECIAL_PLAN", "UITEST_SPECIAL_PLAN_AI_FAILURE"]
        app.launch()
        openSeededPlanDetail(from: app)

        XCTAssertTrue(app.staticTexts["麻婆豆腐"].exists, "seeded dish missing")

        let generate = app.buttons["planner.menu.generate"]
        XCTAssertTrue(generate.waitForExistence(timeout: 5))
        generate.tap()

        let error = app.descendants(matching: .any)["planner.menu.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10), "error state never appeared")
        // The canonical menu is still intact and the plan was not mutated.
        XCTAssertTrue(app.staticTexts["麻婆豆腐"].exists, "a failed generation must keep the saved menu")
        XCTAssertTrue(app.staticTexts["番茄炒鸡蛋"].exists, "a failed generation must keep the saved menu")
        XCTAssertEqual(draftRows(in: app).count, 0, "a failed generation must not leave a draft")
    }

    /// A mounted title can be partly visible while its separate action is
    /// off screen. Protect viewport reachability and stable slot replacement,
    /// not SwiftUI's incidental decision to keep an AX node mounted.
    func testReplacingAnOffScreenDishIsObservedByItsOwnRow() {
        let app = launchWithEmptyMenu("UITEST_SPECIAL_PLAN_AI_MENU",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryLarge")
        openSeededPlanDetail(from: app)
        app.buttons["planner.menu.generate"].tap()
        XCTAssertEqual(SpecialPlanDraftObservation.waitForGeneration(in: app, timeout: 15), .accepted)
        let last = app.staticTexts["白灼菜心"]
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        let identifier = last.identifier
        XCTAssertTrue(identifier.hasPrefix(SpecialPlanDraftObservation.dishPrefix))
        let slot = String(identifier.dropFirst(SpecialPlanDraftObservation.dishPrefix.count))
        let key = SpecialPlanDraftObservation.replacePrefix + slot
        let others = SpecialPlanDraftObservation.mountedRows(in: app).filter { $0.id != slot }
        XCTAssertTrue(others.contains { $0.title == "红烧牛腩" })
        var trace: [String] = []
        defer {
            let attachment = XCTAttachment(string: trace.joined(separator: "\n"))
            attachment.name = "offscreen-slot-geometry"; attachment.lifetime = .keepAlways; add(attachment)
        }
        func viewport() -> CGRect {
            let frame = app.collectionViews.firstMatch.frame.intersection(app.windows.firstMatch.frame)
            let top = max(frame.minY, app.navigationBars["朋友聚餐"].frame.maxY)
            return CGRect(x: frame.minX, y: top, width: frame.width, height: frame.maxY - top)
        }
        func record(_ stage: String) {
            let row = app.collectionViews.firstMatch.cells.containing(.button, identifier: key).firstMatch
            let button = app.buttons[key]
            trace.append("\(stage) id=\(key) cell=\(row.frame) button=\(button.frame) hittable=\(button.isHittable) viewport=\(viewport())")
        }
        record("initial")
        let initialFrame = app.buttons[key].frame
        XCTAssertFalse(initialFrame.isEmpty)
        let offscreen = !initialFrame.intersects(viewport())
        trace.append("initialActionOffscreen=\(offscreen)")
        guard offscreen else { XCTFail("fixture's replace action must start outside viewport"); return }

        // Fresh queries and measured direction after every List-contained drag.
        // No assumption about AX unmounting, safe-area insets or fixed swipes.
        var seen = Set<String>()
        let revealDeadline = Date().addingTimeInterval(20)
        while true {
            guard app.navigationBars["朋友聚餐"].exists else { XCTFail("detail sheet lost"); return }
            let list = app.collectionViews.firstMatch
            let button = app.buttons[key]
            let frame = button.frame
            let visible = viewport()
            guard button.exists, !frame.isEmpty else { XCTFail("slot control lost"); return }
            if visible.contains(frame), button.isHittable, button.isEnabled { break }
            let signature = "\(Int(frame.minY))|\(Int(frame.maxY))"
            guard seen.insert(signature).inserted, Date() < revealDeadline else {
                XCTFail("reveal made no progress or exceeded 20s"); return
            }
            let margin = min(80, visible.height / 4)
            let limit = visible.height - 2 * margin
            let delta = max(-limit, min(limit, frame.midY - visible.midY))
            let y = delta > 0 ? visible.maxY - margin : visible.minY + margin
            let origin = list.coordinate(withNormalizedOffset: .zero)
            let x = visible.midX - list.frame.minX
            origin.withOffset(CGVector(dx: x, dy: y - list.frame.minY)).press(forDuration: 0.1,
                thenDragTo: origin.withOffset(CGVector(dx: x, dy: y - list.frame.minY - delta)),
                withVelocity: .slow, thenHoldForDuration: 0.1)
            record("after drag")
        }
        record("revealed")
        let button = app.buttons[key]
        XCTAssertTrue(viewport().contains(CGPoint(x: button.frame.midX, y: button.frame.midY)))
        XCTAssertEqual(app.staticTexts[identifier].label, "白灼菜心")
        let started = Date()
        button.tap()
        let title = app.staticTexts[identifier]
        let remaining = max(0, 20 - Date().timeIntervalSince(started))
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "清蒸鲈鱼"), object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: remaining), .completed)
        let duration = Date().timeIntervalSince(started)
        trace.append("result=\(title.label) identifier=\(title.identifier) observationSeconds=\(duration)")
        XCTAssertEqual(title.identifier, identifier)
        XCTAssertEqual(title.label, "清蒸鲈鱼")
        XCTAssertLessThan(duration, 20)
        XCTAssertTrue(app.navigationBars["朋友聚餐"].exists, "detail sheet must survive replacement")
        for other in others {
            XCTAssertEqual(SpecialPlanDraftObservation.titleElement(for: other.id, in: app).label, other.title,
                           "untargeted slot must remain unchanged")
        }
    }
}
