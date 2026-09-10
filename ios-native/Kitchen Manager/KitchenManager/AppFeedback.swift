import SwiftUI
import UIKit

/// Presentation-only semantics for transient feedback. This type does not
/// own business state or decide when a notice is created or cleared.
enum AppFeedbackStyle: Equatable {
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
        case .error: AppTheme.danger
        case .informational: AppTheme.primary
        }
    }

    var ink: Color {
        switch self {
        case .success: AppTheme.successInk
        case .warning: AppTheme.warningInk
        case .error: AppTheme.danger
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
        InventoryNoticeText.importedItemsCount(from: message) == nil ? .error : .success
    }
}

/// Keeps the once-per-presentation announcement rule independent from SwiftUI
/// view recomputation. The caller resets this gate when its feedback view
/// leaves the hierarchy, so an identical message can be announced on a later
/// presentation without repeating during the current one.
struct FeedbackAnnouncementGate {
    private var announcedMessage: String?

    mutating func shouldAnnounce(_ message: String) -> Bool {
        guard announcedMessage != message else { return false }
        announcedMessage = message
        return true
    }

    mutating func reset() {
        announcedMessage = nil
    }
}

/// Small reusable feedback label with semantic iconography and a single
/// VoiceOver announcement per displayed message. The caller remains
/// responsible for presentation lifetime and business-state clearing.
struct AppFeedbackView: View {
    let message: String
    let style: AppFeedbackStyle
    /// Callers with a dark surface can override the whole label to a
    /// high-contrast color without changing the feedback's semantic icon.
    var foregroundColor: Color? = nil

    @State private var announcementGate = FeedbackAnnouncementGate()

    var body: some View {
        Label {
            Text(message)
                .foregroundStyle(foregroundColor ?? style.ink)
        } icon: {
            Image(systemName: style.systemImage)
                .foregroundStyle(foregroundColor ?? style.tint)
        }
            .accessibilityLabel(style.accessibilityLabel(for: message))
            .task(id: message) { @MainActor in
                guard UIAccessibility.isVoiceOverRunning,
                      announcementGate.shouldAnnounce(message) else { return }
                UIAccessibility.post(
                    notification: .announcement,
                    argument: style.accessibilityLabel(for: message)
                )
            }
            .onDisappear {
                announcementGate.reset()
            }
    }
}

// MARK: - Shared transient feedback toast

/// Dark high-contrast toast wrapping AppFeedbackView. Always white-on-dark
/// so text remains readable on every background.  The SF Symbol shape and
/// VoiceOver prefix carried by AppFeedbackView distinguish feedback states.
/// Caller manages show/dismiss lifetime via conditional overlay.
struct FeedbackToast: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let message: String
    let style: AppFeedbackStyle
    /// Optional trailing action (e.g. 撤销), rendered as a bordered button that
    /// stays a 44pt target. Nil keeps the toast exactly as shipped.
    var action: (label: String, handler: () -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            AppFeedbackView(message: message, style: style, foregroundColor: .white)
                .font(.subheadline.weight(.semibold))
            if let action {
                Button(action: action.handler) {
                    Text(action.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(minHeight: AppTheme.minimumHitTarget)
                        .contentShape(Rectangle())
                }
                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: AppTheme.radiusCompact))
                .accessibilityIdentifier("feedback.toast.action")
            }
        }
        .padding(.leading, 16)
        // Without an action the toast keeps the metrics it shipped with, so
        // existing callers are untouched. The action's own 44pt height
        // supplies the vertical rhythm when one is present.
        .padding(.trailing, action == nil ? 16 : 8)
        .padding(.vertical, action == nil ? 11 : 4)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: AppTheme.radiusCard))
        .padding(.bottom, 18)
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
    }
}
