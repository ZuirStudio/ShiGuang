import Testing
import Foundation
@testable import FaceGeometry

// MARK: - 槽位映射一致性（Card 1 验收：Linux 单测）
//
// 「一致性」的三层含义（全部在此锁定）：
// 1. **语义槽位一致**：同一语义位置（如左眼外角）在两侧 Provider 产出中
//    落在同一槽位号 —— 锚点槽位逐字断言。
// 2. **拓扑表一致**：区域槽位表与 MediaPipe 官方连接表一致（数量、
//    不相交、范围）—— 防手抄漂移。
// 3. **映射确定**：同输入必同输出（无随机、无字典序依赖）。

@Suite("区域槽位拓扑表")
struct FaceMeshRegionTableTests {

    @Test("槽位总数 = 152，全部落在 0..<468")
    func totalSlots() {
        var all: [Int] = []
        for region in FaceMeshRegion.allCases { all.append(contentsOf: region.slots) }
        #expect(all.count == 152)
        for slot in all {
            #expect(slot >= 0 && slot < FaceGeometry.slotCount)
        }
    }

    @Test("区域槽位两两不相交（无后写覆盖歧义）")
    func regionsDisjoint() {
        var seen = Set<Int>()
        for region in FaceMeshRegion.allCases {
            for slot in region.slots {
                #expect(!seen.contains(slot), "槽位 \(slot) 在 \(region.rawValue) 与更早区域重复")
                seen.insert(slot)
            }
        }
    }

    @Test("各区域槽位数与 MediaPipe 连接表一致")
    func regionSizes() {
        #expect(FaceMeshRegion.rightEye.slots.count == 16)
        #expect(FaceMeshRegion.leftEye.slots.count == 16)
        #expect(FaceMeshRegion.rightEyebrow.slots.count == 10)   // 两段 5+5
        #expect(FaceMeshRegion.leftEyebrow.slots.count == 10)
        #expect(FaceMeshRegion.faceOval.slots.count == 36)
        #expect(FaceMeshRegion.lips.slots.count == 20)
        #expect(FaceMeshRegion.innerLips.slots.count == 20)
        #expect(FaceMeshRegion.nose.slots.count == 10)
        #expect(FaceMeshRegion.noseCrest.slots.count == 14)
    }

    @Test("关键语义锚点槽位（与 MediaPipe 官方表逐字对齐）")
    func anchorSlots() {
        #expect(FaceMeshRegion.rightEye.slots.first == 33)     // 右眼外角
        #expect(FaceMeshRegion.leftEye.slots.first == 263)     // 左眼外角
        #expect(FaceMeshRegion.faceOval.slots.first == 10)     // 额顶中
        #expect(FaceMeshRegion.lips.slots.first == 61)         // 右嘴角
        #expect(FaceMeshRegion.lips.slots.contains(291))       // 左嘴角
        #expect(FaceMeshRegion.nose.slots.first == 168)        // 鼻梁顶
        #expect(FaceMeshRegion.nose.slots.last == 2)           // 鼻尖
        #expect(FaceMeshRegion.faceOval.slots.contains(152))   // 下巴
    }
}

@Suite("区域折线 → 468 槽位")
struct LandmarkSlotAssignTests {

    /// 构造一个区域的规则折线（左上原点归一化坐标）。
    private func ring(_ n: Int, cx: Float = 0.5, cy: Float = 0.5, r: Float = 0.1) -> [Landmark3D] {
        (0..<n).map { i in
            let a = Float(i) / Float(n) * 2 * .pi
            return Landmark3D(x: cx + r * cosf(a), y: cy + r * sinf(a), z: 0)
        }
    }

    @Test("全区域输入 → 恰好 152 个实测槽位，其余为零")
    func fullAssign() {
        var regions: LandmarkSlotMap.RegionInput = [:]
        for region in FaceMeshRegion.allCases {
            regions[region] = ring(region.slots.count)
        }
        let slots = LandmarkSlotMap.assign(regions)
        #expect(slots.count == FaceGeometry.slotCount)
        let measured = slots.filter(\.isMeasured).count
        #expect(measured == 152)
        // 内部密集网格槽位（如脸颊 205）保持零值 —— 兜底能力边界
        #expect(!slots[205].isMeasured)
    }

