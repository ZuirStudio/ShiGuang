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
@Suite("蒙版 alpha 记忆化（R006 性能专项）")
struct AlphaMemoTests {
    private let extent = CGRect(x: 0, y: 0, width: 400, height: 300)
    private let maskID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!

    /// 固定 id 的线性蒙版：`offset` 改变形状
    private func linearMask(offset: Double = 0) -> Mask {
        Mask(
            id: maskID,
            name: "记忆化测试",
            shape: .linear(
                LinearMask(
                    start: MaskPoint(0.2 + offset, 0.1),
                    end: MaskPoint(0.7 + offset, 0.6)
                )
            )
        )
    }

    @Test("形状与 extent 不变时命中缓存（返回同一实例）")
    func memoHitReturnsSameInstance() throws {
        AlphaMemoTestHooks.reset()
        let mask = linearMask()
        let first = try #require(MaskRenderer.alphaImage(for: mask, in: extent))
        let second = try #require(MaskRenderer.alphaImage(for: mask, in: extent))
        #expect(ObjectIdentifier(first) == ObjectIdentifier(second))
    }

    @Test("形状变化后失效，重新生成")
    func memoMissAfterShapeChange() throws {
        AlphaMemoTestHooks.reset()
        let a = try #require(MaskRenderer.alphaImage(for: linearMask(offset: 0), in: extent))
        let b = try #require(MaskRenderer.alphaImage(for: linearMask(offset: 0.12), in: extent))
        #expect(ObjectIdentifier(a) != ObjectIdentifier(b))
    }

    @Test("extent 变化后失效，重新生成")
    func memoMissAfterExtentChange() throws {
        AlphaMemoTestHooks.reset()
        let mask = linearMask()
        let a = try #require(MaskRenderer.alphaImage(for: mask, in: extent))
        let wider = CGRect(x: 0, y: 0, width: 401, height: 300)
        let b = try #require(MaskRenderer.alphaImage(for: mask, in: wider))
        #expect(ObjectIdentifier(a) != ObjectIdentifier(b))
    }

    @Test("同一蒙版的新形状会淘汰旧形状（容量不被单条蒙版占满）")
    func memoEvictsOlderVersionsOfSameMask() throws {
        AlphaMemoTestHooks.reset()
        var lastImage: ObjectIdentifier?
        for i in 0..<5 {
            let image = try #require(MaskRenderer.alphaImage(for: linearMask(offset: Double(i) * 0.02),
                                                             in: extent))
            lastImage = ObjectIdentifier(image)
        }
        // 回到第 1 个形状：它的条目已被同 id 的新形状淘汰 → 必须重新生成
        let back = try #require(MaskRenderer.alphaImage(for: linearMask(offset: 0), in: extent))
        #expect(ObjectIdentifier(back) != lastImage)
        // 且重新生成后应被缓存下来（第二次请求拿到同一实例）
        let again = try #require(MaskRenderer.alphaImage(for: linearMask(offset: 0), in: extent))
        #expect(ObjectIdentifier(back) == ObjectIdentifier(again))
    }
}
