import Foundation
import Combine
import PhotosUI
import SwiftUI
import UIKit

enum AIServiceFailureCategory: String, Codable, CaseIterable, Sendable {
    case network
    case authentication
    case modelUnavailable
    case imageUpload
    case timeout
    case rateLimited
    case server
    case responseFormat
    case emptyResponse

    var title: String {
        switch self {
        case .network: "网络失败"
        case .authentication: "认证失败"
        case .modelUnavailable: "模型不可用"
        case .imageUpload: "图片上传失败"
        case .timeout: "请求超时"
        case .rateLimited: "请求过于频繁"
        case .server: "服务端错误"
        case .responseFormat: "响应格式错误"
        case .emptyResponse: "空响应"
        }
    }
}

struct AIServiceFailure: Codable, Equatable, Sendable {
    let category: AIServiceFailureCategory
    let message: String
    let statusCode: Int?
    let requestID: String?
    let source: String?
    let upstreamCode: String?
    let upstreamMessage: String?
    let date: Date

    static func classify(_ error: Error, imageRequest: Bool = false, source: String? = nil) -> Self {
        let category: AIServiceFailureCategory
        let status: Int?
        let upstreamCode: String?
        let upstreamMessage: String?
        switch error {
        case ImageUploadError.imageTooLarge, ImageUploadError.invalidImage:
            category = .imageUpload; status = nil
            upstreamCode = nil; upstreamMessage = nil
        case APIError.timeout:
            category = .timeout; status = nil
            upstreamCode = nil; upstreamMessage = nil
        case APIError.rateLimited:
            category = .rateLimited; status = 429
            upstreamCode = "rate_limited"; upstreamMessage = error.localizedDescription
        case APIError.transport:
            category = .network; status = nil
            upstreamCode = nil; upstreamMessage = nil
        case APIError.decodingFailed:
            category = .responseFormat; status = nil
            upstreamCode = nil; upstreamMessage = nil
        case is AuthenticationError:
            category = .authentication; status = nil
            upstreamCode = nil; upstreamMessage = nil
        case APIError.server(let code, let payload):
            status = code
            upstreamCode = payload?.code
            upstreamMessage = payload?.displayMessage
            if code == 401 || code == 403 { category = .authentication }
            else if imageRequest && code == 413 { category = .imageUpload }
            else if code == 408 { category = .timeout }
            else if code == 404 || payload?.code?.localizedCaseInsensitiveContains("model") == true || payload?.code?.localizedCaseInsensitiveContains("missing_.*model") == true {
                category = .modelUnavailable
            } else { category = .server }
        case AIChatServiceError.emptyResponse:
            category = .emptyResponse; status = nil
            upstreamCode = "empty_response"; upstreamMessage = error.localizedDescription
        case AIChatServiceError.invalidResponse:
            category = .responseFormat; status = nil
            upstreamCode = nil; upstreamMessage = nil
        case AIChatServiceError.rateLimited:
            category = .rateLimited; status = 429
            upstreamCode = "rate_limited"; upstreamMessage = error.localizedDescription
        default:
            category = imageRequest ? .imageUpload : .server; status = nil
            upstreamCode = nil; upstreamMessage = nil
        }
        let requestID = (error as? APIError).flatMap { apiError in
            if case let .server(_, payload) = apiError { return payload?.requestID }
            return nil
        }
        return Self(category: category, message: Self.safeMessage(for: error, category: category), statusCode: status, requestID: requestID, source: source, upstreamCode: upstreamCode, upstreamMessage: upstreamMessage, date: Date())
    }

    private static func safeMessage(for error: Error, category: AIServiceFailureCategory) -> String {
        switch category {
        case .network: return "无法连接到 Kitchen Manager 服务，请检查网络连接。"
        case .authentication: return "认证信息无效或已过期，请重新登录。"
        case .modelUnavailable: return "后端当前未配置可用的 AI 模型。"
        case .imageUpload: return "图片未能上传或超过服务端大小限制。"
        case .timeout: return "AI 请求超时，请稍后重试。"
        case .rateLimited: return "请求过于频繁，请稍后重试。"
        case .server:
            if case APIError.server(let status, _) = error { return "服务端返回 HTTP \(status)。" }
            return "服务端返回了错误。"
        case .responseFormat: return "服务端响应无法按 App 约定解析。"
        case .emptyResponse: return "服务端返回了空的 AI 内容。"
        }
    }
}

enum AIFailureStore {
    private static let key = "ai.lastFailure.v1"

    static var last: AIServiceFailure? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(AIServiceFailure.self, from: data)
    }

    static func save(_ failure: AIServiceFailure) {
        guard let data = try? JSONEncoder().encode(failure) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clearIfSourceMatches(_ source: String) {
        guard last?.source == source else { return }
        UserDefaults.standard.removeObject(forKey: key)
    }
}

