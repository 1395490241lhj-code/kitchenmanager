import XCTest

/// Visual acceptance for the confirmations, notices and rows PR #31 added, in
/// Light/Dark × Normal/Accessibility XXXL. Every state is reached through the
/// production screens on DEBUG-only seeds, captured, and checked for what a
/// screenshot cannot prove on its own: the controls a member needs are present,
/// hittable and inside the window, and their identifiers survive. Destructive
/// roles are read from the screenshots, since XCUITest does not expose them.
final class PR31VisualAcceptanceUITests: XCTestCase {
    private struct Variant {
        let name: String
        let dark: Bool
        let accessibility: Bool
    }

    private let variants = [
        Variant(name: "Light-Normal", dark: false, accessibility: false),
        Variant(name: "Dark-Normal", dark: true, accessibility: false),
        Variant(name: "Light-AXXXL", dark: false, accessibility: true),
        Variant(name: "Dark-AXXXL", dark: true, accessibility: true)
    ]

    override func setUpWithError() throws { continueAfterFailure = false }

    override func tearDown() {
        XCUIDevice.shared.appearance = .light
        super.tearDown()
    }

    // MARK: - Harness

    /// The simulator appearance alone does not reliably reach the app before its
    /// first render (on CI the Dark runs came out light), so the app's own
    /// appearance preference is pinned too — see `ContentView`'s UI-test hook.
    private func launch(_ arguments: [String], _ variant: Variant) -> XCUIApplication {
        XCUIDevice.shared.appearance = variant.dark ? .dark : .light
        let app = XCUIApplication()
        app.launchArguments = arguments + [
            variant.dark ? "UITEST_FORCE_DARK_APPEARANCE" : "UITEST_FORCE_LIGHT_APPEARANCE",
            "-UIPreferredContentSizeCategoryName",
            variant.accessibility ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryLarge"
        ]
        app.launch()
        return app
    }

