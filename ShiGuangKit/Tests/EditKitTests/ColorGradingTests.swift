import Testing
import Foundation
@testable import EditKit

/// R009 色彩分级：纯逻辑层测试（EditKit 零平台依赖，Linux 可跑）。
///
/// 覆盖：色轮 tintVector 色彩数学、亮度三角窗、balance 再分配、钳制、
/// Recipe 强度混合、Codable 往返、EditOperation 接入。
@Suite struct ColorGradingTests {

    // MARK: - tintVector 色彩数学

    @Test func tintVectorHueZeroIsRed() {
        let v = ColorWheel(hue: 0, saturation: 100).tintVector
        #expect(abs(v.red - 1.0) < 1e-9)
        #expect(abs(v.green) < 1e-9)
        #expect(abs(v.blue) < 1e-9)
    }

    @Test func tintVectorHue120IsGreen() {
        let v = ColorWheel(hue: 120, saturation: 100).tintVector
        #expect(abs(v.green - 1.0) < 1e-9)
        #expect(abs(v.red) < 1e-9)
        #expect(abs(v.blue) < 1e-9)
    }

    @Test func tintVectorZeroSaturationIsZeroOffset() {
        let v = ColorWheel(hue: 200, saturation: 0).tintVector
        #expect(abs(v.red) < 1e-9 && abs(v.green) < 1e-9 && abs(v.blue) < 1e-9)
    }

    /// R009-Fix-6 锁定：整圆色相 —— 240° 必须是**纯蓝**（红绿分量均为 0）。
    ///
    /// 背景：色相范围原为 -180...180，240 被静默截到 180（青色 `(0, s, s)`），
    /// 绿通道被污染 → 三色轮分域语义失效（CI 3 个渲染用例失败的真正根因）。
    @Test func tintVectorHue240IsBlue() {
        let v = ColorWheel(hue: 240, saturation: 100).tintVector
        #expect(abs(v.blue - 1.0) < 1e-9)
        #expect(abs(v.red) < 1e-9)
        #expect(abs(v.green) < 1e-9)
    }

    /// 整圆扫描：任何合法色相的分量都必须落在 [0,1]，不得出现 2.0 这类越界值。
    @Test func tintVectorStaysInGamutAcrossFullCircle() {
        for deg in stride(from: 0.0, through: 360.0, by: 15.0) {
            let t = ColorWheel(hue: deg, saturation: 100).tintVector
            #expect(t.red >= 0 && t.red <= 1)
            #expect(t.green >= 0 && t.green <= 1)
            #expect(t.blue >= 0 && t.blue <= 1)
        }
    }

    /// 负色相折算（防御路径）：`hue` 是 public var，绕过 init 钳制直改时
    /// tintVector 仍须把它折算到整圆（-120° ≡ 240° 蓝），而非产出越界分量。
    @Test func tintVectorWrapsNegativeHueWhenSetDirectly() {
        var wheel = ColorWheel(hue: 0, saturation: 100)
        wheel.hue = -120
        let v = wheel.tintVector
        #expect(abs(v.blue - 1.0) < 1e-9)
        #expect(abs(v.red) < 1e-9)
        #expect(abs(v.green) < 1e-9)
    }

    @Test func tintVectorHalfSaturationScales() {
        let full = ColorWheel(hue: 0, saturation: 100).tintVector
        let half = ColorWheel(hue: 0, saturation: 50).tintVector
        #expect(abs(half.red - full.red * 0.5) < 1e-9)
    }

    // MARK: - 亮度三角窗（端点无污染的数学保证）

    @Test func triangleWindowPeaksAtCenters() {
        #expect(ColorGrading.LuminanceWindow.weight(luminance: 0.25, center: 0.25) == 1.0)
        #expect(ColorGrading.LuminanceWindow.weight(luminance: 0.50, center: 0.50) == 1.0)
        #expect(ColorGrading.LuminanceWindow.weight(luminance: 0.75, center: 0.75) == 1.0)
    }

    @Test func triangleWindowZeroAtBlackAndWhite() {
        // 纯黑 / 纯白：三个窗权重全 0 —— 端点无染色（渲染层验收点的数学保证）
        for center in [0.25, 0.50, 0.75] {
            #expect(ColorGrading.LuminanceWindow.weight(luminance: 0.0, center: center) == 0.0)
            #expect(ColorGrading.LuminanceWindow.weight(luminance: 1.0, center: center) == 0.0)
        }
    }

