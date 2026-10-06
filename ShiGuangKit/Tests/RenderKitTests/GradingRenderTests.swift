import Testing
import CoreImage
import CoreGraphics
import EditKit
@testable import RenderKit

// MARK: - 测试工具

/// 生成纯色测试图（每个像素同色）。
func makeColorImage(r: UInt8, g: UInt8, b: UInt8, size: Int = 8) -> CGImage? {
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.setFillColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()
}

func renderColorToCGImage(
    _ graph: EditGraph,
    r: UInt8,
    g: UInt8,
    b: UInt8,
    renderer: BasicAdjustmentRenderer,
    context: CIContext
) -> CGImage? {
    guard let source = makeColorImage(r: r, g: g, b: b) else { return nil }
    let output = renderer.render(source: CIImage(cgImage: source), graph: graph)
    return context.createCGImage(output, from: output.extent)
}

// MARK: - 立方 LUT 数学（纯函数，无渲染依赖）

@Suite struct GradingCubeMathTests {
    /// 恒等输入不烘焙立方（省一次 LUT 采样）。
    @Test func makeReturnsNilWhenNothingToGrade() {
        #expect(GradingCube.make(curves: ToneCurveSet(), hsl: HSLAdjustment()) == nil)
    }

    /// 曲线或 HSL 任一非恒等都必须烘焙。
    @Test func makeReturnsCubeWhenCurveOrHSLIsSet() {
        var set = ToneCurveSet()
        set.red = ToneCurve(points: [CurvePoint(0, 0), CurvePoint(1, 0.5)])
        #expect(GradingCube.make(curves: set, hsl: HSLAdjustment()) != nil)

        var hsl = HSLAdjustment()
        hsl[.blue, .saturation] = 30
        #expect(GradingCube.make(curves: ToneCurveSet(), hsl: hsl) != nil)
    }

    /// 立方尺寸与数据布局：n³ × 3 分量，交给 CIColorCube 时须补成 RGBA。
    @Test func cubeLayoutMatchesCoreImageContract() {
        var set = ToneCurveSet()
        set.rgb = ToneCurve(points: [CurvePoint(0, 0.2), CurvePoint(1, 1)])
        guard let cube = GradingCube.make(curves: set, hsl: HSLAdjustment()) else {
            Issue.record("烘焙失败")
            return
        }
        let n = cube.size
        #expect(n == GradingCube.dimension)
        #expect(cube.rgb.count == n * n * n * 3)

        let data = LUTParser.colorCubeData(cube)
        #expect(data.count == n * n * n * 4 * MemoryLayout<Float>.size)
    }

    /// 索引序锚定：蓝通道曲线归零后，红色像素必须仍红（红不得被取到蓝的条目）。
    /// 这是立方体行序与 CIColorCube 契约是否一致的"交换机检测器"。
    @Test func cubeIndexOrderMatchesCoreImageContract() {
        var set = ToneCurveSet()
        set.blue = ToneCurve(points: [CurvePoint(0, 0), CurvePoint(1, 0)])   // 蓝输出压到 0
        guard let cube = GradingCube.make(curves: set, hsl: HSLAdjustment()) else {
            Issue.record("烘焙失败")
            return
        }
        let n = cube.size
        // 红最内层：ri 步进 1 对应索引 1，(r=1,g=0,b=0) 落在索引 n-1
        #expect(cube.rgb[0] == 0)                                    // (0,0,0) 红分量
        #expect(cube.rgb[3 * (n - 1)] > 0.9)                         // (r=1,g=0,b=0) 红仍满
        #expect(cube.rgb[(n - 1) * n * n * 3 + 2] == 0)              // (r=0,g=0,b=1) 蓝被压到 0
    }

