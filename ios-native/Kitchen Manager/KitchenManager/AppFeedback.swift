import SwiftUI
import UIKit

/// Presentation-only semantics for transient feedback. This type does not
/// own business state or decide when a notice is created or cleared.
enum AppFeedbackStyle: String, CaseIterable, Equatable {
    case success
    case warning
    case error
    case informational

    var systemImage: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.circle.fill"
        case .informational: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .success: AppTheme.success
        case .warning: AppTheme.warning
        case .error: AppTheme.inventoryExpired
        case .informational: AppTheme.primary
        }
    }

    var accessibilityPrefix: String {
        switch self {
        case .success: "成功"
        case .warning: "提醒"
        case .error: "错误"
        case .informational: "提示"
        }
    }

    func accessibilityLabel(for message: String) -> String {
        "\(accessibilityPrefix)：\(message)"
    }
}

/// Inventory notices currently remain String-valued for compatibility with
/// KitchenStore. Known fixed success copy is the only success case; every
/// other notice is conservatively presented as an error so an unknown
/// persistence/migration failure can never look like a successful save.
enum InventoryNoticePresentation {
    static func style(for message: String) -> AppFeedbackStyle {
        if message.hasPrefix("已添加 "), message.hasSuffix(" 项食材") {
            return .success
        }
        return .error
    }
}

/// Small reusable feedback label with semantic iconography and a single
/// VoiceOver announcement per displayed message. The caller remains
/// responsible for presentation lifetime and business-state clearing.
struct AppFeedbackView: View {
    let message: String
    let style: AppFeedbackStyle

    @State private var announcedMessage: String?

    var body: some View {
        Label(message, systemImage: style.systemImage)
            .foregroundStyle(style.tint)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(style.accessibilityLabel(for: message))
            .task(id: message) {
                guard announcedMessage != message else { return }
                announcedMessage = message
                guard UIAccessibility.isVoiceOverRunning else { return }
                UIAccessibility.post(
                    notification: .announcement,
                    argument: style.accessibilityLabel(for: message)
                )
            }
    }
}
