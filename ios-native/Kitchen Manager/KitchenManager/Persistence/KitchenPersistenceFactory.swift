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
    let preparedComponents: PreparedComponentPersistenceProtocol
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

    /// The one place the store's model list lives. Exposed so a test can open
    /// the *same* schema at its own on-disk URL and exercise real durability
    /// instead of an in-memory stand-in.
    static func makeContainer(configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(
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
            GuestMergeSessionRecord.self,
            InventorySyncEnrollmentRecord.self,
            PreparedComponentRecord.self,
            configurations: configuration
        )
    }

    /// Every persistence in the bundle over one container. Adding a field to
    /// `KitchenPersistenceBundle` breaks here at compile time, which is the
    /// point: a new module cannot reach the app half-wired.
    static func bundle(container: ModelContainer) -> KitchenPersistenceBundle {
        KitchenPersistenceBundle(
            inventory: SwiftDataInventoryPersistence(container: container),
            shoppingList: SwiftDataShoppingListPersistence(container: container),
            todayPlan: SwiftDataTodayPlanPersistence(container: container),
            consumption: SwiftDataConsumptionPersistence(container: container),
            weeklyPlan: SwiftDataWeeklyPlanPersistence(container: container),
            userRecipes: SwiftDataUserRecipePersistence(container: container),
            recipePreferences: SwiftDataRecipePreferencePersistence(container: container),
            preparedComponents: SwiftDataPreparedComponentPersistence(container: container),
            sync: SwiftDataSyncPersistence(modelContainer: container)
        )
    }

    private static func makeBundle(isStoredInMemoryOnly: Bool) -> KitchenPersistenceBundle {
        do {
            return bundle(
                container: try makeContainer(
                    configuration: ModelConfiguration(isStoredInMemoryOnly: isStoredInMemoryOnly)
                )
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
                preparedComponents: FailingPreparedComponentPersistence(underlyingError: error),
                sync: FailingSyncPersistence()
            )
        }
    }
}