    /// 曲线确实喂进了立方：黑角与白角采样到曲线端点值。
    /// （行序与 CIColorCube 契约一致：red 最快、blue 最慢）
    @Test func cubeCornersFollowCurveEndpoints() {
        var set = ToneCurveSet()
        set.rgb = ToneCurve(points: [CurvePoint(0, 0.2), CurvePoint(1, 1)])
        guard let cube = GradingCube.make(curves: set, hsl: HSLAdjustment()) else {
            Issue.record("烘焙失败")
            return
        }
        let n = cube.size
        let black = 0
        let white = ((n - 1) * n * n + (n - 1) * n + (n - 1)) * 3
        #expect(abs(Double(cube.rgb[black]) - 0.2) < 0.02)
        #expect(abs(Double(cube.rgb[black + 1]) - 0.2) < 0.02)
        #expect(abs(Double(cube.rgb[white]) - 1.0) < 0.02)
    }

    /// RGB ↔ HSL 往返保色（含灰轴与三原色）。
    @Test func rgbHSLRoundTripPreservesColor() {
        let samples: [(Double, Double, Double)] = [
            (0.0, 0.0, 0.0), (1, 1, 1), (0.5, 0.5, 0.5),
            (1, 0, 0), (0, 1, 0), (0, 0, 1),
            (0.9, 0.16, 0.16), (0.2, 0.55, 0.8), (0.35, 0.72, 0.28),
        ]
        for (r, g, b) in samples {
            let (h, s, l) = GradingCube.rgbToHSL(r, g, b)
            let back = GradingCube.hslToRGB(h, s, l)
            #expect(abs(back.0 - r) < 1e-9)
            #expect(abs(back.1 - g) < 1e-9)
            #expect(abs(back.2 - b) < 1e-9)
        }
    }

    /// 灰轴无色相：色相偏移对中性灰必须完全无影响。
    @Test func grayAxisIsInvariantUnderGrading() {
        var hsl = HSLAdjustment()
        for channel in HSLChannel.allCases {
            hsl[channel, .hue] = 100
            hsl[channel, .saturation] = 100
        }
        let out = GradingCube.adjustHSL(0.5, 0.5, 0.5, hsl: hsl)
        #expect(abs(out.0 - 0.5) < 1e-12)
        #expect(abs(out.1 - 0.5) < 1e-12)
        #expect(abs(out.2 - 0.5) < 1e-12)
    }

    /// 通道权重：中心为 1、远弧为 0、短弧环绕。
    @Test func hueWeightPeaksAtCenterAndFadesOnShortArc() {
        for channel in HSLChannel.allCases {
            let center = channel.hueCenter
            #expect(abs(GradingCube.hueWeight(center, center: center) - 1) < 1e-12)
            #expect(GradingCube.hueWeight(center + 0.25, center: center) == 0)
            // 短弧：跨 0 点的另一侧同样衰减（0.9 与 0 的短弧距离是 0.1）
            // 短弧环绕：0.95 与 0.05 距 0 的短弧距离都是 0.05，权重相同且显著非零
            let wrapped = GradingCube.hueWeight(0.95, center: 0)
            #expect(wrapped > 0.5)
            #expect(abs(wrapped - GradingCube.hueWeight(0.05, center: 0)) < 1e-12)
            // 短弧距离超过 2.8σ ≈ 0.14 后完全归零（0.8 → 0.2 → t=4）
            #expect(GradingCube.hueWeight(0.8, center: 0) == 0)
        }
    }

    /// 累加器必须夹紧在 [-1, 1]（相邻通道重叠相加不得溢出）。
    @Test func accumulatorsClampToUnitRange() {
        var hsl = HSLAdjustment()
        for channel in HSLChannel.allCases {
            hsl[channel, .saturation] = 100
            hsl[channel, .hue] = 100
            hsl[channel, .luminance] = -100
        }
        let acc = GradingCube.accumulators(hue: 0.1, hsl: hsl)
        #expect(acc.saturation <= 1 && acc.saturation >= -1)
        #expect(acc.hue <= 1 && acc.hue >= -1)
        #expect(acc.luminance <= 1 && acc.luminance >= -1)
    }

