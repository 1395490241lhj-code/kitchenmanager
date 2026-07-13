import Foundation

nonisolated struct AuthConfiguration: Equatable, Sendable {
    let supabaseURL: URL
    let publishableKey: String

    static func load(from bundle: Bundle = .main) throws -> AuthConfiguration {
        try validate(
            urlString: bundle.object(forInfoDictionaryKey: "KM_SUPABASE_URL") as? String,
            publishableKey: bundle.object(forInfoDictionaryKey: "KM_SUPABASE_PUBLISHABLE_KEY") as? String
        )
    }

    static func validate(urlString: String?, publishableKey: String?) throws -> AuthConfiguration {
        let rawURL = (urlString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let key = (publishableKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty, !key.isEmpty else {
            throw AuthenticationError.configuration("账号服务尚未配置，仍可继续使用游客模式。")
        }
        guard !rawURL.contains("YOUR_"), !key.contains("YOUR_") else {
            throw AuthenticationError.configuration("账号服务尚未配置，仍可继续使用游客模式。")
        }
        guard let url = URL(string: rawURL), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else {
            throw AuthenticationError.configuration("账号服务配置无效，仍可继续使用游客模式。")
        }
        guard !key.lowercased().contains("service_role") else {
            throw AuthenticationError.configuration("账号服务配置不安全，已停用登录功能。")
        }
        return AuthConfiguration(supabaseURL: url, publishableKey: key)
    }
}
