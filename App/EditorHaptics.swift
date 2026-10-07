import UIKit

/// R006 追加 B2：编辑器触觉分级。
///
/// 分级设计（对齐「不同语义 = 不同强度」的体感原则）：
/// - `parameterSwitch()` → **selection**（轻微，最频繁，不能烦人）
/// - `limit()`           → **light**（滑杆撞到上下限，提示「到头了」）
/// - `reset()`           → **medium**（参数归零，语义是「回到中性」，比切换重、比完成轻）
/// - `completed()`       → **heavy**（AI 处理完成，一次性的重要事件）
/// - `cancelled()`       → 通知型 warning
///
/// 所有 generator 都做成进程级单例并 `prepare()`：
/// `UIFeedbackGenerator` 首次触发会有十几毫秒的 Taptic Engine 启动延迟，
/// 每次调用后重新 prepare 可以让下一次触发保持零延迟（这是滑杆手感的关键）。
@MainActor
enum EditorHaptics {
    private static let selection = UISelectionFeedbackGenerator()
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private static let notification = UINotificationFeedbackGenerator()

    /// 手势开始前调用（手指刚按下去），把 Taptic Engine 唤醒。
    static func warmUp() {
        selection.prepare()
        light.prepare()
        medium.prepare()
        heavy.prepare()
    }

    static func parameterSwitch() {
        selection.selectionChanged()
        selection.prepare()
    }

    static func limit() {
        light.impactOccurred()
        light.prepare()
    }

    static func reset() {
        medium.impactOccurred(intensity: 1.0)
        medium.prepare()
    }

    static func completed() {
        heavy.impactOccurred(intensity: 1.0)
        heavy.prepare()
    }

    static func cancelled() {
        notification.notificationOccurred(.warning)
        notification.prepare()
    }

    /// 归零判定：本次值已到中性（0）而上一次不是。
    /// 中性值在本项目里恒为 0（未编辑时 `EditorModel.value(for:)` 返回 0）。
    static func shouldDetectReset(previous: Double, current: Double) -> Bool {
        previous != 0 && current == 0
    }
}
