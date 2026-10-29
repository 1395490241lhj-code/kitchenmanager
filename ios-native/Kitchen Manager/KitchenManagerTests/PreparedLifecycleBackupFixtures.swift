import Foundation
@testable import KitchenManager

@MainActor
enum PreparedLifecycleBackupFixtures {
    static let at = Date(timeIntervalSinceReferenceDate: 100)
    static let expiry = Date(timeIntervalSinceReferenceDate: 1_000_000)
    static func row(state: PreparedComponentState = .prepped, storage: PreparedStorage = .frozen,
                    count: Int = 4) -> PreparedComponent {
        PreparedComponent(name: "鸡肉", portionsRemaining: count, state: state, storage: storage,
                          preparedAt: at, expiryDate: expiry)
    }
    static var thaw: PreparedLifecycle {
        PreparedLifecycle(version: 1, thawPhase: .thawing, thawStartedAt: at,
                          thawCompletedAt: nil, cookedAt: nil)
    }
    static var cooked: PreparedLifecycle {
        PreparedLifecycle(version: 1, thawPhase: .inactive, thawStartedAt: at,
                          thawCompletedAt: at.addingTimeInterval(1), cookedAt: at.addingTimeInterval(2))
    }
    static func tracked(_ row: PreparedComponent, _ lifecycle: PreparedLifecycle) throws -> PreparedComponent {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as! [String: Any]
        object["lifecycle"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(lifecycle))
        return try JSONDecoder().decode(PreparedComponent.self, from: JSONSerialization.data(withJSONObject: object))
    }
    static func payload(_ rows: [PreparedComponent] = []) -> KitchenBackupPayload {
        KitchenBackupPayload(inventory: [], plans: [], shoppingItems: [], weeklyPlan: nil,
                             consumptionRecords: [], preparedComponents: rows)
    }
    static func fullPayload(_ rows: [PreparedComponent]) -> KitchenBackupPayload {
        let meal = MealPlanItem(recipeID: "synthetic", recipeName: "合成餐次", date: at)
        return KitchenBackupPayload(
            inventory: [InventoryItem(name: "合成库存", quantity: 2, unit: "份", expiryDate: nil)], plans: [meal],
            shoppingItems: [KitchenShoppingItem(name: "合成购物")],
            weeklyPlan: WeeklyMealPlan(startDate: at, days: [WeeklyMealPlanDay(dayIndex: 0, meals: [])],
                shoppingItems: [], servings: 2, summary: "合成周计划", createdAt: at),
            consumptionRecords: [InventoryConsumptionRecord(id: UUID(), date: at, recipeID: meal.recipeID,
                recipeName: meal.recipeName, planIDs: [meal.id], items: [])], preparedComponents: rows,
            specialPlans: [SpecialPlan(title: "合成聚餐", scheduledAt: at, peopleCount: 2)])
    }
    /// Original row vocabulary is spelled out, independent of the evolving row encoder.
    static func originalRow(_ row: PreparedComponent, version: Int) throws -> [String: Any] {
        var object: [String: Any] = ["id": row.id.uuidString, "name": row.name,
            "portionsRemaining": row.portionsRemaining, "state": row.state.rawValue,
            "storage": row.storage.rawValue, "preparedAt": row.preparedAt.timeIntervalSinceReferenceDate,
            "expiryDate": row.expiryDate.timeIntervalSinceReferenceDate]
        if version == 2, let grouping = row.grouping {
            object["grouping"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(grouping))
        }
        return object
    }
    static func historical(_ payload: KitchenBackupPayload, version: Int, dated: Bool = true) throws -> Data {
        precondition(version == 1 || version == 2)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as! [String: Any]
        object["version"] = version
        object["preparedComponents"] = try payload.preparedComponents.map { try originalRow($0, version: version) }
        if !dated { object.removeValue(forKey: "exportedAt") }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    static func intent(_ action: PreparedLifecycleAction, row: PreparedComponent,
                       eventAt: Date = Date(timeIntervalSinceReferenceDate: 100), selected: Date? = nil, edited: Bool = false) throws -> PreparedLifecycleIntent {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = try selected ?? PreparedLifecycleTransition.defaultExpiryDate(action: action, state: row.state,
            existingExpiryDate: row.expiryDate, eventAt: eventAt, calendar: calendar)
        return PreparedLifecycleIntent(action: action, eventAt: eventAt, calendar: calendar,
            expiryReview: PreparedExpiryReview(action: action, existingExpiryDate: row.expiryDate,
                selectedExpiryDate: date, explicitlyEdited: edited))
    }
}
