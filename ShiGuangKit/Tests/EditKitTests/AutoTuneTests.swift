import Testing
import Foundation
import EditKit

// MARK: - AI 自动调参引擎（端侧启发式）

@Suite struct AutoTuneTests {
    /// 中位 0.1 的暗图
    private var darkStats: ImageStats {
        ImageStats(medianLuma: 0.10, p05Luma: 0.02, p95Luma: 0.35,
                   meanR: 0.12, meanG: 0.10, meanB: 0.09, meanChroma: 0.05)
    }

    /// 中位 0.9 的过曝图
    private var blownStats: ImageStats {
        ImageStats(medianLuma: 0.88, p05Luma: 0.45, p95Luma: 0.995,
                   meanR: 0.88, meanG: 0.86, meanB: 0.85, meanChroma: 0.08)
    }

    /// 曝光正常、阴影死黑、对比不足
    private var normalStats: ImageStats {
        ImageStats(medianLuma: 0.44, p05Luma: 0.005, p95Luma: 0.80,
                   meanR: 0.45, meanG: 0.43, meanB: 0.41, meanChroma: 0.10)
    }

    @Test func darkImageGetsPositiveExposure() {
        let value = AutoTune.suggestedValue(for: .exposure, stats: darkStats) ?? 0
        #expect(value > 1)        // log2(0.42/0.10) ≈ 2.07
        #expect(value <= 2.5)
    }

    @Test func blownImageGetsNegativeExposure() {
        let value = AutoTune.suggestedValue(for: .exposure, stats: blownStats) ?? 0
        #expect(value < -1)
    }

    @Test func alreadyBalancedImageGetsNoExposureOp() {
        let balanced = ImageStats(medianLuma: 0.42, p05Luma: 0.05, p95Luma: 0.92,
                                  meanR: 0.4, meanG: 0.4, meanB: 0.4, meanChroma: 0.2)
        #expect(AutoTune.suggestedValue(for: .exposure, stats: balanced) == nil)
    }

    @Test func crushedShadowsGetShadowLift() {
        let value = AutoTune.suggestedValue(for: .shadows, stats: normalStats) ?? 0
        #expect(value >= 5)
    }

    @Test func blownHighlightsGetSuppression() {
        let value = AutoTune.suggestedValue(for: .highlights, stats: blownStats) ?? 0
        #expect(value < 0)
    }

    @Test func narrowSpreadGetsContrastBoost() {
        // p05=0.3, p95=0.6 → spread 0.3 < 0.62
        let flat = ImageStats(medianLuma: 0.45, p05Luma: 0.30, p95Luma: 0.60,
                              meanR: 0.45, meanG: 0.45, meanB: 0.45, meanChroma: 0.1)
        let value = AutoTune.suggestedValue(for: .contrast, stats: flat) ?? 0
        #expect(value >= 4)
    }

    @Test func warmImageGetsCoolingTemperature() {
        let warm = ImageStats(medianLuma: 0.45, p05Luma: 0.08, p95Luma: 0.88,
                              meanR: 0.55, meanG: 0.45, meanB: 0.30, meanChroma: 0.2)
        let value = AutoTune.suggestedValue(for: .temperature, stats: warm) ?? 0
        #expect(value < 0) // R > B → 建议负值降温
    }

    @Test func coolImageGetsWarmingTemperature() {
        let cool = ImageStats(medianLuma: 0.45, p05Luma: 0.08, p95Luma: 0.88,
                              meanR: 0.30, meanG: 0.45, meanB: 0.58, meanChroma: 0.2)
        let value = AutoTune.suggestedValue(for: .temperature, stats: cool) ?? 0
        #expect(value > 0)
    }

    @Test func desaturatedImageGetsVibrance() {
        let value = AutoTune.suggestedValue(for: .vibrance, stats: normalStats) ?? 0
        #expect(value >= 6)
    }

    @Test func nonTunableParametersReturnNil() {
        for parameter in EditParameter.allCases where !AutoTune.tunableParameters.contains(parameter) {
            #expect(AutoTune.suggestedValue(for: parameter, stats: normalStats) == nil)
        }
    }

    @Test func autoOperationsAreValidAndAtomic() {
        let operations = AutoTune.autoOperations(for: normalStats)
        #expect(!operations.isEmpty)
        for op in operations {
            #expect(op == op.clamped)                    // 建议值都在合法范围
            #expect(AutoTune.tunableParameters.contains(op.parameter))
        }
        // 全部指令合成一个可撤销原子步骤
        let uniqueParameters = Set(operations.map(\.parameter))
        #expect(uniqueParameters.count == operations.count)
    }

    @Test func histogramImbalanceComputed() {
        let warm = ImageStats(medianLuma: 0.4, p05Luma: 0.1, p95Luma: 0.9,
                              meanR: 0.55, meanG: 0.45, meanB: 0.30, meanChroma: 0.1)
        #expect(warm.whiteBalanceImbalance > 0.2)
    }
}
