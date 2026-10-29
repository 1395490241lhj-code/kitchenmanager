import Foundation

enum PreparedConsumptionContext { case manual, immediateMeal }

enum PreparedMealAvailability {
    static func isEligible(_ component: PreparedComponent) -> Bool {
        guard (try? PreparedComponentCollectionValidator.validate([component])) != nil else { return false }
        return component.storage == .refrigerated && component.lifecycle?.thawPhase != .thawing
    }
}
