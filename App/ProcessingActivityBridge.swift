import ActivityKit
import Foundation

/// R006 追加 C：Live Activity（锁屏 / 灵动岛进度卡片）桥接层。
///
/// 设计口径：
/// - **可选能力**：设备未开启实时活动（或系统不支持）时整条链路静默降级，
///   绝不影响图像编辑主流程，也不阻塞任何一次渲染。
/// - 「不黑屏」的连续性由 `AIProcessingState` 保证，本层只负责把同一份进度
///   镜像到锁屏卡片上（`fraction / phaseTitle / detail` 与浮层完全同源）。
/// - 目前主 App 是唯一消费者；契约类型放在 `Shared/`，将来加 Widget 扩展时可直接复用。
@MainActor
final class ProcessingActivityBridge {
    private var box: ActivityBox?

    /// 是否已有一张在跑的卡片（用于避免重复 request）。
    var isActive: Bool { box != nil }

    /// 开始（幂等）：已有卡片时直接返回。
    func startIfNeeded(title: String = "AI 人像美化") {
        guard box == nil else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = ProcessingActivityAttributes(title: title)
        let state = ProcessingActivityAttributes.ContentState(
            fraction: 0,
            phaseTitle: "准备图像",
            detail: "正在准备图像"
        )
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            box = ActivityBox(activity)
        } catch {
            // 权限被拒 / 系统不支持：静默降级为「只有 App 内浮层」。
            box = nil
        }
    }

    /// 刷新进度。
    /// - Parameter finished: 语义参数（结束态由 `end` 处理），此处不改变行为。
    func update(fraction: Double, phaseTitle: String, detail: String, finished: Bool = false) {
        guard let box else { return }
        let clamped = min(max(fraction, 0), 1)
        let content = ActivityContent(
            state: ProcessingActivityAttributes.ContentState(
                fraction: clamped,
                phaseTitle: phaseTitle,
                detail: detail
            ),
            staleDate: nil
        )
        Task {
            await box.update(content)
        }
    }

    /// 结束并移除卡片。
    /// - Parameter finished: `true` = 成功收尾；`false` = 取消 / 失败。两者都立即移除，不残留。
    func end(fraction: Double, phaseTitle: String, detail: String, finished: Bool) {
        guard let box else { return }
        self.box = nil
        let content = ActivityContent(
            state: ProcessingActivityAttributes.ContentState(
                fraction: min(max(fraction, 0), 1),
                phaseTitle: phaseTitle,
                detail: detail
            ),
            staleDate: nil
        )
        Task {
            await box.end(content)
        }
    }
}

// MARK: - 隔离盒

/// ActivityKit 的 `Activity` 是**非 Sendable 的 class**，而它的 `update(_:)` / `end(_:dismissalPolicy:)`
/// 都是 **nonisolated async** 方法。在 `@MainActor` 上直接 `await activity.update(...)` 会被
/// Swift 6 判定为「把 main actor 隔离的值送给 nonisolated 方法」（真实 CI 报错：
/// `sending 'activity' risks causing data races`）。
///
/// 解法：把 `Activity` 关进一个 `@unchecked Sendable` 的盒子里，**所有跨越并发的 async 调用
/// 都发生在盒子内部的 nonisolated 上下文里**，非 Sendable 的 `Activity` 值从不跨隔离域传递。
private final class ActivityBox: @unchecked Sendable {
    private let activity: Activity<ProcessingActivityAttributes>

    init(_ activity: Activity<ProcessingActivityAttributes>) {
        self.activity = activity
    }

    func update(_ content: ActivityContent<ProcessingActivityAttributes.ContentState>) async {
        await activity.update(content)
    }

    func end(_ content: ActivityContent<ProcessingActivityAttributes.ContentState>) async {
        await activity.end(content, dismissalPolicy: .immediate)
    }
}
