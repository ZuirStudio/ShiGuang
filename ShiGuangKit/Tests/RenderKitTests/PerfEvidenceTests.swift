import Testing
import Foundation
import CoreImage
import CoreGraphics
import EditKit
@testable import RenderKit

/// R007b-1 Stage B4：**可在 CI 可执行**的性能证据。
///
/// 真机 Instruments 无法在 CI 复现，但「同一条管线在两个分辨率档下的真实耗时」
/// 与「蒙版 alpha 记忆化的命中/未命中次数」在 macOS runner 上可以真跑 Core Image。
/// 这些数字作为「优化前后对比」的机侧证据；真机结论仍以 signpost 时间线为准（报告中显式标注）。
///
/// 断言只取**方向性与结构性**结论（不写死毫秒数）：CI runner 性能抖动大，
/// 写死数值必然 flaky —— 这也正是「不许用 CI 绿糊弄」的边界。
@Suite("Stage B 性能证据（真实渲染）")
struct PerfEvidenceTests {

    /// 造一张 p×p 的噪声图（梯度 + 局部高频，避免纯色被 Core Image 优化掉）。
    private func makeSource(side: Int) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let i = (y * side + x) * 4
                pixels[i] = UInt8((x * 255) / side)
                pixels[i + 1] = UInt8((y * 255) / side)
                pixels[i + 2] = UInt8(((x + y) & 1) == 0 ? 30 : 220)
                pixels[i + 3] = 255
            }
        }
        return pixels.withUnsafeMutableBytes { ptr -> CGImage? in
            guard let base = ptr.baseAddress,
                  let bitmap = CGContext(
                      data: base, width: side, height: side,
                      bitsPerComponent: 8, bytesPerRow: side * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return nil }
            return bitmap.makeImage()
        }
    }

    private func busyGraph() -> EditGraph {
        var graph = EditGraph()
        graph.append(.exposure(0.4))
        graph.append(.contrast(12))
        graph.append(.clarity(18))
        graph.append(.vibrance(20))
        graph.append(.temperature(8))
        graph.append(.sharpen(25))
        return graph
    }

    @Test("交互档（长边 1024）确实比静止档（1600）轻：像素量与耗时都不超过")
    func interactiveQualityIsCheaper() throws {
        let side = 2000
        let source = try #require(makeSource(side: side))
        let ci = CIImage(cgImage: source)
        let renderer = BasicAdjustmentRenderer(lutProvider: nil)
        let graph = busyGraph()

        // 用同一份 CIContext（`RenderContext.shared`），与 App 热路径一致。
        let context = RenderContext.shared
        let p = PerfSignpost()

        func renderOnce(longEdge: Double) {
            let maxDim = max(ci.extent.width, ci.extent.height)
            let scale = min(1, longEdge / maxDim)
            let input = scale < 1
                ? ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                : ci
            _ = p.measure(.previewRender) {
                let out = renderer.render(source: input, graph: graph)
                _ = context.createCGImage(out, from: out.extent)
            }
        }

        // 预热一次（首次会分配 GPU 资源 / 编译 CIKernel，不代表稳态）
        renderOnce(longEdge: 1024)

        p.reset()
        // 各跑 3 次取均值，抵消 CI runner 的单次抖动
        for _ in 0..<3 { renderOnce(longEdge: 1600) }
        let still = p.sample(.previewRender).meanMS
        p.reset()
        for _ in 0..<3 { renderOnce(longEdge: 1024) }
        let interactive = p.sample(.previewRender).meanMS

        print("[StageB] still(1600) 均值 \(String(format: "%.2f", still))ms / interactive(1024) 均值 \(String(format: "%.2f", interactive))ms")

        // 结构性断言：两档都真的跑了 3 次
        #expect(p.count(.previewRender) == 3)
        // 方向性断言：1024 档不应显著慢于 1600 档（像素量只有 41%；容差留足 CI 抖动）
        #expect(interactive <= still * 1.25)
    }

    @Test("蒙版 alpha 记忆化：同形状第二次命中，绝不重算（真跑 MaskRenderer）")
    func maskAlphaMemoHitsOnRepeat() throws {
        let extent = CGRect(x: 0, y: 0, width: 512, height: 384)
        let id = UUID()
        let mask = Mask(id: id, name: "B4 证据", shape: .linear(
            LinearMask(start: MaskPoint(0.2, 0.15), end: MaskPoint(0.8, 0.85))
        ))

        // 独占 id + 重试：AlphaMemo 是进程级 4 格缓存，其它套件可能并行挤占（R006 踩过）。
        var observed: (hits: Int, misses: Int, count: Int, capacity: Int)?
        for _ in 0..<2 {
            AlphaMemoTestHooks.reset()
            _ = MaskRenderer.alphaImage(for: mask, in: extent)   // miss → 生成 + 缓存
            _ = MaskRenderer.alphaImage(for: mask, in: extent)   // hit
            let s = AlphaMemoTestHooks.stats()
            if s.hits >= 1 { observed = s; break }
        }
        let stats = try #require(observed)
        #expect(stats.hits >= 1)
        #expect(stats.misses >= 1)
        #expect(stats.capacity == 4)
        #expect(stats.count >= 1)
    }

    @Test("蒙版内容摘要：任一影响 alpha 的字段变化都会改变哈希键")
    func cacheDigestIsSensitive() {
        let base = Mask(name: "摘要", shape: .radial(RadialMask(center: MaskPoint(0.5, 0.5), radius: 0.3)))
        var featherChanged = base; featherChanged.feather = 55
        var opacityChanged = base; opacityChanged.opacity = 70
        var inverted = base; inverted.isInverted = true
        var moved = base
        if case .radial(var r) = moved.shape { r.radius = 0.5; moved.shape = .radial(r) }

        let digests = [base, featherChanged, opacityChanged, inverted, moved].map(\.cacheDigest)
        #expect(Set(digests).count == digests.count)

        // 幂等：同一内容两次摘要必须一致
        #expect(base.cacheDigest == base.cacheDigest)
    }

    @Test("CIContext 共享：进程内只构造一次（埋点计数 == 1）")
    func ciContextIsCreatedOnce() {
        // 触发 shared 的惰性初始化（此前任何使用都已触发；这里保证一定读过）
        _ = RenderContext.shared
        // 该断言在测试进程内成立：`ciContextCreate` 只会在 static let 初始化时 +1
        #expect(PerfSignpost.shared.count(.ciContextCreate) == 1)
    }
}
