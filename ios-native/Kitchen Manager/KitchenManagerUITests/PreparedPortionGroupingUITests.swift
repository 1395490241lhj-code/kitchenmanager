import XCTest

final class PreparedPortionGroupingUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func openList(_ app: XCUIApplication) {
        if app.buttons["prepared.add.button"].exists && app.buttons["prepared.add.button"].isHittable { return }
        let entry = app.buttons["home.mealPrep.add"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.tap()
        XCTAssertTrue(app.buttons["prepared.add.button"].waitForExistence(timeout: 5))
    }
    func testAddShowsExactRoundingPreview() {
        let app = XCUIApplication()
        app.launchArguments = ["UITEST_PREPARED_RELIABILITY", "UITEST_FORCE_MEAL_PREP_DAY"]
        app.launch(); openList(app); app.buttons["prepared.add.button"].tap()
        let mass = app.textFields["prepared.editor.mass"]
        XCTAssertTrue(mass.waitForExistence(timeout: 5), "existing add flow must offer optional grams")
        app.textFields["prepared.editor.name"].tap(); app.textFields["prepared.editor.name"].typeText("鸡肉")
        mass.tap(); mass.typeText("100")
        let decrement = app.buttons["prepared.editor.portions-Decrement"]
        XCTAssertGreaterThanOrEqual(decrement.frame.height.rounded(), 44, "portion control hit target")
        decrement.tap()
        let preview = app.staticTexts["prepared.editor.allocation"]
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        XCTAssertTrue(preview.label.contains("33.4g")); XCTAssertTrue(preview.label.contains("33.3g"))
        capture(app, "prepared-rounding-preview-light")
    }
    private let firstID = "88000000-0000-0000-0000-000000000001"
    private let secondID = "88000000-0000-0000-0000-000000000002"
    private let legacyID = "88000000-0000-0000-0000-000000000003"
    private let sourceID = "88000000-0000-0000-0000-000000000100"
    private let session = UUID().uuidString
    private let failure = "备餐记录保存失败，请稍后重试。"

