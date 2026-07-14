import Foundation
import SwiftData

@MainActor
struct KitchenPersistenceBundle {
    let inventory: InventoryPersistenceProtocol
    let shoppingList: ShoppingListPersistenceProtocol
    let todayPlan: TodayPlanPersistenceProtocol
    let consumption: ConsumptionPersistenceProtocol
    let weeklyPlan: WeeklyPlanPersistenceProtocol
    let userRecipes: UserRecipePersistenceProtocol
    let recipePreferences: RecipePreferencePersistenceProtocol
    let sync: any SyncPersistenceProtocol
}

@MainActor
enum KitchenPersistenceFactory {
    static func application() -> KitchenPersistenceBundle {
        makeBundle(isStoredInMemoryOnly: false)
    }

    static func isolatedInMemory() -> KitchenPersistenceBundle {
        makeBundle(isStoredInMemoryOnly: true)
    }

    private static func makeBundle(isStoredInMemoryOnly: Bool) -> KitchenPersistenceBundle {
        do {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: isStoredInMemoryOnly)
            let container = try ModelContainer(
                for: InventoryRecord.self,
                ShoppingItemRecord.self,
                TodayPlanRecord.self,
                ConsumptionRecordEntity.self,
                WeeklyPlanRecord.self,
                UserRecipeRecord.self,
                RecipePreferenceRecord.self,
                SyncMetadataRecord.self,
                PendingMutationRecord.self,
                SyncCursorRecord.self,
                configurations: configuration
            )
            return KitchenPersistenceBundle(
                inventory: SwiftDataInventoryPersistence(container: container),
                shoppingList: SwiftDataShoppingListPersistence(container: container),
                todayPlan: SwiftDataTodayPlanPersistence(container: container),
                consumption: SwiftDataConsumptionPersistence(container: container),
                weeklyPlan: SwiftDataWeeklyPlanPersistence(container: container),
                userRecipes: SwiftDataUserRecipePersistence(container: container),
                recipePreferences: SwiftDataRecipePreferencePersistence(container: container),
                sync: SwiftDataSyncPersistence(modelContainer: container)
            )
        } catch {
            #if DEBUG
            print("[KitchenPersistence] unable to initialize shared store: \(error)")
            #endif
            return KitchenPersistenceBundle(
                inventory: FailingInventoryPersistence(underlyingError: error),
                shoppingList: FailingShoppingListPersistence(underlyingError: error),
                todayPlan: FailingTodayPlanPersistence(underlyingError: error),
                consumption: FailingConsumptionPersistence(underlyingError: error),
                weeklyPlan: FailingWeeklyPlanPersistence(error),
                userRecipes: FailingUserRecipePersistence(error),
                recipePreferences: FailingRecipePreferencePersistence(error),
                sync: FailingSyncPersistence()
            )
        }
    }
}