    @Test func triangleWindowZeroOutsideWindow() {
        // 阴影窗 [0, 0.5]：L=0.6 在窗外
        #expect(ColorGrading.LuminanceWindow.weight(luminance: 0.6, center: 0.25) == 0.0)
        // 高光窗 [0.5, 1.0]：L=0.4 在窗外
        #expect(ColorGrading.LuminanceWindow.weight(luminance: 0.4, center: 0.75) == 0.0)
    }

    // MARK: - balance 再分配

    @Test func balanceRedistributesShadowHighlightWeights() {
        let neutral = ColorGrading(balance: 0)
        #expect(neutral.shadowBalanceScale == 1.0)
        #expect(neutral.highlightBalanceScale == 1.0)

        let shadowHeavy = ColorGrading(balance: 100)
        #expect(abs(shadowHeavy.shadowBalanceScale - 0.5) < 1e-9)
        #expect(abs(shadowHeavy.highlightBalanceScale - 1.5) < 1e-9)

        let highlightHeavy = ColorGrading(balance: -100)
        #expect(abs(highlightHeavy.shadowBalanceScale - 1.5) < 1e-9)
        #expect(abs(highlightHeavy.highlightBalanceScale - 0.5) < 1e-9)
    }

    // MARK: - 钳制

    @Test func colorWheelClampsOutOfRange() {
        // R009-Fix-6：色相范围改为整圆 0...360（与三色轮 UI / App 预设语义一致）
        let wheel = ColorWheel(hue: 999, saturation: -50)
        #expect(wheel.hue == 360)
        #expect(wheel.saturation == 0)

        let wheel2 = ColorWheel(hue: -999, saturation: 999)
        #expect(wheel2.hue == 0)
        #expect(wheel2.saturation == 100)
    }

    @Test func colorGradingClampsBlendingAndBalance() {
        let g = ColorGrading(blending: 500, balance: -500)
        #expect(g.blending == 100)
        #expect(g.balance == -100)
    }

    // MARK: - Recipe 强度混合

    @Test func blendedTowardsIdentityHalvesWheelValues() {
        let g = ColorGrading(
            shadows: ColorWheel(hue: 90, saturation: 80),
            blending: 100,
            balance: 50
        )
        let half = g.blended(towardsIdentity: 0.5)
        #expect(abs(half.shadows.hue - 45) < 1e-9)
        #expect(abs(half.shadows.saturation - 40) < 1e-9)
        // blending 向恒等态的 100 收敛：100 + (100-100)*0.5 = 100
        #expect(abs(half.blending - 100) < 1e-9)
        #expect(abs(half.balance - 25) < 1e-9)
    }

    @Test func blendedZeroIsIdentity() {
        let g = ColorGrading(
            shadows: ColorWheel(hue: 90, saturation: 80),
            blending: 100
        )
        #expect(g.blended(towardsIdentity: 0).isIdentity)
    }

    // MARK: - Codable 往返

    @Test func codableRoundTrip() throws {
        let g = ColorGrading(
            shadows: ColorWheel(hue: 45, saturation: 60),
            midtones: ColorWheel(hue: -120, saturation: 30),
            highlights: ColorWheel(hue: 180, saturation: 90),
            blending: 75,
            balance: -20
        )
        let data = try JSONEncoder().encode(g)
        let decoded = try JSONDecoder().decode(ColorGrading.self, from: data)
        #expect(decoded == g)
    }

    // MARK: - EditOperation 接入

    @Test func operationParameterAndBlendRoundTrip() {
        let g = ColorGrading(shadows: ColorWheel(hue: 30, saturation: 50), blending: 80)
        let op = EditOperation.colorGrading(g)
        #expect(op.parameter == .colorGrading)
        #expect(op.numericValue == nil)             // 结构化指令无单一数值
        #expect(op.clamped == op)                   // withValue 原样返回
        let blended = op.blended(amount: 0.5)
        guard case .colorGrading(let bg) = blended else {
            Issue.record("混合后应为 colorGrading"); return
        }
        #expect(abs(bg.shadows.hue - 15) < 1e-9)
        // blending 向恒等态 100 收敛：100 + (80-100)*0.5 = 90
        #expect(abs(bg.blending - 90) < 1e-9)
    }

    @Test func identityGradingIsNotRendered() {
        #expect(ColorGrading().isIdentity)
    }

    // MARK: - R011：极端色相与极端饱和度边界

