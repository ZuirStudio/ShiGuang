import Testing
import CoreImage
import CoreGraphics
@testable import EditKit
@testable import RenderKit

/// R009 色彩分级渲染测试：CIColorKernel 行为验收。
///
/// 纪律（R007d 延续）：kernel 为逐像素直通（无采样模糊），纯色输入可**精确**
/// 断言——不依赖任何模糊绝对值，CI 软件渲染器下同样成立。
///
/// 覆盖（用户验收点）：
/// 1. 纯黑 / 纯白像素无污染（三角窗端点权重为 0 的渲染层证明）
/// 2. 灰阶正确色彩偏移（中灰 = 中间调窗中心；0.25 灰 = 阴影窗中心；0.75 灰 = 高光窗中心）
/// 3. blending=0 恒等；balance 再分配生效
@Suite struct ColorGradingRenderTests {

    /// 生成指定填充色的 1x1 CIImage。
    private func solidPixel(_ color: (r: Double, g: Double, b: Double)) -> CIImage {
        let cg = CGImage.solidColor(
            red: color.r, green: color.g, blue: color.b, alpha: 1,
            size: CGSize(width: 1, height: 1)
        )
        return CIImage(cgImage: cg)
    }

    /// 渲染并取 1x1 像素（软件渲染器，与 CI 环境一致）。
    private func pixel(of image: CIImage, context: CIContext) -> (r: Double, g: Double, b: Double)? {
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        return cg.pixel(at: CGPoint(x: 0, y: 0))
    }

    // MARK: - 验收点 1：纯黑 / 纯白无污染

    @Test func pureBlackIsUncontaminated() throws {
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let grading = ColorGrading(
            shadows: ColorWheel(hue: 0, saturation: 100),
            midtones: ColorWheel(hue: 120, saturation: 100),
            highlights: ColorWheel(hue: 240, saturation: 100),
            blending: 100,
            balance: 0
        )
        let black = solidPixel((0, 0, 0))
        let out = try #require(ColorGradingRenderer.apply(grading, on: black))
        let p = try #require(pixel(of: out, context: context))
        #expect(abs(p.r) < 0.004 && abs(p.g) < 0.004 && abs(p.b) < 0.004)
    }

    @Test func pureWhiteIsUncontaminated() throws {
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let grading = ColorGrading(
            shadows: ColorWheel(hue: 0, saturation: 100),
            midtones: ColorWheel(hue: 120, saturation: 100),
            highlights: ColorWheel(hue: 240, saturation: 100),
            blending: 100
        )
        let white = solidPixel((1, 1, 1))
        let out = try #require(ColorGradingRenderer.apply(grading, on: white))
        let p = try #require(pixel(of: out, context: context))
        #expect(abs(p.r - 1) < 0.004 && abs(p.g - 1) < 0.004 && abs(p.b - 1) < 0.004)
    }

    // MARK: - 验收点 2：灰阶正确色彩偏移

    @Test func midGrayGetsMidtoneWheelOffsetOnly() throws {
        let context = CIContext(options: [.useSoftwareRenderer: true])
        // 中灰 (0.5) 是中间调窗中心：只有 midtones 轮施效（阴影/高光窗权重为 0）
        let grading = ColorGrading(
            shadows: ColorWheel(hue: 0, saturation: 100),      // 红
            midtones: ColorWheel(hue: 120, saturation: 100),   // 绿
            highlights: ColorWheel(hue: 240, saturation: 100), // 蓝
            blending: 100
        )
        let gray = solidPixel((0.5, 0.5, 0.5))
        let out = try #require(ColorGradingRenderer.apply(grading, on: gray))
        let p = try #require(pixel(of: out, context: context))
        // 期望：0.5 + 绿偏移 (0,1,0)*1 → clamp 后 (0.5, 1, 0.5)
        #expect(abs(p.r - 0.5) < 0.004)
        #expect(abs(p.g - 1.0) < 0.004)
        #expect(abs(p.b - 0.5) < 0.004)
    }

    @Test func quarterGrayGetsShadowWheelOffsetOnly() throws {
        let context = CIContext(options: [.useSoftwareRenderer: true])
        // 0.25 灰 = 阴影窗中心（|0.25-0.25|/0.25 = 0 → 权重 1）
        let grading = ColorGrading(
            shadows: ColorWheel(hue: 0, saturation: 50),       // 半幅红
            midtones: ColorWheel(hue: 120, saturation: 100),
            highlights: ColorWheel(hue: 240, saturation: 100),
            blending: 100
        )
        let gray = solidPixel((0.25, 0.25, 0.25))
        let out = try #require(ColorGradingRenderer.apply(grading, on: gray))
        let p = try #require(pixel(of: out, context: context))
        // 期望：0.25 + 红偏移 (0.5,0,0) → (0.75, 0.25, 0.25)
        #expect(abs(p.r - 0.75) < 0.004)
        #expect(abs(p.g - 0.25) < 0.004)
        #expect(abs(p.b - 0.25) < 0.004)
    }

