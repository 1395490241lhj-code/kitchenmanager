import XCTest
import UserNotifications
@testable import KitchenManager

@MainActor
final class RecipeCookingSupportTests: XCTestCase {
    /// The controller schedules on its own `Task`. The fakes below never
    /// suspend, so a few yields let that task run to the end.
    private func drainNotificationTask() async {
        for _ in 0..<5 { await Task.yield() }
    }

    func testServingScalerHandlesFractionsDecimalsAndFreeText() {
        XCTAssertEqual(RecipeServingScaler.scaledText("番茄 1/2 个", multiplier: 2), "番茄 1 个")
        XCTAssertEqual(RecipeServingScaler.scaledText("油 1.5 汤匙", multiplier: 2), "油 3 汤匙")
        XCTAssertEqual(RecipeServingScaler.scaledText("盐 适量", multiplier: 4), "盐 适量")
    }

    func testCookingSessionKeepsChecklistAndStepNavigationWithinBounds() {
        let session = RecipeCookingSession(servings: 2)
        session.toggleIngredient(at: 1)
        XCTAssertEqual(session.checkedIngredientIndexes, [1])
        session.toggleIngredient(at: 1)
        XCTAssertTrue(session.checkedIngredientIndexes.isEmpty)
        session.previous(stepCount: 3)
        XCTAssertEqual(session.currentStepIndex, 0)
        session.next(stepCount: 3); session.next(stepCount: 3); session.next(stepCount: 3)
        XCTAssertEqual(session.currentStepIndex, 2)
        XCTAssertTrue(session.completedStepIndexes.isEmpty)
        session.toggleStep(at: 2)
        XCTAssertEqual(session.completedStepIndexes, [2])
        session.moveToStep(8, stepCount: 0)
        XCTAssertEqual(session.currentStepIndex, 0)
    }

    func testTimerUsesAbsoluteEndDateAcrossPauseResumeAndDelayedRefresh() {
        let start = Date(timeIntervalSince1970: 1_000)
        var state = CookingTimerState()
        state.start(seconds: 120, now: start)
        XCTAssertEqual(state.endDate, start.addingTimeInterval(120))

        XCTAssertFalse(state.refresh(now: start.addingTimeInterval(65.2)))
        XCTAssertEqual(state.remainingSeconds, 55)
        state.pause(now: start.addingTimeInterval(65.2))
        XCTAssertNil(state.endDate)

        let resumeDate = start.addingTimeInterval(500)
        state.resume(now: resumeDate)
        XCTAssertEqual(state.endDate, resumeDate.addingTimeInterval(55))
        XCTAssertFalse(state.refresh(now: resumeDate.addingTimeInterval(54)))
        XCTAssertEqual(state.remainingSeconds, 1)
        XCTAssertTrue(state.refresh(now: resumeDate.addingTimeInterval(55)))
        XCTAssertEqual(state.status, .finished)
        XCTAssertNil(state.endDate)
        XCTAssertFalse(state.refresh(now: resumeDate.addingTimeInterval(80)))
        XCTAssertEqual(state.status, .finished)

        state.cancel()
        XCTAssertEqual(state.status, .idle)
        XCTAssertEqual(state.remainingSeconds, 0)
    }

    func testTimerControllerResolvesFinishedWhenForegroundRefreshFindsPassedEndDate() {
        let start = Date(timeIntervalSince1970: 2_000)
        let controller = CookingTimerController(
            notificationAuthorizationStatus: { .denied },
            requestNotificationAuthorization: {},
            scheduleNotification: { _ in },
            cancelNotification: {}
        )

        controller.start(seconds: 30, now: start)
        controller.refresh(now: start.addingTimeInterval(31))

        XCTAssertEqual(controller.state.status, .finished)
        XCTAssertEqual(controller.state.remainingSeconds, 0)
        XCTAssertNil(controller.state.endDate)
    }

