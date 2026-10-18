import Testing
import Foundation
@testable import EditKit

/// R010-C 安全审查修复：CropRect 钳制。
///
/// 背景：`EditOperation.clamped` 此前只钳数值参数，裁剪矩形作为结构化指令
/// 原样透传 —— 越界 / 零尺寸 / 负尺寸矩形直达 `CICrop` 会产出空 extent，
/// 令预览静默停更。本组用例锚定 `normalized()` 的全部规则。
@Suite struct CropRectClampTests {
    @Test func inBoundsRectIsUnchanged() {
        let r = CropRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25).normalized()
        #expect(r == CropRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25))
    }

    @Test func negativeOriginIsClamped() {
        let r = CropRect(x: -0.5, y: -0.5, width: 0.5, height: 0.5).normalized()
        #expect(r.x == 0 && r.y == 0)
        #expect(r.width == 0.5 && r.height == 0.5)
    }

    @Test func oversizedEdgesArePulledInsideUnitBox() {
        // 右 / 下边缘越界 → 原点被拉回，尺寸不变（不缩小用户框，只平移）
        let r = CropRect(x: 0.75, y: 0.75, width: 0.5, height: 0.5).normalized()
        #expect(r == CropRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
    }

    @Test func zeroAndNegativeSizeFloorsToMinimum() {
        let r = CropRect(x: 0.1, y: 0.1, width: 0, height: -2).normalized()
        #expect(r.x == 0.1 && r.y == 0.1)
        #expect(abs(r.width - 0.01) < 1e-12 && abs(r.height - 0.01) < 1e-12)
    }

    @Test func oversizedSizeIsClampedToOne() {
        let r = CropRect(x: 0, y: 0, width: 4, height: 9).normalized()
        #expect(r == CropRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func nanInputFallsBackToOriginAndMinimumSize() {
        // Swift 的 min(max(v, 0), 1) 链对 NaN 返回另一操作数 → 下界
        let r = CropRect(x: .nan, y: .nan, width: .nan, height: .nan).normalized()
        #expect(r.x == 0 && r.y == 0)
        #expect(abs(r.width - 0.01) < 1e-12 && abs(r.height - 0.01) < 1e-12)
    }

    @Test func clampedOperationNormalizesCrop() {
        // 图谱入口（append / updateInteractive）必经 .clamped → 非法矩形进不了管线
        let op = EditOperation.crop(CropRect(x: 2, y: 2, width: 5, height: 5)).clamped
        #expect(op == .crop(CropRect(x: 0, y: 0, width: 1, height: 1)))
    }

    @Test func clampedOperationKeepsNumericParameters() {
        // 回归：crop 分支不得影响数值参数钳制语义
        #expect(EditOperation.exposure(8).clamped == .exposure(5))
        #expect(EditOperation.straighten(-90).clamped == .straighten(-45))
        // 结构化非 crop 指令原样透传
        let ref = LUTReference(name: "x")
        #expect(EditOperation.lut(ref).clamped == .lut(ref))
    }
}
