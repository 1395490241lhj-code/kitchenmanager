#if DEBUG
import Foundation

nonisolated enum AIConversationAcceptanceFixture {
    static let mealID = UUID(uuidString: "12000000-0000-0000-0000-000000000002")!
    static let specialPlanID = UUID(uuidString: "12000000-0000-0000-0000-000000000004")!
    static let spicyDishIDs = [
        UUID(uuidString: "12000000-0000-0000-0000-000000000041")!,
        UUID(uuidString: "12000000-0000-0000-0000-000000000042")!
    ]
    static var scenario: String? {
        ["A", "B", "C", "D"].first {
            ProcessInfo.processInfo.arguments.contains("UITEST_AI_CONVERSATION_ACCEPTANCE_\($0)")
        }
    }

    @MainActor static func seed(kitchenStore: KitchenStore, recipeStore: RecipeStore, conversationStore: ConversationStore) {
        guard scenario != nil else { return }
        kitchenStore.addInventory(name: "新鲜菠菜", quantity: 2, unit: "把", expiryDate: nil)
        if scenario == "C" {
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            let conversation = AIConversation(
                id: UUID(uuidString: "12000000-0000-0000-0000-000000000003")!,
                createdAt: date, title: "过期库存记录", lifecycleType: .dailyMeal,
                entryAffinity: .dailyMeal, lastActivityAt: date, activeUntil: date)
            let message = AIConversationMessage(conversationID: conversation.id, role: .assistant,
                createdAt: date, state: .completed,
                contentBlocks: [.text(.init(text: "库存里只有旧土豆 1 个"))], turnID: UUID())
            try! conversationStore.saveConversation(conversation)
            try! conversationStore.saveMessage(message)
        }
        for (id, title, ingredient) in [("acceptance-spinach", "清炒菠菜", "新鲜菠菜"),
                                         ("acceptance-tofu", "清蒸豆腐", "豆腐")] {
            try! recipeStore.saveUserRecipe(Recipe(id: id, title: title, cookingTime: 10,
                difficulty: "简单", tags: [], ingredients: [ingredient], steps: ["清洗后蒸熟。"]))
        }
        if scenario == "B" {
            let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 18))!
            kitchenStore.plans = [MealPlanItem(id: mealID, recipeID: "acceptance-chicken",
                recipeName: "香辣鸡丁", date: date)]
        }
        if scenario == "D" {
            let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 18))!
            kitchenStore.specialPlans = [SpecialPlan(id: specialPlanID, title: "七人聚餐",
                scheduledAt: date, peopleCount: 7, constraintNotes: ["不吃辣", "不吃花生"],
                dishes: [
                    SpecialPlanDish(id: spicyDishIDs[0], recipeID: "old-tofu", recipeName: "麻辣豆腐"),
                    SpecialPlanDish(id: spicyDishIDs[1], recipeID: "old-chicken", recipeName: "辣子鸡"),
                    SpecialPlanDish(id: UUID(uuidString: "12000000-0000-0000-0000-000000000043")!, recipeID: "rice", recipeName: "白米饭")
                ], createdAt: date, updatedAt: date)]
        }
    }
}
#endif
