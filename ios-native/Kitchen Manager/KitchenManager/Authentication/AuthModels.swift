import Foundation

nonisolated struct AuthUser: Equatable, Sendable {
    let id: UUID
    let email: String?
}

nonisolated struct AuthSession: Equatable, Sendable, CustomStringConvertible {
    let user: AuthUser
    let accessToken: String

    var description: String { "AuthSession(user: \(user.id), accessToken: <redacted>)" }
}

nonisolated enum AuthenticationStatus: Equatable {
    case guest
    case signedIn(AuthUser)
}

nonisolated enum AuthenticationActivity: Equatable {
    case idle
    case restoring
    case submitting
}

nonisolated enum AuthStateChange: Sendable {
    case sessionUpdated(AuthSession)
    case signedOut
}

nonisolated enum SignUpOutcome: Equatable, Sendable {
    case signedIn(AuthSession)
    case confirmationRequired(email: String)
}

nonisolated struct AccountProfile: Decodable, Equatable, Sendable {
    let id: UUID
    let email: String?
    let displayName: String?
}

nonisolated struct AccountHousehold: Decodable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let role: String

    var roleTitle: String {
        switch role {
        case "owner": "所有者"
        case "admin": "管理员"
        default: "成员"
        }
    }
}

nonisolated struct CurrentAccount: Decodable, Equatable, Sendable {
    let user: AccountProfile
    let households: [AccountHousehold]
}

nonisolated enum AuthenticationError: LocalizedError, Equatable {
    case invalidCredentials
    case emailNotConfirmed
    case emailAlreadyRegistered
    case weakPassword
    case rateLimited
    case configuration(String)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidCredentials: "邮箱或密码不正确。"
        case .emailNotConfirmed: "请先在邮箱中完成确认。"
        case .emailAlreadyRegistered: "这个邮箱已经注册，可以直接登录。"
        case .weakPassword: "密码强度不足，请换一个更安全的密码。"
        case .rateLimited: "尝试次数过多，请稍后再试。"
        case .configuration(let message): message
        case .unavailable: "账号服务暂时不可用，请稍后再试。"
        }
    }
}

nonisolated enum AccountServiceError: LocalizedError, Equatable {
    case unauthorized
    case forbidden
    case temporarilyUnavailable
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized: "登录状态需要更新，请稍后重试。"
        case .forbidden: "当前账号没有权限读取这项资料。"
        case .temporarilyUnavailable: "暂时无法读取账号资料，本机功能仍可继续使用。"
        case .invalidResponse: "账号资料暂时无法识别，请稍后重试。"
        }
    }
}
