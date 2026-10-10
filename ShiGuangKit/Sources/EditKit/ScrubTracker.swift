import Foundation
import CoreGraphics

/// 参数调整手势的纯逻辑内核：**轴向锁定 + 段落化位移 + 数值归一化推进**。
///
/// 设计目标（对应 R007b-1 Stage A）：
/// 1. 首次触摸即锁定轴向，锁定后**不再抖动切换**；只有「明显逆转」（另一轴位移 > 已锁轴 × 2）才允许换轴。
/// 2. 垂直位移**段落化**：每 `stepHeight` 点位移 = 切一格参数（不是连续滚动），因此不会「一秒冲到最后一个」。
/// 3. 水平位移归一化：`normalizedProgress` 把位移换算成相对量（跨屏宽 = 1.0），由调用方乘以参数跨度。
///
/// 本类型**不含任何 UI 依赖**（仅 Foundation/CoreGraphics），因此可在 CI 单元测试中完整覆盖。
public struct ScrubTracker: Sendable {

    // MARK: - 类型

    /// 手势轴向。
    public enum Axis: Sendable, Equatable {
        case horizontal
        case vertical
    }

    /// 可调参数。
    public struct Configuration: Sendable, Equatable {
        /// 锁定轴向所需的最小位移（避免轻触即锁）。默认 8pt。
        public var lockThreshold: CGFloat
        /// 垂直段落高度：每 48pt = 切一格参数。默认 48pt。
        public var stepHeight: CGFloat
        /// 换轴所需的「明显逆转」倍数：另一轴位移 > 已锁轴 × 该倍数才换轴。默认 2.0。
        public var axisSwitchRatio: CGFloat
        /// 水平归一化距离：位移达到该值 = 归一化 1.0（跨屏宽）。默认 240pt。
        public var fullRangeDistance: CGFloat

        public init(
            lockThreshold: CGFloat = 8,
            stepHeight: CGFloat = 48,
            axisSwitchRatio: CGFloat = 2.0,
            fullRangeDistance: CGFloat = 240
        ) {
            self.lockThreshold = max(lockThreshold, 0.1)
            self.stepHeight = max(stepHeight, 1)
            self.axisSwitchRatio = max(axisSwitchRatio, 1)
            self.fullRangeDistance = max(fullRangeDistance, 1)
        }

        public static let `default` = Configuration()
    }

    /// 一次 update 的结果。
    public struct Update: Sendable, Equatable {
        /// 当前锁定的轴向；尚未达到锁定阈值时为 nil。
        public var axis: Axis?
        /// 本次 update 是否发生了轴向变化（调用方应据此**重新锚定**初始值/初始项）。
        public var axisChanged: Bool
        /// 本次的垂直段落数：向上滑为正（前一项），向下滑为负。
        public var verticalSteps: Int
        /// 本次的水平归一化位移（跨 `fullRangeDistance` = 1.0）。
        public var horizontalProgress: CGFloat
    }

    // MARK: - 状态

    public private(set) var axis: Axis?
    public var configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
        self.axis = nil
    }

    /// 手势开始（onChanged 首次触发）时重置轴向。
    public mutating func reset() {
        axis = nil
    }

    /// 喂入累计位移（`DragGesture.Value.translation`），返回本次结果。
    ///
    /// - 未锁定：位移超过 `lockThreshold` 后按主轴方向锁定。
    /// - 已锁定：若另一轴位移 > 已锁轴 × `axisSwitchRatio`，则换轴（视为明显逆转）。
    public mutating func update(translation: CGSize) -> Update {
        let dx = translation.width
        let dy = translation.height
        let absX = abs(dx)
        let absY = abs(dy)
        var changed = false

        if let locked = axis {
            switch locked {
            case .vertical:
                if absX > absY * configuration.axisSwitchRatio {
                    axis = .horizontal
                    changed = true
                }
            case .horizontal:
                if absY > absX * configuration.axisSwitchRatio {
                    axis = .vertical
                    changed = true
                }
            }
        } else if max(absX, absY) > configuration.lockThreshold {
            axis = absX > absY ? .horizontal : .vertical
            changed = true
        }

        return Update(
            axis: axis,
            axisChanged: changed,
            verticalSteps: verticalSteps(translation: translation),
            horizontalProgress: horizontalProgress(translation: translation)
        )
    }

    // MARK: - 换算

    /// 垂直段落数：向上滑（负 dy）返回正数（切到前一项）。
    /// 只在已锁定为垂直轴时有效，其它情况返回 0。
    public func verticalSteps(translation: CGSize) -> Int {
        guard axis == .vertical else { return 0 }
        return Int((-translation.height / configuration.stepHeight).rounded(.towardZero))
    }

    /// 水平归一化位移：向右为正，1.0 = 跨 `fullRangeDistance`。
    /// 只在已锁定为水平轴时有效，其它情况返回 0。
    public func horizontalProgress(translation: CGSize) -> CGFloat {
        guard axis == .horizontal else { return 0 }
        return translation.width / configuration.fullRangeDistance
    }
}

// MARK: - 映射辅助（纯函数，便于测试）

public extension ScrubTracker {

    /// 把「初始索引 + 段落数」映射为**钳制后**的索引，并告知是否撞到边界。
    /// 表达式与原实现一致：`newIndex = initial - steps`（向上滑 = 前一项）。
    static func mappedIndex(
        initial: Int,
        steps: Int,
        count: Int
    ) -> (index: Int, hitBoundary: Bool) {
        guard count > 0 else { return (0, true) }
        let raw = initial - steps
        let clamped = min(max(raw, 0), count - 1)
        return (clamped, clamped != raw)
    }

    /// 把「初始值 + 归一化位移」映射为钳制到 `range` 内的参数值。
    static func mappedValue(
        initial: Double,
        progress: CGFloat,
        range: ClosedRange<Double>,
        sensitivity: Double = 1.0
    ) -> (value: Double, hitBoundary: Bool) {
        let span = range.upperBound - range.lowerBound
        let raw = initial + Double(progress) * span * sensitivity
        let clamped = min(max(raw, range.lowerBound), range.upperBound)
        return (clamped, abs(clamped - raw) > 1e-9)
    }
}