    /// 全色轮扫描：±100 边界不得产生 NaN / 越界。
    @Test func fullParameterSweepStaysInBounds() {
        for hueStep in 0...36 {
            let hue = Double(hueStep) / 36
            for value in [-100.0, -50, 0, 50, 100] {
                var hsl = HSLAdjustment()
                for channel in HSLChannel.allCases {
                    hsl[channel, .hue] = value
                    hsl[channel, .saturation] = value
                    hsl[channel, .luminance] = value
                }
                let out = GradingCube.adjustHSL(hue, 0.6, 0.4, hsl: hsl)
                for v in [out.0, out.1, out.2] {
                    #expect(v.isFinite)
                    #expect(v >= -1e-9 && v <= 1 + 1e-9)
                }
            }
        }
    }

    /// 色相 +100（≈ +180°）把纯红转到青，且通道值合法。
    @Test func hueShiftPlus180TurnsRedCyan() {
        var hsl = HSLAdjustment()
        hsl[.red, .hue] = 100
        let red = GradingCube.adjustHSL(1, 0, 0, hsl: hsl)
        #expect(red.0 < 0.1)
        #expect(red.1 > 0.9)
        #expect(red.2 > 0.9)
    }

    /// 色相 −100 与 +100 等价（同一条 180° 弧，方向相反）。
    @Test func hueShiftIsSymmetricAtBoundary() {
        var plus = HSLAdjustment()
        plus[.red, .hue] = 100
        var minus = HSLAdjustment()
        minus[.red, .hue] = -100
        let a = GradingCube.adjustHSL(1, 0, 0, hsl: plus)
        let b = GradingCube.adjustHSL(1, 0, 0, hsl: minus)
        #expect(abs(a.0 - b.0) < 1e-9)
        #expect(abs(a.1 - b.1) < 1e-9)
        #expect(abs(a.2 - b.2) < 1e-9)
    }
}

// MARK: - 曲线渲染

@Suite struct ToneCurveRenderTests {
    let renderer = BasicAdjustmentRenderer()
    /// 固定 sRGB 工作空间：曲线与 HSL 定义在 sRGB 编码域，
    /// 显式固定后断言数值不受运行环境色彩管理（P3 显示器等）影响。
    let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    private func render(_ set: ToneCurveSet, r: UInt8 = 128, g: UInt8 = 128, b: UInt8 = 128) -> CGImage? {
        var graph = EditGraph()
        graph.append(.toneCurve(set))
        return renderColorToCGImage(graph, r: r, g: g, b: b, renderer: renderer, context: context)
    }

    /// 恒等曲线 y = x 不改变像素。
    @Test func identityCurveLeavesPixelsUntouched() {
        guard let out = render(ToneCurveSet()) else { Issue.record("渲染失败"); return }
        let p = centerPixel(of: out, context: context)
        #expect(abs(Int(p.r) - 128) <= 2)
        #expect(abs(Int(p.g) - 128) <= 2)
        #expect(abs(Int(p.b) - 128) <= 2)
    }

    /// 主曲线抬中灰：128 → 约 141。
    @Test func masterCurveLiftsMidtones() {
        var set = ToneCurveSet()
        set.rgb = ToneCurve(points: [CurvePoint(0, 0.1), CurvePoint(1, 1)])
        guard let out = render(set) else { Issue.record("渲染失败"); return }
        let p = centerPixel(of: out, context: context)
        #expect(Int(p.r) > 133)
        #expect(abs(Int(p.r) - Int(p.g)) <= 2)
        #expect(abs(Int(p.g) - Int(p.b)) <= 2)
    }

    /// 主曲线压中灰：128 → 约 115。
    @Test func masterCurveDarkensMidtones() {
        var set = ToneCurveSet()
        set.rgb = ToneCurve(points: [CurvePoint(0, 0), CurvePoint(1, 0.9)])
        guard let out = render(set) else { Issue.record("渲染失败"); return }
        let p = centerPixel(of: out, context: context)
        #expect(Int(p.r) < 123)
    }

    /// 单通道曲线只影响对应通道（灰图 → g / b 必须原样）。
    @Test func singleChannelCurveOnlyTouchesItsChannel() {
        var set = ToneCurveSet()
        set.red = ToneCurve(points: [CurvePoint(0, 0.1), CurvePoint(1, 1)])
        guard let out = render(set) else { Issue.record("渲染失败"); return }
        let p = centerPixel(of: out, context: context)
        #expect(Int(p.r) > 133)
        #expect(abs(Int(p.g) - 128) <= 2)
        #expect(abs(Int(p.b) - 128) <= 2)
    }

