import XCTest
@testable import KitchenManager

/// The Kitchen AI conversation value layer.
///
/// These tests exist because the conversation layer is the one place where model
/// output crosses into the app. If that boundary accepted arbitrary payloads, a
/// provider could name UI or smuggle unvalidated mutations through a dictionary.
/// So the block set is closed at six cases, mutation intent is a closed enum of
/// five proposals, and every type round-trips losslessly through Codable because
/// these values are what local history actually stores.
@MainActor
final class AIConversationModelsTests: XCTestCase {
    private func makeRecipe(id: String = "ai-probe", title: String = "番茄鸡蛋面") -> Recipe {
        Recipe(
            id: id,
            title: title,
            cookingTime: 15,
            difficulty: "简单",
            tags: ["家常"],
            ingredients: ["番茄 2 个", "鸡蛋 2 个"],
            steps: ["炒熟"],
            baseServings: 2
        )
    }

    // MARK: - Content blocks

    func testContentBlocksRoundTripWithoutArbitraryWidgetCase() throws {
        let recipe = makeRecipe()
        let blocks: [AIContentBlock] = [
            .text(.init(text: "推荐两个选择")),
            .recipe(.init(recipe: recipe, isTransient: true, reason: "优先使用临期番茄")),
            .plannerPreview(.init(
                title: "周三 · 晚餐",
                changes: [.init(targetID: UUID(), before: "宫保鸡丁", after: "清蒸鲈鱼")],
                pendingActionID: UUID()
            )),
            .contextResult(.init(title: "快过期", rows: [.init(label: "青椒", detail: "明天")])),
            .actionStatus(.init(message: "已加入今晚", actionID: UUID(), canUndo: true)),
            .error(.init(message: "暂时无法读取库存", retry: .contextRead))
        ]

        let data = try JSONEncoder().encode(blocks)
        XCTAssertEqual(try JSONDecoder().decode([AIContentBlock].self, from: data), blocks)
    }

    /// Every block carries a stable identity so a SwiftUI `ForEach` over a
    /// streaming message never reuses one block's view for another's content.
    func testEveryBlockExposesItsOwnStableIdentity() {
        let text = AITextBlock(text: "一")
        let status = AIActionStatusBlock(message: "已加入今晚", actionID: UUID(), canUndo: false)
        XCTAssertEqual(AIContentBlock.text(text).id, text.id)
        XCTAssertEqual(AIContentBlock.actionStatus(status).id, status.id)
        XCTAssertNotEqual(AIContentBlock.text(text).id, AIContentBlock.actionStatus(status).id)
    }

    /// A transient AI recipe is not yet canonical kitchen truth. The flag has to
    /// survive storage, because history rendering must not silently imply that a
    /// never-saved suggestion exists in `RecipeStore`.
    func testTransientRecipeFlagSurvivesStorage() throws {
        let block = AIRecipeBlock(recipe: makeRecipe(), isTransient: true, reason: nil)
        let decoded = try JSONDecoder().decode(
            AIRecipeBlock.self, from: JSONEncoder().encode(block)
        )
        XCTAssertTrue(decoded.isTransient)
        XCTAssertEqual(decoded.recipe, block.recipe)
        XCTAssertNil(decoded.reason)
    }

    // MARK: - Messages and conversations

    func testMessageRoundTripPreservesBlockOrder() throws {
        let conversationID = UUID()
        let message = AIConversationMessage(
            conversationID: conversationID,
            role: .assistant,
            state: .completed,
            contentBlocks: [
                .text(.init(text: "先看库存")),
                .contextResult(.init(title: "库存", rows: [.init(label: "鸡蛋", detail: "4 个")])),
                .text(.init(text: "两个选择"))
            ],
            turnID: UUID()
        )

        let decoded = try JSONDecoder().decode(
            AIConversationMessage.self, from: JSONEncoder().encode(message)
        )
        XCTAssertEqual(decoded, message)
        XCTAssertEqual(decoded.contentBlocks.count, 3)
        if case .contextResult = decoded.contentBlocks[1] {} else {
            XCTFail("block order changed during storage")
        }
    }

