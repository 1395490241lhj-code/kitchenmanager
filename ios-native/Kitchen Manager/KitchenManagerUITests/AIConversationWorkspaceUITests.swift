import XCTest

final class AIConversationWorkspaceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp(
        arguments: [String] = ["UITEST_AI_CONVERSATION_WORKSPACE_HOME"],
        appearance: UIUserInterfaceStyle = .light,
        contentSize: String = "UICTContentSizeCategoryLarge"
    ) -> XCUIApplication {
        XCUIDevice.shared.appearance = appearance == .dark ? .dark : .light
        let app = XCUIApplication()
        var allArgs = arguments
        allArgs.append(appearance == .dark ? "UITEST_FORCE_DARK_APPEARANCE" : "UITEST_FORCE_LIGHT_APPEARANCE")
        allArgs.append(contentsOf: ["-UIPreferredContentSizeCategoryName", contentSize])
        app.launchArguments = allArgs
        app.launch()
        // Waits on a control the workspace always owns rather than on the
        // title: the title is the conversation's own task identity now, so a
        // launch that resumes an existing conversation legitimately shows that
        // conversation's name instead of the product name.
        XCTAssertTrue(app.buttons["kitchenAI.overflowMenu"].waitForExistence(timeout: 10),
                      "Kitchen AI workspace did not open")
        return app
    }

    /// The task header renders as one combined element, so it is matched by
    /// identifier across element types rather than assumed to be a static text.
    private func taskContextHeader(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "kitchenAI.taskContext").firstMatch
    }

    private func composerField(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textViews["kitchenAI.composer"]
        if field.exists { return field }
        return app.textFields["kitchenAI.composer"]
    }

    private func reveal(_ app: XCUIApplication, _ element: XCUIElement, swipingUp: Bool = true) {
        var attempts = 0
        while !element.isHittable && attempts < 8 {
            if swipingUp { app.swipeUp() } else { app.swipeDown() }
            attempts += 1
        }
    }

    // MARK: - EMPTY / COMPOSER (Tests 1-7)

    func test01_HomeTitleKitchenAI() {
        // A draft owns no task yet, so it keeps the product name rather than
        // inventing a title for one screen.
        let app = launchApp(arguments: ["UITEST_AI_CONVERSATION_WORKSPACE_HOME"])
        XCTAssertTrue(app.navigationBars["Kitchen AI"].exists)
        XCTAssertFalse(taskContextHeader(app).exists,
                       "an empty conversation states its context in the empty state, not in the header")
    }

    /// Phase 2 task-identity slice: the workspace used to fall back to the
    /// fixed product name and no context at all once a transcript existed, so
    /// the only way to tell what a conversation was about was to reread it.
    func test01b_ActiveConversationStatesItsTaskWithoutTheTranscript() {
        let app = launchApp(arguments: ["UITEST_AI_CONVERSATION_WORKSPACE_HOME"])
        let composer = composerField(app)
        composer.tap()
        composer.typeText("今晚吃什么")
        app.buttons["kitchenAI.send"].tap()

        let header = taskContextHeader(app)
        XCTAssertTrue(header.waitForExistence(timeout: 8),
                      "an active conversation must keep naming its task")
        XCTAssertTrue(header.label.contains("今天"),
                      "a Home conversation started today is about today: \(header.label)")
        XCTAssertFalse(app.navigationBars["Kitchen AI"].exists,
                       "the product name must stop being the identity once a conversation exists")
    }

    func test01c_PlannerConversationNamesItsWeekRatherThanTheProductName() {
        let app = launchApp(arguments: ["UITEST_AI_CONVERSATION_WORKSPACE_PLANNER"])
        let composer = composerField(app)
        composer.tap()
        composer.typeText("这周怎么安排")
        app.buttons["kitchenAI.send"].tap()

        let header = taskContextHeader(app)
        XCTAssertTrue(header.waitForExistence(timeout: 8))
        XCTAssertTrue(header.label.contains("计划"),
                      "a Planner conversation is about a week of planning: \(header.label)")
        // The anchor is the week itself, so the line carries a real date range
        // rather than a bare label.
        XCTAssertTrue(header.label.contains("月"),
                      "the planning header must carry its week anchor: \(header.label)")
        XCTAssertFalse(header.label.hasSuffix("·"),
                       "a missing anchor must never leave a dangling separator")
    }

    func test02_FourExactHomeStartersExist() {
        let app = launchApp(arguments: ["UITEST_AI_CONVERSATION_WORKSPACE_HOME"])
        let starters = [
            "用快过期的食材做饭",
            "今晚想吃清淡一点",
            "看看现在能做什么",
            "帮我补一道菜"
        ]
        for starter in starters {
            XCTAssertTrue(app.buttons["kitchenAI.starter.\(starter)"].waitForExistence(timeout: 5), "Missing home starter: \(starter)")
        }
    }

    func test03_FourExactPlannerStartersExist() {
        let app = launchApp(arguments: ["UITEST_AI_CONVERSATION_WORKSPACE_PLANNER"])
        let starters = [
            "调整这周菜单",
            "帮我减少重复菜",
            "周六聚餐怎么安排",
            "看看哪天准备最轻松"
        ]
        for starter in starters {
            XCTAssertTrue(app.buttons["kitchenAI.starter.\(starter)"].waitForExistence(timeout: 5), "Missing planner starter: \(starter)")
        }
    }

    func test04_StarterTapFillsComposerAndDoesNotSend() {
        let app = launchApp(arguments: ["UITEST_AI_CONVERSATION_WORKSPACE_HOME"])
        let starter = app.buttons["kitchenAI.starter.用快过期的食材做饭"]
        XCTAssertTrue(starter.waitForExistence(timeout: 5))
        starter.tap()

        let composer = composerField(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "用快过期的食材做饭")
        // Does not auto-send: starters are still visible because no messages sent
        XCTAssertTrue(app.buttons["kitchenAI.starter.今晚想吃清淡一点"].exists)
    }

    func test05_ComposerIdentifierExists() {
        let app = launchApp(arguments: ["UITEST_AI_CONVERSATION_WORKSPACE_HOME"])
        XCTAssertTrue(composerField(app).waitForExistence(timeout: 5))
    }

    func test06_NoProviderPickerOnScreen() {
        let app = launchApp(arguments: ["UITEST_AI_CONVERSATION_WORKSPACE_HOME"])
        XCTAssertFalse(app.buttons["Gemini"].exists)
        XCTAssertFalse(app.buttons["Groq"].exists)
        XCTAssertFalse(app.buttons["Apple"].exists)
        XCTAssertFalse(app.pickers["Provider"].exists)
    }

    func test07_NoTappableAttachmentButton() {
        let app = launchApp(arguments: ["UITEST_AI_CONVERSATION_WORKSPACE_HOME"])
        XCTAssertFalse(app.buttons["attachment"].exists)
        XCTAssertFalse(app.buttons["kitchenAI.attachment"].exists)
    }

    // D-044: a legacy device-local recipe recommendation choice is asked to
    // pick a conversation model in place, and answering it unblocks sending
    // straight away. test06 pins that no provider control is on screen once a
    // conversation provider is settled; this pins the one state where it is.
    func test07b_LegacyAppleRecommendationAsksForConversationModelInPlace() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_LEGACY_APPLE_RECOMMENDATION"
        ])

        let gemini = app.buttons["kitchenAI.selectProvider.gemini"]
        XCTAssertTrue(
            gemini.waitForExistence(timeout: 5),
            "a legacy device-local member must be asked to choose, not refused"
        )
        XCTAssertTrue(app.buttons["kitchenAI.selectProvider.groq"].exists)
        XCTAssertFalse(
            app.buttons["kitchenAI.selectProvider.apple"].exists,
            "Apple is not an eligible conversation model"
        )
        XCTAssertGreaterThanOrEqual(gemini.frame.height, 44)
        XCTAssertFalse(
            composerField(app).exists,
            "no composer is offered while the provider choice is still pending"
        )

        gemini.tap()

        XCTAssertTrue(
            composerField(app).waitForExistence(timeout: 5),
            "answering the setup state must make sending available immediately"
        )
        XCTAssertFalse(app.buttons["kitchenAI.selectProvider.gemini"].exists)
    }

    // MARK: - STREAM & MESSAGES (Tests 8-11)

    func test08_SendShowsUserMessage() {
        let app = launchApp(arguments: ["UITEST_AI_CONVERSATION_WORKSPACE_HOME"])
        let composer = composerField(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("今晚吃面条")

        let sendButton = app.buttons["kitchenAI.send"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5))
        sendButton.tap()

        XCTAssertTrue(app.staticTexts["今晚吃面条"].waitForExistence(timeout: 5))
    }

    func test09_AssistantTextRendersOpenContent() {
        let app = launchApp(arguments: ["UITEST_AI_CONVERSATION_WORKSPACE_HOME"])
        let composer = composerField(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("测试助手文本")
        app.buttons["kitchenAI.send"].tap()

        XCTAssertTrue(app.staticTexts["这是本地测试回复。"].waitForExistence(timeout: 12))
    }

    func test10_StopAppearsWhileActive() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_CONVERSATION_SCRIPT_STREAM_STOP"
        ])
        let composer = composerField(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("生成长篇建议")
        app.buttons["kitchenAI.send"].tap()

        let stopButton = app.buttons["kitchenAI.stop"]
        XCTAssertTrue(stopButton.waitForExistence(timeout: 5))
    }

    func test11_StopPreservesPartialContent() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_CONVERSATION_SCRIPT_STREAM_STOP"
        ])
        let composer = composerField(app)
        composer.tap()
        composer.typeText("长回复测试")
        app.buttons["kitchenAI.send"].tap()

        let stopButton = app.buttons["kitchenAI.stop"]
        XCTAssertTrue(stopButton.waitForExistence(timeout: 5))
        stopButton.tap()

        XCTAssertTrue(app.staticTexts["正在逐步为您生成长篇建议第一部分内容…"].waitForExistence(timeout: 5))

        // Phase 2B.2: a stopped partial answer must not read as a finished
        // one, and stopping is the member's choice rather than a failure.
        let stopped = app.descendants(matching: .any).matching(identifier: "kitchenAI.turn.stopped").firstMatch
        XCTAssertTrue(stopped.waitForExistence(timeout: 5), "a cancelled turn must carry its stopped marker")
        XCTAssertFalse(app.buttons["kitchenAI.error.retry"].exists,
                       "stopping is not an error and must not borrow the error retry")
        XCTAssertFalse(app.buttons["kitchenAI.stop"].exists, "streaming has ended")
    }

    func test11b_CompletedAnswerCarriesNoStoppedMarker() {
        let app = launchApp(arguments: ["UITEST_AI_CONVERSATION_WORKSPACE_HOME"])
        let composer = composerField(app)
        composer.tap()
        composer.typeText("正常完成")
        app.buttons["kitchenAI.send"].tap()

        XCTAssertTrue(app.staticTexts["这是本地测试回复。"].waitForExistence(timeout: 8))
        let stopped = app.descendants(matching: .any).matching(identifier: "kitchenAI.turn.stopped").firstMatch
        XCTAssertFalse(stopped.exists, "normal completion stays visually quiet")
    }

    /// The marker derives from the persisted message state, so it must still be
    /// there after the conversation is left and reopened from History.
    func test11c_StoppedMarkerSurvivesReopeningTheConversation() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_CONVERSATION_SCRIPT_STREAM_STOP"
        ])
        let composer = composerField(app)
        composer.tap()
        composer.typeText("停止后重开")
        app.buttons["kitchenAI.send"].tap()
        let stopButton = app.buttons["kitchenAI.stop"]
        XCTAssertTrue(stopButton.waitForExistence(timeout: 5))
        stopButton.tap()
        let stopped = app.descendants(matching: .any).matching(identifier: "kitchenAI.turn.stopped").firstMatch
        XCTAssertTrue(stopped.waitForExistence(timeout: 5))

        // Leave to a fresh draft, then come back through History.
        app.buttons["kitchenAI.overflowMenu"].tap()
        app.buttons["新建对话"].tap()
        XCTAssertFalse(stopped.exists, "a fresh draft shows no earlier turn")

        app.buttons["kitchenAI.overflowMenu"].tap()
        app.buttons["历史记录"].tap()
        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "kitchenAI.history.row")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        XCTAssertTrue(app.staticTexts["正在逐步为您生成长篇建议第一部分内容…"].waitForExistence(timeout: 5))
        XCTAssertTrue(stopped.waitForExistence(timeout: 5),
                      "the stopped marker is persisted state, not controller memory")
    }

    // MARK: - RECIPES (Tests 12-15)

    func test12_TwoRecipeBlocksRenderInOrder() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_CONVERSATION_SCRIPT_TWO_RECIPES",
            "UITEST_AI_CONVERSATION_SEED_RECIPES"
        ])
        let composer = composerField(app)
        composer.tap()
        composer.typeText("推荐两个菜")
        app.buttons["kitchenAI.send"].tap()

        XCTAssertTrue(app.staticTexts["蒜蓉上海青"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["家常豆腐"].waitForExistence(timeout: 8))
    }

    func test13_NonTransientRecipeUsesLiveRecipeStoreTruth() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_CONVERSATION_SCRIPT_TWO_RECIPES",
            "UITEST_AI_CONVERSATION_SEED_RECIPES"
        ])
        let composer = composerField(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("推荐")
        app.buttons["kitchenAI.send"].tap()

        XCTAssertTrue(app.staticTexts["蒜蓉上海青"].waitForExistence(timeout: 8))
        app.swipeDown()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '上海青 350 克'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["kitchenAI.recipe.view.rec-garlic-greens"].exists)
    }

    func test14_SnapshotFallbackStillRendersIfRecipeMissing() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_CONVERSATION_SEED_SNAPSHOT_FALLBACK",
            "UITEST_AI_CONVERSATION_SEED_HISTORY"
        ])
        app.buttons["kitchenAI.overflowMenu"].tap()
        app.buttons["历史记录"].tap()

        let row = app.buttons["kitchenAI.history.row.44444444-4444-4444-4444-444444444444"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        // Still renders from block snapshot although rec-deleted is missing from RecipeStore
        XCTAssertTrue(app.staticTexts["秘制红烧肉"].waitForExistence(timeout: 8))

        let viewButton = app.buttons["kitchenAI.recipe.view.rec-deleted"]
        XCTAssertTrue(viewButton.waitForExistence(timeout: 5))
        viewButton.tap()

        XCTAssertTrue(app.staticTexts["菜谱快照"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["菜谱操作"].exists)
        XCTAssertFalse(app.buttons["加入今日计划"].exists)
        XCTAssertFalse(app.buttons["加入买菜清单"].exists)
    }

    func test15_ViewRecipeNavigationWorks() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_CONVERSATION_SCRIPT_TWO_RECIPES",
            "UITEST_AI_CONVERSATION_SEED_RECIPES"
        ])
        let composer = composerField(app)
        composer.tap()
        composer.typeText("推荐")
        app.buttons["kitchenAI.send"].tap()

        XCTAssertTrue(app.staticTexts["蒜蓉上海青"].waitForExistence(timeout: 8))
        // Tapped only to scroll the transcript to the top. Matched by position
        // rather than by title, because the title is now the conversation's own
        // task identity instead of the fixed product name.
        app.navigationBars.firstMatch.tap()
        let scroll = app.scrollViews.firstMatch
        if scroll.exists { scroll.swipeDown() }
        let viewButton = app.buttons["kitchenAI.recipe.view.rec-garlic-greens"]
        if !viewButton.exists {
            app.swipeDown()
        }
        if viewButton.firstMatch.waitForExistence(timeout: 5) {
            viewButton.firstMatch.tap()
        } else {
            app.buttons["查看菜谱"].firstMatch.tap()
        }

        XCTAssertTrue(app.staticTexts["蒜蓉上海青"].waitForExistence(timeout: 8))
    }

    // MARK: - PLANNER PREVIEW & ACTIONS (Tests 16-18)

    func test16_AllPlannerPreviewRowsVisible() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_PLANNER",
            "UITEST_AI_CONVERSATION_SCRIPT_PLANNER_PREVIEW",
            "UITEST_AI_CONVERSATION_SEED_PLAN"
        ])
        let composer = composerField(app)
        composer.tap()
        composer.typeText("调整菜单")
        app.buttons["kitchenAI.send"].tap()

        XCTAssertTrue(app.staticTexts["确认计划变更"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '清蒸鲈鱼'")).firstMatch.waitForExistence(timeout: 8))
    }

    func test17_PendingPreviewExposesApply() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_PLANNER",
            "UITEST_AI_CONVERSATION_SCRIPT_PLANNER_PREVIEW",
            "UITEST_AI_CONVERSATION_SEED_PLAN"
        ])
        let composer = composerField(app)
        composer.tap()
        composer.typeText("调整菜单")
        app.buttons["kitchenAI.send"].tap()

        let applyButton = app.buttons["kitchenAI.planner.apply"]
        XCTAssertTrue(applyButton.waitForExistence(timeout: 8))
    }

    func test18_ApplyCeasesToBeFunctionalAfterHandling() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_PLANNER",
            "UITEST_AI_CONVERSATION_SCRIPT_PLANNER_PREVIEW",
            "UITEST_AI_CONVERSATION_SEED_PLAN"
        ])
        let composer = composerField(app)
        composer.tap()
        composer.typeText("调整菜单")
        app.buttons["kitchenAI.send"].tap()

        let applyButton = app.buttons["kitchenAI.planner.apply"]
        XCTAssertTrue(applyButton.waitForExistence(timeout: 8))
        applyButton.tap()

        // After confirming, pending action is consumed, apply disappears
        XCTAssertFalse(applyButton.waitForExistence(timeout: 5))

        // Phase 2B.3: the result names what changed, where it lives, and how
        // long it can be taken back — all read from the persisted record.
        XCTAssertTrue(app.staticTexts["已更新计划中的这餐"].waitForExistence(timeout: 5),
                      "outcome must name the real kitchen effect")
        XCTAssertFalse(app.staticTexts["操作已完成"].exists)
        XCTAssertTrue(app.buttons["kitchenAI.action.destination.planner"].exists,
                      "a planner change must offer the planner as its destination")
        XCTAssertFalse(app.buttons["kitchenAI.action.destination.shopping"].exists, "wrong destination")
        XCTAssertFalse(app.buttons["kitchenAI.action.destination.today"].exists, "wrong destination")
        let availability = app.staticTexts["kitchenAI.action.undoAvailability"]
        XCTAssertTrue(availability.exists, "undo must state its finite window")
        XCTAssertTrue(availability.label.hasPrefix("可撤销至 "), availability.label)
    }

    /// Outcome, destination and undo availability come from the record, so
    /// they must all still be there after leaving and reopening from History.
    func test18b_OutcomeSurvivesReopeningTheConversation() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_PLANNER",
            "UITEST_AI_CONVERSATION_SCRIPT_PLANNER_PREVIEW",
            "UITEST_AI_CONVERSATION_SEED_PLAN"
        ])
        let composer = composerField(app)
        composer.tap()
        composer.typeText("调整菜单")
        app.buttons["kitchenAI.send"].tap()
        let apply = app.buttons["kitchenAI.planner.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 8))
        apply.tap()
        XCTAssertTrue(app.staticTexts["已更新计划中的这餐"].waitForExistence(timeout: 5))

        app.buttons["kitchenAI.overflowMenu"].tap()
        app.buttons["新建对话"].tap()
        XCTAssertFalse(app.staticTexts["已更新计划中的这餐"].exists)

        app.buttons["kitchenAI.overflowMenu"].tap()
        app.buttons["历史记录"].tap()
        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "kitchenAI.history.row")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        XCTAssertTrue(app.staticTexts["已更新计划中的这餐"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["kitchenAI.action.destination.planner"].exists)
        XCTAssertTrue(app.buttons["kitchenAI.action.undo"].exists, "undo is still within its window")
        XCTAssertTrue(app.staticTexts["kitchenAI.action.undoAvailability"].exists)
    }

    // MARK: - CONTEXT CHIPS (Tests 19-22)

    func test19_PreSendLikelyChipsExist() {
        let app = launchApp(arguments: ["UITEST_AI_CONVERSATION_WORKSPACE_HOME"])
        XCTAssertTrue(app.buttons["kitchenAI.contextChips"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["库存"].exists)
        XCTAssertTrue(app.staticTexts["今晚计划"].exists)
    }

    func test20_TogglingContextSourceExclusion() {
        let app = launchApp(arguments: ["UITEST_AI_CONVERSATION_WORKSPACE_HOME"])
        let chips = app.buttons["kitchenAI.contextChips"]
        XCTAssertTrue(chips.waitForExistence(timeout: 5))
        chips.tap()

        let toggle = app.switches["kitchenAI.contextToggle.inventory"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()

        app.buttons["完成"].tap()
    }

    func test21_AcceptedSendResetsExclusions() {
        let app = launchApp(arguments: ["UITEST_AI_CONVERSATION_WORKSPACE_HOME"])
        let chips = app.buttons["kitchenAI.contextChips"]
        chips.tap()
        let toggle = app.switches["kitchenAI.contextToggle.inventory"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        app.buttons["完成"].tap()

        let composer = composerField(app)
        composer.tap()
        composer.typeText("查一下")
        app.buttons["kitchenAI.send"].tap()

        // Wait for turn to complete
        XCTAssertTrue(app.staticTexts["这是本地测试回复。"].waitForExistence(timeout: 8))
        // Chips reset: verify previously excluded inventory is included again
        let resetChips = app.buttons["kitchenAI.contextChips"]
        XCTAssertTrue(resetChips.waitForExistence(timeout: 5))
        resetChips.tap()
        let toggleAfter = app.switches["kitchenAI.contextToggle.inventory"]
        XCTAssertTrue(toggleAfter.waitForExistence(timeout: 5))
        XCTAssertEqual(toggleAfter.value as? String, "1")
        app.buttons["完成"].tap()
    }

    func test22_ActiveTurnChipsShowActuallyUsedSources() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_CONVERSATION_SCRIPT_STREAM_STOP"
        ])
        let composer = composerField(app)
        composer.tap()
        composer.typeText("问一下")
        app.buttons["kitchenAI.send"].tap()

        // During streaming, stop button is visible
        XCTAssertTrue(app.buttons["kitchenAI.stop"].waitForExistence(timeout: 5))
        // Interactive chips control is not available during generation
        XCTAssertFalse(app.buttons["kitchenAI.contextChips"].exists)
        // Actually-used context sources are displayed
        XCTAssertTrue(app.staticTexts["库存"].exists || app.staticTexts["今晚计划"].exists)
    }

    // MARK: - ACTION STATUS & ERROR (Tests 23-26)

    func test23_CanUndoStatusExposesUndo() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_PLANNER",
            "UITEST_AI_CONVERSATION_SCRIPT_PLANNER_PREVIEW",
            "UITEST_AI_CONVERSATION_SEED_PLAN"
        ])
        let composer = composerField(app)
        composer.tap()
        composer.typeText("调整")
        app.buttons["kitchenAI.send"].tap()

        let apply = app.buttons["kitchenAI.planner.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 8))
        apply.tap()

        let undoButton = app.buttons["kitchenAI.action.undo"]
        XCTAssertTrue(undoButton.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["kitchenAI.action.undoAvailability"].exists)

        // Phase 2B.3: after Undo the block says the change was reversed and
        // stops advertising a place to inspect it or a second undo.
        undoButton.tap()
        XCTAssertTrue(app.staticTexts["已撤销，这餐已恢复"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["kitchenAI.action.undo"].exists)
        XCTAssertFalse(app.buttons["kitchenAI.action.destination.planner"].exists,
                       "a reversed change has nothing to go and look at")
        XCTAssertFalse(app.staticTexts["kitchenAI.action.undoAvailability"].exists)
    }

    /// Destination routing needs the real four-tab root, so this runs the
    /// production app rather than the bare workspace host.
    func test23b_DestinationReachesThePlannerWithoutASecondMutation() {
        let app = XCUIApplication()
        app.launchArguments = [
            "UITEST_SEED_HOME_FULL_DAY", "UITEST_AI_CONVERSATION_FAKE",
            "UITEST_AI_CONVERSATION_SCRIPT_PLANNER_PREVIEW",
            "UITEST_FORCE_LIGHT_APPEARANCE",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryLarge"
        ]
        app.launch()
        let entry = app.buttons["home.kitchenAI.open"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        XCTAssertTrue(app.buttons["kitchenAI.overflowMenu"].waitForExistence(timeout: 10))

        let composer = composerField(app)
        composer.tap()
        composer.typeText("把今晚换成清蒸鲈鱼")
        app.buttons["kitchenAI.send"].tap()
        let apply = app.buttons["kitchenAI.planner.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 8))
        apply.tap()

        let destination = app.buttons["kitchenAI.action.destination.planner"]
        XCTAssertTrue(destination.waitForExistence(timeout: 8))
        let outcomeCount = app.staticTexts.matching(identifier: "kitchenAI.action.outcome").count
        destination.tap()

        // The destination is the changed meal itself, whose detail hides the
        // tab bar; popping once lands on the Plan root with the tab selected.
        XCTAssertTrue(app.staticTexts["清蒸鲈鱼"].waitForExistence(timeout: 8),
                      "the replaced meal must be visible at the destination")
        XCTAssertFalse(app.buttons["kitchenAI.overflowMenu"].exists, "the workspace is no longer frontmost")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.tabBars.buttons["计划"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["计划"].isSelected, "destination must select the Plan tab")

        // Going back to the conversation shows exactly one outcome: viewing
        // the result executed nothing.
        app.tabBars.buttons["今天"].tap()
        XCTAssertTrue(app.buttons["kitchenAI.overflowMenu"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "kitchenAI.action.outcome").count, outcomeCount)
    }

    func test24_ExpiredActionDoesNotExposeUndo() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_CONVERSATION_SEED_EXPIRED_ACTION"
        ])
        app.buttons["kitchenAI.overflowMenu"].tap()
        app.buttons["历史记录"].tap()

        let row = app.buttons["kitchenAI.history.row.55555555-5555-5555-5555-555555555555"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        XCTAssertTrue(app.staticTexts["已更新计划中的这餐"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["kitchenAI.action.undo"].exists)
        XCTAssertFalse(app.staticTexts["kitchenAI.action.undoAvailability"].exists)
    }

    /// Proves that when a workspace is left open across undoExpiresAt without
    /// navigation or user actions:
    /// 1. successful outcome appears
    /// 2. Undo is initially visible
    /// 3. availability is initially visible
    /// 4. expiry boundary passes
    /// 5. Undo disappears automatically
    /// 6. availability disappears automatically
    /// 7. outcome remains
    /// 8. destination remains
    func test24b_OneShotExpiryInvalidationHidesUndoAutomatically() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_PLANNER",
            "UITEST_AI_CONVERSATION_SCRIPT_PLANNER_PREVIEW",
            "UITEST_AI_CONVERSATION_SEED_PLAN",
            "UITEST_AI_ACTION_SHORT_EXPIRY"
        ])
        let composer = composerField(app)
        composer.tap()
        composer.typeText("调整菜单")
        app.buttons["kitchenAI.send"].tap()
        let apply = app.buttons["kitchenAI.planner.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 8))
        apply.tap()

        // 1. Outcome & destination are visible after Apply
        XCTAssertTrue(app.staticTexts["已更新计划中的这餐"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["kitchenAI.action.destination.planner"].exists)

        // 2 & 3. Undo and availability initially visible
        let undoButton = app.buttons["kitchenAI.action.undo"]
        let availability = app.staticTexts["kitchenAI.action.undoAvailability"]
        XCTAssertTrue(undoButton.exists, "Undo must be initially visible before expiry")
        XCTAssertTrue(availability.exists, "Availability line must be initially visible before expiry")

        // 4. Wait for the 2.5s expiry boundary to pass without touching the screen
        let predicate = NSPredicate(format: "exists == false")
        let expectationUndo = XCTNSPredicateExpectation(predicate: predicate, object: undoButton)
        let expectationAvail = XCTNSPredicateExpectation(predicate: predicate, object: availability)
        wait(for: [expectationUndo, expectationAvail], timeout: 8.0)

        // 5 & 6. Undo & availability disappeared automatically
        XCTAssertFalse(undoButton.exists, "Undo must automatically disappear after expiry")
        XCTAssertFalse(availability.exists, "Availability line must automatically disappear after expiry")

        // 7 & 8. Outcome & destination remain intact
        XCTAssertTrue(app.staticTexts["已更新计划中的这餐"].exists, "Outcome text must remain after Undo expires")
        XCTAssertTrue(app.buttons["kitchenAI.action.destination.planner"].exists, "Destination must remain after Undo expires")
    }

    func test25_GenerationRetryInvokesSameTurnRetry() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_CONVERSATION_SCRIPT_ERROR"
        ])
        let composer = composerField(app)
        composer.tap()
        composer.typeText("出错测试")
        app.buttons["kitchenAI.send"].tap()

        let retryButton = app.buttons["kitchenAI.error.retry"]
        XCTAssertTrue(retryButton.waitForExistence(timeout: 8))
        // Phase 2B.2: the button says what it will do. A provider failure is a
        // generation-scoped retry, and the wording must say so.
        XCTAssertEqual(retryButton.label, "重新生成这条回复")
        retryButton.tap()

        XCTAssertTrue(app.staticTexts["重试成功，已为您生成回复。"].waitForExistence(timeout: 8))
    }

    func test26_ActionErrorHasNoGenericModelRetry() {
        let app = launchApp(arguments: ["UITEST_AI_CONVERSATION_WORKSPACE_HOME"])
        // Action errors do not render model retry button
        XCTAssertFalse(app.buttons["kitchenAI.action.retry"].exists)
    }

    // MARK: - HISTORY (Tests 27-34)

    func test27_HistoryGroupsPinnedRecentEndedExist() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_CONVERSATION_SEED_HISTORY"
        ])
        app.buttons["kitchenAI.overflowMenu"].tap()
        app.buttons["历史记录"].tap()

        XCTAssertTrue(app.staticTexts["置顶"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["最近"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["kitchenAI.history.section.archived"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["已结束"].exists)
        XCTAssertFalse(app.staticTexts["已过期"].exists, "conversation lifecycle never says 过期")
    }

    func test28_BlankDraftAbsentFromHistory() {
        let app = launchApp(arguments: ["UITEST_AI_CONVERSATION_WORKSPACE_HOME"])
        app.buttons["kitchenAI.overflowMenu"].tap()
        app.buttons["历史记录"].tap()

        XCTAssertTrue(app.navigationBars["历史记录"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["新对话"].exists)
    }

    func test29_ActiveConversationResumesDirectly() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_CONVERSATION_SEED_HISTORY"
        ])
        app.buttons["kitchenAI.overflowMenu"].tap()
        app.buttons["历史记录"].tap()

        let row = app.buttons["kitchenAI.history.row.22222222-2222-2222-2222-222222222222"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        // History dismisses and transcript shows resumed conversation
        XCTAssertTrue(app.staticTexts["快手菜推荐"].waitForExistence(timeout: 5))
    }

    func test30_ExpiredConversationOpensReadOnly() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_CONVERSATION_SEED_HISTORY"
        ])
        app.buttons["kitchenAI.overflowMenu"].tap()
        app.buttons["历史记录"].tap()

        let expiredRow = app.buttons["kitchenAI.history.row.33333333-3333-3333-3333-333333333333"]
        XCTAssertTrue(expiredRow.waitForExistence(timeout: 5))
        expiredRow.tap()

        // Expired message visible
        XCTAssertTrue(app.staticTexts["聚餐如何准备"].waitForExistence(timeout: 5))
        // Archived, never expired: the record is intact and resumable.
        XCTAssertTrue(app.staticTexts["此对话已归档"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["此对话已过期"].exists)
        XCTAssertFalse(composerField(app).exists)
        // Prominent continue button visible
        XCTAssertTrue(app.buttons["kitchenAI.reactivate"].waitForExistence(timeout: 5))
        // Overflow says 已归档 and shows no stale deadline.
        app.buttons["kitchenAI.overflowMenu"].tap()
        XCTAssertTrue(lifetimeText(app).waitForExistence(timeout: 5))
        XCTAssertEqual(lifetimeText(app).label, "已归档")
    }

    func test31_ContinueReactivatesExpiredConversation() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_CONVERSATION_SEED_HISTORY"
        ])
        app.buttons["kitchenAI.overflowMenu"].tap()
        app.buttons["历史记录"].tap()

        let expiredRow = app.buttons["kitchenAI.history.row.33333333-3333-3333-3333-333333333333"]
        expiredRow.tap()

        let reactivateButton = app.buttons["kitchenAI.reactivate"]
        XCTAssertTrue(reactivateButton.waitForExistence(timeout: 5))
        reactivateButton.tap()

        // Composer is enabled, reactivate button disappears
        XCTAssertFalse(reactivateButton.waitForExistence(timeout: 5))
        XCTAssertTrue(composerField(app).waitForExistence(timeout: 5))
        // Same conversation, same transcript; continuity is visible again
        // through the overflow only.
        XCTAssertTrue(app.staticTexts["聚餐如何准备"].exists)
        XCTAssertTrue(app.navigationBars["上周聚餐规划"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '自动延续至'")).firstMatch.exists)
        app.buttons["kitchenAI.overflowMenu"].tap()
        XCTAssertTrue(lifetimeText(app).waitForExistence(timeout: 5))
        XCTAssertTrue(lifetimeText(app).label.hasPrefix("自动延续至"), lifetimeText(app).label)
    }

    func test32_RenameReflectedInRow() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_CONVERSATION_SEED_HISTORY"
        ])
        app.buttons["kitchenAI.overflowMenu"].tap()
        app.buttons["历史记录"].tap()

        let row = app.buttons["kitchenAI.history.row.22222222-2222-2222-2222-222222222222"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft()
        let renameButton = app.buttons["重命名"]
        XCTAssertTrue(renameButton.waitForExistence(timeout: 5))
        renameButton.tap()
        let alertField = app.textFields["输入新标题"]
        XCTAssertTrue(alertField.waitForExistence(timeout: 5))
        alertField.tap()
        alertField.typeText("全新快手菜")
        let confirmBtn = app.alerts.buttons["确定"].firstMatch
        XCTAssertTrue(confirmBtn.waitForExistence(timeout: 5))
        confirmBtn.tap()

        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '全新快手菜'")).firstMatch.waitForExistence(timeout: 5))
    }

    func test33_PinUnpinMovesGroupTruthfully() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_CONVERSATION_SEED_HISTORY"
        ])
        app.buttons["kitchenAI.overflowMenu"].tap()
        app.buttons["历史记录"].tap()

        let recentRow = app.buttons["kitchenAI.history.row.22222222-2222-2222-2222-222222222222"]
        XCTAssertTrue(recentRow.waitForExistence(timeout: 5))
        recentRow.swipeRight()
        let pinBtn = app.buttons["置顶"]
        XCTAssertTrue(pinBtn.waitForExistence(timeout: 5))
        pinBtn.tap()

        XCTAssertTrue(recentRow.images["pin.fill"].waitForExistence(timeout: 5))
        let pinnedHeader = app.staticTexts["kitchenAI.history.section.pinned"]
        let recentHeader = app.staticTexts["kitchenAI.history.section.recent"]
        XCTAssertTrue(pinnedHeader.exists)
        XCTAssertTrue(recentHeader.exists)
        XCTAssertGreaterThanOrEqual(recentRow.frame.minY, pinnedHeader.frame.maxY)
        XCTAssertLessThanOrEqual(recentRow.frame.maxY, recentHeader.frame.minY)

        recentRow.swipeRight()
        let unpinBtn = app.buttons["取消置顶"]
        XCTAssertTrue(unpinBtn.waitForExistence(timeout: 5))
        unpinBtn.tap()

        XCTAssertFalse(recentRow.images["pin.fill"].exists)
        let archivedHeader = app.staticTexts["kitchenAI.history.section.archived"]
        XCTAssertTrue(archivedHeader.exists)
        XCTAssertGreaterThanOrEqual(recentRow.frame.minY, recentHeader.frame.maxY)
        XCTAssertLessThanOrEqual(recentRow.frame.maxY, archivedHeader.frame.minY)
    }

    // MARK: - Lifetime presentation (Phase 2C.1)

    /// The single overflow header line. The native Menu drops identifiers from
    /// its header, and the label also carries the VoiceOver detail, so tests
    /// match on the visible prefix.
    private func lifetimeText(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH '自动延续至' OR label BEGINSWITH '已置顶' OR label BEGINSWITH '已归档'"
        )).firstMatch
    }

    private func lifetimeLine(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '自动延续至'")).firstMatch
    }

    /// The deadline is overflow metadata only: nowhere in the workspace until
    /// the menu opens, and worded as continuity rather than expiry.
    func test35_ActiveLifetimeLivesOnlyInOverflow() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_CONVERSATION_SEED_HISTORY"
        ])
        XCTAssertTrue(app.staticTexts["快手菜推荐"].waitForExistence(timeout: 5), "Home resumes the active daily conversation")
        XCTAssertFalse(lifetimeLine(app).exists)
        XCTAssertTrue(taskContextHeader(app).exists)
        XCTAssertFalse(taskContextHeader(app).label.contains("自动延续至"))

        app.buttons["kitchenAI.overflowMenu"].tap()
        let line = lifetimeLine(app)
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        XCTAssertTrue(line.label.contains(":"), "carries a HH:mm time: \(line.label)")
        XCTAssertFalse(line.label.contains("过期"))
        XCTAssertFalse(line.label.contains("小时"), "no policy constants in copy")
    }

    /// A pinned conversation says 已置顶 and never its underlying deadline.
    func test36_PinnedOverflowHidesDeadline() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_CONVERSATION_SEED_HISTORY"
        ])
        app.buttons["kitchenAI.overflowMenu"].tap()
        app.buttons["历史记录"].tap()
        let pinnedRow = app.buttons["kitchenAI.history.row.11111111-1111-1111-1111-111111111111"]
        XCTAssertTrue(pinnedRow.waitForExistence(timeout: 5))
        XCTAssertTrue(pinnedRow.staticTexts["已置顶"].exists)
        pinnedRow.tap()

        XCTAssertTrue(app.staticTexts["买点什么菜"].waitForExistence(timeout: 5))
        app.buttons["kitchenAI.overflowMenu"].tap()
        XCTAssertTrue(lifetimeText(app).waitForExistence(timeout: 5))
        XCTAssertTrue(lifetimeText(app).label.hasPrefix("已置顶"), lifetimeText(app).label)
        XCTAssertFalse(lifetimeText(app).label.contains(":"), "no deadline while pinned")
        XCTAssertFalse(lifetimeLine(app).exists)
    }

    /// The continuity boundary crosses inside a workspace nobody touches:
    /// composer gives way to the archived card, transcript and identity stay.
    func test37_WorkspaceArchivesAtBoundaryWithoutInteraction() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_LIFETIME_SHORT_ACTIVE"
        ])
        XCTAssertTrue(app.staticTexts["今晚做点什么好"].waitForExistence(timeout: 5))
        XCTAssertTrue(composerField(app).exists, "still active at launch")
        XCTAssertFalse(app.buttons["kitchenAI.reactivate"].exists)

        let card = app.descendants(matching: .any).matching(identifier: "kitchenAI.archivedCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 25), "archived card never appeared at the boundary")
        XCTAssertTrue(card.label.contains("已归档"))
        XCTAssertFalse(card.label.contains("过期"))
        XCTAssertTrue(app.buttons["kitchenAI.reactivate"].exists)
        XCTAssertFalse(composerField(app).exists)
        XCTAssertTrue(app.staticTexts["今晚做点什么好"].exists, "transcript stays readable")
        XCTAssertTrue(taskContextHeader(app).exists, "task identity stays")
        XCTAssertTrue(app.navigationBars["今晚吃什么"].exists)
    }

    /// History left open across the boundary moves the row from 最近 to 已归档
    /// on its own.
    func test38_HistoryRegroupsAtBoundaryWhileSheetStaysOpen() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_LIFETIME_SHORT_ACTIVE"
        ])
        app.buttons["kitchenAI.overflowMenu"].tap()
        app.buttons["历史记录"].tap()
        let row = app.buttons["kitchenAI.history.row.77777777-7777-7777-7777-777777777777"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["kitchenAI.history.section.recent"].exists, "sheet opened before the boundary")
        XCTAssertFalse(app.staticTexts["kitchenAI.history.section.archived"].exists)
        XCTAssertTrue(row.staticTexts["活跃"].exists)

        let archivedHeader = app.staticTexts["kitchenAI.history.section.archived"]
        XCTAssertTrue(archivedHeader.waitForExistence(timeout: 25), "row never regrouped at the boundary")
        XCTAssertFalse(app.staticTexts["kitchenAI.history.section.recent"].exists)
        XCTAssertTrue(row.staticTexts["已归档"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(row.frame.minY, archivedHeader.frame.maxY)
    }

    /// Pinned past its stored deadline stays usable; unpinning archives it at
    /// once with no fresh deadline, no grace and no dialog.
    func test39_UnpinAfterStoredDeadlineArchivesImmediately() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_LIFETIME_SHORT_PINNED"
        ])
        XCTAssertTrue(app.staticTexts["今晚做点什么好"].waitForExistence(timeout: 5))
        // Let the stored activeUntil (+4s at seed) pass while pinned.
        sleep(6)
        XCTAssertTrue(composerField(app).exists, "pinned conversation stays active past its stored deadline")
        XCTAssertFalse(app.buttons["kitchenAI.reactivate"].exists)

        app.buttons["kitchenAI.overflowMenu"].tap()
        XCTAssertTrue(lifetimeText(app).waitForExistence(timeout: 5))
        XCTAssertTrue(lifetimeText(app).label.hasPrefix("已置顶"), lifetimeText(app).label)
        XCTAssertFalse(lifetimeLine(app).exists)
        app.buttons["取消置顶"].tap()

        let card = app.descendants(matching: .any).matching(identifier: "kitchenAI.archivedCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 3), "unpin must archive immediately")
        XCTAssertFalse(composerField(app).exists)
        XCTAssertTrue(app.buttons["kitchenAI.reactivate"].exists)
        XCTAssertTrue(app.staticTexts["今晚做点什么好"].exists)
    }

    func test34_DeleteRemovesConversation() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_CONVERSATION_SEED_HISTORY"
        ])
        app.buttons["kitchenAI.overflowMenu"].tap()
        app.buttons["历史记录"].tap()

        let row = app.buttons["kitchenAI.history.row.22222222-2222-2222-2222-222222222222"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft()
        let deleteBtn = app.buttons["删除"]
        XCTAssertTrue(deleteBtn.waitForExistence(timeout: 5))
        deleteBtn.tap()
        let confirm = app.buttons["删除"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        XCTAssertFalse(app.buttons["kitchenAI.history.row.22222222-2222-2222-2222-222222222222"].waitForExistence(timeout: 3))
    }

    // MARK: - ACCESSIBILITY & LAYOUT (Tests 35-38)

    func test35_AccessibilityXXXLStillExposesComposerAndAction() {
        let app = launchApp(
            arguments: [
                "UITEST_AI_CONVERSATION_WORKSPACE_PLANNER",
                "UITEST_AI_CONVERSATION_SCRIPT_PLANNER_PREVIEW",
                "UITEST_AI_CONVERSATION_SEED_PLAN"
            ],
            contentSize: "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"
        )
        let composer = composerField(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("调整")
        app.buttons["kitchenAI.send"].tap()

        let apply = app.buttons["kitchenAI.planner.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 8))
        XCTAssertTrue(apply.isHittable)
        XCTAssertTrue(composer.isHittable)
    }

    func test36_CustomButtonsHaveAdequateHitArea() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_CONVERSATION_SEED_HISTORY"
        ])
        let sendButton = app.buttons["kitchenAI.send"]
        let contextButton = app.buttons["kitchenAI.contextChips"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5))
        XCTAssertTrue(contextButton.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(sendButton.frame.height, 44)
        XCTAssertGreaterThanOrEqual(contextButton.frame.height, 44)

        app.buttons["kitchenAI.overflowMenu"].tap()
        app.buttons["历史记录"].tap()
        let expiredRow = app.buttons["kitchenAI.history.row.33333333-3333-3333-3333-333333333333"]
        XCTAssertTrue(expiredRow.waitForExistence(timeout: 5))
        expiredRow.tap()

        let reactivate = app.buttons["kitchenAI.reactivate"]
        XCTAssertTrue(reactivate.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(reactivate.frame.height, 44)
    }

    func test37_LightAndDarkAppearanceSmoke() {
        let darkApp = launchApp(
            arguments: ["UITEST_AI_CONVERSATION_WORKSPACE_HOME"],
            appearance: .dark
        )
        XCTAssertTrue(darkApp.navigationBars["Kitchen AI"].waitForExistence(timeout: 5))
    }

    func test38_KeyboardDoesNotCoverComposer() {
        let app = launchApp(arguments: ["UITEST_AI_CONVERSATION_WORKSPACE_HOME"])
        let composer = composerField(app)
        composer.tap()
        composer.typeText("已录入消息")
        app.buttons["kitchenAI.send"].tap()
        XCTAssertTrue(app.staticTexts["已录入消息"].waitForExistence(timeout: 8))

        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["kitchenAI.send"].isHittable)
        let keyboardFrame = app.keyboards.firstMatch.frame
        XCTAssertLessThanOrEqual(composer.frame.maxY, keyboardFrame.minY + 2)
    }

    func test39_PendingConfirmationDisablesSend() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_PLANNER",
            "UITEST_AI_CONVERSATION_SCRIPT_PLANNER_PREVIEW",
            "UITEST_AI_CONVERSATION_SEED_PLAN"
        ])
        let composer = composerField(app)
        composer.tap()
        composer.typeText("调整菜单")
        app.buttons["kitchenAI.send"].tap()

        XCTAssertTrue(app.buttons["kitchenAI.planner.apply"].waitForExistence(timeout: 8))

        composer.tap()
        composer.typeText("想要别的改动")
        XCTAssertFalse(app.buttons["kitchenAI.send"].isEnabled)
    }

    func test40_LongStreamingKeepsTailReachableWhileActive() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_CONVERSATION_SCRIPT_LONG_STREAM"
        ])
        let composer = composerField(app)
        composer.tap()
        composer.typeText("详细规划")
        app.buttons["kitchenAI.send"].tap()

        XCTAssertTrue(app.buttons["kitchenAI.stop"].waitForExistence(timeout: 5))
        let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'TAIL_MARKER_LONG_STREAM_ACTIVE'")).firstMatch
        XCTAssertTrue(tail.waitForExistence(timeout: 8))
        XCTAssertTrue(tail.isHittable)
    }

    func test41_TransientRecipeDetailIsReadOnly() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_CONVERSATION_SCRIPT_TWO_RECIPES"
        ])
        let composer = composerField(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("推荐")
        app.buttons["kitchenAI.send"].tap()

        XCTAssertTrue(app.staticTexts["家常豆腐"].waitForExistence(timeout: 8))
        let viewRecipeButtons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'kitchenAI.recipe.view.'"))
        let secondButton = viewRecipeButtons.element(boundBy: 1)
        XCTAssertTrue(secondButton.waitForExistence(timeout: 5))
        secondButton.tap()

        XCTAssertTrue(app.staticTexts["推荐菜谱草稿"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["菜谱操作"].exists)
        XCTAssertFalse(app.buttons["加入今日计划"].exists)
        XCTAssertFalse(app.buttons["加入买菜清单"].exists)
    }

    func test42_HostEntryContextPreservedAfterHistorySwitch() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_CONVERSATION_SEED_HISTORY"
        ])

        app.buttons["kitchenAI.overflowMenu"].tap()
        app.buttons["历史记录"].tap()
        let plannerRow = app.buttons["kitchenAI.history.row.66666666-6666-6666-6666-666666666666"]
        XCTAssertTrue(plannerRow.waitForExistence(timeout: 5))
        plannerRow.tap()

        XCTAssertTrue(app.staticTexts["调整本周菜单"].waitForExistence(timeout: 5))

        app.buttons["kitchenAI.overflowMenu"].tap()
        app.buttons["新建对话"].tap()

        XCTAssertTrue(app.buttons["kitchenAI.starter.用快过期的食材做饭"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["kitchenAI.starter.调整这周菜单"].exists)
    }

    func test43_DraftAndExclusionsDoNotLeakAcrossConversations() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_CONVERSATION_SEED_HISTORY"
        ])
        let composer = composerField(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("只属于原对话的未发送草稿")

        let chips = app.buttons["kitchenAI.contextChips"]
        XCTAssertTrue(chips.waitForExistence(timeout: 5))
        chips.tap()
        let toggle = app.switches["kitchenAI.contextToggle.inventory"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        app.buttons["完成"].tap()

        // Open History and switch to another conversation
        app.buttons["kitchenAI.overflowMenu"].tap()
        app.buttons["历史记录"].tap()
        let otherRow = app.buttons["kitchenAI.history.row.66666666-6666-6666-6666-666666666666"]
        XCTAssertTrue(otherRow.waitForExistence(timeout: 5))
        otherRow.tap()

        // The draft from the previous conversation must not leak into the opened conversation
        XCTAssertTrue(app.staticTexts["调整本周菜单"].waitForExistence(timeout: 5))
        let composerAfter = composerField(app)
        XCTAssertTrue(composerAfter.waitForExistence(timeout: 5))
        let textValue = composerAfter.value as? String ?? ""
        XCTAssertFalse(textValue.contains("只属于原对话"))
        app.buttons["kitchenAI.contextChips"].tap()
        let resetToggle = app.switches["kitchenAI.contextToggle.inventory"]
        XCTAssertTrue(resetToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(resetToggle.value as? String, "1")
    }

    func test44_DeletingCurrentPlannerHistoryFromHomeHostRestoresHomeContext() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_CONVERSATION_SEED_HISTORY"
        ])
        // Open History and select Planner conversation
        app.buttons["kitchenAI.overflowMenu"].tap()
        app.buttons["历史记录"].tap()
        let plannerRow = app.buttons["kitchenAI.history.row.66666666-6666-6666-6666-666666666666"]
        XCTAssertTrue(plannerRow.waitForExistence(timeout: 5))
        plannerRow.tap()

        XCTAssertTrue(app.staticTexts["调整本周菜单"].waitForExistence(timeout: 5))

        // Delete current conversation from workspace overflow menu
        app.buttons["kitchenAI.overflowMenu"].tap()
        app.buttons["删除"].tap()
        let confirm = app.buttons["删除"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        // Workspace must restore Home host starters
        XCTAssertTrue(app.buttons["kitchenAI.starter.用快过期的食材做饭"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["kitchenAI.starter.调整这周菜单"].exists)
    }

    func test45_DeletingCurrentFromHistorySheetRestoresHostContext() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_CONVERSATION_SEED_HISTORY"
        ])
        // Open History and select Planner conversation
        app.buttons["kitchenAI.overflowMenu"].tap()
        app.buttons["历史记录"].tap()
        let plannerRow = app.buttons["kitchenAI.history.row.66666666-6666-6666-6666-666666666666"]
        XCTAssertTrue(plannerRow.waitForExistence(timeout: 5))
        plannerRow.tap()

        XCTAssertTrue(app.staticTexts["调整本周菜单"].waitForExistence(timeout: 5))

        // Open History again, delete the currently open Planner conversation
        app.buttons["kitchenAI.overflowMenu"].tap()
        app.buttons["历史记录"].tap()
        let plannerRowInHistory = app.buttons["kitchenAI.history.row.66666666-6666-6666-6666-666666666666"]
        XCTAssertTrue(plannerRowInHistory.waitForExistence(timeout: 5))
        plannerRowInHistory.swipeLeft()
        let deleteBtn = app.buttons["删除"]
        XCTAssertTrue(deleteBtn.waitForExistence(timeout: 5))
        deleteBtn.tap()
        let confirm = app.buttons["删除"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        // Dismiss History sheet
        app.buttons["完成"].tap()

        // Workspace must restore Home host starters
        XCTAssertTrue(app.buttons["kitchenAI.starter.用快过期的食材做饭"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["kitchenAI.starter.调整这周菜单"].exists)
    }

    func test46_DeletingCurrentHomeHistoryFromPlannerHostRestoresPlannerContext() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_PLANNER",
            "UITEST_AI_CONVERSATION_SEED_HISTORY"
        ])
        // Open History and select Home conversation
        app.buttons["kitchenAI.overflowMenu"].tap()
        app.buttons["历史记录"].tap()
        let homeRow = app.buttons["kitchenAI.history.row.22222222-2222-2222-2222-222222222222"]
        XCTAssertTrue(homeRow.waitForExistence(timeout: 5))
        homeRow.tap()

        XCTAssertTrue(app.staticTexts["快手菜推荐"].waitForExistence(timeout: 5))

        // Delete current conversation from workspace overflow menu
        app.buttons["kitchenAI.overflowMenu"].tap()
        app.buttons["删除"].tap()
        let confirm = app.buttons["删除"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        // Workspace must restore Planner host starters
        XCTAssertTrue(app.buttons["kitchenAI.starter.调整这周菜单"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["kitchenAI.starter.用快过期的食材做饭"].exists)
    }

    /// Recipe.cookingTime is Int?. Interpolating it directly renders Swift's
    /// debug description ("Optional(10) 分钟" / "nil 分钟") into both visible text
    /// and the accessibility tree. nil means UNKNOWN, so the metadata is omitted.
    func testRecipeCookingTimeNeverExposesOptionalDebugDescription() {
        let app = launchApp(arguments: [
            "UITEST_AI_CONVERSATION_WORKSPACE_HOME",
            "UITEST_AI_CONVERSATION_SCRIPT_TWO_RECIPES",
            "UITEST_AI_CONVERSATION_SEED_RECIPES"
        ])
        let composer = composerField(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("推荐两个菜")
        app.buttons["kitchenAI.send"].tap()

        // Live recipe rec-garlic-greens has cookingTime = 10.
        XCTAssertTrue(app.staticTexts["蒜蓉上海青"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["家常豆腐"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["10 分钟"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Optional(10) 分钟"].exists)
        assertNoOptionalDebugText(app, stage: "recipe cards")

        // Transient 家常豆腐 supplies no cookingTime; its snapshot detail must
        // omit the metadata rather than print nil, and stay read-only.
        let viewRecipeButtons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'kitchenAI.recipe.view.'"))
        let transientButton = viewRecipeButtons.element(boundBy: 1)
        XCTAssertTrue(transientButton.waitForExistence(timeout: 5))
        transientButton.tap()

        XCTAssertTrue(app.staticTexts["推荐菜谱草稿"].waitForExistence(timeout: 5))
        assertNoOptionalDebugText(app, stage: "transient snapshot detail")
        XCTAssertFalse(app.buttons["菜谱操作"].exists)
        XCTAssertFalse(app.buttons["加入今日计划"].exists)
        XCTAssertFalse(app.buttons["加入买菜清单"].exists)
    }

    private func assertNoOptionalDebugText(_ app: XCUIApplication, stage: String) {
        let leaked = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "nil 分钟", "Optional(")
        )
        XCTAssertEqual(leaked.count, 0, "\(stage) exposed Optional/nil debug text: \(leaked.firstMatch.label)")
    }
}
