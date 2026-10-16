import Testing
import Foundation
import CoreImage
import CoreGraphics
@testable import EditKit
@testable import RenderKit

// MARK: - P1-E 自动选区的端到端验证
//
// `.auto` 形状的蒙版没有几何 alpha，必须由 `BasicAdjustmentRenderer.maskAlphaProvider`
// 注入（生产链路 = AICore 生成）。这里用"上白下黑"的人工掩码替身，
// 证明注入后 **局部调整 / 预览叠加** 都真的按掩码生效，且尺寸不一致时几何仍然对齐。

private let autoTestSize = 96
private let autoTestGray = 128

/// 上白下黑的**不透明三通道**掩码位图（与 AICore 产物同形态）。
/// CGImage 第 0 行 = 图像顶行（与蒙版坐标约定一致）。
private func topHalfMaskBytes(size: Int, topWhite: Bool = true) -> CGImage? {
    var bytes = [UInt8](repeating: 0, count: size * size * 4)
    for row in 0..<size {
        for col in 0..<size {
            let i = (row * size + col) * 4
            let isTop = row < size / 2
            let v: UInt8 = (isTop == topWhite) ? 255 : 0
            bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v; bytes[i + 3] = 255
        }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
        width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )
}

/// 构建「一个自动选区蒙版 + 一组局部调整」的图谱。
private func autoGraph(
    kind: MaskKind = .sky,
    adjustments: [EditOperation],
    inverted: Bool = false
) -> (EditGraph, Mask) {
    let mask = Mask(
        name: "自动-\\(kind.rawValue)",
        shape: .auto(kind),
        isInverted: inverted,
        feather: 0,
        opacity: 100
    )
    var updated = mask
    updated.adjustments = adjustments
    // 直接以携调整的蒙版构图，避免 upsertMask 再追加一条重复的 .mask 操作
    // （重复会让局部调整被应用两次，断言就失去意义）。
    let graph = EditGraph(operations: [.mask(updated)])
    return (graph, updated)
}

/// 渲染并取「顶部 / 底部」采样灰度，用来判断掩码落点。
private func renderStats(_ image: CIImage, context: CIContext) -> (top: Int, bottom: Int)? {
    guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
    guard let top = sampleGray(cg, row: cg.height / 4), let bottom = sampleGray(cg, row: cg.height * 3 / 4) else {
        return nil
    }
    return (top, bottom)
}

/// 取某一行（居中）的平均灰度（读 R 通道）。
private func sampleGray(_ image: CGImage, row: Int) -> Int? {
    guard let data = image.dataProvider?.data else { return nil }
    let ptr = CFDataGetBytePtr(data)!
    let bpr = image.bytesPerRow
    let bpp = image.bitsPerPixel / 8
    guard bpp >= 3, row >= 0, row < image.height else { return nil }
    var sum = 0
    let start = row * bpr
    for col in 0..<image.width {
        sum += Int(ptr[start + col * bpp])
    }
    return sum / max(1, image.width)
}

// MARK: - P1-E 端到端

@Suite("自动选区（P1-E）管线接线")
struct AutoMaskPipelineTests {