enum AIDiagnosticTest: String, CaseIterable, Identifiable {
    case configuration, connectivity, authentication, minimalAI, image
    var id: String { rawValue }
    var title: String {
        switch self {
        case .configuration: "Configuration Check"
        case .connectivity: "Server Connectivity"
        case .authentication: "Authentication"
        case .minimalAI: "Minimal AI Request"
        case .image: "Image Capability Test"
        }
    }
}

enum AIDiagnosticStatus: String {
    case notRun = "Not Run", running = "Running", passed = "Passed", failed = "Failed"
}

struct AIDiagnosticResult: Identifiable {
    let id: AIDiagnosticTest
    var status: AIDiagnosticStatus = .notRun
    var statusCode: Int?
    var latency: TimeInterval?
    var message: String?
    var requestID: String?
    var date: Date?
}

@MainActor
final class AIServiceDiagnosticsStore: ObservableObject {
    @Published private(set) var results = Dictionary(uniqueKeysWithValues: AIDiagnosticTest.allCases.map { ($0, AIDiagnosticResult(id: $0)) })
    @Published private(set) var lastFailure = AIFailureStore.last
    @Published var selectedImage: UIImage?
    @Published private(set) var isRunning = false

    private let apiClient: APIClient
    private var runningTests = Set<AIDiagnosticTest>()
    var authStore: AuthStore?

    init(apiClient: APIClient = .shared, authStore: AuthStore) {
        self.apiClient = apiClient
        self.authStore = authStore
    }

    func runAll() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        await run(.configuration)
        await run(.connectivity)
        await run(.authentication)
        await run(.minimalAI)
        if selectedImage != nil { await run(.image) }
    }

    func run(_ test: AIDiagnosticTest) async {
        guard runningTests.insert(test).inserted else { return }
        defer { runningTests.remove(test) }
        results[test] = AIDiagnosticResult(id: test, status: .running)
        let started = Date()
        do {
            let result: AIDiagnosticResult
            switch test {
            case .configuration: result = try await configurationResult()
            case .connectivity: result = try await connectivityResult()
            case .authentication: result = try await authenticationResult()
            case .minimalAI: result = try await aiResult(prompt: "仅返回 OK", taskType: "diagnostics")
            case .image:
                guard let selectedImage else { throw ImageUploadError.invalidImage }
                let (_, data) = try ImageUploadProcessor().process(selectedImage)
                result = try await aiResult(prompt: "请仅返回 OK", taskType: "receipt", imageData: data)
            }
            results[test] = result
        } catch {
            let failure = AIServiceFailure.classify(error, imageRequest: test == .image, source: source(for: test))
            let metadata = failure.statusCode
            let message = test == .configuration && metadata == 404
                ? "诊断配置接口尚未部署（HTTP 404），无法从当前后端读取模型配置。"
                : failure.message
            let result = AIDiagnosticResult(id: test, status: .failed, statusCode: metadata, latency: Date().timeIntervalSince(started), message: message, requestID: failure.requestID, date: failure.date)
            results[test] = result
            if test == .minimalAI || test == .image {
                AIFailureStore.save(failure); lastFailure = failure
            }
        }
    }

    private func source(for test: AIDiagnosticTest) -> String {
        switch test {
        case .configuration: return "GET /api/ai-diagnostics/config"
        case .connectivity: return "GET /health"
        case .authentication: return "GET /api/me"
        case .minimalAI: return "POST /api/ai-chat · diagnostics"
        case .image: return "POST /api/ai-chat · diagnostics-image"
        }
    }

    private struct ConfigurationResponse: Decodable {
        let textModel: String?
        let visionModel: String?
        let textModelConfigured: Bool
        let visionModelConfigured: Bool
        let apiKeyConfigured: Bool
    }

    private func configurationResult() async throws -> AIDiagnosticResult {
        let authPresent = authStore?.currentAccessToken()?.isEmpty == false
        let raw = try await apiClient.sendRawDetailed(.get(path: "/api/ai-diagnostics/config", timeout: 15))
        let config = try JSONDecoder().decode(ConfigurationResponse.self, from: raw.data)
        let textModel = config.textModel ?? "未配置"
        let visionModel = config.visionModel ?? "未配置"
        return AIDiagnosticResult(id: .configuration, status: .passed, statusCode: raw.metadata.statusCode, latency: raw.metadata.latency, message: "环境：\(APIEnvironment.current.label)；Base URL：\(APIEnvironment.current.baseURL.host ?? "未知")；文本模型：\(textModel)；视觉模型：\(visionModel)；后端 API Key：\(config.apiKeyConfigured ? "已配置（掩码）" : "未配置")；App 认证信息：\(authPresent ? "已存在（掩码）" : "未登录/不存在")", requestID: raw.metadata.requestID, date: Date())
    }

    private func connectivityResult() async throws -> AIDiagnosticResult {
        let started = Date()
        let raw = try await apiClient.sendRawDetailed(.get(path: "/health", timeout: 15))
        return AIDiagnosticResult(id: .connectivity, status: .passed, statusCode: raw.metadata.statusCode, latency: raw.metadata.latency, message: "App 直接请求 /health 成功。", requestID: raw.metadata.requestID, date: started)
    }

    private func authenticationResult() async throws -> AIDiagnosticResult {
        guard let token = authStore?.currentAccessToken(), !token.isEmpty else {
            throw AuthenticationError.unavailable
        }
        let started = Date()
        let raw = try await apiClient.sendRawDetailed(.get(path: "/api/me", headers: ["Authorization": "Bearer \(token)"], timeout: 20))
        return AIDiagnosticResult(id: .authentication, status: .passed, statusCode: raw.metadata.statusCode, latency: raw.metadata.latency, message: "当前 App access token 通过 /api/me 鉴权。", requestID: raw.metadata.requestID, date: started)
    }

    private func aiResult(prompt: String, taskType: String, imageData: Data? = nil) async throws -> AIDiagnosticResult {
        let started = Date()
        let service = AIChatService(apiClient: apiClient)
        let result = try await service.requestDetailed(prompt: prompt, taskType: taskType, imageBase64: imageData.map { "data:image/jpeg;base64,\($0.base64EncodedString())" }, timeout: 50)
        AIFailureStore.clearIfSourceMatches(source(for: imageData == nil ? .minimalAI : .image))
        lastFailure = AIFailureStore.last
        return AIDiagnosticResult(id: imageData == nil ? .minimalAI : .image, status: .passed, statusCode: result.metadata.statusCode, latency: result.metadata.latency, message: result.content == "OK" ? "返回 OK。" : "收到非空响应（内容已隐藏）。", requestID: result.metadata.requestID, date: started)
    }
}