    /// R011：hue 360 ≡ hue 0 = 红（整圆闭环：360° 与 0° 是同一点，
    /// `truncatingRemainder(dividingBy: 360)` 不得把 360 漂移到越界或黑）。
    @Test func tintVectorHue360EqualsHueZero() {
        let at360 = ColorWheel(hue: 360, saturation: 100).tintVector
        let at0 = ColorWheel(hue: 0, saturation: 100).tintVector
        #expect(abs(at360.red - 1.0) < 1e-9)
        #expect(abs(at360.green) < 1e-9 && abs(at360.blue) < 1e-9)
        #expect(abs(at360.red - at0.red) < 1e-9)
        #expect(abs(at360.green - at0.green) < 1e-9)
        #expect(abs(at360.blue - at0.blue) < 1e-9)
    }

    /// R011：hue 360 + saturation 0（双极端端点）= 零偏移，不染色。
    @Test func hue360WithZeroSaturationIsZeroOffset() {
        let v = ColorWheel(hue: 360, saturation: 0).tintVector
        #expect(abs(v.red) < 1e-9 && abs(v.green) < 1e-9 && abs(v.blue) < 1e-9)
    }

    /// R011：极端饱和度混合 —— s=0 时任何强度都不产生偏移（零保持零，
    /// 不因色相缩放把 0 饱和度拖出恒等）。
    @Test func blendedZeroSaturationStaysZeroOffsetAtAnyStrength() {
        for t in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let b = ColorWheel(hue: 210, saturation: 0).blended(towardsIdentity: t)
            #expect(b.saturation == 0)
            let v = b.tintVector
            #expect(abs(v.red) < 1e-9 && abs(v.green) < 1e-9 && abs(v.blue) < 1e-9)
        }
    }

    /// R011：极端饱和度混合 —— s=100 满幅：t=0 归零、t=1 满幅原样、t=0.5 半幅；
    /// 色相随强度线性缩放（240° × 0.5 = 120° 纯绿方向）。
    @Test func blendedFullSaturationScalesLinearly() {
        let full = ColorWheel(hue: 240, saturation: 100)
        #expect(full.blended(towardsIdentity: 0).isIdentity)
        #expect(full.blended(towardsIdentity: 1) == full)
        let half = full.blended(towardsIdentity: 0.5)
        #expect(abs(half.hue - 120) < 1e-9)
        #expect(abs(half.saturation - 50) < 1e-9)
        let v = half.tintVector
        #expect(abs(v.green - 0.5) < 1e-9)
        #expect(abs(v.red) < 1e-9 && abs(v.blue) < 1e-9)
    }

    /// R011：hue 360 满饱和在 t=0.5 下色相折半为 180°（青）——
    /// 锁定「色相线性缩放」语义：360 不是特例，与任何色相同律。
    @Test func blendedHue360AtHalfStrengthIsCyanHalf() {
        let half = ColorWheel(hue: 360, saturation: 100).blended(towardsIdentity: 0.5)
        #expect(abs(half.hue - 180) < 1e-9)
        #expect(abs(half.saturation - 50) < 1e-9)
        let v = half.tintVector
        #expect(abs(v.green - 0.5) < 1e-9 && abs(v.blue - 0.5) < 1e-9)
        #expect(abs(v.red) < 1e-9)
    }

    /// R011：blending 极端值下混合端点与输入无关 —— t=0 恒等、t=1 原样。
    @Test func blendedEndpointsIndependentOfBlending() {
        for blending in [0.0, 50.0, 100.0] {
            let g = ColorGrading(
                shadows: ColorWheel(hue: 30, saturation: 80),
                midtones: ColorWheel(hue: 180, saturation: 20),
                highlights: ColorWheel(hue: 300, saturation: 60),
                blending: blending,
                balance: 40
            )
            #expect(g.blended(towardsIdentity: 0).isIdentity)
            #expect(g.blended(towardsIdentity: 1) == g)
        }
    }

    /// R011：blended 的 t 越界钳制（负 → 0 恒等；>1 → 1 原样）。
    @Test func blendedClampsOutOfRangeAmount() {
        let g = ColorGrading(
            shadows: ColorWheel(hue: 90, saturation: 80),
            blending: 60,
            balance: 30
        )
        #expect(g.blended(towardsIdentity: -3).isIdentity)
        #expect(g.blended(towardsIdentity: 4) == g)
    }
}
