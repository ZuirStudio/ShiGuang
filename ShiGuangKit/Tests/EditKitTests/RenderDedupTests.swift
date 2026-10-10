import Testing
import Foundation
@testable import EditKit

@Suite("RenderDeduper 预览渲染去重")
struct RenderDedupTests {

    private func key(_ ops: [EditOperation] = [], quality: String = "s",
                     sourceToken: Int = 0, maskToken: Int = 0,
                     overlay: UUID? = nil) -> RenderKey {
        RenderKey(graph: EditGraph(operations: ops), quality: quality,
                  sourceToken: sourceToken, maskToken: maskToken, overlayMaskID: overlay)
    }

    @Test("无记录时任何请求都放行")
    func firstRequestAlwaysRenders() {
        var d = RenderDeduper()
        #expect(d.shouldRender(key()))
        #expect(d.skippedCount == 0)
    }

    @Test("完全相同的键被去重（这就是 autoStill 重复渲染的修复）")
    func identicalKeyIsSkipped() {
        var d = RenderDeduper()
        let k = key([.exposure(0.5)])
        #expect(d.shouldRender(k))
        d.recordAccepted(k)
        #expect(d.shouldRender(k) == false)
        #expect(d.shouldRender(k) == false)
        #expect(d.skippedCount == 2)
        #expect(d.acceptedCount == 1)
        #expect(d.skipRatio == 2.0 / 3.0)
    }

    @Test("档位不同绝不去重（拖动中 1024 → 松手 1600 必须重渲）")
    func qualityIsPartOfKey() {
        var d = RenderDeduper()
        let interactive = key(quality: "i")
        let still = key(quality: "s")
        #expect(d.shouldRender(interactive))
        d.recordAccepted(interactive)
        #expect(d.shouldRender(still))
        d.recordAccepted(still)
        #expect(d.shouldRender(interactive))   // 再次降档也算新请求
    }

    @Test("图谱变化会重渲")
    func graphChangeRerenders() {
        var d = RenderDeduper()
        let a = key([.exposure(0.1)])
        let b = key([.exposure(0.2)])
        #expect(d.shouldRender(a)); d.recordAccepted(a)
        #expect(d.shouldRender(b))
    }

    @Test("源换代会重渲（换图 / 重新 load）")
    func sourceTokenChangeRerenders() {
        var d = RenderDeduper()
        let a = key(sourceToken: 0)
        let b = key(sourceToken: 1)
        #expect(d.shouldRender(a)); d.recordAccepted(a)
        #expect(d.shouldRender(b))
    }

    @Test("人像掩码就绪会重渲（掩码不能被去重吃掉）")
    func maskTokenChangeRerenders() {
        var d = RenderDeduper()
        let a = key(maskToken: 0)
        let b = key(maskToken: 1)
        #expect(d.shouldRender(a)); d.recordAccepted(a)
        #expect(d.shouldRender(b))
    }

    @Test("切换 / 开关选区叠加会重渲")
    func overlayChangeRerenders() {
        var d = RenderDeduper()
        let id = UUID()
        let a = key(overlay: id)
        let b = key(overlay: nil)
        #expect(d.shouldRender(a)); d.recordAccepted(a)
        #expect(d.shouldRender(b))
    }

    @Test("force 绕过去重")
    func forceBypassesDedup() {
        var d = RenderDeduper()
        let k = key([.contrast(3)])
        #expect(d.shouldRender(k)); d.recordAccepted(k)
        #expect(d.shouldRender(k) == false)
        #expect(d.shouldRender(k, force: true))
        #expect(d.skippedCount == 1)
    }

    @Test("invalidate 后同一键再次放行")
    func invalidateClearsRecord() {
        var d = RenderDeduper()
        let k = key([.vibrance(2)])
        #expect(d.shouldRender(k)); d.recordAccepted(k)
        #expect(d.shouldRender(k) == false)
        d.invalidate()
        #expect(d.shouldRender(k))
    }

    @Test("reset 清空统计")
    func resetClearsStats() {
        var d = RenderDeduper()
        let k = key([.blackPoint(-1)])
        #expect(d.shouldRender(k)); d.recordAccepted(k)
        _ = d.shouldRender(k)
        d.reset()
        #expect(d.skippedCount == 0)
        #expect(d.acceptedCount == 0)
        #expect(d.lastAccepted == nil)
    }

    @Test("模拟一轮真实拖动序列：每档每状态只渲一次")
    func simulatedDragSequence() {
        var d = RenderDeduper()
        var renders = 0
        // 拖动中不断变化 → 每次都接受
        for i in 1...10 {
            let k = key([.exposure(Double(i) / 10)], quality: "i")
            if d.shouldRender(k) { d.recordAccepted(k); renders += 1 }
        }
        // 松手 → 静止档一帧
        let still = key([.exposure(1.0)], quality: "s")
        if d.shouldRender(still) { d.recordAccepted(still); renders += 1 }
        // 900ms 兜底又调一次 endInteractiveEditing（同一状态）
        for _ in 0..<3 {
            let dup = key([.exposure(1.0)], quality: "s")
            if d.shouldRender(dup) { d.recordAccepted(dup); renders += 1 }
        }
        #expect(renders == 11)          // 10 拖动帧 + 1 静止帧
        #expect(d.skippedCount == 3)    // 三次兜底全部跳过
    }
}