    /// 极端源：全黑提亮、全白压暗，均须产出有效图像。
    @Test func extremeSourceValuesAreStable() {
        var lift = ToneCurveSet()
        lift.rgb = ToneCurve(points: [CurvePoint(0, 0.3), CurvePoint(1, 1)])
        guard let black = render(lift, r: 0, g: 0, b: 0) else { Issue.record("黑场渲染失败"); return }
        let bp = centerPixel(of: black, context: context)
        #expect(Int(bp.r) > 60)          // 0 → 0.3 ≈ 76
        #expect(Int(bp.r) < 95)

        var lower = ToneCurveSet()
        lower.rgb = ToneCurve(points: [CurvePoint(0, 0), CurvePoint(1, 0.7)])
        guard let white = render(lower, r: 255, g: 255, b: 255) else { Issue.record("白场渲染失败"); return }
        let wp = centerPixel(of: white, context: context)
        #expect(Int(wp.r) < 195)         // 255 → 0.7 ≈ 178
        #expect(Int(wp.r) > 160)
    }

    /// 极陡曲线（低阈值翻转）不崩溃、不越界、不过冲。
    @Test func steepCurveIsStable() {
        var set = ToneCurveSet()
        set.rgb = ToneCurve(points: [
            CurvePoint(0, 0), CurvePoint(0.45, 0.05), CurvePoint(0.55, 0.95), CurvePoint(1, 1),
        ])
        // 陡升段下侧（0.39）仍是暗部
        guard let dark = render(set, r: 100, g: 100, b: 100) else { Issue.record("渲染失败"); return }
        #expect(Int(centerPixel(of: dark, context: context).r) < 40)
        // 陡升段上侧（0.61）已是亮部：不过冲（≤255）、不反转
        guard let bright = render(set, r: 155, g: 155, b: 155) else { Issue.record("渲染失败"); return }
        let bp = centerPixel(of: bright, context: context)
        #expect(Int(bp.r) > 215)
        #expect(Int(bp.r) <= 255)
        // 陡升段中点：单调、不饱和到极值
        guard let mid = render(set) else { Issue.record("渲染失败"); return }
        let mp = centerPixel(of: mid, context: context)
        #expect(Int(mp.r) > 100 && Int(mp.r) < 160)
    }
}

// MARK: - HSL 渲染

@Suite struct HSLRenderTests {
    let renderer = BasicAdjustmentRenderer()
    let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    /// 24 参数全零不改变像素。
    @Test func zeroHSLIsNoOp() {
        var graph = EditGraph()
        for channel in HSLChannel.allCases {
            for component in HSLComponent.allCases {
                graph.append(.hsl(channel, component, 0))
            }
        }
        guard let out = renderColorToCGImage(graph, r: 230, g: 40, b: 40, renderer: renderer, context: context)
        else { Issue.record("渲染失败"); return }
        let p = centerPixel(of: out, context: context)
        #expect(abs(Int(p.r) - 230) <= 3)
        #expect(abs(Int(p.g) - 40) <= 3)
        #expect(abs(Int(p.b) - 40) <= 3)
    }

    /// 单通道饱和度 −100：该色域变灰，其他色域不动。
    @Test func channelSaturationMinus100GraysOnlyThatHue() {
        var red = HSLAdjustment()
        red[.red, .saturation] = -100

        var graph = EditGraph()
        graph.append(.hsl(.red, .saturation, -100))
        guard let redOut = renderColorToCGImage(graph, r: 230, g: 40, b: 40, renderer: renderer, context: context)
        else { Issue.record("渲染失败"); return }
        let rp = centerPixel(of: redOut, context: context)
        #expect(abs(Int(rp.r) - Int(rp.g)) <= 4)
        #expect(abs(Int(rp.g) - Int(rp.b)) <= 4)
        #expect(Int(rp.r) > 100 && Int(rp.r) < 180)   // 变成中灰（保持明度）

        // 蓝色域不在红通道的软窗内 → 原样保留
        guard let blueOut = renderColorToCGImage(graph, r: 40, g: 40, b: 230, renderer: renderer, context: context)
        else { Issue.record("渲染失败"); return }
        let bp = centerPixel(of: blueOut, context: context)
        #expect(abs(Int(bp.b) - 230) <= 4)
        #expect(abs(Int(bp.r) - 40) <= 4)
        #expect(Int(bp.b) - Int(bp.r) > 150)          // 仍然是彩色
    }

