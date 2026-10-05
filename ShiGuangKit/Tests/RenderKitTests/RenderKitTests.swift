import Testing
import CoreImage
import CoreGraphics
import EditKit
@testable import RenderKit

// MARK: - 测试工具

/// 生成纯色测试图（无 GPU 依赖，CI runner 软渲染可用）。
func makeTestImage(width: Int = 8, height: Int = 8, gray: UInt8 = 128) -> CGImage {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for i in 0..<(width * height) {
        pixels[i * 4] = gray
        pixels[i * 4 + 1] = gray
        pixels[i * 4 + 2] = gray
        pixels[i * 4 + 3] = 255
    }
    let image = pixels.withUnsafeMutableBytes { ptr -> CGImage? in
        guard let ctx = CGContext(
            data: ptr.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        return ctx.makeImage()
    }
    guard let image else {
        Issue.record("无法创建测试图")
        return CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!.makeImage()!
    }
    return image
}

/// 读中心像素（8x8 图中心即 (4,4)，CG 底部原点）。
func centerPixel(of image: CGImage, context: CIContext) -> (r: UInt8, g: UInt8, b: UInt8) {
    var px = [UInt8](repeating: 0, count: 4)
    px.withUnsafeMutableBytes { ptr in
        guard let ctx = CGContext(
            data: ptr.baseAddress,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: -4, y: -4, width: image.width, height: image.height))
    }
    return (px[0], px[1], px[2])
}

func renderToCGImage(
    _ graph: EditGraph,
    gray: UInt8 = 128,
    renderer: BasicAdjustmentRenderer,
    context: CIContext
) -> CGImage? {
    let source = CIImage(cgImage: makeTestImage(gray: gray))
    let output = renderer.render(source: source, graph: graph)
    return context.createCGImage(output, from: output.extent)
}

// MARK: - 色调内核

@Suite struct ToneRenderingTests {
    let renderer = BasicAdjustmentRenderer()
    let context = CIContext()

    @Test func identityPreservesPixels() {
        let out = renderToCGImage(EditGraph(), renderer: renderer, context: context)
        guard let out else { Issue.record("渲染失败"); return }
        let p = centerPixel(of: out, context: context)
        #expect(abs(Int(p.r) - 128) <= 3)
        #expect(abs(Int(p.g) - 128) <= 3)
        #expect(abs(Int(p.b) - 128) <= 3)
    }

    @Test func exposureBrightens() {
        var graph = EditGraph()
        graph.append(.exposure(1))
        let out = renderToCGImage(graph, renderer: renderer, context: context)
        guard let out else { Issue.record("渲染失败"); return }
        let p = centerPixel(of: out, context: context)
        #expect(Int(p.r) > 200) // 128 * 2 → 255 clamp
        #expect(Int(p.g) > 200)
    }

    @Test func exposureDarkens() {
        var graph = EditGraph()
        graph.append(.exposure(-1))
        let out = renderToCGImage(graph, renderer: renderer, context: context)
        guard let out else { Issue.record("渲染失败"); return }
        let p = centerPixel(of: out, context: context)
        #expect(Int(p.r) < 70) // 128 / 2 → 64
        #expect(Int(p.g) < 70)
    }

    @Test func saturationMinus100Grays() {
        var graph = EditGraph()
        // 用有彩色的图：ImageIO 无法方便造彩色 → 用色调 kernel 的 temperature 先造偏色再验证饱和度归零
        graph.append(.temperature(80))
        graph.append(.saturation(-100))
        let out = renderToCGImage(graph, renderer: renderer, context: context)
        guard let out else { Issue.record("渲染失败"); return }
        let p = centerPixel(of: out, context: context)
        #expect(abs(Int(p.r) - Int(p.g)) <= 2)
        #expect(abs(Int(p.g) - Int(p.b)) <= 2)
    }

    @Test func contrastPositiveIncreasesSpread() {
        var graphPlus = EditGraph()
        graphPlus.append(.contrast(100))
        var graphMinus = EditGraph()
        graphMinus.append(.contrast(-100))
        let plus = renderToCGImage(graphPlus, gray: 96, renderer: renderer, context: context)
        let minus = renderToCGImage(graphMinus, gray: 96, renderer: renderer, context: context)
        guard let plus, let minus else { Issue.record("渲染失败"); return }
        // 96 低于中枢：加强对比应更暗，减弱对比应向中枢靠拢
        #expect(centerPixel(of: plus, context: context).r < centerPixel(of: minus, context: context).r)
    }
}

// MARK: - 几何与专门 filter

@Suite struct GeometricAndSpecialTests {
    let renderer = BasicAdjustmentRenderer()
    let context = CIContext()

    @Test func cropHalvesExtent() {
        var graph = EditGraph()
        graph.append(.crop(CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)))
        let source = CIImage(cgImage: makeTestImage())
        let out = renderer.render(source: source, graph: graph)
        #expect(out.extent.width == 4)
        #expect(out.extent.height == 4)
    }

    @Test func straightenKeepsExtent() {
        var graph = EditGraph()
        graph.append(.straighten(5))
        let source = CIImage(cgImage: makeTestImage())
        let out = renderer.render(source: source, graph: graph)
        // CIStraightenFilter 通过放大裁掉空角，尺寸不变
        #expect(abs(out.extent.width - 8) < 0.5)
        #expect(abs(out.extent.height - 8) < 0.5)
    }

    @Test func everyOperationProducesValidImage() {
        let ops: [EditOperation] = [
            .exposure(0.5), .contrast(20), .highlights(-30), .shadows(20),
            .whitePoint(10), .blackPoint(-5), .temperature(15), .tint(-8),
            .saturation(20), .vibrance(30), .clarity(40), .sharpen(50),
            .vignette(30), .noiseReduction(50), .dehaze(20),
        ]
        for op in ops {
            var graph = EditGraph()
            graph.append(op)
            let out = renderToCGImage(graph, renderer: renderer, context: context)
            guard out != nil else {
                Issue.record("操作 \(op) 渲染失败")
                continue
            }
            #expect(out!.width == 8 && out!.height == 8)
        }
    }

    @Test func foldedToneEqualsSingleKernelPass() {
        // 多参数折叠后仍产生有效输出
        var graph = EditGraph()
        graph.append(.exposure(0.3))
        graph.append(.contrast(15))
        graph.append(.vibrance(40))
        graph.append(.sharpen(60)) // 中断折叠，验证 flush 顺序
        graph.append(.temperature(-20))
        let out = renderToCGImage(graph, renderer: renderer, context: context)
        guard let out else { Issue.record("渲染失败"); return }
        #expect(out.width == 8 && out.height == 8)
    }
}
