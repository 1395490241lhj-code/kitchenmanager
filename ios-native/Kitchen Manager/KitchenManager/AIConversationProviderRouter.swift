import Foundation
import SwiftUI

/// Where a conversation turn is allowed to run. Only this layer decides it;
/// nothing below it in the conversation path knows about provider identity.
nonisolated enum AIConversationProviderRoute: Sendable, Equatable {
    case cloud(provider: AIRecommendationProvider)
    /// No conversation provider has been chosen and none may be inferred.
    /// The surface asks for an explicit choice; no transport is built.
    case needsProviderSelection
}

/// Canonical owner of the Kitchen AI conversation provider: its storage, its
/// eligible values, its default, and the one-time carry-over from the older
/// shared preference. Every conversation surface resolves through here, so
/// Settings, the view and the orchestrator cannot drift apart (D-044).
///
/// Provider credentials and endpoints stay shared and untouched — this type
/// scopes the *preference*, not the configuration.
///
/// The R13 privacy rule is unchanged: an explicit device-local choice must
/// never silently send content to a cloud provider. What changed is where it
/// applies. The recipe recommendation preference no longer decides whether
/// conversation works; a member who picked Apple there is asked to choose a
/// conversation model rather than being routed to cloud or refused outright.
nonisolated enum AIConversationProviderPreference {
    static let storageKey = "aiConversationProvider"

    /// Conversation runs on cloud models only today. Apple is absent because
    /// device-local conversation is not implemented — not because a
    /// device-local choice is overridden.
    static let eligibleProviders: [AIRecommendationProvider] = [.gemini, .groq]

    static let setupTitle = "AI 对话目前需要云端模型。"
    static let setupDetail = "选择 Gemini 或 Groq 后即可使用，菜谱推荐仍按你的设置使用设备端模型。"

    /// The explicit choice, when one has been made and is still eligible.
    static func storedProvider(in userDefaults: UserDefaults) -> AIRecommendationProvider? {
        guard let raw = userDefaults.string(forKey: storageKey),
              let provider = AIRecommendationProvider(rawValue: raw),
              eligibleProviders.contains(provider) else { return nil }
        return provider
    }

    /// Pure read. Never writes, so resolving can never itself change what the
    /// next send does.
    static func resolve(in userDefaults: UserDefaults = .standard) -> AIConversationProviderRoute {
        if let raw = userDefaults.string(forKey: storageKey),
           let stored = AIRecommendationProvider(rawValue: raw) {
            // A readable but ineligible choice can only mean a device-local one.
            // It stays unrouted rather than falling through to a cloud default.
            return eligibleProviders.contains(stored)
                ? .cloud(provider: stored)
                : .needsProviderSelection
        }
        // No dedicated choice yet. An absent or unreadable legacy value is a
        // fresh install, which takes the one canonical cloud default.
        guard let legacyRaw = userDefaults.string(forKey: AIRecommendationProvider.storageKey),
              let legacy = AIRecommendationProvider(rawValue: legacyRaw) else {
            return .cloud(provider: AIRecommendationProvider.defaultProvider)
        }
        switch legacy {
        case .gemini, .groq:
            // A legacy cloud choice carries over unchanged.
            return .cloud(provider: legacy)
        case .apple:
            // A legacy device-local choice is not convertible into a cloud one.
            return .needsProviderSelection
        }
    }

    static func select(_ provider: AIRecommendationProvider, in userDefaults: UserDefaults = .standard) {
        guard eligibleProviders.contains(provider) else { return }
        userDefaults.set(provider.rawValue, forKey: storageKey)
    }

    /// Materializes the carry-over once, at the composition root, so a later
    /// change to the recipe recommendation model can no longer move an
    /// existing member's conversation provider. Writes nothing for a fresh
    /// install and nothing for a legacy Apple choice — the first has a default
    /// that needs no storage, the second needs a person to decide.
    static func migrateIfNeeded(in userDefaults: UserDefaults = .standard) {
        guard storedProvider(in: userDefaults) == nil,
              userDefaults.string(forKey: AIRecommendationProvider.storageKey) != nil,
              case let .cloud(provider) = resolve(in: userDefaults) else { return }
        userDefaults.set(provider.rawValue, forKey: storageKey)
    }
}

struct AIConversationProviderSettingsRow: View {
    // Both keys are observed so the row stays truthful while either one is
    // edited on screen. Neither declaration writes anything.
    @AppStorage(AIConversationProviderPreference.storageKey)
    private var storedRawValue = ""
    @AppStorage(AIRecommendationProvider.storageKey)
    private var legacyRawValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("AI 对话模型", selection: selection) {
                ForEach(AIConversationProviderPreference.eligibleProviders) { provider in
                    Text(provider.title).tag(provider.rawValue)
                }
            }
            .accessibilityIdentifier("settings.aiConversationProvider.picker")

            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: ChromeMetrics.minimumRowHeight)
    }

    /// Shows what conversation will actually use. An unselected row means the
    /// resolver genuinely has no answer, which happens only to a member whose
    /// legacy choice was the device-local model.
    private var selection: Binding<String> {
        Binding(
            get: {
                if case let .cloud(provider) = AIConversationProviderPreference.resolve() {
                    return provider.rawValue
                }
                return ""
            },
            set: { raw in
                guard let provider = AIRecommendationProvider(rawValue: raw) else { return }
                AIConversationProviderPreference.select(provider)
            }
        )
    }

    private var statusText: String {
        if case .needsProviderSelection = AIConversationProviderPreference.resolve() {
            return AIConversationProviderPreference.setupTitle + AIConversationProviderPreference.setupDetail
        }
        return "AI 对话只支持云端模型，与「菜谱推荐模型」各自独立。"
    }
}
