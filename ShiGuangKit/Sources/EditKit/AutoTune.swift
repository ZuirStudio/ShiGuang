import Foundation

// MARK: - 图像统计

/// 图像统计快照（由 RenderKit 的 ImageAnalyzer 从像素提取）。
/// 值域均为 0...1 的 sRGB 编码域；纯数据结构，100% 可单测。
public struct ImageStats: Equatable, Sendable {
    /// 中位亮度（曝光依据）
    public var medianLuma: Double
    /// 5% 分位亮度（黑点估计）
    public var p05Luma: Double
    /// 95% 分位亮度（白点估计）
    public var p95Luma: Double
    /// 平均通道值（白平衡依据）
    public var meanR: Double
    public var meanG: Double
    public var meanB: Double
    /// 平均 chroma（max-min 归一，饱和度依据）
    public var meanChroma: Double

    public init(
        medianLuma: Double,
        p05Luma: Double,
        p95Luma: Double,
        meanR: Double,
        meanG: Double,
        meanB: Double,
        meanChroma: Double
    ) {
        self.medianLuma = medianLuma
        self.p05Luma = p05Luma
        self.p95Luma = p95Luma
        self.meanR = meanR
        self.meanG = meanG
        self.meanB = meanB
        self.meanChroma = meanChroma
    }

    /// 灰世界假设的通道不平衡度。
    public var whiteBalanceImbalance: Double { meanR - meanB }
}

// MARK: - AI 自动调参引擎（端侧启发式 v1）

/// 端侧自动调色引擎（P3 将叠加 Core ML 回归模型；v1 为可解释启发式，零联网零排队）。
/// 设计原则：
/// - 建议幅度保守（宁可少调不过调）
/// - 每个公式独立可单测
/// - 与滑杆共用 EditOperation 管线（AI 结果也是非破坏指令，可撤销可微调）
public enum AutoTune {
    /// AI 可建议的参数集合。
    public static let tunableParameters: [EditParameter] = [
        .exposure, .contrast, .highlights, .shadows,
        .whitePoint, .blackPoint, .temperature, .tint, .vibrance,
    ]

    /// 全自动修图：一次生成全部建议（一个原子历史步骤，可整体撤销）。
    public static func autoOperations(for stats: ImageStats) -> [EditOperation] {
        tunableParameters.compactMap { parameter in
            suggestedValue(for: parameter, stats: stats).map {
                EditOperation.make(parameter: parameter, value: $0)
            }
        }
    }

    /// 单参数自动建议；不适用该参数时返回 nil。
    public static func suggestedValue(for parameter: EditParameter, stats: ImageStats) -> Double? {
        switch parameter {
        case .exposure:
            // 目标中位亮度 0.42（中灰偏上）；对极暗/极亮图收敛
            guard stats.medianLuma > 0.01, stats.medianLuma < 0.99 else { return nil }
            let ev = log2(0.42 / stats.medianLuma)
            guard abs(ev) > 0.06 else { return nil } // 已接近目标不调，避免零值指令噪声
            return clamp(ev, -2.5, 2.5)

        case .contrast:
            // 动态范围不足时增强对比（p05-p95 分布宽 < 0.55）
            let spread = stats.p95Luma - stats.p05Luma
            guard spread < 0.62 else { return nil }
            let target: Double = 0.62
            let amount = (target - spread) * 110
            return clamp(amount, 4, 45)

        case .highlights:
            // 高光溢出（p95 > 0.97）→ 压高光
            guard stats.p95Luma > 0.97 else { return nil }
            let amount = (stats.p95Luma - 0.97) * 900
            return -clamp(amount, 5, 40)

        case .shadows:
            // 阴影死黑（p05 < 0.02）→ 提阴影
            guard stats.p05Luma < 0.02 else { return nil }
            let amount = (0.02 - stats.p05Luma) * 900
            return clamp(amount, 5, 40)

        case .whitePoint:
            // 白点未到（p95 < 0.9 且不溢出）→ 提白点
            guard stats.p95Luma < 0.9, stats.p95Luma > 0.05 else { return nil }
            let amount = (0.9 - stats.p95Luma) * 90
            return clamp(amount, 5, 35)

        case .blackPoint:
            // 黑点发灰（p05 > 0.08）→ 压黑点
            guard stats.p05Luma > 0.08 else { return nil }
            let amount = (stats.p05Luma - 0.06) * 140
            return -clamp(amount, 5, 30)

        case .temperature:
            // 灰世界：R > B → 图偏暖 → 给负（降温）；反之加温
            let imbalance = stats.whiteBalanceImbalance
            guard abs(imbalance) > 0.02 else { return nil }
            return clamp(-imbalance * 220, -35, 35)

        case .tint:
            // G 偏离 R/B 均值 → 反向调 tint
            let greenShift = stats.meanG - (stats.meanR + stats.meanB) / 2
            guard abs(greenShift) > 0.015 else { return nil }
            return clamp(-greenShift * 260, -25, 25)

        case .vibrance:
            // 整体欠饱和 → 提自然饱和度
            guard stats.meanChroma < 0.16 else { return nil }
            let amount = (0.16 - stats.meanChroma) * 260
            return clamp(amount, 6, 38)

        default:
            return nil
        }
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
