import Foundation

/// Presentation-only state for the signed-in inventory sync section.
/// This type deliberately contains no transport, persistence, or auth logic.
nonisolated enum InventorySyncPresentationState: Equatable, Sendable {
    case featureDisabled
    case noHousehold
    case notEnrolled
    case idle
    case pending(count: Int)
    case syncing
    case completed
    case offline
    case error
    case rateLimited(retryAfter: Date)
    case upgradeRequired

    /// DEBUG fixture actions are always local no-ops. This helper keeps the
    /// fixture surface aligned with the real action affordance without ever
    /// granting it a network path.
    var isActionSafeForFixture: Bool {
        switch self {
        case .idle, .pending, .completed, .offline, .error:
            true
        default:
            false
        }
    }
}

nonisolated struct InventorySyncPresentation: Equatable, Sendable {
    let state: InventorySyncPresentationState
    let title: String
    let message: String
    let detail: String?
    let systemImage: String
    let actionTitle: String?
    let actionEnabled: Bool
    let pendingCount: Int?

    var showsAction: Bool { actionTitle != nil }

    static func make(
        state: InventorySyncPresentationState,
        now: Date = Date(),
        detail: String? = nil
    ) -> InventorySyncPresentation {
        switch state {
        case .featureDisabled:
            return .init(state: state, title: "尚未开启", message: "库存同步功能尚未开启。", detail: detail,
                         systemImage: "arrow.triangle.2.circlepath", actionTitle: nil,
                         actionEnabled: false, pendingCount: nil)
        case .noHousehold:
            return .init(state: state, title: "没有可同步的家庭", message: "当前账号没有可同步的家庭。", detail: detail,
                         systemImage: "person.2.slash", actionTitle: nil,
                         actionEnabled: false, pendingCount: nil)
        case .notEnrolled:
            return .init(state: state, title: "尚未完成合并", message: "完成库存合并后，才能同步后续库存变化。", detail: detail,
                         systemImage: "arrow.triangle.merge", actionTitle: nil,
                         actionEnabled: false, pendingCount: nil)
        case .idle:
            return .init(state: state, title: "已同步", message: "没有待处理的库存更改。", detail: detail,
                         systemImage: "checkmark.circle", actionTitle: "立即同步库存",
                         actionEnabled: true, pendingCount: nil)
        case .pending(let count):
            return .init(state: state, title: "待同步", message: "有 \(count) 项库存更改等待手动同步。", detail: detail,
                         systemImage: "arrow.triangle.2.circlepath", actionTitle: "立即同步库存",
                         actionEnabled: true, pendingCount: count)
        case .syncing:
            return .init(state: state, title: "正在同步", message: "正在处理库存更改，请稍候。", detail: detail,
                         systemImage: "arrow.triangle.2.circlepath", actionTitle: "正在同步…",
                         actionEnabled: false, pendingCount: nil)
        case .completed:
            return .init(state: state, title: "已同步", message: "最近一次库存同步已完成。", detail: detail,
                         systemImage: "checkmark.circle", actionTitle: "再次同步",
                         actionEnabled: true, pendingCount: nil)
        case .offline:
            return .init(state: state, title: "暂时离线", message: "当前无法连接同步服务，本机数据仍会保留。", detail: detail,
                         systemImage: "wifi.exclamationmark", actionTitle: "重试同步",
                         actionEnabled: true, pendingCount: nil)
        case .error:
            return .init(state: state, title: "同步遇到问题", message: "同步未完成，本机数据仍会保留。", detail: detail,
                         systemImage: "exclamationmark.triangle", actionTitle: "重试同步",
                         actionEnabled: true, pendingCount: nil)
        case .rateLimited(let retryAfter):
            let remaining = Int(ceil(retryAfter.timeIntervalSince(now)))
            if remaining > 0 {
                return .init(state: state, title: "请稍后重试", message: "同步请求过于频繁，请在 \(remaining) 秒后重试。", detail: detail,
                             systemImage: "clock", actionTitle: "等待后重试",
                             actionEnabled: false, pendingCount: nil)
            }
            return .init(state: state, title: "可以重试", message: "同步请求限制已解除。", detail: detail,
                         systemImage: "arrow.clockwise", actionTitle: "重试同步",
                         actionEnabled: true, pendingCount: nil)
        case .upgradeRequired:
            return .init(state: state, title: "需要更新 App", message: "更新 App 后才能继续使用家庭同步。", detail: detail,
                         systemImage: "arrow.down.app", actionTitle: nil,
                         actionEnabled: false, pendingCount: nil)
        }
    }
}