    func testTimerControllerCancelsBeforeCancelAndRestartScheduling() async {
        var events: [String] = []
        let controller = CookingTimerController(
            notificationAuthorizationStatus: { .authorized },
            requestNotificationAuthorization: { events.append("authorize") },
            scheduleNotification: { _ in events.append("schedule") },
            cancelNotification: { events.append("cancel") }
        )

        controller.start(seconds: 60)
        await drainNotificationTask()
        controller.cancel()
        controller.start(seconds: 60)
        await drainNotificationTask()

        XCTAssertEqual(events, ["cancel", "schedule", "cancel", "cancel", "schedule"])
    }

    func testTimerControllerAsksForNotificationsOnStartWhileUndecided() async {
        var events: [String] = []
        let controller = CookingTimerController(
            notificationAuthorizationStatus: { .notDetermined },
            requestNotificationAuthorization: { events.append("authorize") },
            scheduleNotification: { _ in events.append("schedule") },
            cancelNotification: { events.append("cancel") }
        )

        controller.start(seconds: 60)
        await drainNotificationTask()

        // Asked first, so the notification is scheduled under the answer.
        XCTAssertEqual(events, ["cancel", "authorize", "schedule"])
    }

    /// Cancelling before the status answer arrives must not raise a prompt
    /// for a timer that no longer exists.
    func testTimerControllerDoesNotAskAfterTheTimerWasCancelled() async {
        var events: [String] = []
        let controller = CookingTimerController(
            notificationAuthorizationStatus: { .notDetermined },
            requestNotificationAuthorization: { events.append("authorize") },
            scheduleNotification: { _ in events.append("schedule") },
            cancelNotification: { events.append("cancel") }
        )

        controller.start(seconds: 60)
        controller.cancel()
        await drainNotificationTask()

        XCTAssertFalse(events.contains("authorize"), "取消后不再弹权限请求")
        XCTAssertFalse(events.contains("schedule"))
    }

    /// No UI test handles the system permission alert, so a UI-test launch
    /// never raises it; it would cover the timer screenshots.
    func testUITestLaunchesNeverRaiseTheNotificationPrompt() {
        XCTAssertFalse(CookingTimerController.asksForNotificationPermission(launchArguments: ["UITEST_SEED_RECIPE_COOKING"]))
        XCTAssertTrue(CookingTimerController.asksForNotificationPermission(launchArguments: ["-AppleLanguages", "(zh-Hans)"]))
    }

    func testTimerControllerDoesNotAskAgainOnceNotificationsWereDecided() async {
        for status in [UNAuthorizationStatus.denied, .authorized, .provisional] {
            var events: [String] = []
            let controller = CookingTimerController(
                notificationAuthorizationStatus: { status },
                requestNotificationAuthorization: { events.append("authorize") },
                scheduleNotification: { _ in events.append("schedule") },
                cancelNotification: { events.append("cancel") }
            )

            controller.start(seconds: 60)
            await drainNotificationTask()

            XCTAssertEqual(events, ["cancel", "schedule"], "authorization status \(status.rawValue)")
        }
    }

    func testTimerControllerKeepsTheDueNotificationWhenTheTimerFinishesNaturally() async {
        let start = Date(timeIntervalSince1970: 3_000)
        var events: [String] = []
        let controller = CookingTimerController(
            notificationAuthorizationStatus: { .authorized },
            requestNotificationAuthorization: { events.append("authorize") },
            scheduleNotification: { _ in events.append("schedule") },
            cancelNotification: { events.append("cancel") }
        )

        controller.start(seconds: 30, now: start)
        await drainNotificationTask()
        events.removeAll()

        controller.refresh(now: start.addingTimeInterval(31))

        XCTAssertEqual(controller.state.status, .finished)
        XCTAssertEqual(events, [], "the pending notification is the alarm; finishing must not remove it")

        // Leaving the page afterwards still clears it, as before.
        controller.cancel()
        XCTAssertEqual(events, ["cancel"])
    }