    /// 单通道明度 ±100：该色域压到黑 / 提到白。
    @Test func channelLuminanceExtremesDriveBlackAndWhite() {
        var dark = EditGraph()
        dark.append(.hsl(.red, .luminance, -100))
        guard let darkOut = renderColorToCGImage(dark, r: 230, g: 40, b: 40, renderer: renderer, context: context)
        else { Issue.record("渲染失败"); return }
        let d = centerPixel(of: darkOut, context: context)
        #expect(Int(d.r) <= 40)
        #expect(Int(d.g) <= 40)

        var bright = EditGraph()
        bright.append(.hsl(.red, .luminance, 100))
        guard let brightOut = renderColorToCGImage(bright, r: 230, g: 40, b: 40, renderer: renderer, context: context)
        else { Issue.record("渲染失败"); return }
        let br = centerPixel(of: brightOut, context: context)
        #expect(Int(br.r) >= 220)
        #expect(Int(br.g) >= 220)
    }

    /// 色相 ±180° 边界：红色转青、不崩溃。
    @Test func hueShiftBoundaryTurnsRedCyan() {
        var graph = EditGraph()
        graph.append(.hsl(.red, .hue, -100))
        guard let out = renderColorToCGImage(graph, r: 230, g: 40, b: 40, renderer: renderer, context: context)
        else { Issue.record("渲染失败"); return }
        let p = centerPixel(of: out, context: context)
        #expect(Int(p.r) < 120)
        #expect(Int(p.b) > Int(p.r))
    }

    /// 曲线与 HSL 混合、且中间插入非折叠算子：折叠刷新后两者都必须生效。
    @Test func foldedGradingSurvivesInterleavedOperations() {
        var set = ToneCurveSet()
        set.rgb = ToneCurve(points: [CurvePoint(0, 0.1), CurvePoint(1, 1)])

        var graph = EditGraph()
        graph.append(.toneCurve(set))
        graph.append(.contrast(20))          // 中断折叠 → 触发 flush
        graph.append(.hsl(.red, .saturation, -100))

        guard let out = renderColorToCGImage(graph, r: 230, g: 40, b: 40, renderer: renderer, context: context)
        else { Issue.record("渲染失败"); return }
        let p = centerPixel(of: out, context: context)
        // 饱和度归零仍然成立（区块内 HSL 生效）
        #expect(abs(Int(p.r) - Int(p.g)) <= 6)
        #expect(abs(Int(p.g) - Int(p.b)) <= 6)
    }

    /// 语义锚定：默认色彩空间的上下文与 sRGB 工作空间上下文结果一致
    /// —— 证明 CIColorCubeWithColorSpace 确实在 sRGB 编码域做查表
    /// （若退化为线性域查表，同一曲线会得出明显不同的像素）。
    @Test func gradingLooksUpInSRGBDomain() {
        var set = ToneCurveSet()
        set.rgb = ToneCurve(points: [CurvePoint(0, 0.1), CurvePoint(1, 1)])

        var graph = EditGraph()
        graph.append(.toneCurve(set))

        let defaultContext = CIContext()
        guard let a = renderColorToCGImage(graph, r: 128, g: 128, b: 128, renderer: renderer, context: defaultContext),
              let b = renderColorToCGImage(graph, r: 128, g: 128, b: 128, renderer: renderer, context: context)
        else { Issue.record("渲染失败"); return }
        let pa = centerPixel(of: a, context: defaultContext)
        let pb = centerPixel(of: b, context: context)
        #expect(abs(Int(pa.r) - Int(pb.r)) <= 4)
        #expect(Int(pa.r) > 133)
    }
}