    @Test func threeQuarterGrayGetsHighlightWheelOffsetOnly() throws {
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let grading = ColorGrading(
            shadows: ColorWheel(hue: 0, saturation: 100),
            midtones: ColorWheel(hue: 120, saturation: 100),
            highlights: ColorWheel(hue: 240, saturation: 50),  // 半幅蓝
            blending: 100
        )
        let gray = solidPixel((0.75, 0.75, 0.75))
        let out = try #require(ColorGradingRenderer.apply(grading, on: gray))
        let p = try #require(pixel(of: out, context: context))
        // 期望：0.75 + 蓝偏移 (0,0,0.5) → (0.75, 0.75, 1.0 附近 clamp)
        #expect(abs(p.r - 0.75) < 0.004)
        #expect(abs(p.g - 0.75) < 0.004)
        #expect(abs(p.b - 1.0) < 0.004)
    }

    // MARK: - blending / balance

    @Test func zeroBlendingIsIdentity() throws {
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let grading = ColorGrading(
            midtones: ColorWheel(hue: 120, saturation: 100),
            blending: 0   // 全局混合 0 = 恒等
        )
        let gray = solidPixel((0.5, 0.5, 0.5))
        let out = try #require(ColorGradingRenderer.apply(grading, on: gray))
        let p = try #require(pixel(of: out, context: context))
        #expect(abs(p.r - 0.5) < 0.004 && abs(p.g - 0.5) < 0.004 && abs(p.b - 0.5) < 0.004)
    }

    @Test func balanceScalesShadowVersusHighlightWheels() throws {
        let context = CIContext(options: [.useSoftwareRenderer: true])
        // 同一只阴影红轮 + 高光蓝轮，balance 拉满阴影侧：
        // 0.25 灰（阴影窗中心）偏移 = 0.5 × shadowScale(0.5) = 0.25
        let grading = ColorGrading(
            shadows: ColorWheel(hue: 0, saturation: 100),
            highlights: ColorWheel(hue: 240, saturation: 100),
            blending: 100,
            balance: 100
        )
        let gray = solidPixel((0.25, 0.25, 0.25))
        let out = try #require(ColorGradingRenderer.apply(grading, on: gray))
        let p = try #require(pixel(of: out, context: context))
        #expect(abs(p.r - 0.5) < 0.004)   // 0.25 + 1.0 × 0.5
        #expect(abs(p.g - 0.25) < 0.004)
        #expect(abs(p.b - 0.25) < 0.004)
    }

    // MARK: - 全链路（EditGraph → BasicAdjustmentRenderer）

    @Test func gradingFlowsThroughFullRenderPipeline() throws {
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let source = solidPixel((0.5, 0.5, 0.5))
        var graph = EditGraph()
        graph.append(.colorGrading(ColorGrading(
            midtones: ColorWheel(hue: 120, saturation: 100),
            blending: 100
        )))
        let out = BasicAdjustmentRenderer().render(source: source, graph: graph)
        let p = try #require(pixel(of: out, context: context))
        #expect(abs(p.g - 1.0) < 0.004)
        #expect(abs(p.r - 0.5) < 0.004)
    }
}

// MARK: - 测试辅助（像素构造/取样）

private extension CGImage {
    /// 生成纯色 1x1 位图（8-bit sRGB）。
    static func solidColor(red: Double, green: Double, blue: Double, alpha: Double,
                           size: CGSize) -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let width = Int(size.width), height = Int(size.height)
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            data[i * 4]     = UInt8((min(max(red, 0), 1) * 255).rounded())
            data[i * 4 + 1] = UInt8((min(max(green, 0), 1) * 255).rounded())
            data[i * 4 + 2] = UInt8((min(max(blue, 0), 1) * 255).rounded())
            data[i * 4 + 3] = UInt8((min(max(alpha, 0), 1) * 255).rounded())
        }
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: colorSpace, bitmapInfo: bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }

    /// 读单像素（返回 0...1 归一化 RGB；premultiplied alpha=1 时即原值）。
    func pixel(at point: CGPoint) -> (r: Double, g: Double, b: Double)? {
        guard let provider = dataProvider, let data = provider.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }
        let bytesPerPixel = bitsPerPixel / 8
        let x = Int(point.x), y = Int(point.y)
        let offset = y * bytesPerRow + x * bytesPerPixel
        guard offset + 2 < CFDataGetLength(data) else { return nil }
        return (Double(ptr[offset]) / 255, Double(ptr[offset + 1]) / 255, Double(ptr[offset + 2]) / 255)
    }
}