    @Test("点数与槽位数相同 → 恒等直通（逐点相等）")
    func identityPassthrough() {
        let eye = ring(FaceMeshRegion.leftEye.slots.count, cx: 0.7, r: 0.03)
        let slots = LandmarkSlotMap.assign([.leftEye: eye])
        for (i, slotIndex) in FaceMeshRegion.leftEye.slots.enumerated() {
            #expect(slots[slotIndex] == eye[i])
            #expect(slots[slotIndex].isMeasured)
        }
    }

    @Test("语义槽位一致：左眼折线首点 → 槽位 263（左眼外角）")
    func semanticSlotConsistency() {
        let first = Landmark3D(x: 0.72, y: 0.4)
        let slots = LandmarkSlotMap.assign([.leftEye: [first, Landmark3D(x: 0.75, y: 0.4)]])
        #expect(slots[263].x == 0.72)
        #expect(slots[263].y == 0.4)
        #expect(slots[362].isMeasured)  // 左眼内角（折线末点）
    }

    @Test("确定性：同一输入两次映射结果逐点相等")
    func determinism() {
        let oval = ring(12)
        let a = LandmarkSlotMap.assign([.faceOval: oval])
        let b = LandmarkSlotMap.assign([.faceOval: oval])
        #expect(a == b)
    }

    @Test("缺区域 → 对应槽位零值，不崩溃")
    func missingRegions() {
        let slots = LandmarkSlotMap.assign([.nose: [Landmark3D(x: 0.5, y: 0.5)]])
        #expect(slots[168].isMeasured)             // 鼻梁顶
        #expect(!slots[33].isMeasured)             // 右眼未提供
        #expect(!slots[10].isMeasured)             // 轮廓未提供
        let empty = LandmarkSlotMap.assign([:])
        #expect(empty.allSatisfy { !$0.isMeasured })
    }

    @Test("单点折线 → 该区域所有槽位坍缩到该点")
    func degenerateSinglePoint() {
        let p = Landmark3D(x: 0.3, y: 0.6)
        let slots = LandmarkSlotMap.assign([.rightEye: [p]])
        for slot in FaceMeshRegion.rightEye.slots {
            #expect(slots[slot] == Landmark3D(x: 0.3, y: 0.6, z: 0, confidence: 1))
        }
    }
}

@Suite("弧长重采样")
struct ResampleTests {

    @Test("闭合环：单位正方形 count=4 → 精确复原四角")
    func squareClosedExact() {
        let square = [
            Landmark3D(x: 0, y: 0), Landmark3D(x: 1, y: 0),
            Landmark3D(x: 1, y: 1), Landmark3D(x: 0, y: 1)
        ]
        let out = LandmarkSlotMap.resampleClosed(square, count: 4)
        #expect(out.count == 4)
        #expect(out[0].x == 0 && out[0].y == 0)
        #expect(out[1].x == 1 && out[1].y == 0)
        #expect(out[2].x == 1 && out[2].y == 1)
        #expect(out[3].x == 0 && out[3].y == 1)
    }

    @Test("闭合环：单位正方形 count=8 → 角点 + 边中点")
    func squareClosedMidpoints() {
        let square = [
            Landmark3D(x: 0, y: 0), Landmark3D(x: 1, y: 0),
            Landmark3D(x: 1, y: 1), Landmark3D(x: 0, y: 1)
        ]
        let out = LandmarkSlotMap.resampleClosed(square, count: 8)
        #expect(abs(out[1].x - 0.5) < 1e-5 && abs(out[1].y) < 1e-5)   // 底边中点
        #expect(abs(out[3].x - 1) < 1e-5 && abs(out[3].y - 0.5) < 1e-5) // 右边中点
    }

    @Test("开放折线：两点线段 count=5 → 等距五点")
    func lineOpenEven() {
        let line = [Landmark3D(x: 0, y: 0), Landmark3D(x: 1, y: 0)]
        let out = LandmarkSlotMap.resampleOpen(line, count: 5)
        #expect(out.count == 5)
        for (i, p) in out.enumerated() {
            #expect(abs(p.x - Float(i) / 4) < 1e-5)
            #expect(abs(p.y) < 1e-5)
        }
    }

