import Foundation
import SystemKit

/// R006 追加 C：Live Activity（锁屏 / 灵动岛进度卡片）桥接层。
///
/// R009 起改为 `ProgressManager` 的薄封装：进度真源、节流与降级策略
/// 全部收敛到 SystemKit（AGENTS.md 第 4 节纪律：后续耗时任务必须使用
/// `ProgressManager`，不允许再私接 `Activity.request`）。本类只保留
/// EditorModel 既有的调用形状，避免牵动 AI 处理链路。
///
/// 设计口径（沿用 R006）：
/// - **可选能力**：设备未开启实时活动（或系统不支持）时整条链路静默降级，
///   绝不影响图像编辑主流程，也不阻塞任何一次渲染。
/// - 「不黑屏」的连续性由 `AIProcessingState` 保证，本层只负责把同一份进度
///   镜像到锁屏卡片上（`fraction / phaseTitle / detail` 与浮层完全同源）。
@MainActor
final class ProcessingActivityBridge {
    private let manager = ProgressManager.shared

    /// 是否已有一张在跑的卡片（用于避免重复 request）。
    var isActive: Bool { manager.isActive }

    /// 开始（幂等）：已有卡片时直接返回。
    func startIfNeeded(title: String = "AI 人像美化") {
        manager.begin(title: title)
    }

    /// 刷新进度。
    /// - Parameter finished: 语义参数（结束态由 `end` 处理），此处不改变行为。
    func update(fraction: Double, phaseTitle: String, detail: String, finished: Bool = false) {
        manager.report(fraction: fraction, phase: phaseTitle, detail: detail)
    }

    /// 结束并移除卡片。
    /// - Parameter finished: `true` = 成功收尾；`false` = 取消 / 失败。两者都立即移除，不残留。
    func end(fraction: Double, phaseTitle: String, detail: String, finished: Bool) {
        if finished {
            manager.finish(phase: phaseTitle, detail: detail)
        } else {
            manager.cancel(phase: phaseTitle, detail: detail)
        }
    }
}