    /// 1) 自动选区**不自带** alpha（几何渲染给不出）→ 必须由 provider 注入。
    @Test("自动选区的内置 alpha 为空，只能由外部提供")
    func autoShapeHasNoBuiltInAlpha() {
        let mask = Mask(name: "天空", shape: .auto(.sky))
        let alpha = MaskRenderer.alphaImage(for: mask, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        #expect(alpha == nil)
    }

    /// 2) provider 提供 alpha 后，局部调整真的只在掩码白区生效。
    @Test("provider 注入的 alpha 让局部调整按选区生效")
    func providerAlphaDrivesLocalAdjustment() throws {
        let size = 96
        let source = try #require(makeColorImage(r: 100, g: 100, b: 100, size: size))
        let base = CIImage(cgImage: source)
        let (graph, mask) = autoGraph(adjustments: [.exposure(2)])

        let context = CIContext(options: [.useSoftwareRenderer: true])
        let maskImage = try #require(topHalfMaskBytes(size: size))

        let renderer = BasicAdjustmentRenderer(maskAlphaProvider: { m, _ in
            m.id == mask.id ? maskImage : nil
        })
        let out = renderer.render(source: base, graph: graph)
        let cg = try #require(context.createCGImage(out, from: base.extent))
        let top = try #require(sampleGray(cg, row: cg.height / 4))
        let bottom = try #require(sampleGray(cg, row: cg.height * 3 / 4))

        #expect(top > 140)          // 白区：曝光 +2 明显提亮
        #expect(abs(bottom - 100) <= 3)   // 黑区：与原图一致
    }

    /// 3) 没有 provider（例如生成失败/尚未生成）→ 自动选区是**恒等**，不崩、不误作用全图。
    ///    这条同时是 P0-D「人像效果作用到全图」的反向保险：掩码缺失时绝不退化成全图。
    @Test("provider 缺失时自动选区恒等（不误作用全图）")
    func missingProviderIsIdentity() throws {
        let size = 96
        let source = try #require(makeColorImage(r: 100, g: 100, b: 100, size: size))
        let base = CIImage(cgImage: source)
        let (graph, _) = autoGraph(adjustments: [.exposure(2)])

        let renderer = BasicAdjustmentRenderer()
        let out = renderer.render(source: base, graph: graph)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let cg = try #require(context.createCGImage(out, from: base.extent))
        let top = try #require(sampleGray(cg, row: cg.height / 4))
        let bottom = try #require(sampleGray(cg, row: cg.height * 3 / 4))
        #expect(abs(top - 100) <= 3)
        #expect(abs(bottom - 100) <= 3)
    }

    /// 4) **尺寸不一致**（2048 档自动选区 vs 512 档预览）时几何仍然对齐 —— 直接盯 P0-B 那类 bug。
    @Test("provider alpha 与渲染尺寸不一致时几何对齐")
    func providerAlphaIsFittedToExtent() throws {
        let renderSize = 96
        let maskSize = 40           // 刻意与渲染尺寸不同
        let source = try #require(makeColorImage(r: 100, g: 100, b: 100, size: renderSize))
        let base = CIImage(cgImage: source)
        let (graph, mask) = autoGraph(adjustments: [.exposure(2)])
        let maskImage = try #require(topHalfMaskBytes(size: maskSize))

        let renderer = BasicAdjustmentRenderer(maskAlphaProvider: { m, _ in
            m.id == mask.id ? maskImage : nil
        })
        let out = renderer.render(source: base, graph: graph)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let cg = try #require(context.createCGImage(out, from: base.extent))
        let top = try #require(sampleGray(cg, row: cg.height / 4))
        let bottom = try #require(sampleGray(cg, row: cg.height * 3 / 4))

        // 只裁不缩（旧实现）会取到掩码的**下半部**：上亮下暗直接反转。
        #expect(top > 140, "上半部应为掩码白区（曝光生效）")
        #expect(abs(bottom - 100) <= 3, "下半部应为掩码黑区（保持原样）")
    }

    /// 5) 选区预览叠加色也走 provider alpha（tint 同样必须先缩放再采样）。
    @Test("自动选区的预览叠加色按 provider alpha 生效")
    func overlayTintUsesProvidedAlpha() throws {
        let size = 96
        let source = try #require(makeColorImage(r: 128, g: 128, b: 128, size: size))
        let base = CIImage(cgImage: source)
        let (graph, mask) = autoGraph(adjustments: [])
        let maskImage = try #require(topHalfMaskBytes(size: size / 3))

        let renderer = BasicAdjustmentRenderer(
            maskOverlayID: mask.id,
            maskAlphaProvider: { m, _ in m.id == mask.id ? maskImage : nil }
        )
        let out = renderer.render(source: base, graph: graph)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let cg = try #require(context.createCGImage(out, from: base.extent))

        let top = try #require(sampleColor(cg, row: cg.height / 4))
        let bottom = try #require(sampleColor(cg, row: cg.height * 3 / 4))
        // 叠加色是暖橙（R 明显高于 B）：白区里 R-B 被拉开，黑区保持中性灰。
        let topSpread = Int(top.r) - Int(top.b)
        let bottomSpread = Int(bottom.r) - Int(bottom.b)
        #expect(topSpread > 20, "掩码白区应带上叠加色")
        #expect(abs(bottomSpread) <= 6, "掩码黑区不应着色")
    }
}

/// 取某一行（居中）的平均 RGB（用于叠加色断言）。
private func sampleColor(_ image: CGImage, row: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
    guard let data = image.dataProvider?.data else { return nil }
    let ptr = CFDataGetBytePtr(data)!
    let bpr = image.bytesPerRow
    let bpp = image.bitsPerPixel / 8
    guard bpp >= 3, row >= 0, row < image.height else { return nil }
    var sr = 0, sg = 0, sb = 0
    let start = row * bpr
    for col in 0..<image.width {
        sr += Int(ptr[start + col * bpp])
        sg += Int(ptr[start + col * bpp + 1])
        sb += Int(ptr[start + col * bpp + 2])
    }
    let n = max(1, image.width)
    return (UInt8(sr / n), UInt8(sg / n), UInt8(sb / n))
}