    private func capture(_ app: XCUIApplication, _ variant: Variant, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "PR31-\(variant.name)-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// A SwiftUI `Label`'s identifier can land on its icon (iOS 26.5 on CI), and
    /// an icon is never hittable. So the identifier is only checked to survive,
    /// and the label is found and judged by its text.
    private func labelText(_ app: XCUIApplication, identifier: NSPredicate, containing fragment: String,
                           _ variant: Variant, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier).firstMatch.exists,
                      "\(variant.name): no element matches \(identifier)", file: file, line: line)
        return text(app, containing: fragment)
    }

    private func labelText(_ app: XCUIApplication, _ identifier: String, containing fragment: String,
                           _ variant: Variant, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        labelText(app, identifier: NSPredicate(format: "identifier == %@", identifier), containing: fragment,
                  variant, file: file, line: line)
    }

    /// Scrolls until the element is on screen and clear of the edges, or fails
    /// with where it was.
    @discardableResult
    private func reveal(_ target: XCUIElement, in app: XCUIApplication, _ variant: Variant,
                        file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let window = app.windows.firstMatch.frame
        for _ in 0..<14 {
            if target.exists, target.isHittable,
               target.frame.minY >= window.minY, target.frame.maxY <= window.maxY - 40 { return target }
            app.swipeUp()
        }
        XCTAssertTrue(target.exists && target.isHittable,
                      "\(variant.name): \(target) never became reachable", file: file, line: line)
        return target
    }

    /// Reachable, and not pushed past either side of the window.
    private func assertReachable(_ target: XCUIElement, in app: XCUIApplication, _ variant: Variant, _ what: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(target.exists, "\(variant.name): \(what) missing", file: file, line: line)
        XCTAssertTrue(target.isHittable, "\(variant.name): \(what) not hittable", file: file, line: line)
        XCTAssertGreaterThanOrEqual(target.frame.minX, window.minX - 1, "\(variant.name): \(what) overflows left", file: file, line: line)
        XCTAssertLessThanOrEqual(target.frame.maxX, window.maxX + 1, "\(variant.name): \(what) overflows right", file: file, line: line)
    }

    /// A text element whose label holds the whole expected copy: not cut, not
    /// replaced by an ellipsis.
    private func assertFullText(_ target: XCUIElement, contains expected: String, _ variant: Variant, _ what: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(target.exists, "\(variant.name): \(what) missing", file: file, line: line)
        XCTAssertTrue(target.label.contains(expected), "\(variant.name): \(what) reads \(target.label)", file: file, line: line)
        XCTAssertFalse(target.label.hasSuffix("…"), "\(variant.name): \(what) is truncated", file: file, line: line)
    }

    private func text(_ app: XCUIElement, containing fragment: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    // MARK: - Weekly menu: past first day

    func testWeeklyPastStartConfirmation() {
        for variant in variants {
            let app = launch(["UITEST_SEED_PLANNER_REGRESSION", "PLANNER_DATA_WEEKLY_PAST_START"], variant)
            XCTAssertTrue(app.navigationBars["生成的菜单"].waitForExistence(timeout: 10), "\(variant.name): result screen")
            let add = reveal(app.buttons["weekly.result.materialize"], in: app, variant)
            add.tap()

            let alert = app.alerts["菜单日期已过"]
            XCTAssertTrue(alert.waitForExistence(timeout: 5), "\(variant.name): prompt")
            assertFullText(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "菜品和顺序不变")).firstMatch,
                           contains: "9月10日–9月12日", variant, "prompt message")
            assertReachable(alert.buttons["weekly.stale.confirm"].firstMatch, in: app, variant, "顺延到今天并加入")
            assertReachable(alert.buttons["weekly.stale.cancel"].firstMatch, in: app, variant, "取消")
            capture(app, variant, "Weekly-PastStartPrompt")

            alert.buttons["weekly.stale.confirm"].firstMatch.tap()
            XCTAssertTrue(element(app, "weekly.result.materialized").waitForExistence(timeout: 10), "\(variant.name): added")
            capture(app, variant, "Weekly-PastStartAdded")
            app.terminate()
        }
    }

    // MARK: - Special plan: discard a draft, delete a plan

    private func openSeededSpecialPlan(_ app: XCUIApplication, _ variant: Variant) {
        let planTab = app.tabBars.buttons["计划"]
        XCTAssertTrue(planTab.waitForExistence(timeout: 10), "\(variant.name): 计划 tab")
        planTab.tap()
        XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 5), "\(variant.name): planner")
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "planner.special.entry.")).firstMatch
        for _ in 0..<10 where !(card.exists && card.isHittable) { app.swipeUp() }
        XCTAssertTrue(card.exists, "\(variant.name): seeded special plan row")
        card.tap()
        XCTAssertTrue(app.navigationBars["朋友聚餐"].waitForExistence(timeout: 5), "\(variant.name): plan detail")
    }

    func testSpecialPlanDraftDiscardAndDeleteConfirmations() {
        for variant in variants {
            let app = launch(["UITEST_SEED_SPECIAL_PLAN", "UITEST_SEED_SPECIAL_PLAN_EMPTY_MENU", "UITEST_SPECIAL_PLAN_AI_MENU"], variant)
            openSeededSpecialPlan(app, variant)
            reveal(app.buttons["planner.menu.generate"], in: app, variant).tap()
            XCTAssertTrue(app.staticTexts["红烧牛腩"].waitForExistence(timeout: 15), "\(variant.name): draft menu")

            let back = app.buttons["planner.special.back"]
            assertReachable(back, in: app, variant, "返回")
            back.tap()
            let discard = app.alerts["放弃这份 AI 菜单草稿？"]
            XCTAssertTrue(discard.waitForExistence(timeout: 5), "\(variant.name): discard prompt")
            assertFullText(text(app, containing: "草稿还没有保存"), contains: "返回后这些菜不会保留", variant, "discard message")
            assertReachable(discard.buttons["放弃并返回"].firstMatch, in: app, variant, "放弃并返回")
            assertReachable(discard.buttons["继续编辑"].firstMatch, in: app, variant, "继续编辑")
            capture(app, variant, "SpecialPlan-DiscardPrompt")
            discard.buttons["继续编辑"].firstMatch.tap()

            let more = app.buttons["更多操作"]
            assertReachable(more, in: app, variant, "更多操作")
            more.tap()
            let delete = app.buttons["planner.special.delete"]
            XCTAssertTrue(delete.waitForExistence(timeout: 5), "\(variant.name): 删除计划 in the menu")
            capture(app, variant, "SpecialPlan-DeleteMenu")
            delete.tap()
            let confirm = app.alerts["删除这个特殊计划？"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5), "\(variant.name): delete prompt")
            assertFullText(text(app, containing: "无法撤销"), contains: "菜谱库里的菜谱不受影响", variant, "delete message")
            assertReachable(confirm.buttons["删除"].firstMatch, in: app, variant, "删除")
            assertReachable(confirm.buttons["取消"].firstMatch, in: app, variant, "取消")
            capture(app, variant, "SpecialPlan-DeletePrompt")
            confirm.buttons["取消"].firstMatch.tap()
            XCTAssertTrue(app.navigationBars["朋友聚餐"].exists, "\(variant.name): 取消 keeps the plan")
            app.terminate()
        }
    }

    // MARK: - Settings: backup scope and clear-data copy

    func testBackupScopeAndClearDataWarnings() {
        for variant in variants {
            let app = launch(["UITEST_SETTINGS_EXPERIENCE"], variant)
            app.tabBars.buttons["我的"].tap()
            XCTAssertTrue(app.navigationBars.staticTexts["我的"].waitForExistence(timeout: 5), "\(variant.name): 我的")

            reveal(element(app, "settings.backup.link"), in: app, variant).tap()
            let backupWarning = reveal(labelText(app, "backup.userRecipes.warning", containing: "备份不包含用户菜谱",
                                                 variant), in: app, variant)
            assertFullText(backupWarning, contains: "且无法从备份恢复", variant, "backup warning")
            capture(app, variant, "Settings-BackupScope")
            app.navigationBars.buttons.firstMatch.tap()

            let clear = reveal(element(app, "settings.cleardata.button"), in: app, variant)
            capture(app, variant, "Settings-ClearDataRow")
            // The footer under the button is the last thing on the page: it
            // must scroll clear of the tab bar, not just exist.
            let footer = reveal(labelText(app, "settings.cleardata.recipeWarning", containing: "厨房备份不包含用户菜谱",
                                          variant), in: app, variant)
            assertFullText(footer, contains: "清除后无法从备份恢复", variant, "clear-data footer")
            let tabBar = app.tabBars.firstMatch
            if tabBar.exists {
                XCTAssertLessThanOrEqual(footer.frame.maxY, tabBar.frame.minY + 1,
                                         "\(variant.name): footer \(footer.frame) under tab bar \(tabBar.frame)")
            }
            capture(app, variant, "Settings-ClearDataFooter")
            reveal(clear, in: app, variant).tap()
            let prompt = app.alerts["清除全部本地数据？"]
            XCTAssertTrue(prompt.waitForExistence(timeout: 5), "\(variant.name): clear-data prompt")
            assertFullText(text(prompt, containing: "厨房备份不包含用户菜谱"), contains: "清除后无法从备份恢复",
                           variant, "clear-data prompt message")
            capture(app, variant, "Settings-ClearDataPrompt")
            app.terminate()
        }
    }

    // MARK: - Account deletion copy

    func testAccountDeletionStatesWhatItClears() {
        for variant in variants {
            let app = launch(["UITEST_ACCOUNT_OWNER", "UITEST_ACCOUNT_TEST"], variant)
            app.tabBars.buttons["我的"].tap()
            reveal(app.buttons["settings.account.entry"], in: app, variant).tap()
            XCTAssertTrue(app.navigationBars.staticTexts["账号"].waitForExistence(timeout: 10), "\(variant.name): 账号")
            reveal(app.buttons["account.delete.link"], in: app, variant).tap()
            let notice = reveal(text(app, containing: "删除完成后会自动退出登录"), in: app, variant)
            assertFullText(notice, contains: "请先到「设置 › 备份与恢复」导出备份", variant, "local data notice")
            capture(app, variant, "Account-DeletionNotice")
            app.terminate()
        }
    }

    // MARK: - Shopping: mark-all undo, clear purchased

    func testShoppingMarkAllUndoAndClearPurchasedNotice() {
        for variant in variants {
            let app = launch(["UITEST_SEED_SHOPPING"], variant)
            XCTAssertTrue(app.navigationBars.staticTexts["买菜"].waitForExistence(timeout: 8), "\(variant.name): 买菜")
            let bulk = app.buttons["shopping.bulk.menu"]
            assertReachable(bulk, in: app, variant, "bulk menu")
            bulk.tap()
            app.buttons["全部标记为已购买"].firstMatch.tap()
            let undo = app.buttons["feedback.toast.action"]
            XCTAssertTrue(undo.waitForExistence(timeout: 5), "\(variant.name): undo toast")
            assertReachable(undo, in: app, variant, "撤销")
            capture(app, variant, "Shopping-MarkAllUndoToast")

            bulk.tap()
            app.buttons["清除已购买"].firstMatch.tap()
            let stockFirst = app.buttons["先全部入库"].firstMatch
            XCTAssertTrue(stockFirst.waitForExistence(timeout: 5), "\(variant.name): clear-purchased notice")
            XCTAssertTrue(text(app, containing: "还没有入库").exists, "\(variant.name): says they are not stocked")
            assertReachable(stockFirst, in: app, variant, "先全部入库")
            capture(app, variant, "Shopping-ClearPurchasedNotice")
            app.terminate()
        }
    }

    // MARK: - Planner: a completed meal's servings

    func testCompletedMealShowsItsServingsAsText() {
        let cookedMeal = "planner.meal.63000000-0000-0000-0000-000000000001"
        for variant in variants {
            let app = launch(["UITEST_SEED_PLANNER_REGRESSION", "PLANNER_DATA_WEEK"], variant)
            XCTAssertTrue(app.navigationBars["用餐计划"].waitForExistence(timeout: 10), "\(variant.name): planner")
            let row = app.buttons[cookedMeal]
            for _ in 0..<8 where !row.exists { app.swipeUp() }
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(variant.name): cooked meal row")
            row.swipeRight()
            let edit = app.buttons["编辑"].firstMatch
            XCTAssertTrue(edit.waitForExistence(timeout: 5), "\(variant.name): 编辑")
            edit.tap()
            XCTAssertTrue(app.navigationBars["编辑这一餐"].waitForExistence(timeout: 5), "\(variant.name): editor")
            let footer = reveal(app.staticTexts["planner.mealForm.cookedFooter"], in: app, variant)
            assertFullText(footer, contains: "这道菜已完成，份量不再可改", variant, "cooked footer")
            XCTAssertTrue(app.staticTexts["2 人份"].exists, "\(variant.name): fixed servings as text")
            capture(app, variant, "Planner-CompletedMealServings")
            app.terminate()
        }
    }

    // MARK: - Home: a stuck shared link

    func testStuckSharedLinkCanBeRemoved() {
        for variant in variants {
            // The removal toast normally lasts 1.8s, which the idle wait after
            // the tap can outrun on CI; the argument holds it for the check.
            let app = launch(["UITEST_SEED_EMPTY_HOME", "UITEST_SEED_SHARED_IMPORT_STUCK", "UITEST_LONG_FEEDBACK_TOAST"],
                             variant)
            let discard = app.buttons["sharedImport.discard"]
            XCTAssertTrue(discard.waitForExistence(timeout: 15), "\(variant.name): the shared link sheet")
            assertReachable(discard, in: app, variant, "不再导入")
            assertReachable(app.buttons["关闭"], in: app, variant, "关闭")
            capture(app, variant, "SharedImport-StuckLink")
            discard.tap()
            XCTAssertTrue(text(app, containing: "已移除这条分享").waitForExistence(timeout: 5), "\(variant.name): removal toast")
            XCTAssertFalse(discard.exists, "\(variant.name): the sheet closes")
            capture(app, variant, "SharedImport-Removed")
            app.terminate()
        }
    }

    // MARK: - Cook confirmation: unit mismatch and a status staple

    func testConsumptionSheetExplainsUnitsAndStatusStaples() {
        for variant in variants {
            let app = launch(["UITEST_SEED_CONSUMPTION_REVIEW"], variant)
            let recipe = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.list.")).firstMatch
            XCTAssertTrue(recipe.waitForExistence(timeout: 10), "\(variant.name): recipe list")
            recipe.tap()
            reveal(app.buttons["recipe.detail.startCooking"], in: app, variant).tap()
            let finish = app.buttons["recipe.cooking.finish"]
            for _ in 0..<10 where !finish.exists {
                let next = app.buttons["recipe.cooking.next"]
                XCTAssertTrue(next.waitForExistence(timeout: 3), "\(variant.name): next step")
                next.tap()
            }
            finish.tap()
            XCTAssertTrue(app.navigationBars.staticTexts["确认本次食材消耗"].waitForExistence(timeout: 8), "\(variant.name): sheet")
            capture(app, variant, "Consumption-Top")

            let staple = labelText(app, identifier: NSPredicate(format: "identifier ENDSWITH %@", ".statusStaple"),
                                   containing: "按状态记录，不自动扣减", variant)
            reveal(staple, in: app, variant)
            assertFullText(text(app, containing: "按状态记录的常备食材"), contains: "做饭不会自动扣减", variant, "status staple note")
            XCTAssertFalse(text(app, containing: "没有找到「葱」").exists, "\(variant.name): a status staple is never reported missing")
            capture(app, variant, "Consumption-StatusStaple")

            let mismatch = labelText(app, identifier: NSPredicate(format: "identifier ENDSWITH %@", ".notDeducted"),
                                     containing: "单位不同，未扣减", variant)
            reveal(mismatch, in: app, variant)
            assertFullText(text(app, containing: "和菜谱的单位不同"), contains: "未扣减", variant, "unit mismatch note")
            capture(app, variant, "Consumption-UnitMismatch")

            reveal(app.buttons["更新冰箱"], in: app, variant)
            capture(app, variant, "Consumption-Bottom")
            app.terminate()
        }
    }
}
