import Testing
import Foundation
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

    /// 像素断言容差（≈5 LSB）。
    ///
    /// 预算来自 8-bit 量化的**真实误差**，不是拍脑袋放水：
    /// 1. 窗中心 0.25 / 0.50 / 0.75 在 8-bit 下**无法精确表示**
    ///    （64/128/191 → 0.250980 / 0.501961 / 0.749020），偏离中心最多 0.25 LSB；
    /// 2. 偏离中心即产生**邻窗泄漏**：中间调输入会吃到高光窗 0.0078 的权重
    ///    （CI 实测，正是此前 `midGray p.b=130` 的来源），泄漏量最多 1 LSB；
    /// 3. 输出再量化 0.5 LSB。
    /// 合计 ~1.5 LSB ≈ 0.006，取 0.02 留足余量；同时远小于「kernel 出错」的
    /// 0.2 级偏差 —— 容差放宽不会掩盖真 bug（色彩空间写反时偏差为 0.25 级）。
    private static let pixelTolerance = 0.02

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
        #expect(abs(p.r) < Self.pixelTolerance && abs(p.g) < Self.pixelTolerance && abs(p.b) < Self.pixelTolerance)
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
        #expect(abs(p.r - 1) < Self.pixelTolerance && abs(p.g - 1) < Self.pixelTolerance && abs(p.b - 1) < Self.pixelTolerance)
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
        #expect(abs(p.r - 0.5) < Self.pixelTolerance)
        #expect(abs(p.g - 1.0) < Self.pixelTolerance)
        #expect(abs(p.b - 0.5) < Self.pixelTolerance)
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
        #expect(abs(p.r - 0.75) < Self.pixelTolerance)
        #expect(abs(p.g - 0.25) < Self.pixelTolerance)
        #expect(abs(p.b - 0.25) < Self.pixelTolerance)
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
        #expect(abs(p.r - 0.75) < Self.pixelTolerance)
        #expect(abs(p.g - 0.75) < Self.pixelTolerance)
        #expect(abs(p.b - 1.0) < Self.pixelTolerance)
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
        #expect(abs(p.r - 0.5) < Self.pixelTolerance && abs(p.g - 0.5) < Self.pixelTolerance && abs(p.b - 0.5) < Self.pixelTolerance)
    }

    @Test func balanceScalesShadowVersusHighlightWheels() throws {
        let context = CIContext(options: [.useSoftwareRenderer: true])
        // 同一只阴影红轮（sat 100 → tint (1,0,0)）+ 高光蓝轮，balance 拉满阴影侧：
        // 0.25 灰（阴影窗中心，权重 1）× shadowBalanceScale(100) = 0.5 → 偏移 0.5
        let grading = ColorGrading(
            shadows: ColorWheel(hue: 0, saturation: 100),
            highlights: ColorWheel(hue: 240, saturation: 100),
            blending: 100,
            balance: 100
        )
        let gray = solidPixel((0.25, 0.25, 0.25))
        let out = try #require(ColorGradingRenderer.apply(grading, on: gray))
        let p = try #require(pixel(of: out, context: context))
        #expect(abs(p.r - 0.75) < Self.pixelTolerance)  // 0.25 + tint 1.0 × 窗 1.0 × scale 0.5
        #expect(abs(p.g - 0.25) < Self.pixelTolerance)
        #expect(abs(p.b - 0.25) < Self.pixelTolerance)
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
        #expect(abs(p.g - 1.0) < Self.pixelTolerance)
        #expect(abs(p.r - 0.5) < Self.pixelTolerance)
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
