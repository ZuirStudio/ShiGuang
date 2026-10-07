import ActivityKit
import Foundation

/// Live Activity 桥接（R006 追加 C 差异化项）。
///
/// 设计原则：**全程静默降级**。系统不支持 / 用户关掉了实时活动 / 扩展没装，都不影响主流程，
/// 所有失败只写日志，不弹错、不中断处理。
@MainActor
final class ProcessingActivityBridge {

    private var activity: Activity<ProcessingActivityAttributes>?

    /// 系统与用户是否都允许实时活动。
    var isAvailable: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// 开启一条实时活动。重复调用安全（已有则直接更新）。
    func startIfNeeded(title: String = "AI 人像美化") {
        guard isAvailable else { return }
        if activity != nil { return }
        let attributes = ProcessingActivityAttributes(title: title)
        let content = ActivityContent(
            state: ProcessingActivityAttributes.ContentState(
                fraction: 0,
                phaseTitle: "准备中",
                detail: "拾光正在处理人像"
            ),
            staleDate: nil
        )
        do {
            activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
        } catch {
            // 常见原因：设备设置里关闭了「实时活动」、同时存在的活动数超限、
            // 或未安装渲染用的 Widget 扩展。一律静默降级：处理流程照常跑完。
            activity = nil
        }
    }

    /// 刷新进度。
    /// - Parameter finished: 保留给调用方的语义参数（结束态由 `end` 处理），此处不改变行为。
    func update(fraction: Double, phaseTitle: String, detail: String, finished: Bool = false) {
        guard let activity else { return }
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
            await activity.update(content)
        }
    }

    /// 结束并移除。
    /// - Parameter finished: `true` = 成功收尾（立即移除卡片）；`false` = 中断/失败（也移除，不残留）。
    func end(fraction: Double, phaseTitle: String, detail: String, finished: Bool) {
        guard let activity else { return }
        self.activity = nil
        let content = ActivityContent(
            state: ProcessingActivityAttributes.ContentState(
                fraction: min(max(fraction, 0), 1),
                phaseTitle: phaseTitle,
                detail: detail
            ),
            staleDate: nil
        )
        Task {
            await activity.end(content, dismissalPolicy: .immediate)
        }
    }
}
