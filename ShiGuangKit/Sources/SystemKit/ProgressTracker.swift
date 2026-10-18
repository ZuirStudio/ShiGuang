import Foundation

// MARK: - 进度模型（纯逻辑，零平台依赖）

/// 单个处理步骤（权重可不同：如「AI 消除」的识别步比收尾步重）。
public struct ProgressStep: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    /// 权重（>= 0；总权重为 0 时按单步等分退化为线性进度）。
    public var weight: Double

    public init(id: String, title: String, weight: Double = 1) {
        self.id = id
        self.title = title
        self.weight = max(0, weight)
    }

    /// 无步骤信息任务的占位步（自由式进度上报用）。
    public static let single = ProgressStep(id: "single", title: "处理中")
}

/// 任务进度跟踪器：把「步骤推进 + 步内进度」折叠为单一 0...1 分数。
///
/// 纯值类型（`Sendable`），无任何平台依赖 —— Linux 可直接单测；
/// App 内浮层、灵动岛 / 锁屏卡片、通知文案**共用同一份进度**，保证同源。
///
/// 两种用法：
/// - 步骤式：`begin(steps:)` → `advance(toStepID:)` 逐步推进（批量导出：下载/处理/写盘/收尾）；
/// - 自由式：默认单步，`setProgress(_:)` 直接给 0...1（AI 消除：只有总进度）。
public struct ProgressTracker: Sendable, Equatable {
    /// 当前步骤表（恒非空：空输入退化为 `[.single]`）。
    public private(set) var steps: [ProgressStep]
    /// 当前步骤下标；-1 = 未开始。
    public private(set) var currentIndex: Int
    /// 当前步内进度 0...1。
    public private(set) var withinStep: Double
    /// 最近一次阶段文案（跟随步骤切换，可被外部覆盖）。
    public private(set) var phaseTitle: String

    public init(steps: [ProgressStep] = [.single]) {
        self.steps = steps.isEmpty ? [.single] : steps
        self.currentIndex = -1
        self.withinStep = 0
        self.phaseTitle = self.steps[0].title
    }

    /// 总权重（<= 0 时 fraction 退化为 withinStep）。
    public var totalWeight: Double { steps.reduce(0) { $0 + $1.weight } }

    /// 当前步骤（未开始时为第一步）。
    public var currentStep: ProgressStep {
        let index = currentIndex >= 0 && steps.indices.contains(currentIndex) ? currentIndex : 0
        return steps[index]
    }

    /// 总进度 0...1 =（已完成步权重 + 当前步权重 × 步内进度）/ 总权重。
    public var fraction: Double {
        guard totalWeight > 0 else { return min(max(withinStep, 0), 1) }
        var done = 0.0
        if currentIndex >= 0 {
            for (index, step) in steps.enumerated() where index < currentIndex {
                done += step.weight
            }
            if steps.indices.contains(currentIndex) {
                done += steps[currentIndex].weight * min(max(withinStep, 0), 1)
            }
        }
        return min(max(done / totalWeight, 0), 1)
    }

    public var isRunning: Bool { currentIndex >= 0 }

    /// 开始（幂等重置）：回到第一步、步内进度清零。
    public mutating func begin() {
        currentIndex = 0
        withinStep = 0
        phaseTitle = steps[0].title
    }

    /// 前进到指定步骤（未知 ID 返回 false，不改变状态）。
    @discardableResult
    public mutating func advance(toStepID id: String) -> Bool {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return false }
        currentIndex = index
        withinStep = 0
        phaseTitle = steps[index].title
        return true
    }

    /// 设置当前步内进度（钳制 0...1）。
    public mutating func setProgress(_ value: Double) {
        withinStep = min(max(value, 0), 1)
    }

    /// 覆盖阶段文案（步骤切换时由 `advance` 自动设置，此处供临时覆盖）。
    public mutating func setPhase(_ title: String) {
        phaseTitle = title
    }

    /// 完成：进度拉满。
    public mutating func complete() {
        currentIndex = steps.count - 1
        withinStep = 1
    }

    /// 复位到未开始态。
    public mutating func reset() {
        currentIndex = -1
        withinStep = 0
        phaseTitle = steps[0].title
    }
}