    private func launch(seed: Bool = false, extra: [String] = [], app: XCUIApplication = XCUIApplication()) -> XCUIApplication {
        app.launchArguments = ["UITEST_PREPARED_GROUPING"] + extra
        if !extra.contains("UITEST_FORCE_QUICK_DAY") { app.launchArguments.append("UITEST_FORCE_MEAL_PREP_DAY") }
        if seed { app.launchArguments.append("UITEST_GROUPED_SEED_LINKED") }
        app.launchEnvironment["PREPARED_GROUPING_SESSION"] = session
        app.launch()
        return app
    }
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func reach(_ app: XCUIApplication, _ item: XCUIElement, line: UInt = #line) {
        for up in [true, false] {
            for _ in 0..<7 {
                if item.exists && item.isHittable { return }
                if up { app.swipeUp() } else { app.swipeDown() }
            }
        }
        XCTAssertTrue(item.exists && item.isHittable, "control must be reachable", line: line)
    }
    private func replace(_ field: XCUIElement, _ text: String) {
        field.tap()
        let current = field.value as? String ?? ""
        if !current.isEmpty, current != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
    }
    private func done(_ app: XCUIApplication) {
        let button = app.buttons["prepared.editor.keyboardDone"]
        if button.exists && button.isHittable { button.tap() }
    }
    private func add(_ app: XCUIApplication, name: String = "鸡肉", mass: String = "800") {
        app.buttons["prepared.add.button"].tap()
        let field = app.textFields["prepared.editor.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 3)); replace(field, name)
        replace(app.textFields["prepared.editor.mass"], mass); done(app)
    }
    private func assert44(_ button: XCUIElement, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(button.frame.height.rounded(), 44, line: line)
        XCTAssertGreaterThanOrEqual(button.frame.width.rounded(), 44, line: line)
    }
    private func assertSuccess(_ app: XCUIApplication, _ message: String) {
        let toast = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "成功：" + message)).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 2))
    }
    private func waitForEditorPresentation(_ app: XCUIApplication) {
        let bar = app.navigationBars["编辑备餐"]
        var lastFrame = CGRect.zero
        var stableSince = ProcessInfo.processInfo.systemUptime
        let settled = NSPredicate { _, _ in
            guard bar.exists else { return false }
            let frame = bar.frame
            if frame != lastFrame { lastFrame = frame; stableSince = ProcessInfo.processInfo.systemUptime }
            return frame.minY < app.frame.height / 4 && ProcessInfo.processInfo.systemUptime - stableSince >= 0.5
        }
        expectation(for: settled, evaluatedWith: bar)
        waitForExpectations(timeout: 5)
    }
    private func showFully(_ app: XCUIApplication, _ item: XCUIElement) {
        for _ in 0..<8 {
            let top = app.navigationBars.firstMatch.frame.maxY + 8
            let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY - 8 : app.frame.maxY - 40
            if item.exists, item.frame.minY >= top, item.frame.maxY <= bottom { return }
            // Same measured, slow-drag pattern as the Planner/Shopping regressions.
            // Full-screen flings can skip a tall Dynamic Type header in both directions.
            let limit = (bottom - top) * 0.6
            let delta = item.exists ? max(-limit, min(limit, item.frame.midY - (top + bottom) / 2)) : limit
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let y = delta >= 0 ? bottom - 20 : top + 20
            origin.withOffset(CGVector(dx: app.frame.midX, dy: y)).press(forDuration: 0.1,
                thenDragTo: origin.withOffset(CGVector(dx: app.frame.midX, dy: y - delta)),
                withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTFail("Target did not fit the safe viewport: \(item.debugDescription)")
    }
    private func save(_ app: XCUIApplication) {
        let save = app.buttons["prepared.editor.save"]
        XCTAssertTrue(save.isEnabled); save.tap()
        XCTAssertTrue(app.buttons["prepared.add.button"].waitForExistence(timeout: 5))
    }
    private func dismissFailure(_ app: XCUIApplication, name: String) {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3)); XCTAssertTrue(alert.staticTexts[failure].exists)
        capture(app, name); alert.buttons["好"].tap()
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "成功：")).firstMatch.exists)
    }
    private func rowIDs(_ app: XCUIApplication) -> [String] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "prepared.edit.")).allElementsBoundByIndex.map {
            String($0.identifier.dropFirst("prepared.edit.".count))
        }
    }
    private func delete(_ app: XCUIApplication, id: String) {
        let edit = app.buttons["prepared.edit." + id]; reach(app, edit)
        let cell = app.cells.containing(.button, identifier: "prepared.edit." + id).firstMatch
        XCTAssertTrue(cell.exists)
        // The title can be hittable while the swipe midpoint is under the native tab bar.
        let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : app.frame.maxY - 44
        for _ in 0..<5 {
            if cell.frame.maxY <= bottom - 8 { break }
            app.swipeUp()
        }
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.35)).press(forDuration: 0.05,
            thenDragTo: cell.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.35)))
        let action = app.buttons["prepared.delete." + id]
        XCTAssertTrue(action.waitForExistence(timeout: 3)); action.tap()
    }
    func testMeasuredCreateSplitEditConsumeRestartAndLegacyCreation() throws {
        let app = launch(); openList(app); add(app)
        XCTAssertTrue(app.staticTexts["prepared.editor.allocation"].label.contains("200g × 4份"))
        save(app)
        let original = try XCTUnwrap(rowIDs(app).first)
        let split = app.buttons["prepared.split." + original]; reach(app, split); split.tap()
        XCTAssertEqual(app.staticTexts["prepared.split.preview"].label, "原组保留3份；新组1份")
        app.buttons["prepared.split.save"].tap()
        XCTAssertTrue(app.buttons["prepared.add.button"].waitForExistence(timeout: 3))
        let ids = rowIDs(app); XCTAssertEqual(ids.count, 2); XCTAssertTrue(ids.contains(original))
        let sibling = try XCTUnwrap(ids.first { $0 != original })
        let edit = app.buttons["prepared.edit." + original]; reach(app, edit); edit.tap()
        XCTAssertFalse(app.textFields["prepared.editor.mass"].exists)
        XCTAssertFalse(app.buttons["prepared.editor.portions-Increment"].exists)
        XCTAssertFalse(element(app, "prepared.editor.state").exists)
        replace(app.textFields["prepared.editor.name"], "鸡肉改名"); done(app); save(app)
        let consume = app.buttons["prepared.consume." + sibling]; reach(app, consume); consume.tap()
        assertSuccess(app, "这组已用完")
        XCTAssertFalse(app.buttons["prepared.edit." + sibling].exists)
        let source = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "prepared.source.")).firstMatch
        reach(app, source); XCTAssertTrue(source.label.contains("600克")); XCTAssertTrue(source.label.contains("800克"))
        capture(app, "grouped-after-use-light")
        app.terminate(); _ = launch(app: app); openList(app)
        XCTAssertTrue(app.buttons["prepared.edit." + original].exists)
        XCTAssertFalse(app.buttons["prepared.edit." + sibling].exists)
        delete(app, id: original)
        XCTAssertTrue(app.staticTexts["还没有备餐"].waitForExistence(timeout: 3))
        add(app, name: "卤鸡腿", mass: ""); save(app)
        let legacy = try XCTUnwrap(rowIDs(app).first)
        XCTAssertFalse(app.staticTexts["prepared.mass." + legacy].exists)
        app.buttons["prepared.edit." + legacy].tap()
        XCTAssertTrue(app.buttons["prepared.editor.portions-Increment"].exists)
        XCTAssertTrue(element(app, "prepared.editor.state").exists)
        app.buttons["取消"].tap()
        delete(app, id: legacy); XCTAssertTrue(app.staticTexts["还没有备餐"].waitForExistence(timeout: 3))
    }
    func testBucketChangesValidationFailureAndMeasuredSaveRetryPreserveDraft() throws {
        let app = launch(extra: ["UITEST_GROUPED_FAIL_WRITE=1"]); openList(app); add(app, mass: "800")
        app.buttons["prepared.editor.portions-Decrement"].tap()
        replace(app.textFields["prepared.editor.mass"], "100"); done(app)
        XCTAssertTrue(app.staticTexts["prepared.editor.allocation"].label.contains("33.4g"))
        replace(app.textFields["prepared.editor.mass"], "100.01"); done(app)
        XCTAssertFalse(app.buttons["prepared.editor.save"].isEnabled)
        XCTAssertTrue(app.staticTexts["prepared.editor.validation"].exists)
        capture(app, "grouped-invalid-precision-light")
        replace(app.textFields["prepared.editor.mass"], "800")
        app.buttons["prepared.editor.portions-Increment"].tap(); done(app)
        XCTAssertTrue(app.staticTexts["prepared.editor.allocation"].label.contains("200g × 4份"))
        replace(app.textFields["prepared.editor.mass"], "100")
        app.buttons["prepared.editor.portions-Decrement"].tap(); done(app)
        app.buttons["prepared.editor.save"].tap(); dismissFailure(app, name: "grouped-add-failure-light")
        XCTAssertEqual(app.textFields["prepared.editor.name"].value as? String, "鸡肉")
        XCTAssertEqual(app.textFields["prepared.editor.mass"].value as? String, "100")
        save(app)
        XCTAssertEqual(rowIDs(app).count, 2)
        capture(app, "grouped-rounding-list-light")
        app.terminate(); _ = launch(app: app); openList(app)
        XCTAssertEqual(rowIDs(app).count, 2)
    }
    func testSplitSaveFailureRetryThenDeleteOnlySelectedEqualNameSibling() throws {
        let app = launch(seed: true, extra: ["UITEST_GROUPED_FAIL_WRITE=1"]); openList(app)
        let split = app.buttons["prepared.split." + firstID]; reach(app, split); split.tap()
        app.buttons["prepared.split.save"].tap(); dismissFailure(app, name: "grouped-split-failure")
        XCTAssertEqual(app.staticTexts["prepared.split.preview"].label, "原组保留1份；新组1份")
        app.buttons["prepared.split.save"].tap()
        XCTAssertTrue(app.buttons["prepared.add.button"].waitForExistence(timeout: 3))
        delete(app, id: secondID)
        XCTAssertFalse(app.buttons["prepared.edit." + secondID].exists)
        reach(app, app.buttons["prepared.edit." + firstID])
        XCTAssertTrue(app.buttons["prepared.edit." + firstID].exists)
        reach(app, app.buttons["prepared.edit." + legacyID])
        XCTAssertTrue(app.buttons["prepared.edit." + legacyID].exists)
        capture(app, "grouped-selected-delete-keeps-siblings")
    }
    func testGroupedEditFailureAndStaleRecheckKeepEnteredName() throws {
        let app = launch(seed: true, extra: ["UITEST_GROUPED_FAIL_WRITE=1", "UITEST_GROUPED_STALE_EDIT"]); openList(app)
        let edit = app.buttons["prepared.edit." + firstID]; reach(app, edit); edit.tap()
        replace(app.textFields["prepared.editor.name"], "保留的改名"); done(app)
        app.buttons["prepared.editor.save"].tap(); dismissFailure(app, name: "grouped-edit-failure")
        XCTAssertEqual(app.textFields["prepared.editor.name"].value as? String, "保留的改名")
        let change = app.buttons["prepared.editor.fixture.consume"]; reach(app, change); change.tap()
        app.buttons["prepared.editor.save"].tap()
        let stale = app.alerts.firstMatch
        XCTAssertTrue(stale.waitForExistence(timeout: 3))
        XCTAssertTrue(stale.staticTexts["这条备餐记录已变更，这次修改没有保存。请重新打开后查看。"].exists)
        capture(app, "grouped-stale-error"); stale.buttons["好"].tap()
        let recheck = app.buttons["prepared.editor.recheck"]; reach(app, recheck)
        capture(app, "grouped-stale-recheck")
        recheck.tap()
        XCTAssertEqual(app.textFields["prepared.editor.name"].value as? String, "保留的改名")
        save(app)
        let updated = app.buttons["prepared.edit." + firstID]; reach(app, updated)
        XCTAssertTrue(updated.label.contains("保留的改名")); XCTAssertTrue(updated.label.contains("剩 1 份"))
    }
    func testUnavailableReloadStaysDistinctFromEmpty() {
        let app = launch(seed: true, extra: ["UITEST_GROUPED_UNREADABLE"]); openList(app)
        XCTAssertTrue(app.staticTexts["prepared.unavailable"].exists)
        XCTAssertFalse(app.buttons["prepared.add.button"].isEnabled)
        app.buttons["prepared.reload"].tap(); XCTAssertTrue(app.staticTexts["prepared.unavailable"].exists)
        capture(app, "grouped-unavailable-reload")
        app.buttons["prepared.reload"].tap()
        XCTAssertTrue(app.buttons["prepared.add.button"].isEnabled)
        XCTAssertFalse(app.staticTexts["prepared.unavailable"].exists)
    }
    private func appearance(dark: Bool, ax: Bool) -> XCUIApplication {
        var extra = dark ? ["UITEST_FORCE_DARK_APPEARANCE"] : []
        if ax { extra += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        let app = launch(seed: true, extra: extra); openList(app)
        let source = element(app, "prepared.source." + sourceID); showFully(app, source)
        capture(app, "grouped-list-\(dark ? "dark" : "light")-\(ax ? "axxxl" : "normal")")
        return app
    }
    func testAppearanceLightNormalAndGroupedReadOnlyEditor() {
        let app = appearance(dark: false, ax: false)
        let first = app.buttons["prepared.edit." + firstID]; reach(app, first)
        let firstLabel = first.label
        let second = app.buttons["prepared.edit." + secondID]; reach(app, second)
        XCTAssertNotEqual(firstLabel, second.label, "same-name groups must be distinguishable")
        second.tap(); waitForEditorPresentation(app)
        XCTAssertFalse(app.buttons["prepared.editor.portions-Increment"].exists)
        capture(app, "grouped-edit-light-normal")
    }
    func testAppearanceDarkNormalAndSplitSheet() {
        let app = appearance(dark: true, ax: false)
        let split = app.buttons["prepared.split." + firstID]; reach(app, split); assert44(split); split.tap()
        assert44(app.buttons["prepared.split.portions-Decrement"])
        assert44(app.buttons["prepared.split.portions-Increment"])
        capture(app, "grouped-split-dark-normal")
        app.buttons["取消"].tap()
    }
    func testAppearanceLightAXXXLControlsDoNotOverlapAndRemainReachable() {
        let app = appearance(dark: false, ax: true)
        let split = app.buttons["prepared.split." + firstID]; reach(app, split)
        let consume = app.buttons["prepared.consume." + firstID]
        assert44(split); assert44(consume)
        XCTAssertFalse(split.frame.intersects(consume.frame))
        XCTAssertTrue(split.label.contains("第1组")); XCTAssertTrue(consume.label.contains("鸡肉"))
        capture(app, "grouped-actions-light-axxxl")
        split.tap(); capture(app, "grouped-split-light-axxxl"); app.buttons["取消"].tap()
        let edit = app.buttons["prepared.edit." + firstID]; reach(app, edit); edit.tap(); waitForEditorPresentation(app)
        capture(app, "grouped-edit-light-axxxl")
        let protected = app.staticTexts["原记鸡肉，共800g、4份"]; showFully(app, protected)
        capture(app, "grouped-protected-light-axxxl")
        let date = element(app, "prepared.editor.expiry"); reach(app, date)
        capture(app, "grouped-dates-light-axxxl")
    }
    func testAppearanceDarkAXXXLAddValidationAndPreview() {
        let app = appearance(dark: true, ax: true)
        app.buttons["prepared.add.button"].tap()
        replace(app.textFields["prepared.editor.name"], "鸡肉")
        let mass = app.textFields["prepared.editor.mass"]; reach(app, mass); replace(mass, "800"); done(app)
        let preview = app.staticTexts["prepared.editor.allocation"]; reach(app, preview)
        XCTAssertTrue(preview.label.contains("200g × 4份")); capture(app, "grouped-add-dark-axxxl")
        reach(app, mass); replace(mass, "800.05"); done(app)
        XCTAssertFalse(app.buttons["prepared.editor.save"].isEnabled)
        let validation = app.staticTexts["prepared.editor.validation"]; reach(app, validation)
        capture(app, "grouped-invalid-dark-axxxl")
        app.buttons["取消"].tap()
        let massLabel = app.staticTexts["prepared.mass." + firstID]; showFully(app, massLabel)
        capture(app, "grouped-row-dark-axxxl")
        let edit = app.buttons["prepared.edit." + firstID]; reach(app, edit); edit.tap(); waitForEditorPresentation(app)
        let protected = app.staticTexts["原记鸡肉，共800g、4份"]; showFully(app, protected)
        capture(app, "grouped-protected-dark-axxxl")
    }

    func testVisibleRoundingBackupPreviewRestoreAndRestartPreserveGroupUUIDs() throws {
        let app = launch(); openList(app); add(app, mass: "100")
        app.buttons["prepared.editor.portions-Decrement"].tap(); save(app)
        let ids = rowIDs(app); XCTAssertEqual(ids.count, 2)
        app.terminate(); _ = launch(extra: ["UITEST_GROUPED_STAGE_RECOVERY"], app: app); openList(app)
        delete(app, id: ids[0])
        XCTAssertFalse(app.buttons["prepared.edit." + ids[0]].exists)
        app.tabBars.buttons["我的"].tap()
        let backup = element(app, "settings.backup.link"); reach(app, backup); backup.tap()
        let restore = app.buttons["backup.recovery.restore"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5)); restore.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["用副本恢复"].waitForExistence(timeout: 3))
        capture(app, "grouped-restore-preview")
        let allocations = app.staticTexts["prepared.restore.allocations"]
        reach(app, allocations)
        XCTAssertTrue(allocations.label.contains("33.4g")); XCTAssertTrue(allocations.label.contains("33.3g"))
        capture(app, "grouped-restore-allocation-detail")
        let confirm = app.buttons["restorePreview.confirm"]; reach(app, confirm); confirm.tap()
        app.buttons["替换"].tap()
        XCTAssertTrue(app.alerts["数据已恢复"].waitForExistence(timeout: 5)); app.alerts["数据已恢复"].buttons["好"].tap()
        let today = app.tabBars.buttons["今天"]
        if !today.exists || !today.isHittable { app.tabBars.buttons["我的"].tap() }
        if !today.waitForExistence(timeout: 3) { app.swipeDown() }
        XCTAssertTrue(today.waitForExistence(timeout: 3)); today.tap(); openList(app)
        XCTAssertEqual(Set(rowIDs(app)), Set(ids))
        capture(app, "grouped-restored-visible")
        app.terminate(); _ = launch(app: app); openList(app)
        XCTAssertEqual(Set(rowIDs(app)), Set(ids))
        let masses = ids.map { app.staticTexts["prepared.mass." + $0].label }
        XCTAssertTrue(masses.contains { $0.contains("33.4") }); XCTAssertTrue(masses.contains { $0.contains("33.3") })
    }

    func testGroupedDeleteAndConsumeFailuresRetainRowsUntilRetryAndFinalUseRemovesSource() {
        let app = launch(seed: true, extra: ["UITEST_GROUPED_FAIL_WRITE=1"]); openList(app)
        delete(app, id: secondID); dismissFailure(app, name: "grouped-delete-failure")
        reach(app, app.buttons["prepared.edit." + secondID]); XCTAssertTrue(app.buttons["prepared.edit." + secondID].exists)
        delete(app, id: secondID); XCTAssertFalse(app.buttons["prepared.edit." + secondID].exists)
        app.terminate(); _ = launch(extra: ["UITEST_GROUPED_FAIL_WRITE=1"], app: app); openList(app)
        let use = app.buttons["prepared.consume." + firstID]; reach(app, use); use.tap()
        dismissFailure(app, name: "grouped-consume-failure")
        let edit = app.buttons["prepared.edit." + firstID]; reach(app, edit)
        XCTAssertTrue(edit.label.contains("剩 2 份"))
        reach(app, use); use.tap()
        XCTAssertTrue(edit.label.contains("剩 1 份"))
        use.tap(); XCTAssertFalse(edit.exists)
        XCTAssertFalse(element(app, "prepared.source." + sourceID).exists)
        reach(app, app.buttons["prepared.edit." + legacyID]); XCTAssertTrue(app.buttons["prepared.edit." + legacyID].exists)
        XCTAssertFalse(app.buttons["撤销"].exists)
    }
    func testCancelAddAndSplitDoesNotPersistDraft() {
        let app = launch(); openList(app); add(app)
        app.buttons["取消"].tap()
        XCTAssertTrue(app.staticTexts["还没有备餐"].waitForExistence(timeout: 3))
        add(app); save(app)
        let original = rowIDs(app).first!
        app.buttons["prepared.split." + original].tap()
        app.buttons["prepared.split.portions-Increment"].tap()
        app.buttons["取消"].tap()
        XCTAssertEqual(rowIDs(app), [original])
        XCTAssertTrue(app.buttons["prepared.edit." + original].label.contains("剩 4 份"))
    }

    func testQuickMealShowsRoundingGroupAndConsumesLiveUUIDThenSibling() {
        let app = launch(extra: ["UITEST_GROUPED_SEED_RECOMMENDATION", "UITEST_FORCE_QUICK_DAY"])
        let first = app.buttons["home.quickMeal.usePrepared." + firstID]
        XCTAssertTrue(first.waitForExistence(timeout: 10)); reach(app, first); assert44(first)
        XCTAssertTrue(first.label.contains("33.4克")); XCTAssertTrue(first.label.contains("第1组"))
        XCTAssertTrue(first.label.contains("冷藏"))
        capture(app, "grouped-quick-usage-rounding-before")
        first.tap()
        assertSuccess(app, "这组已用完")
        capture(app, "grouped-quick-success-group-scope")
        let sibling = app.buttons["home.quickMeal.usePrepared." + secondID]
        XCTAssertTrue(sibling.waitForExistence(timeout: 5)); reach(app, sibling)
        XCTAssertFalse(first.exists); XCTAssertTrue(sibling.label.contains("33.3克"))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.quickMeal.usePrepared.")).count, 1)
        capture(app, "grouped-quick-usage-rounding-after")
        sibling.tap()
        assertSuccess(app, "这组还剩 1 份")
        XCTAssertTrue(sibling.waitForExistence(timeout: 3))
        let usage = element(app, "home.quickMeal.prepared." + secondID)
        XCTAssertTrue(usage.label.contains("备餐剩 1 份"))
    }

    func testComponentMealAXXXLShowsLinkedContextAndLiveConsumption() {
        let app = launch(extra: ["UITEST_GROUPED_SEED_RECOMMENDATION", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        openList(app); app.buttons["prepared.assemble"].tap()
        let first = app.buttons["componentMeal.usePrepared." + firstID]
        XCTAssertTrue(first.waitForExistence(timeout: 5)); reach(app, first); assert44(first)
        XCTAssertTrue(first.label.contains("33.4克")); XCTAssertTrue(first.label.contains("第1组"))
        let label = element(app, "componentMeal.prepared." + firstID)
        XCTAssertFalse(first.frame.intersects(label.frame))
        capture(app, "grouped-component-usage-axxxl")
        first.tap()
        assertSuccess(app, "这组已用完")
        capture(app, "grouped-component-success-group-scope")
        let sibling = app.buttons["componentMeal.usePrepared." + secondID]
        XCTAssertTrue(sibling.waitForExistence(timeout: 5)); reach(app, sibling)
        XCTAssertFalse(first.exists); XCTAssertTrue(sibling.label.contains("33.3克"))
        capture(app, "grouped-component-usage-sibling-axxxl")
    }

}