    func testTimerControllerStillCancelsTheNotificationOnPauseAndCancel() async {
        var events: [String] = []
        let controller = CookingTimerController(
            notificationAuthorizationStatus: { .notDetermined },
            requestNotificationAuthorization: { events.append("authorize") },
            scheduleNotification: { _ in events.append("schedule") },
            cancelNotification: { events.append("cancel") }
        )

        controller.start(seconds: 60)
        await drainNotificationTask()
        events.removeAll()

        controller.pause()
        XCTAssertEqual(controller.state.status, .paused)
        XCTAssertEqual(events, ["cancel"])

        // Only a start asks for permission; resuming just reschedules.
        controller.resume()
        await drainNotificationTask()
        XCTAssertEqual(events, ["cancel", "cancel", "schedule"])

        events.removeAll()
        controller.cancel()
        XCTAssertEqual(events, ["cancel"])
    }

    func testOnlyTheCookingTimerNotificationIsPresentedInTheForeground() {
        // Pending requests from earlier builds use this identifier.
        XCTAssertEqual(CookingTimerNotificationDelegate.timerNotificationIdentifier, "native-km-cooking-timer")
        XCTAssertEqual(
            CookingTimerNotificationDelegate.presentationOptions(forNotificationIdentifier: "native-km-cooking-timer"),
            [.banner, .sound, .list]
        )
        // Expiry and restock reminders keep their current foreground behaviour:
        // nothing is shown while the app is open.
        for identifier in [
            "expiry-\(UUID().uuidString)-\(ExpiryNotificationLeadTime.dayOf.rawValue)",
            "staple-restock-\(UUID().uuidString)",
            ""
        ] {
            XCTAssertEqual(
                CookingTimerNotificationDelegate.presentationOptions(forNotificationIdentifier: identifier),
                [],
                identifier
            )
        }
    }

    func testStepTimerSuggestionAcceptsBoundedMinuteTextOnly() {
        XCTAssertEqual(RecipeStepTimerSuggestion.seconds(in: "小火焖 10 分钟"), 600)
        XCTAssertNil(RecipeStepTimerSuggestion.seconds(in: "适量煮熟"))
        XCTAssertNil(RecipeStepTimerSuggestion.seconds(in: "焖 999 分钟"))
        XCTAssertEqual(RecipeStepTimerSuggestion.seconds(in: "小火炖20分钟至软烂"), 1200)
        XCTAssertEqual(RecipeStepTimerSuggestion.seconds(in: "大火煮开后转小火焖5分钟"), 300)
        XCTAssertNil(RecipeStepTimerSuggestion.seconds(in: "焖1000分钟"))
    }

    func testScreenAwakeRestoresPriorState() {
        var value = false
        let controller = ScreenAwakeController(read: { value }, write: { value = $0 })
        controller.activate(); XCTAssertTrue(value)
        controller.deactivate(); XCTAssertFalse(value)
        value = true
        controller.activate(); controller.deactivate(); XCTAssertTrue(value)
    }

    func testCookingFinishOnlyMarksPlanWhenContextExists() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let bundle = KitchenPersistenceFactory.isolatedInMemory()
        let store = KitchenStore(userDefaults: defaults, inventoryPersistence: bundle.inventory, shoppingListPersistence: bundle.shoppingList, todayPlanPersistence: bundle.todayPlan, consumptionPersistence: bundle.consumption, weeklyPlanPersistence: bundle.weeklyPlan)
        let recipe = Recipe.samples[0]
        store.addPlan(recipe: recipe, plannedServings: 2)
        let plan = try! XCTUnwrap(store.todayPlans.first)
        XCTAssertFalse(plan.isCooked)
        store.markPlanCooked(plan)
        XCTAssertTrue(store.todayPlans.first?.isCooked == true)
    }
}