struct AIServiceDiagnosticsView: View {
    @EnvironmentObject private var authStore: AuthStore
    @StateObject private var store: AIServiceDiagnosticsStore
    @State private var photoItem: PhotosPickerItem?

    init(authStore: AuthStore) { _store = StateObject(wrappedValue: AIServiceDiagnosticsStore(authStore: authStore)) }

    var body: some View {
        List {
            Section {
                Button("Run All Tests", systemImage: "play.fill") { Task { await store.runAll() } }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.managementActionFill)
                    .foregroundStyle(AppTheme.onManagementAction)
                    .disabled(store.isRunning)
                Text("所有请求均由当前 iOS App 直接发起；不会显示或保存 Token、API Key、图片或完整响应。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(AIDiagnosticTest.allCases) { test in
                diagnosticRow(test)
            }
            if let failure = store.lastFailure {
                Section("最近一次 AI 失败（脱敏）") {
                    LabeledContent("类型", value: failure.category.title)
                    LabeledContent("说明", value: failure.message)
                    if let source = failure.source { LabeledContent("来源", value: source) }
                    if let code = failure.upstreamCode { LabeledContent("上游 Code", value: code) }
                    if let message = failure.upstreamMessage { LabeledContent("上游错误", value: message) }
                    if let code = failure.statusCode { LabeledContent("HTTP", value: "\(code)") }
                    LabeledContent("时间", value: failure.date.formatted(date: .abbreviated, time: .standard))
                }
            }
        }
        .navigationTitle("AI Service Diagnostics")
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            PhotosPicker(selection: $photoItem, matching: .images) { Label("视觉测试图片", systemImage: "photo") }
        }}
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    store.selectedImage = UIImage(data: data)
                }
            }
        }
        .onAppear { store.authStore = authStore }
    }

    @ViewBuilder private func diagnosticRow(_ test: AIDiagnosticTest) -> some View {
        let result = store.results[test] ?? AIDiagnosticResult(id: test)
        Section {
            HStack {
                Label(test.title, systemImage: result.status == .passed ? "checkmark.circle.fill" : result.status == .failed ? "xmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(result.status == .passed ? .green : result.status == .failed ? .red : .primary)
                Spacer()
                Text(result.status.rawValue).font(.caption).foregroundStyle(.secondary)
                Button("Retry") { Task { await store.run(test) } }.buttonStyle(.borderless).disabled(result.status == .running)
            }
            if let code = result.statusCode { LabeledContent("HTTP", value: "\(code)") }
            if let latency = result.latency { LabeledContent("Latency", value: "\(Int(latency * 1000)) ms") }
            if let message = result.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            if let requestID = result.requestID { LabeledContent("Request ID", value: requestID) }
            if let date = result.date { LabeledContent("时间", value: date.formatted(date: .abbreviated, time: .standard)) }
        }
    }
}
