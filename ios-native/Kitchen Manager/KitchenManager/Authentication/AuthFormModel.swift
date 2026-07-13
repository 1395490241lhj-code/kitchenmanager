import Foundation
import Combine

enum AuthFormMode: String, CaseIterable, Identifiable {
    case signIn
    case signUp

    var id: String { rawValue }
    var title: String { self == .signIn ? "登录" : "创建账号" }
}

@MainActor
final class AuthFormModel: ObservableObject {
    @Published var mode: AuthFormMode = .signIn
    @Published var email = ""
    @Published var password = ""
    @Published var passwordConfirmation = ""
    @Published private(set) var validationMessage: String?

    var normalizedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    func validate() -> Bool {
        guard normalizedEmail.contains("@"), normalizedEmail.contains(".") else {
            validationMessage = "请输入有效的邮箱地址。"
            return false
        }
        guard password.count >= 6 else {
            validationMessage = "密码至少需要 6 个字符。"
            return false
        }
        guard mode != .signUp || password == passwordConfirmation else {
            validationMessage = "两次输入的密码不一致。"
            return false
        }
        validationMessage = nil
        return true
    }

    func resetMessages() { validationMessage = nil }
}
