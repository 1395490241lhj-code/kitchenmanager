import SwiftUI

enum KitchenActionPhase: CaseIterable {
    case idle, processing, success, failure
}

/// Presentation only. The caller owns the operation, disable rules, errors and
/// navigation. Reserve all four labels' footprint without imposing a fixed
/// height, so Dynamic Type and state changes cannot move the button's edges.
struct KitchenActionLabel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let phase: KitchenActionPhase
    let idleTitle: String
    let idleSymbol: String
    var processingTitle = "正在保存"
    var successTitle = "已保存"
    var failureTitle = "重试保存"

    var body: some View {
        ZStack {
            ForEach(KitchenActionPhase.allCases, id: \.self) { candidate in
                Label(title(for: candidate), systemImage: symbol(for: candidate))
                    .hidden()
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            Label {
                Text(title(for: phase))
                    .contentTransition(.opacity)
            } icon: {
                if phase == .processing {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.opacity)
                } else {
                    Image(systemName: symbol(for: phase))
                        .contentTransition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : KitchenMotion.feedback, value: phase)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title(for: phase)))
        .accessibilityValue(phase == .failure ? Text("保存失败") : Text(""))
    }

    private func title(for phase: KitchenActionPhase) -> String {
        switch phase {
        case .idle: idleTitle
        case .processing: processingTitle
        case .success: successTitle
        case .failure: failureTitle
        }
    }

    private func symbol(for phase: KitchenActionPhase) -> String {
        switch phase {
        case .idle: idleSymbol
        case .processing: "arrow.trianglehead.2.clockwise"
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.circle"
        }
    }
}
