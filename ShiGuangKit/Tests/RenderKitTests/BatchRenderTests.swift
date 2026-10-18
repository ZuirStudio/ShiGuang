import Testing
import CoreImage
import CoreGraphics
@testable import EditKit
@testable import RenderKit

/// R010 任务 2 验收：同一份编辑指令（Recipe 折叠）**并发**应用到多张图 ——
/// 结果同序、单张失败不中断、进度单调收敛到 total。
///
/// 与 `ConcurrentRenderTests` 的分工：那边证明「渲染器无共享可变状态」
/// （TaskGroup 直接调 `BasicAdjustmentRenderer`）；这边证明 `BatchRenderer`
/// 这个**批量编排原语**本身（滑窗口限流 / 结果归位 / 失败隔离 / 进度契约）。
@Suite struct BatchRenderTests {

    /// 进度收集盒：`render` 的 progress 闭包是 `@Sendable` 且在 actor 上下文
    /// 调用，本地 var 无法直接捕获（Swift 6）—— 沿用 BatchExportTests 的盒子模式。
    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [BatchRenderProgress] = []
        func append(_ progress: BatchRenderProgress) {
            lock.lock(); defer { lock.unlock() }
            items.append(progress)
        }
        var snapshot: [BatchRenderProgress] {
            lock.lock(); defer { lock.unlock() }
            return items
        }
    }

    /// 造一张指定尺寸的灰底渐变图（避免纯色的巧合通过）。
    private func makeImage(width: Int, height: Int) -> CIImage {
        let cg = CGImage.gradient(
            size: CGSize(width: width, height: height),
            top: (r: 0.30, g: 0.35, b: 0.40),
            bottom: (r: 0.70, g: 0.65, b: 0.60)
        )
        return CIImage(cgImage: cg)
    }

    /// 批量场景的共享编辑结果（覆盖数值与结构化指令）。
    private func makeOperations() -> [EditOperation] {
        [
            .exposure(0.3),
            .contrast(12),
            .colorGrading(ColorGrading(
                shadows: ColorWheel(hue: 20, saturation: 35),
                midtones: ColorWheel(hue: 140, saturation: 45),
                highlights: ColorWheel(hue: 230, saturation: 30),
                blending: 80,
                balance: 15
            )),
        ]
    }

    // MARK: 并发应用多尺寸 + 结果归位

    @Test func concurrentRenderOrdersResultsByIndex() async throws {
        let sizes = [(w: 32, h: 24), (w: 64, h: 64), (w: 128, h: 96), (w: 17, h: 40), (w: 8, h: 128)]
        let images = sizes.map { makeImage(width: $0.w, height: $0.h) }
        let operations = makeOperations()
        let box = ProgressBox()

        let results = await BatchRenderer().render(
            images, operations: operations, options: BatchRenderOptions(maxConcurrentTasks: 2)
        ) { progress in
            box.append(progress)
        }

        // 结果与输入同序同尺寸（滑窗归位正确，无相互覆盖）
        #expect(results.count == sizes.count)
        for (index, size) in sizes.enumerated() {
            let image = try #require(results[index])
            #expect(image.width == size.w)
            #expect(image.height == size.h)
        }

        // 进度契约：单调、收敛到 total
        let progresses = box.snapshot
        #expect(!progresses.isEmpty)
        #expect(progresses.last == BatchRenderProgress(completed: sizes.count, total: sizes.count))
        for pair in zip(progresses, progresses.dropFirst()) {
            #expect(pair.1.completed > pair.0.completed)
        }

        // 自 oracle：与串行渲染逐像素一致（并发不改变渲染语义）
        let serial = BasicAdjustmentRenderer().render(
            source: makeImage(width: 32, height: 24),
            graph: EditGraph(operations: operations)
        )
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let expected = try #require(context.createCGImage(serial, from: serial.extent))
        let actual = try #require(results[0])
        let mid = CGPoint(x: actual.width / 2, y: actual.height / 2)
        let pa = try #require(actual.pixel(at: mid))
        let pb = try #require(expected.pixel(at: mid))
        #expect(abs(pa.r - pb.r) < 0.004 && abs(pa.g - pb.g) < 0.004 && abs(pa.b - pb.b) < 0.004)
    }

    // MARK: 失败隔离

    @Test func singleFailureDoesNotAbortBatch() async throws {
        // 第 3 张是空 extent 的坏图（真实来源：损坏文件 / 零像素图）
        let images = [
            makeImage(width: 32, height: 24),
            makeImage(width: 48, height: 48),
            CIImage(),
            makeImage(width: 64, height: 64),
        ]
        let box = ProgressBox()

        let results = await BatchRenderer().render(
            images, operations: makeOperations()
        ) { progress in
            box.append(progress)
        }

        #expect(results.count == 4)
        #expect(results[0] != nil)
        #expect(results[1] != nil)
        #expect(results[2] == nil)   // 失败位：nil，不炸整批
        #expect(results[3] != nil)
        // 失败也计入 completed（进度收敛到 total，不会卡在 3/4）
        #expect(box.snapshot.last == BatchRenderProgress(completed: 4, total: 4))
    }

    // MARK: 边界

    @Test func emptyInputReturnsEmpty() async {
        let results = await BatchRenderer().render([], operations: makeOperations()) { _ in }
        #expect(results.isEmpty)
    }

    @Test func concurrencyClampedToImageCount() {
        #expect(BatchRenderOptions(maxConcurrentTasks: 8).effectiveConcurrency(imageCount: 3) == 3)
        #expect(BatchRenderOptions(maxConcurrentTasks: 2).effectiveConcurrency(imageCount: 10) == 2)
        #expect(BatchRenderOptions().effectiveConcurrency(imageCount: 1) == 1)
        // 上限纪律：默认封顶 4（内存峰值 = 并发数 × 单张 CGImage）
        #expect(BatchRenderOptions().effectiveConcurrency(imageCount: 100) == 4)
    }

    /// 长边钳制：超大图只缩不放大（小图原样）。
    @Test func longEdgeDownscaleIsClamped() {
        let big = makeImage(width: 8192, height: 4096)
        let downscaled = BatchRenderer.downscaled(big, longEdge: 4096)
        #expect(abs(downscaled.extent.width - 4096) < 1)
        #expect(abs(downscaled.extent.height - 2048) < 1)
        let small = makeImage(width: 1024, height: 768)
        #expect(BatchRenderer.downscaled(small, longEdge: 4096).extent.width == 1024)
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
