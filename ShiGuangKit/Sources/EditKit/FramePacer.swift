import Foundation

/// R007b-1 Stage B3：交互档预览的**自适应帧预算**（纯逻辑，可单测）。
///
/// 为什么不是「固定把合并窗口从 24ms 升到 150ms」：
/// 固定放大窗口会把**快机上本可跟手**的预览一起拖慢（150ms ≈ 6.7fps 图像刷新），
/// 与 A3「拖动中实时刷新预览」和 B4「滑杆拖动 60fps」直接冲突。
/// 真正造成卡顿与发热的是**渲染排队堆积**（一帧没画完又来一帧），所以：
///
///     下一次允许发车的间隔 = clamp(上次实际渲染耗时 × headroom, floor, ceiling)
///
/// - 渲染快（如 12ms）→ 间隔 24ms（floor，保持跟手，也不比 R006 更密）
/// - 渲染中等（如 40ms）→ 间隔 50ms（自然错开，不再堆积）
/// - 渲染很慢（如 130ms）→ 间隔 150ms（ceiling）
///
/// 注意：数值反馈（参数数字）始终是即时的，这里限制的只是**图像**刷新节奏。
public struct FramePacer: Sendable {
    public struct Configuration: Sendable {
        /// 最快节奏（毫秒）——与 R006 的交互档合并窗口一致，不更密。
        public var floorMS: Double
        /// 最慢节奏（毫秒）。
        public var ceilingMS: Double
        /// 余量系数：间隔 = 上次耗时 × headroom。
        public var headroom: Double
        /// 判定为「降档中」的耗时门槛（毫秒）。
        public var slowThresholdMS: Double

        public init(
            floorMS: Double = 24,
            ceilingMS: Double = 150,
            headroom: Double = 1.25,
            slowThresholdMS: Double = 40
        ) {
            self.floorMS = Swift.max(1, floorMS)
            self.ceilingMS = Swift.max(self.floorMS, ceilingMS)
            self.headroom = Swift.max(1, headroom)
            self.slowThresholdMS = Swift.max(0, slowThresholdMS)
        }
    }

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// 依据上一次实际渲染耗时给出下一次渲染的最小间隔（毫秒）。
    public func intervalMS(lastRenderMS: Double) -> Double {
        guard lastRenderMS > 0, lastRenderMS.isFinite else { return configuration.floorMS }
        let target = lastRenderMS * configuration.headroom
        return Swift.min(Swift.max(target, configuration.floorMS), configuration.ceilingMS)
    }

    /// 同上，但直接给出 `Duration`（可直接喂给 `Task.sleep(for:)`）。
    public func interval(lastRenderMS: Double) -> Duration {
        .milliseconds(Int(intervalMS(lastRenderMS: lastRenderMS).rounded()))
    }

    /// 是否处于降档状态（间隔已被拉大，说明渲染慢）。
    public func isThrottled(lastRenderMS: Double) -> Bool {
        intervalMS(lastRenderMS: lastRenderMS) > configuration.floorMS + 0.5
    }

    /// 相对 floor 的倍数，便于报告里量化「省了多少」。
    public func throttleRatio(lastRenderMS: Double) -> Double {
        intervalMS(lastRenderMS: lastRenderMS) / configuration.floorMS
    }
}