    /// Entitlement is evaluated by policy at runtime. Persisting a plan name would
    /// make a stale subscription string act as truth and could make local history
    /// look unreadable merely because a tier value changed.
    func testConversationStoresNoSubscriptionOrTierTruth() throws {
        let conversation = AIConversation(
            title: AIConversation.defaultTitle,
            lifecycleType: .weeklyPlanning,
            entryAffinity: .weeklyPlanning,
            lastActivityAt: Date(timeIntervalSince1970: 1_700_000_000),
            activeUntil: Date(timeIntervalSince1970: 1_700_172_800)
        )

        let object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(conversation)
        ) as? [String: Any]
        let keys = Set((object?.keys ?? [:].keys).map { $0.lowercased() })
        XCTAssertFalse(keys.isEmpty)
        for forbidden in ["tier", "subscription", "entitlement", "ispro", "ispaid", "billing"] {
            XCTAssertFalse(
                keys.contains(where: { $0.contains(forbidden) }),
                "conversation must not persist \(forbidden) as truth"
            )
        }
    }

    /// A user rename is a decision, not a cache. Title generation has to be able to
    /// tell "still the placeholder" from "the user named this", so the distinction
    /// is stored rather than guessed from the string.
    func testUserEditedTitleIsRepresentedExplicitly() throws {
        var conversation = AIConversation(
            title: AIConversation.defaultTitle,
            activeUntil: Date(timeIntervalSince1970: 1_700_172_800)
        )
        XCTAssertFalse(conversation.hasUserEditedTitle)
        XCTAssertTrue(conversation.acceptsGeneratedTitle)

        conversation.applyUserTitle("周三聚餐")
        XCTAssertTrue(conversation.hasUserEditedTitle)
        XCTAssertFalse(conversation.acceptsGeneratedTitle)

        let decoded = try JSONDecoder().decode(
            AIConversation.self, from: JSONEncoder().encode(conversation)
        )
        XCTAssertEqual(decoded, conversation)
        XCTAssertTrue(decoded.hasUserEditedTitle)
    }

    /// Title generation runs after the first response and can land late. A rename
    /// that got there first is a decision, so the generated title is dropped
    /// rather than allowed to overwrite it.
    func testGeneratedTitleNeverOverwritesAUserTitle() {
        var conversation = AIConversation(
            title: AIConversation.defaultTitle,
            activeUntil: Date(timeIntervalSince1970: 1_700_172_800)
        )
        conversation.applyGeneratedTitle("今晚吃什么")
        XCTAssertEqual(conversation.title, "今晚吃什么")
        XCTAssertFalse(conversation.hasUserEditedTitle)

        conversation.applyUserTitle("周三聚餐")
        conversation.applyGeneratedTitle("清淡晚餐建议")
        XCTAssertEqual(conversation.title, "周三聚餐")

        var blank = AIConversation(activeUntil: Date(timeIntervalSince1970: 1))
        blank.applyGeneratedTitle("   ")
        XCTAssertEqual(blank.title, AIConversation.defaultTitle)
        blank.applyUserTitle("   ")
        XCTAssertFalse(blank.hasUserEditedTitle)
    }

    /// A seventh, open-ended block case is exactly the failure the closed set
    /// exists to prevent, so an unknown discriminator must not decode.
    func testUnknownBlockKindDoesNotDecode() {
        let unknown = Data(#"{"customWidget":{"_0":{"html":"<b>hi</b>"}}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AIContentBlock.self, from: unknown))
    }

    /// Turn state answers "may the user send now" in one place. `.awaitingConfirmation`
    /// accepts input on purpose: a pending preview must not freeze the composer.
    func testTurnStateOwnsComposerAvailability() {
        for state in [AIConversationTurnState.idle, .completed, .cancelled, .failed, .awaitingConfirmation] {
            XCTAssertTrue(state.acceptsUserInput, "\(state) should accept input")
        }
        for state in [AIConversationTurnState.preparingContext, .requesting, .streaming, .toolRequested, .executing] {
            XCTAssertFalse(state.acceptsUserInput, "\(state) should not accept input")
        }
        XCTAssertEqual(
            [AIConversationTurnState.completed, .cancelled, .failed].filter(\.isTerminal).count, 3
        )
        XCTAssertFalse(AIConversationTurnState.streaming.isTerminal)
    }

    // MARK: - Actions

    func testActionProposalsMapToTheFiveApprovedTypes() {
        let recipe = AIRecipeBlock(recipe: makeRecipe(), isTransient: false)
        let planID = UUID()
        let cases: [(AIActionProposal, AIActionType)] = [
            (.addRecipeToTonight(recipe: recipe), .addRecipeToTonight),
            (.replacePlannedMeal(planID: planID, replacement: recipe), .replacePlannedMeal),
            (.applyPlannerChanges(changes: [
                .init(planID: planID, replacement: recipe, plannedServings: 2)
            ]), .applyPlannerChanges),
            (.replaceSpecialPlanDishes(planID: planID, changes: [
                .init(dishID: UUID(), replacement: recipe)
            ]), .replaceSpecialPlanDishes),
            (.addShoppingItems(items: [
                .init(name: "青椒", quantity: 2, unit: "个", remark: nil)
            ]), .addShoppingItems)
        ]

        XCTAssertEqual(Set(AIActionType.allCases.map(\.rawValue)).count, 5)
        for (proposal, expected) in cases {
            XCTAssertEqual(proposal.actionType, expected)
        }
    }

    func testActionProposalRoundTripsAndKeepsItsDomainReferences() throws {
        let planID = UUID()
        let proposal = AIActionProposal.replacePlannedMeal(
            planID: planID,
            replacement: AIRecipeBlock(recipe: makeRecipe(), isTransient: false)
        )
        let decoded = try JSONDecoder().decode(
            AIActionProposal.self, from: JSONEncoder().encode(proposal)
        )
        XCTAssertEqual(decoded, proposal)
        XCTAssertEqual(decoded.relatedEntityIDs, [planID.uuidString, "ai-probe"])
    }

    /// The batch proposals are the ones with flattening logic, so their entity
    /// references have to be deterministic across decodings.
    func testBatchProposalsFlattenDomainReferencesDeterministically() {
        let firstPlan = UUID()
        let secondPlan = UUID()
        let dish = UUID()
        let specialPlan = UUID()
        let a = AIRecipeBlock(recipe: makeRecipe(id: "r-a"), isTransient: false)
        let b = AIRecipeBlock(recipe: makeRecipe(id: "r-b"), isTransient: true)

        XCTAssertEqual(
            AIActionProposal.applyPlannerChanges(changes: [
                .init(planID: firstPlan, replacement: a),
                .init(planID: secondPlan, replacement: b)
            ]).relatedEntityIDs,
            [firstPlan.uuidString, "r-a", secondPlan.uuidString, "r-b"]
        )
        XCTAssertEqual(
            AIActionProposal.replaceSpecialPlanDishes(planID: specialPlan, changes: [
                .init(dishID: dish, replacement: a)
            ]).relatedEntityIDs,
            [specialPlan.uuidString, dish.uuidString, "r-a"]
        )
        XCTAssertEqual(
            AIActionProposal.addShoppingItems(items: [
                .init(name: "青椒", quantity: 2, unit: "个")
            ]).relatedEntityIDs,
            ["青椒|2.0|个"]
        )
        XCTAssertEqual(
            AIActionProposal.addRecipeToTonight(recipe: b).relatedEntityIDs, ["r-b"]
        )
    }

    /// `relatedEntityIDs` is provenance, not identity.
    ///
    /// Two proposals that touch the same rows but differ in payload — a different
    /// serving count, a different remark — must not be mistaken for each other.
    /// Pinning that here stops a later idempotency key from being derived from
    /// these values alone, which would silently drop a real second edit.
    func testDomainReferencesDoNotDistinguishDifferentPayloads() {
        let planID = UUID()
        let recipe = AIRecipeBlock(recipe: makeRecipe(id: "r-a"), isTransient: false)
        let twoServings = AIActionProposal.applyPlannerChanges(changes: [
            .init(planID: planID, replacement: recipe, plannedServings: 2)
        ])
        let fourServings = AIActionProposal.applyPlannerChanges(changes: [
            .init(planID: planID, replacement: recipe, plannedServings: 4)
        ])
        XCTAssertEqual(twoServings.relatedEntityIDs, fourServings.relatedEntityIDs)
        XCTAssertNotEqual(twoServings, fourServings)

        let plain = AIActionProposal.addShoppingItems(items: [
            .init(name: "青椒", quantity: 2, unit: "个")
        ])
        let remarked = AIActionProposal.addShoppingItems(items: [
            .init(name: "青椒", quantity: 2, unit: "个", remark: "要小个的")
        ])
        XCTAssertEqual(plain.relatedEntityIDs, remarked.relatedEntityIDs)
        XCTAssertNotEqual(plain, remarked)
    }

    /// The receipt is what Undo actually replays. It stores both the pre-mutation
    /// state to restore and the post-mutation state to compare against, so a later
    /// user edit can be detected instead of silently overwritten.
    func testMutationReceiptRoundTripsBeforeAndAfterState() throws {
        let before = MealPlanItem(recipeID: "old", recipeName: "宫保鸡丁")
        let after = MealPlanItem(id: before.id, recipeID: "new", recipeName: "清蒸鲈鱼")
        let receipt = AIDomainMutationReceipt.plannerReplacement(
            before: [before], after: [after], createdRecipeIDs: ["ai-generated-1"]
        )

        let record = AIConversationActionRecord(
            conversationID: UUID(),
            turnID: UUID(),
            actionType: .replacePlannedMeal,
            idempotencyKey: "abc123",
            status: .succeeded,
            relatedEntityIDs: [before.id.uuidString],
            undoReference: receipt
        )

        let decoded = try JSONDecoder().decode(
            AIConversationActionRecord.self, from: JSONEncoder().encode(record)
        )
        XCTAssertEqual(decoded, record)
        guard case let .plannerReplacement(decodedBefore, decodedAfter, decodedCreated) = decoded.undoReference else {
            return XCTFail("undo receipt lost its planner payload")
        }
        XCTAssertEqual(decodedBefore, [before])
        XCTAssertEqual(decodedAfter, [after])
        // The ids a replacement created survive the round trip too. Undo needs
        // them to take back a recipe the action itself wrote.
        XCTAssertEqual(decodedCreated, ["ai-generated-1"])
        XCTAssertEqual(decoded.undoReference?.createdRecipeIDs, ["ai-generated-1"])
    }

    func testContextSnapshotRoundTripsProvenanceOnly() throws {
        let snapshot = AIContextSnapshot(
            turnID: UUID(),
            readAt: Date(timeIntervalSince1970: 1_700_000_000),
            contextKinds: [.inventory, .tonightPlan],
            relatedEntityIDs: ["plan-1"],
            sourceFingerprints: ["inventory:12"]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                AIContextSnapshot.self, from: JSONEncoder().encode(snapshot)
            ),
            snapshot
        )
    }

    // MARK: - Entry context

    func testEntryContextCarriesOnlyItsOwnAnchor() {
        let weekStart = Date(timeIntervalSince1970: 1_700_000_000)
        let specialPlanID = UUID()
        XCTAssertEqual(AIConversationEntryContext.home.newConversationLifecycle, .dailyMeal)
        XCTAssertEqual(
            AIConversationEntryContext.planner(weekStart: weekStart, specialPlanID: specialPlanID)
                .newConversationLifecycle,
            .weeklyPlanning
        )
        XCTAssertEqual(
            AIConversationEntryContext.planner(weekStart: weekStart, specialPlanID: nil).anchorDate,
            weekStart
        )
        XCTAssertNil(AIConversationEntryContext.home.anchorDate)
    }

    /// The whole value layer has to work off the main actor: persistence, the
    /// orchestrator's transcript assembly, and Codable all run outside the UI actor.
    nonisolated func testValuesAreUsableOffTheMainActor() async throws {
        try await Task.detached {
            let block = AIContentBlock.text(.init(text: "离主线程"))
            let decoded = try JSONDecoder().decode(
                AIContentBlock.self, from: JSONEncoder().encode(block)
            )
            XCTAssertEqual(decoded, block)
        }.value
    }
}
