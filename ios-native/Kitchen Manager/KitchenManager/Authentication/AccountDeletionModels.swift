import Foundation

nonisolated struct AccountDeletionPreview: Decodable, Equatable, Sendable {
    let canDelete: Bool
    let blockingReason: String?
    let householdCount: Int
    let ownedHouseholdCount: Int
    let requiresOwnershipTransfer: Bool
    let requiresHouseholdDeletion: Bool
    let pendingMutationCountBucket: String
    let confirmationVersion: String
}

nonisolated struct AccountDeletionConfirmResult: Decodable, Equatable, Sendable {
    let status: String
}

nonisolated struct AccountDeletionReauthenticationResult: Decodable, Equatable, Sendable {
    let reauthenticationProof: String
}

nonisolated struct TransferCandidate: Decodable, Equatable, Hashable, Identifiable, Sendable {
    let userId: UUID
    let role: String
    let displayName: String

    var id: UUID { userId }
}

/// Mirrors the backend's own error-code vocabulary (see
/// src/server/account/deletion-routes.js and
/// supabase/migrations/20260716000100_account_deletion_lifecycle.sql) —
/// never invented client-side, so a server behavior change surfaces as an
/// "unrecognized code" fallback rather than a silently-wrong local meaning.
nonisolated enum AccountDeletionError: LocalizedError, Equatable {
    case ownershipTransferRequired
    case householdActionRequired
    case reauthenticationRequired
    case reauthenticationFailed
    case reauthenticationExpired
    case reauthenticationUnsupported
    case stalePreview
    case deletionInProgress
    case blocked
    case unavailable

    init(code: String?) {
        switch code {
        case "OWNERSHIP_TRANSFER_REQUIRED": self = .ownershipTransferRequired
        case "HOUSEHOLD_ACTION_REQUIRED": self = .householdActionRequired
        case "REAUTHENTICATION_REQUIRED", "ACCOUNT_DELETION_REAUTH_REQUIRED": self = .reauthenticationRequired
        case "ACCOUNT_DELETION_REAUTH_FAILED": self = .reauthenticationFailed
        case "ACCOUNT_DELETION_REAUTH_EXPIRED": self = .reauthenticationExpired
        case "ACCOUNT_DELETION_REAUTH_UNSUPPORTED": self = .reauthenticationUnsupported
        case "STALE_DELETION_PREVIEW": self = .stalePreview
        case "ACCOUNT_DELETION_IN_PROGRESS": self = .deletionInProgress
        case "ACCOUNT_DELETION_BLOCKED": self = .blocked
        default: self = .unavailable
        }
    }

    var errorDescription: String? {
        switch self {
        case .ownershipTransferRequired: "还有其他成员的家庭需要先转移所有权，才能删除账号。"
        case .householdActionRequired: "需要先处理你所属的家庭，才能删除账号。"
        case .reauthenticationRequired: "为了保护你的账号，请重新验证身份。"
        case .reauthenticationFailed: "身份验证失败，请重试。"
        case .reauthenticationExpired: "身份验证已过期，请重新验证。"
        case .reauthenticationUnsupported: "当前登录方式暂不支持账号删除，请联系支持团队。"
        case .stalePreview: "账号状态已变化，请重新获取删除确认信息。"
        case .deletionInProgress: "账号删除正在进行中，请稍后查看结果。"
        case .blocked: "账号当前无法删除，请先处理提示的问题。"
        case .unavailable: "账号删除服务暂时不可用，请稍后再试。"
        }
    }
}
