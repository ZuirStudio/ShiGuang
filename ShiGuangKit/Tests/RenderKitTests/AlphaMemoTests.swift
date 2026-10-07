import Testing
import Foundation
import CoreImage
import CoreGraphics
@testable import EditKit
@testable import RenderKit

/// R006 追加 A（性能）验证：`MaskRenderer.alphaImage` 的记忆化行为。
///
/// 只验证**可观测契约**，不碰私有实现：
/// 1. 形状 / extent 不变 → 返回同一实例（命中，不重算）
/// 2. 形状变化 → 返回新实例（失效，必须重算）
/// 3. extent 变化 → 返回新实例
/// 4. 同一蒙版的新形状会淘汰旧形状（不会把 4 格容量全占满）
///
/// ## 为什么这里要这么小心（踩过的坑）
/// `AlphaMemo.shared` 是**进程级**单例、容量只有 4 格，而 Swift Testing 默认**并行**跑测试，
/// 其它套件（MaskRenderTests 等）的渲染会往同一个缓存里塞条目，可能把我刚存进去的那格挤掉。
/// 第一版测试用同一套「同一个 maskID」跑 4 个用例 → 用例之间互相淘汰，
/// 于是「相邻两次调用返回同一实例」偶发失败（CI run 37615632010）。
/// 现在：① 每个用例**独占一个 maskID**；② 套件标 `.serialized` 自身不交错；
/// ③ 命中类断言允许重试一次 —— 真回归（记忆化彻底失效）两次都会落空而失败，
///    偶发被其它套件挤出则不会误报。
@Suite("蒙版 alpha 记忆化（R006 性能专项）", .serialized)
struct AlphaMemoTests {
    private let extent = CGRect(x: 0, y: 0, width: 400, height: 300)

    /// 每个用例独立的蒙版 id（共享 id 会互相淘汰）。
    private func uniqueID() -> UUID { UUID() }

    /// 固定 id 的线性蒙版：`offset` 改变形状
    private func linearMask(id: UUID, offset: Double = 0) -> Mask {
        Mask(
            id: id,
            name: "记忆化测试",
            shape: .linear(
                LinearMask(
                    start: MaskPoint(0.2 + offset, 0.1),
                    end: MaskPoint(0.7 + offset, 0.6)
                )
            )
        )
    }

    /// 「命中」断言：重置缓存后连取两次，实例相同即算命中；失败允许整体重来一次。
    @discardableResult
    private func hitsWithinRetries(_ attempts: Int = 2, _ make: () -> CIImage?) -> Bool {
        for _ in 0..<attempts {
            AlphaMemoTestHooks.reset()
            guard let first = make(), let second = make() else { return false }
            if ObjectIdentifier(first) == ObjectIdentifier(second) { return true }
        }
        return false
    }

    @Test("形状与 extent 不变时命中缓存（返回同一实例）")
    func memoHitReturnsSameInstance() {
        let id = uniqueID()
        #expect(hitsWithinRetries { MaskRenderer.alphaImage(for: linearMask(id: id), in: extent) })
    }

    @Test("形状变化后失效，重新生成")
    func memoMissAfterShapeChange() throws {
        let id = uniqueID()
        let a = try #require(MaskRenderer.alphaImage(for: linearMask(id: id, offset: 0), in: extent))
        let b = try #require(MaskRenderer.alphaImage(for: linearMask(id: id, offset: 0.12), in: extent))
        #expect(ObjectIdentifier(a) != ObjectIdentifier(b))
    }

    @Test("extent 变化后失效，重新生成")
    func memoMissAfterExtentChange() throws {
        let id = uniqueID()
        let mask = linearMask(id: id)
        let a = try #require(MaskRenderer.alphaImage(for: mask, in: extent))
        let wider = CGRect(x: 0, y: 0, width: 401, height: 300)
        let b = try #require(MaskRenderer.alphaImage(for: mask, in: wider))
        #expect(ObjectIdentifier(a) != ObjectIdentifier(b))
    }

    @Test("同一蒙版的新形状会淘汰旧形状（容量不被单条蒙版占满）")
    func memoEvictsOlderVersionsOfSameMask() throws {
        let id = uniqueID()
        // 连续 5 个形状：同 id 只保留最新一格
        var last: CIImage?
        for i in 0..<5 {
            last = try #require(
                MaskRenderer.alphaImage(for: linearMask(id: id, offset: Double(i) * 0.02), in: extent)
            )
        }
        // 回到最初的形状：它的条目已被同 id 的新形状淘汰 → 必须是新实例
        let lastImage = try #require(last)
        let back = try #require(MaskRenderer.alphaImage(for: linearMask(id: id), in: extent))
        #expect(ObjectIdentifier(back) != ObjectIdentifier(lastImage))
        // 且重新生成后应被缓存下来（命中）
        #expect(hitsWithinRetries { MaskRenderer.alphaImage(for: linearMask(id: id), in: extent) })
    }
}
