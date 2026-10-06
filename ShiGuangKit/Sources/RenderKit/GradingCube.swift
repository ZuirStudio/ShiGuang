import CoreImage
import EditKit

/// 曲线 + HSL 合并烘焙为 3D 立方 LUT。
///
/// 决策（ADR-005）：4.1 要求 4 条独立曲线（RGB 主曲线 + R/G/B 分通道曲线），
/// 而系统 `CIColorCurves` 只能对 R/G/B 施加**同一条**曲线，无法表达分通道语义。
/// 本仓库既有的 LUT 路径（`CIColorCubeWithColorSpace` + `LUTCube`，见 `LUTParser`）
/// 已在软件渲染器（CI runner 无 GPU）下被既有测试验证可用，故曲线与 HSL 统一
/// 烘焙为一个立方 LUT 一次应用：既满足分通道语义，又不引入新的运行时 kernel 编译风险。
///
/// 色彩域说明：`CIColorCubeWithColorSpace` 会把输入转到 `inputColorSpace`（sRGB）后查表，
/// 因此本文件的 HSL 换算在 **sRGB 编码域**进行（与 Lightroom 等调色工具的直觉一致），
/// 而非 kernel 所用的线性光域。
public enum GradingCube {

    /// 立方维度：32³ = 32768 体素 ≈ 512 KB，烘焙量级 ~10 ms，适配 80 ms 防抖预算。
    public static let dimension = 32

    /// 曲线与 HSL 全为恒等时返回 nil（调用方跳过本次应用）。
    public static func make(curves: ToneCurveSet, hsl: HSLAdjustment) -> LUTCube? {
        guard !curves.isIdentity || !hsl.isIdentity else { return nil }
        let n = dimension
        // 每通道合成表（RGB 主曲线 ∘ 通道曲线）
        let tableR = curves.table(for: .red, count: n)
        let tableG = curves.table(for: .green, count: n)
        let tableB = curves.table(for: .blue, count: n)
        let useHSL = !hsl.isIdentity

        var rgb = [Float](repeating: 0, count: n * n * n * 3)
        var p = 0
        // CIColorCube 契约：条目按 "red 最快、blue 最慢" 排列 —— 红在最内层循环。
        // 顺序写反会让红蓝取到彼此的条目（实测锚定见 GradingRenderTests 索引序测试）。
        for bi in 0..<n {
            let cb = tableB[bi]
            for gi in 0..<n {
                let cg = tableG[gi]
                for ri in 0..<n {
                    var r = tableR[ri]
                    var g = cg
                    var b = cb
                    if useHSL {
                        (r, g, b) = adjustHSL(r, g, b, hsl: hsl)
                    }
                    rgb[p] = Float(r)
                    rgb[p + 1] = Float(g)
                    rgb[p + 2] = Float(b)
                    p += 3
                }
            }
        }
        return LUTCube(title: "拾光调色立方", size: n, rgb: rgb)
    }

    // MARK: - HSL

    /// 通道权重：色轮短弧距离上的平滑高斯窗（σ = 0.05 ≈ 18°）。
    /// 取**原始**权重（不在通道间归一化），使通道中心处权重恰为 1 —— 单通道
    /// 饱和度 -100 时该色域可精确变为灰，同时相邻通道自然重叠过渡。
    public static func hueWeight(_ hue: Double, center: Double, sigma: Double = 0.05) -> Double {
        var d = abs(hue - center)
        if d > 0.5 { d = 1 - d }
        let t = d / sigma
        return t > 2.8 ? 0 : exp(-0.5 * t * t)
    }

    /// 24 参数 → 单像素的（色相偏移 / 饱和度增益 / 明度增益），整体夹紧到 [-1, 1]。
    public static func accumulators(
        hue: Double,
        hsl: HSLAdjustment
    ) -> (hue: Double, saturation: Double, luminance: Double) {
        var aHue = 0.0
        var aSat = 0.0
        var aLum = 0.0
        for channel in HSLChannel.allCases {
            let w = hueWeight(hue, center: channel.hueCenter)
            guard w > 0 else { continue }
            aHue += w * hsl[channel, .hue] / 100
            aSat += w * hsl[channel, .saturation] / 100
            aLum += w * hsl[channel, .luminance] / 100
        }
        return (clamp(aHue), clamp(aSat), clamp(aLum))
    }

    /// RGB（sRGB 编码域）→ HSL → 加权调整 → RGB
    public static func adjustHSL(
        _ r: Double, _ g: Double, _ b: Double, hsl: HSLAdjustment
    ) -> (Double, Double, Double) {
        let (h, s, l) = rgbToHSL(r, g, b)
        guard s > 1e-6 else { return (r, g, b) }   // 灰轴无色相可言
        let acc = accumulators(hue: h, hsl: hsl)
        var nh = h + acc.hue * 0.5                 // 参数 ±100 → 色相 ±180°
        nh -= nh.rounded(.down)                    // 环绕回 0...1
        let ns = min(max(s * (1 + acc.saturation), 0), 1)
        let nl = min(max(l * (1 + acc.luminance), 0), 1)
        return hslToRGB(nh, ns, nl)
    }

    static func clamp(_ v: Double) -> Double { min(max(v, -1), 1) }

    public static func rgbToHSL(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, l: Double) {
        let maxV = max(r, g, b)
        let minV = min(r, g, b)
        let l = (maxV + minV) / 2
        let d = maxV - minV
        guard d > 1e-12 else { return (0, 0, l) }
        let s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
        var h: Double
        if maxV == r {
            h = (g - b) / d + (g < b ? 6 : 0)
        } else if maxV == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        h /= 6
        return (h, s, l)
    }

    public static func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        guard s > 1e-12 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        return (
            hueToChannel(p, q, h + 1.0 / 3),
            hueToChannel(p, q, h),
            hueToChannel(p, q, h - 1.0 / 3)
        )
    }

    private static func hueToChannel(_ p: Double, _ q: Double, _ t: Double) -> Double {
        var t = t
        if t < 0 { t += 1 }
        if t > 1 { t -= 1 }
        if t < 1.0 / 6 { return p + (q - p) * 6 * t }
        if t < 1.0 / 2 { return q }
        if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
        return p
    }
}
