import SwiftUI

/// A foreground Kitchen AI request the member is waiting on, said in words:
/// `[activity indicator] [status text] [optional cancel]`.
///
/// Scope is deliberately narrow. It presents only an active wait that a real
/// runtime state backs; it is not a generic loading view, and terminal or error
/// states keep their own presentation. Callers own the copy, the identifiers
/// and the surrounding font, so each surface keeps its own wording.
///
/// The visible text is the only thing VoiceOver reads for the status: the orb
/// is hidden inside this row, and the cancel button stays a separate action.
struct KitchenAIStatus: View {
    /// The existing caller styles, kept exactly as they were before the rows
    /// were consolidated. A closed set on purpose: this is not a styling API.
    enum Presentation {
        /// AI 做菜 and the weekly menu: form rows with a borderless 取消.
        case form
        /// Special Plan: 10 pt spacing and a medium-weight 取消生成.
        case planner
        /// The AI Conversation reply row: 8 pt spacing, Kitchen secondary text.
        case conversation

        var spacing: CGFloat? {
            switch self {
            case .form: return nil
            case .planner: return 10
            case .conversation: return 8
            }
        }

        var spacerMinLength: CGFloat {
            self == .planner ? 8 : KitchenTheme.pageGutter
        }

        var messageStyle: AnyShapeStyle {
            self == .conversation ? AnyShapeStyle(KitchenTheme.textSecondary) : AnyShapeStyle(.secondary)
        }
    }

    struct Cancel {
        let title: String
        let identifier: String
        let action: () -> Void

        init(_ title: String = "取消", identifier: String, action: @escaping () -> Void) {
            self.title = title
            self.identifier = identifier
            self.action = action
        }
    }

    let phase: KitchenAIActivityPhase
    let message: String
    let messageIdentifier: String?
    let cancel: Cancel?
    let presentation: Presentation

    init(
        phase: KitchenAIActivityPhase,
        message: String,
        messageIdentifier: String? = nil,
        cancel: Cancel? = nil,
        presentation: Presentation = .form
    ) {
        self.phase = phase
        self.message = message
        self.messageIdentifier = messageIdentifier
        self.cancel = cancel
        self.presentation = presentation
    }

    var body: some View {
        HStack(spacing: presentation.spacing) {
            KitchenAIActivityIndicator(phase: phase, size: .small)
                .accessibilityHidden(true)
            messageText
            if let cancel {
                Spacer(minLength: presentation.spacerMinLength)
                cancelButton(cancel)
            }
        }
    }

    @ViewBuilder
    private func cancelButton(_ cancel: Cancel) -> some View {
        switch presentation {
        case .planner:
            Button(cancel.title, action: cancel.action)
                .font(.subheadline.weight(.medium))
                .frame(minHeight: AppTheme.minimumHitTarget)
                .accessibilityIdentifier(cancel.identifier)
        case .form, .conversation:
            Button(action: cancel.action) {
                // The height sits on the label so the tap target really is
                // that tall; a borderless button is only as big as what it
                // draws.
                Text(cancel.title).frame(minHeight: AppTheme.minimumHitTarget)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(cancel.identifier)
        }
    }

    @ViewBuilder
    private var messageText: some View {
        let text = Text(message).foregroundStyle(presentation.messageStyle)
        // Leaf-level only: an identifier on the enclosing row would override
        // the cancel button's own.
        if let messageIdentifier {
            text.accessibilityIdentifier(messageIdentifier)
        } else {
            text
        }
    }
}

#Preview("Kitchen AI Status") {
    List {
        KitchenAIStatus(
            phase: .waiting,
            message: "正在生成菜谱…",
            cancel: .init(identifier: "preview.cancel") {}
        )
        KitchenAIStatus(
            phase: .waiting,
            message: "正在设计菜单…",
            cancel: .init("取消生成", identifier: "preview.planner.cancel") {},
            presentation: .planner
        )
        .font(.subheadline)
        KitchenAIStatus(
            phase: .composing,
            message: KitchenAIActivityPhase.composing.statusText,
            presentation: .conversation
        )
            .font(.footnote)
    }
}
