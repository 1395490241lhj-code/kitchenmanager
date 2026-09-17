import XCTest
@testable import KitchenManager

@MainActor
final class ConversationContextAssemblerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let conversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let focusID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private final class Domain: AIConversationDomainTooling {
        var calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }()
        var reads: [AIContextKind] = []
        var openedWeek: Date?
        var eggs: Double = 2
        var lots = false
        var unicodeText: String?
        var reverse = false
        var stamp = Date(timeIntervalSince1970: 1)
        let eventDate = Date(timeIntervalSince1970: 500)
        var focusedID: UUID?
        var missing = false
        func inventoryContext(now: Date) -> AIInventoryContext {
            reads.append(.inventory)
            var items = [AIInventoryItemContext(name: unicodeText ?? "eggs", quantity: eggs, unit: "个", isStaple: false, isReadyToCook: false, remainingDays: 2)]
            if lots { items += (0..<100).map { AIInventoryItemContext(name: "food-\($0)" + String(repeating: "长", count: 500), quantity: 1, unit: "g", isStaple: false, isReadyToCook: false, remainingDays: 1) } }
            if reverse { items.reverse() }
            return .init(readAt: stamp, available: items, expiring: items)
        }
        func tonightPlanContext(now: Date, calendar: Calendar) -> AITonightPlanContext {
            reads.append(.tonightPlan)
            return .init(readAt: stamp, day: calendar.startOfDay(for: now), meals: [])
        }
        func plannerWeekContext(weekStart: Date, calendar: Calendar) -> AIPlannerWeekContext {
            reads.append(.plannerWeek); openedWeek = weekStart
            return .init(readAt: stamp, weekStart: weekStart, weekEnd: weekStart.addingTimeInterval(604800), meals: [], specialPlans: [])
        }
        func specialPlanContext(id: UUID) -> AISpecialPlanContext? {
            reads.append(.specialPlan); focusedID = id
            guard !missing else { return nil }
            return .init(readAt: stamp, planID: id, title: unicodeText ?? "聚餐", scheduledAt: eventDate,
                peopleCount: 4, constraintNotes: lots ? Array(repeating: String(repeating: "\"\n长", count: 500), count: 50) : ["无辣"], notes: lots ? String(repeating: "长", count: 10000) : "家人", usesHomeInventory: true, dishes: [])
        }
        func resolveRecipe(id: String) -> Recipe? { XCTFail("No recipe preload"); return nil }
        func addRecipeToTonight(_ block: AIRecipeBlock, now: Date) throws -> AIDomainMutationReceipt { fatalError("no mutation") }
        func replacePlannedMeals(_ changes: [AIPlannerMealChange]) throws -> AIDomainMutationReceipt { fatalError("no mutation") }
        func replaceSpecialPlanDishes(planID: UUID, changes: [AISpecialPlanDishChange]) throws -> AIDomainMutationReceipt { fatalError("no mutation") }
        func addShoppingItems(_ items: [AIShoppingItemProposal]) throws -> AIDomainMutationReceipt { fatalError("no mutation") }
        func undo(_ receipt: AIDomainMutationReceipt) throws { XCTFail("no mutation") }
    }

    private func message(_ text: String, index: Int = 100, role: AIConversationRole = .user,
                         state: AIConversationMessageState = .completed) -> AIConversationMessage {
        .init(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 10))!,
            conversationID: conversationID, role: role, createdAt: now.addingTimeInterval(Double(index)), state: state,
            contentBlocks: [.text(.init(text: text))], turnID: conversationID)
    }
    private func prepare(_ domain: Domain? = nil, entry: AIConversationEntryContext = .home,
                         history: [AIConversationMessage] = [], current: AIConversationMessage? = nil,
                         summary: String = "", excluded: Set<AIContextKind> = [], system: String = ConversationContextAssembler.instructions) throws -> PreparedAIConversationRequest {
        try ConversationContextAssembler(domainTools: domain ?? Domain()).prepare(entry: entry, summary: summary, messages: history,
            currentUserMessage: current ?? message("快过期的食材做什么"), excludedKinds: excluded, readAt: now, systemInstructions: system)
    }

    private func encodedCount(_ messages: [AIConversationTranscriptMessage]) -> Int {
        let values = messages.map { ["role": $0.role.rawValue, "content": $0.content!] }
        let data = try! JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .withoutEscapingSlashes])
        return (String(decoding: data, as: UTF8.self) as NSString).length
    }
    private func independentCounts(_ r: PreparedAIConversationRequest) -> [Int] {
        [encodedCount([r.messages[0]]), encodedCount([r.messages[1]]), encodedCount([r.messages[2]]),
         encodedCount(r.recentMessages), encodedCount([r.messages.last!])]
    }

    func testHomeExpiryPreloadsInventoryAndTonightOnly() throws {
        let d = Domain(); let r = try prepare(d)
        XCTAssertEqual(d.reads, [.inventory, .tonightPlan]); XCTAssertEqual(r.contexts.map(\.kind), [.inventory, .tonightPlan])
        XCTAssertFalse(r.liveContext.contains("weekStart")); XCTAssertFalse(r.liveContext.contains("specialPlans"))
    }
    func testHomeUnrelatedQuestionDoesNotReadInventory() throws {
        let d = Domain(); _ = try prepare(d, current: message("你好")); XCTAssertEqual(d.reads, [.tonightPlan])
    }
    func testPlannerUsesOpenedWeek() throws {
        let d = Domain(); _ = try prepare(d, entry: .planner(weekStart: now, specialPlanID: nil), current: message("安排菜单"))
        XCTAssertEqual(d.openedWeek, now); XCTAssertEqual(d.reads, [.plannerWeek])
    }
    func testPlannerReadsOnlyFocusedSpecialPlan() throws {
        let d = Domain(); let r = try prepare(d, entry: .planner(weekStart: now, specialPlanID: focusID), current: message("安排聚餐"))
        XCTAssertEqual(d.focusedID, focusID); XCTAssertEqual(d.reads, [.plannerWeek, .specialPlan])
        XCTAssertEqual(r.contexts.last?.anchorEntityID, focusID)
    }
    func testPlannerInventoryRequiresRelevantQuestion() throws {
        let d = Domain(); _ = try prepare(d, entry: .planner(weekStart: now, specialPlanID: nil))
        XCTAssertEqual(d.reads, [.inventory, .plannerWeek])
    }
    func testMissingFocusedPlanDoesNotInventContext() throws {
        let d = Domain(); d.missing = true
        let r = try prepare(d, entry: .planner(weekStart: now, specialPlanID: focusID), current: message("菜单"))
        XCTAssertEqual(r.contexts.map(\.kind), [.plannerWeek])
    }
    func testInventoryExclusionPreventsRead() throws {
        let d = Domain(); let r = try prepare(d, excluded: [.inventory])
        XCTAssertEqual(d.reads, [.tonightPlan]); XCTAssertFalse(r.liveContext.contains("eggs"))
    }
    func testExclusionsResetOnNextPrepare() throws {
        let d = Domain(); _ = try prepare(d, excluded: [.inventory]); d.eggs = 3
        let r = try prepare(d); XCTAssertEqual(d.reads, [.tonightPlan, .inventory, .tonightPlan]); XCTAssertTrue(r.liveContext.contains("\"quantity\":3"))
    }
    func testAllSelectedExclusionsPreventReads() throws {
        let d = Domain(); let r = try prepare(d, entry: .planner(weekStart: now, specialPlanID: focusID), excluded: Set(AIContextKind.allCases))
        XCTAssertTrue(d.reads.isEmpty); XCTAssertTrue(r.contexts.isEmpty)
    }
    func testOldFourEggClaimDoesNotReplaceLiveTwoEggs() throws {
        let r = try prepare(history: [message("4 eggs", index: 0, role: .assistant)])
        XCTAssertTrue(r.liveContext.contains("\"quantity\":2")); XCTAssertEqual(r.recentMessages.first?.content, "4 eggs")
    }
    func testEveryPreparationRereadsChangedInventory() throws {
        let d = Domain(); let a = try prepare(d); d.eggs = 7; let b = try prepare(d)
        XCTAssertNotEqual(a.liveContext, b.liveContext); XCTAssertTrue(b.liveContext.contains("\"quantity\":7"))
    }
    func testAtMostTwelvePriorMessages() throws {
        let h = (0..<20).map { message("m\($0)", index: $0) }; let r = try prepare(history: h)
        XCTAssertEqual(r.recentMessageIDs, Array(h.suffix(12)).map(\.id))
    }
    func testRecentBudgetTrimsOldestFirstPreservingOrder() throws {
        let h = (0..<6).map { message(String(repeating: "\($0)", count: 1000), index: $0) }
        let r = try prepare(history: h)
        XCTAssertEqual(r.recentMessageIDs, Array(h.suffix(3)).map(\.id)); XCTAssertLessThanOrEqual(independentCounts(r)[3], 3200)
    }
    func testOversizedHistoryIsSkippedWithoutTruncatingClaims() throws {
        let a = message("useful", index: 0); let r = try prepare(history: [a, message(String(repeating: "x", count: 4000), index: 1)])
        XCTAssertEqual(r.recentMessageIDs, [a.id])
    }
    func testCurrentRowExcludedByIdentityEvenWhenInHistory() throws {
        let u = message("same"); let earlier = message("same", index: 0)
        let r = try prepare(history: [earlier, u], current: u)
        XCTAssertEqual(r.recentMessageIDs, [earlier.id])
    }
    func testIncompleteAndSystemHistoryNotReplayed() throws {
        let r = try prepare(history: [message("failed", index: 1, state: .failed), message("stream", index: 2, state: .streaming), message("status", index: 3, role: .systemStatus)])
        XCTAssertTrue(r.recentMessages.isEmpty)
    }
    func testOtherConversationHistoryNotReplayed() throws {
        var foreign = message("SECRET OTHER CHAT"); foreign.conversationID = focusID
        let r = try prepare(history: [foreign]); XCTAssertTrue(r.recentMessages.isEmpty)
    }
    func testSystemBudgetIncludesFramingAndEscapes() throws {
        let r = try prepare(system: String(repeating: "\"\n👨‍👩‍👧‍👦", count: 2000))
        XCTAssertLessThanOrEqual(independentCounts(r)[0], 1600); XCTAssertGreaterThan(independentCounts(r)[0], 1500)
    }
    func testSummaryBudgetIncludesFramingAndEscapes() throws {
        let r = try prepare(summary: String(repeating: "\"\n👨‍👩‍👧‍👦", count: 2000))
        XCTAssertLessThanOrEqual(independentCounts(r)[1], 1200); XCTAssertGreaterThan(independentCounts(r)[1], 1100)
    }
    func testLiveBudgetRetainsValidJSONAndUsefulSources() throws {
        let d = Domain(); d.lots = true; let r = try prepare(d)
        XCTAssertLessThanOrEqual(independentCounts(r)[2], 3000)
        XCTAssertEqual(r.contexts.count, 2); _ = try JSONSerialization.jsonObject(with: Data(r.liveContext.utf8))
        for c in r.contexts { _ = try JSONSerialization.jsonObject(with: Data(c.value.utf8)) }
    }
    func testCurrentUserBudgetIncludesFramingAndEscapes() throws {
        let r = try prepare(current: message(String(repeating: "\"\n👨‍👩‍👧‍👦", count: 2000)))
        XCTAssertLessThanOrEqual(independentCounts(r)[4], 1500); XCTAssertGreaterThan(independentCounts(r)[4], 1400)
    }
    func testAllBucketsAndTotalNoBorrowing() throws {
        let d = Domain(); d.lots = true
        let long = String(repeating: "x", count: 20000)
        let r = try prepare(d, history: (0..<20).map { message(String(repeating: "y", count: 1000), index: $0) }, current: message("inventory " + long), summary: long, system: long)
        for (count, maximum) in zip(independentCounts(r), [1600,1200,3000,3200,1500]) { XCTAssertLessThanOrEqual(count, maximum) }
        XCTAssertLessThanOrEqual(independentCounts(r).reduce(0,+), 10500)
        XCTAssertLessThanOrEqual(encodedCount(r.messages), 10500)
    }
    func testSameInputsAreDeterministicDespiteAdapterClock() throws {
        let d = Domain(); let a = try prepare(d); d.stamp = now; let b = try prepare(d)
        XCTAssertEqual(a, b); XCTAssertFalse(a.liveContext.contains("readAt"))
    }
    func testInventoryOrderingIsStable() throws {
        let d = Domain(); d.lots = true; let a = try prepare(d); d.reverse = true
        XCTAssertEqual(a, try prepare(d))
    }
    func testProvenanceCarriesExplicitTimestampAndAnchors() throws {
        let d = Domain(); let r = try prepare(d, entry: .planner(weekStart: now, specialPlanID: focusID), current: message("菜单"))
        XCTAssertEqual(r.contexts.map(\.readAt), [now, now]); XCTAssertEqual(r.contexts[0].anchorDate, now)
        XCTAssertEqual(r.contexts[1].relatedEntityIDs, [focusID.uuidString]); XCTAssertEqual(r.contexts[1].anchorDate, d.eventDate)
    }
    func testRealDomainProjectionDoesNotLeakUnrelatedSecrets() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("SECRET_TOKEN_SENTINEL", forKey: "access_token")
        let store = KitchenStore(userDefaults: defaults)
        let recipes = RecipeStore(userDefaults: defaults)
        let r = try ConversationContextAssembler(domainTools: KitchenConversationDomainTools(kitchenStore: store, recipeStore: recipes))
            .prepare(entry: .home, summary: "", messages: [], currentUserMessage: message("库存"), excludedKinds: [], readAt: now)
        let text = r.messages.compactMap(\.content).joined()
        for secret in ["SECRET_TOKEN_SENTINEL", "access_token", "Authorization", "cursor", "householdID", "debug"] { XCTAssertFalse(text.contains(secret)) }
    }
    func testRejectsNonUserCurrentRow() {
        XCTAssertThrowsError(try prepare(current: message("assistant", role: .assistant)))
    }
    func testPlannerAndFocusedPlanClocksAreExcludedFromModelText() throws {
        let d = Domain(); let entry = AIConversationEntryContext.planner(weekStart: now, specialPlanID: focusID)
        let a = try prepare(d, entry: entry); d.stamp = now.addingTimeInterval(1000)
        XCTAssertEqual(a, try prepare(d, entry: entry))
        XCTAssertFalse(a.liveContext.contains("readAt"))
    }
    func testThreeSourceWorstCaseEscapingIsBoundedAndMarkedPartial() throws {
        let d = Domain(); d.lots = true
        let r = try prepare(d, entry: .planner(weekStart: now, specialPlanID: focusID))
        XCTAssertEqual(r.contexts.count, 3); XCTAssertLessThanOrEqual(independentCounts(r)[2], 3000)
        XCTAssertTrue(r.liveContext.contains("\"partial\":true"))
        _ = try JSONSerialization.jsonObject(with: Data(r.liveContext.utf8))
    }
    func testFutureRowsAreNotPriorHistory() throws {
        let r = try prepare(history: [message("future", index: 101)], current: message("now", index: 100))
        XCTAssertTrue(r.recentMessages.isEmpty)
    }
    func testRealDomainRereadsInventoryAndOmitsUnrelatedCollections() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = KitchenStore(userDefaults: defaults); let recipes = RecipeStore(userDefaults: defaults)
        var item = InventoryItem(name: "eggs", quantity: 4, unit: "个", expiryDate: nil)
        item.stapleNote = "SECRET_INVENTORY_NOTE"; store.inventory = [item]
        store.addSpecialPlan(.init(title: "SECRET_UNRELATED_EVENT", scheduledAt: now, notes: "SECRET_NOTES"))
        let unrelated = Recipe(id: "unrelated", title: "SECRET_UNRELATED_WEEK", cookingTime: nil, difficulty: nil, tags: [], ingredients: ["x"], steps: ["cook"])
        _ = store.addPlan(recipe: unrelated, on: now.addingTimeInterval(604800), plannedServings: nil, calendar: Calendar(identifier: .gregorian))
        let tools = KitchenConversationDomainTools(kitchenStore: store, recipeStore: recipes)
        let assembler = ConversationContextAssembler(domainTools: tools)
        let user = message("inventory"); let old = message("4 eggs", index: 1, role: .assistant)
        let first = try assembler.prepare(entry: .home, summary: "", messages: [old], currentUserMessage: user, excludedKinds: [], readAt: now)
        store.inventory[0].quantity = 2
        let next = try assembler.prepare(entry: .home, summary: "", messages: [old], currentUserMessage: user, excludedKinds: [], readAt: now)
        XCTAssertTrue(first.liveContext.contains("\"quantity\":4")); XCTAssertTrue(next.liveContext.contains("\"quantity\":2"))
        XCTAssertFalse(next.liveContext.contains("SECRET_")); XCTAssertEqual(next.recentMessages.first?.content, "4 eggs")
    }


    private func assertUTF16Budgets(_ r: PreparedAIConversationRequest, file: StaticString = #filePath, line: UInt = #line) throws {
        let counts = independentCounts(r)
        XCTAssertEqual(r.bucketCharacterCounts, counts, file: file, line: line)
        for (count, maximum) in zip(counts, [1600, 1200, 3000, 3200, 1500]) {
            XCTAssertLessThanOrEqual(count, maximum, file: file, line: line)
        }
        XCTAssertLessThanOrEqual(counts.reduce(0, +), 10500, file: file, line: line)
        XCTAssertLessThanOrEqual(encodedCount(r.messages), 10500, file: file, line: line)
        // NSString length independently measures UTF-16, including supplementary scalars.
        XCTAssertLessThanOrEqual(r.messages.reduce(0) { $0 + (($1.content ?? "") as NSString).length }, 10500, file: file, line: line)
        for content in [r.system, r.summary, r.liveContext, r.currentUser] + r.contexts.map(\.value) {
            _ = try JSONSerialization.jsonObject(with: Data(content.utf8))
        }
    }

    func testZWJEmojiCurrentUserFitsUTF16WithoutSplittingGraphemes() throws {
        let emoji = "👨‍👩‍👧‍👦"
        let r = try prepare(current: message(String(repeating: emoji, count: 2000)))
        try assertUTF16Budgets(r)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(r.currentUser.utf8)) as? [String: String])
        let text = try XCTUnwrap(object["message"])
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.allSatisfy { String($0) == emoji })
        XCTAssertGreaterThan(independentCounts(r)[4], 1480)
    }

    func testHugeCombiningClusterCurrentUserIsOmittedWhole() throws {
        let cluster = "a" + String(repeating: "\u{0301}", count: 15000)
        XCTAssertEqual(cluster.count, 1)
        let r = try prepare(current: message(cluster))
        try assertUTF16Budgets(r)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(r.currentUser.utf8)) as? [String: String])
        XCTAssertEqual(object["message"], "")
    }

    func testZWJEmojiRecentHistoryTrimsOldestByUTF16() throws {
        let h = (0..<4).map { message(String(repeating: "👨‍👩‍👧‍👦", count: 100), index: $0) }
        let r = try prepare(history: h)
        try assertUTF16Budgets(r)
        XCTAssertEqual(r.recentMessageIDs, Array(h.suffix(2)).map(\.id))
        XCTAssertEqual(r.recentMessages.map(\.content), Array(h.suffix(2)).map { Optional($0.plainTextSummary) })
    }

    func testHugeCombiningClusterRecentHistoryIsSkippedWhole() throws {
        let useful = message("retain this claim", index: 0)
        let huge = message("a" + String(repeating: "\u{0301}", count: 15000), index: 1)
        let r = try prepare(history: [useful, huge])
        try assertUTF16Budgets(r)
        XCTAssertEqual(r.recentMessageIDs, [useful.id])
    }

    func testZWJEmojiAllBucketsAndFinalTotalUseUTF16() throws {
        let text = String(repeating: "👨‍👩‍👧‍👦", count: 2000)
        let d = Domain(); d.unicodeText = text
        let r = try prepare(d, entry: .planner(weekStart: now, specialPlanID: focusID),
            history: (0..<12).map { message(String(repeating: "👨‍👩‍👧‍👦", count: 100), index: $0) },
            current: message("inventory " + text), summary: text, system: text)
        try assertUTF16Budgets(r)
        XCTAssertEqual(r.contexts.count, 3)
        XCTAssertTrue(r.liveContext.contains("\"partial\":true"))
    }

    func testHugeCombiningClusterAllBucketsAndFinalTotalUseUTF16() throws {
        let text = "a" + String(repeating: "\u{0301}", count: 15000)
        let d = Domain(); d.unicodeText = text
        let r = try prepare(d, entry: .planner(weekStart: now, specialPlanID: focusID),
            history: [message(text, index: 0)], current: message("inventory " + text), summary: text, system: text)
        try assertUTF16Budgets(r)
        XCTAssertEqual(r.contexts.count, 3)
        XCTAssertFalse(r.liveContext.contains("\u{0301}"))
        XCTAssertTrue(r.liveContext.contains("\"partial\":true"))
    }

}
