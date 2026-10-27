#if DEBUG
import Foundation

/// Opt-in UI faults use an isolated kitchen and the real SwiftData save path.
/// Normal launches and Release builds never enter this fixture.
@MainActor
enum PreparedReliabilityFixture {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("UITEST_PREPARED_RELIABILITY") }

    static func configure(_ bundle: KitchenPersistenceBundle) -> KitchenPersistenceBundle {
        precondition(isEnabled)
        let arguments = ProcessInfo.processInfo.arguments
        let quick = arguments.contains("UITEST_FORCE_QUICK_DAY")
        let now = Date()
        let batch = PreparedComponent(
            id: UUID(uuidString: "77000000-0000-0000-0000-000000000001")!,
            name: quick ? "卤牛肉" : "卤鸡腿",
            portionsRemaining: arguments.contains("UITEST_PREPARED_FINAL_PORTION") ? 1 : 3,
            state: .cooked, storage: .refrigerated,
            preparedAt: now, expiryDate: now.addingTimeInterval(86_400)
        )
        do {
            try bundle.preparedComponents.replaceComponents(with: [batch])
            try bundle.inventory.replaceInventory(with: [
                InventoryItem(name: quick ? "米饭" : "红薯", quantity: 2, unit: "份", expiryDate: now.addingTimeInterval(432_000)),
                InventoryItem(name: quick ? "上海青" : "西兰花", quantity: 2, unit: "份", expiryDate: now.addingTimeInterval(432_000))
            ])
        } catch {
            preconditionFailure("Prepared reliability fixture could not seed isolated data")
        }
        if arguments.contains("UITEST_PREPARED_UNREADABLE") {
            return KitchenPersistenceBundle(
                inventory: bundle.inventory, shoppingList: bundle.shoppingList, todayPlan: bundle.todayPlan,
                consumption: bundle.consumption, weeklyPlan: bundle.weeklyPlan,
                userRecipes: bundle.userRecipes, recipePreferences: bundle.recipePreferences,
                preparedComponents: FailTwoReads(wrapping: bundle.preparedComponents),
                specialPlans: bundle.specialPlans, conversations: bundle.conversations, sync: bundle.sync
            )
        }
        guard let prepared = bundle.preparedComponents as? SwiftDataPreparedComponentPersistence else {
            preconditionFailure("Prepared reliability fixture needs SwiftData")
        }
        prepared.failNextReplaceSaveForTesting = InjectedFailure()
        return bundle
    }

    private struct InjectedFailure: Error {}

    private final class FailTwoReads: PreparedComponentPersistenceProtocol {
        let wrapped: PreparedComponentPersistenceProtocol
        private var reads = 0
        init(wrapping wrapped: PreparedComponentPersistenceProtocol) { self.wrapped = wrapped }
        func loadComponents() throws -> [PreparedComponent] {
            reads += 1
            if reads <= 2 { throw InjectedFailure() }
            return try wrapped.loadComponents()
        }
        func replaceComponents(with components: [PreparedComponent]) throws { try wrapped.replaceComponents(with: components) }
        func upsert(_ component: PreparedComponent) throws { try wrapped.upsert(component) }
        func delete(id: UUID) throws { try wrapped.delete(id: id) }
        func deleteAll() throws { try wrapped.deleteAll() }
    }
}
#endif
