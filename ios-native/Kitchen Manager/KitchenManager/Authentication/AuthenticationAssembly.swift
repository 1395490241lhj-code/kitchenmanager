import Foundation

@MainActor
enum AuthenticationAssembly {
    static func make(bundle: Bundle = .main) -> AuthStore {
        do {
            let configuration = try AuthConfiguration.load(from: bundle)
            return AuthStore(
                authService: SupabaseAuthService(configuration: configuration),
                accountService: APIAccountService()
            )
        } catch {
            let message = (error as? AuthenticationError)?.localizedDescription
                ?? "账号服务尚未配置，仍可继续使用游客模式。"
            return AuthStore(
                authService: UnavailableAuthService(),
                accountService: UnavailableAccountService(),
                configurationMessage: message
            )
        }
    }
}