    @Test("闭合环：点数多于槽位仍保持单调环绕")
    func closedOversampled() {
        let dodecagon = (0..<12).map { i -> Landmark3D in
            let a = Float(i) / 12 * 2 * .pi
            return Landmark3D(x: cosf(a), y: sinf(a))
        }
        let out = LandmarkSlotMap.resampleClosed(dodecagon, count: 6)
        #expect(out.count == 6)
        // 12 边形隔点采样 → 每隔 60° 的正六边形顶点。
        // 注意 distance2D 是**弦长**不是弧长：单位圆上 60° 弧对应的弦
        // = 2·sin(π/6) = 1.0（早期误写为弧长 2π/6 ≈ 1.0472，弦 ≠ 弧）。
        let expectedChord: Float = 2 * sin(Float.pi / 6)
        for i in 0..<6 {
            let d = out[i].distance2D(to: out[(i + 1) % 6])
            #expect(abs(d - expectedChord) < 1e-4)
        }
        // 单调环绕：相邻输出点极角步进恒为 +60°（防跳变 / 反向 / 重复点；
        // 弦长相等不足以保证方向——300° 步进的弦长也是 1.0）
        var previous = atan2(Double(out[0].y), Double(out[0].x))
        for i in 1..<6 {
            let angle = atan2(Double(out[i].y), Double(out[i].x))
            var step = angle - previous
            while step <= -.pi { step += 2 * .pi }
            while step > .pi { step -= 2 * .pi }
            #expect(abs(step - .pi / 3) < 1e-4)
            previous = angle
        }
    }

    @Test("count=1 → 首点")
    func singleOutput() {
        let line = [Landmark3D(x: 0.2, y: 0.3), Landmark3D(x: 0.9, y: 0.8)]
        #expect(LandmarkSlotMap.resampleOpen(line, count: 1) == [Landmark3D(x: 0.2, y: 0.3)])
    }
}

@Suite("Vision 坐标转换")
struct VisionCoordinateTests {

    @Test("框内归一化（左下原点）→ 图像归一化（左上原点）")
    func boxTransform() {
        let box = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5)
        // 框左下角 → 图像 (0.2, 0.7)
        let bl = LandmarkSlotMap.visionToImageNormalized(CGPoint(x: 0, y: 0), inFaceBox: box)
        #expect(abs(bl.x - 0.2) < 1e-6)
        #expect(abs(bl.y - 0.7) < 1e-6)
        // 框右上角 → 图像 (0.6, 0.2)
        let tr = LandmarkSlotMap.visionToImageNormalized(CGPoint(x: 1, y: 1), inFaceBox: box)
        #expect(abs(tr.x - 0.6) < 1e-6)
        #expect(abs(tr.y - 0.2) < 1e-6)
        // 框中心 → 图像 (0.4, 0.45)
        let c = LandmarkSlotMap.visionToImageNormalized(CGPoint(x: 0.5, y: 0.5), inFaceBox: box)
        #expect(abs(c.x - 0.4) < 1e-6)
        #expect(abs(c.y - 0.45) < 1e-6)
    }

    @Test("越界点被钳制到框内")
    func clamped() {
        let box = CGRect(x: 0, y: 0, width: 1, height: 1)
        let p = LandmarkSlotMap.visionToImageNormalized(CGPoint(x: 1.5, y: -0.5), inFaceBox: box)
        #expect(p.x == 1)
        #expect(p.y == 1)
    }

    @Test("全屏人脸框 → 恒等（仅 y 翻转）")
    func fullFrameBox() {
        let box = CGRect(x: 0, y: 0, width: 1, height: 1)
        let p = LandmarkSlotMap.visionToImageNormalized(CGPoint(x: 0.3, y: 0.8), inFaceBox: box)
        #expect(abs(p.x - 0.3) < 1e-6)
        #expect(abs(p.y - 0.2) < 1e-6)
    }
}

@Suite("包围盒")
struct BoundingBoxTests {

    @Test("实测槽位包围盒（左上原点）")
    func measuredBox() {
        let slots = [
            Landmark3D(x: 0.2, y: 0.3),
            Landmark3D(x: 0.6, y: 0.5),
            Landmark3D.zero
        ]
        let box = LandmarkSlotMap.boundingBox(of: slots)
        #expect(abs(box.minX - 0.2) < 1e-6)
        #expect(abs(box.minY - 0.3) < 1e-6)
        #expect(abs(box.width - 0.4) < 1e-6)
        #expect(abs(box.height - 0.2) < 1e-6)
    }

    @Test("全零 → .zero")
    func allZero() {
        #expect(LandmarkSlotMap.boundingBox(of: [.zero, .zero]) == .zero)
    }
}
