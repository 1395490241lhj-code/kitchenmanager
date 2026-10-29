import Foundation

/// IDs belong to the draft, so validation and save retries reuse the same identities.
struct PreparedSourceDraft {
    let sourceID: UUID
    let groupIDs: [UUID]
    var name: String
    var massDecigrams: Int64
    var portionCount: Int
    var state: PreparedComponentState
    var storage: PreparedStorage
    var preparedAt: Date
    var expiryDate: Date
}
