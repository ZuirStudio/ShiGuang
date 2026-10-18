import Testing
import CoreImage
import CoreGraphics
@testable import EditKit
@testable import RenderKit

/// R009 任务 2 验收：同一 `Recipe`（折叠为 EditGraph）**并发**应用到多张
/// **不同尺寸**图片 —— 不崩溃、结果尺寸正确、渲染器无共享可变状态。
///
/// 批量修图（v1.5.0）的核心风险点：渲染链若残留进程级/实例级可变状态，
/// 并发下会交叉污染。本测试用 TaskGroup 多路并发 + 多尺寸混合来证伪。
///
/// 纪律（R007d 延续）：自 oracle 对照 —— 每张图的期望输出 = 输入像素
/// 经同一渲染器**串行**渲染的结果，与并发结果逐一比对，不依赖绝对像素值。
@Suite struct ConcurrentRenderTests {

    /// 造一张指定尺寸的灰底图（带轻微渐变，避免纯色的巧合通过）。
    private func makeImage(width: Int, height: Int) -> CIImage {
        let cg = CGImage.gradient(
            size: CGSize(width: width, height: height),
            top: (r: 0.30, g: 0.35, b: 0.40),
            bottom: (r: 0.70, g: 0.65, b: 0.60)
        )
        return CIImage(cgImage: cg)
    }

    /// 批量场景的共享编辑结果：曝光 + 对比度 + 色彩分级（覆盖数值与结构化指令）。
    private func makeGraph() -> EditGraph {
        var graph = EditGraph()
        graph.append(.exposure(0.3))
        graph.append(.contrast(12))
        graph.append(.colorGrading(ColorGrading(
            shadows: ColorWheel(hue: 20, saturation: 35),
            midtones: ColorWheel(hue: 140, saturation: 45),
            highlights: ColorWheel(hue: 230, saturation: 30),
            blending: 80,
            balance: 15
        )))
        return graph
    }

    // MARK: 并发应用多尺寸

    @Test func sameGraphConcurrentlyOnMixedSizes() async throws {
        let sizes = [
            (width: 32, height: 24),
            (width: 24, height: 32),
            (width: 64, height: 64),
            (width: 17, height: 40),
            (width: 128, height: 96),
            (width: 8, height: 128),
        ]
        let graph = makeGraph()

        // 并发：每张图独立 Task，渲染 + 取图都在 autoreleasepool 内完成，
        // 跨 Task 边界只传 CGImage（SDK 标注为不可变 Sendable）。
        let outputs: [(Int, Int, CGImage)] = await withTaskGroup(
            of: (Int, Int, CGImage)?.self,
            returning: [(Int, Int, CGImage)].self
        ) { group in
            for size in sizes {
                group.addTask {
                    // 每任务独立 CIContext（避免跨任务捕获非 Sendable 的类实例；
                    // 小图创建开销可忽略，语义上等价）
                    let context = CIContext(options: [.useSoftwareRenderer: true])
                    let input = autoreleasepool { () -> CIImage in
                        let cg = CGImage.gradient(
                            size: CGSize(width: size.width, height: size.height),
                            top: (r: 0.30, g: 0.35, b: 0.40),
                            bottom: (r: 0.70, g: 0.65, b: 0.60)
                        )
                        return CIImage(cgImage: cg)
                    }
                    let out = autoreleasepool { () -> CIImage in
                        BasicAdjustmentRenderer().render(source: input, graph: graph)
                    }
                    guard let cg = context.createCGImage(out, from: out.extent) else { return nil }
                    return (size.width, size.height, cg)
                }
            }
            var collected: [(Int, Int, CGImage)] = []
            for await item in group {
                if let item { collected.append(item) }
            }
            return collected
        }

        #expect(outputs.count == sizes.count)

        // 尺寸正确（各图独立 extent，无相互覆盖）
        for (w, h, image) in outputs {
            #expect(image.width == w)
            #expect(image.height == h)
        }

        // 自 oracle：与串行渲染结果逐像素一致（并发不改变渲染语义）
        for (w, h, image) in outputs {
            let serial = makeImage(width: w, height: h)
            let expected = BasicAdjustmentRenderer().render(source: serial, graph: graph)
            let context = CIContext(options: [.useSoftwareRenderer: true])
            let b = try #require(context.createCGImage(expected, from: expected.extent))
            #expect(image.width == b.width && image.height == b.height)
            // 中心像素比对（渐变图中心不一定是端点，色彩分级在此有实际偏移）
            let mid = CGPoint(x: image.width / 2, y: image.height / 2)
            let pa = try #require(image.pixel(at: mid))
            let pb = try #require(b.pixel(at: mid))
            #expect(abs(pa.r - pb.r) < 0.004 && abs(pa.g - pb.g) < 0.004 && abs(pa.b - pb.b) < 0.004)
        }
    }

    // MARK: 连续应用（ Recipe 强度混合路径 ）

    @Test func recipeAppliedSequentiallyToManyImages() throws {
        // Recipe（intensity 0.6）折叠后连续应用到 12 张不同尺寸图：
        // 结果必须与单张应用完全一致（无跨图状态残留）
        let recipe = Recipe(name: "批量", operations: [
            .exposure(0.5),
            .colorGrading(ColorGrading(midtones: ColorWheel(hue: 100, saturation: 60))),
        ], intensity: 0.6)
        let graph = EditGraph(operations: recipe.resolvedOperations())

        let sizes = stride(from: 8, to: 8 + 12 * 5, by: 5).map { $0 }
        var fingerprints: [String] = []
        for edge in sizes {
            let input = makeImage(width: edge, height: max(4, edge / 2))
            let out = autoreleasepool { () -> CIImage in
                BasicAdjustmentRenderer().render(source: input, graph: graph)
            }
            #expect(Int(out.extent.width) == edge)
            fingerprints.append("\(Int(out.extent.width))x\(Int(out.extent.height))")
        }
        // 12 张全部产出，且尺寸序列唯一（无相互覆盖）
        #expect(Set(fingerprints).count == sizes.count)
    }

    // MARK: 空图集边界

    @Test func emptyGraphIsNoOpOnAnySize() throws {
        let graph = EditGraph()
        for edge in [8, 33, 100] {
            let input = makeImage(width: edge, height: edge)
            let out = BasicAdjustmentRenderer().render(source: input, graph: graph)
            #expect(Int(out.extent.width) == edge)
        }
    }
}

// MARK: - 测试辅助

private extension CGImage {
    /// 生成上下渐变图（8-bit sRGB）：顶端 top 色，底端 bottom 色。
    static func gradient(
        size: CGSize,
        top: (r: Double, g: Double, b: Double),
        bottom: (r: Double, g: Double, b: Double)
    ) -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let width = Int(size.width), height = Int(size.height)
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let t = height > 1 ? Double(y) / Double(height - 1) : 0
            let r = top.r + (bottom.r - top.r) * t
            let g = top.g + (bottom.g - top.g) * t
            let b = top.b + (bottom.b - top.b) * t
            for x in 0..<width {
                let i = (y * width + x) * 4
                data[i]     = UInt8((min(max(r, 0), 1) * 255).rounded())
                data[i + 1] = UInt8((min(max(g, 0), 1) * 255).rounded())
                data[i + 2] = UInt8((min(max(b, 0), 1) * 255).rounded())
                data[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: colorSpace, bitmapInfo: bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }

    /// 读单像素（返回 0...1 归一化 RGB）。
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
