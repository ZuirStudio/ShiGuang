import Foundation

// MARK: - 区域折线 → 468 槽位映射（v1.5.0 Card 1）
//
// 纯算法、跨平台（Linux 可测）。使用方：
// - Vision 兜底 Provider（AICore）：VNFaceLandmarkRegion2D 各区域折线
//   经坐标转换后喂入 `assign`，产出 468 槽位。
// - MediaPipe 主路径不经过本映射（直出 468 点）—— 本表只服务兜底。
//
// 映射规则（确定性，无随机、无阈值）：
// 1. 每个语义区域有自己的 MediaPipe 槽位序列（FaceMeshTopology）。
// 2. 输入折线按**弧长**重采样到槽位序列长度（闭合环含闭合边），
//    槽位 0 = 折线起点；点数与槽位数相同时恒等直通。
// 3. 实测槽位 confidence = 1；未提供区域的槽位保持零值（confidence 0）。
// 4. 全部区域槽位两两不相交（单测锁定），不存在后写覆盖歧义。
//
// 诚实声明（兜底的能力边界）：
// - 只填 152 个外壳槽位（眼/眉/轮廓/唇/鼻），内部密集网格槽位为零。
//   消费者按 `FaceGeometry.slotCoverage` 判断（≈0.32）。
// - 眉弓方向语义（MediaPipe 两段连接序 vs Vision 整条折线）不保证严格
//   对应 —— 兜底只用于圈定面部区域（Card 2 液化护栏），不用于渲染。

public enum LandmarkSlotMap {

    /// 语义区域 → 折线（图像归一化、左上原点；z 忽略）。
    public typealias RegionInput = [FaceMeshRegion: [Landmark3D]]

    /// 把各区域折线映射为 468 槽位。
    public static func assign(_ regions: RegionInput) -> [Landmark3D] {
        var slots = Array(repeating: Landmark3D.zero, count: FaceGeometry.slotCount)
        for region in FaceMeshRegion.allCases {
            guard let polyline = regions[region], !polyline.isEmpty else { continue }
            let target = region.slots
            let resampled = region.isClosed
                ? resampleClosed(polyline, count: target.count)
                : resampleOpen(polyline, count: target.count)
            for (slotIndex, point) in zip(target, resampled) {
                slots[slotIndex] = Landmark3D(
                    x: point.x, y: point.y, z: point.z, confidence: 1
                )
            }
        }
        return slots
    }

    // MARK: - 弧长重采样

    /// 开放折线重采样到 count 个点（首末端点保留；count == 1 时取首点）。
    public static func resampleOpen(_ points: [Landmark3D], count: Int) -> [Landmark3D] {
        guard count > 0 else { return [] }
        guard let first = points.first else {
            return Array(repeating: .zero, count: count)
        }
        guard points.count > 1 else {
            return Array(repeating: first, count: count)
        }
        // 恒等直通契约（文件头注释第 2 条）：点数与目标点数相同时逐点返回。
        // 必须显式短路 —— 弧长参数化 target_i = total·i/(count-1) 在
        // count ≠ 顶点弧长位置数时不会落回原顶点（lerp 引入 ulp 级漂移），
        // "逐点相等"的调用方（如 Provider 直通）依赖此路径的精确性。
        if points.count == count { return points }
        var lengths: [Float] = []
        var total: Float = 0
        for i in 0..<(points.count - 1) {
            let d = points[i].distance2D(to: points[i + 1])
            lengths.append(d)
            total += d
        }
        guard total > 0 else {
            return Array(repeating: first, count: count)
        }
        let steps = max(count - 1, 1)
        var out: [Landmark3D] = []
        out.reserveCapacity(count)
        var seg = 0
        var acc: Float = 0
        for i in 0..<count {
            let target = total * Float(i) / Float(steps)
            while seg < lengths.count - 1 && acc + lengths[seg] < target {
                acc += lengths[seg]
                seg += 1
            }
            let len = lengths[seg]
            let t = len > 0 ? min(max((target - acc) / len, 0), 1) : 0
            out.append(lerp(points[seg], points[seg + 1], t))
        }
        return out
    }

    /// 闭合环重采样到 count 个点（含末→首闭合边；槽位 0 = 折线首点）。
    public static func resampleClosed(_ points: [Landmark3D], count: Int) -> [Landmark3D] {
        guard count > 0 else { return [] }
        guard let first = points.first else {
            return Array(repeating: .zero, count: count)
        }
        guard points.count > 1 else {
            return Array(repeating: first, count: count)
        }
        // 恒等直通契约（同 resampleOpen）：点数与目标点数相同时逐点返回，
        // 避免闭合环弧长参数化在 Float 下的 ulp 漂移。
        if points.count == count { return points }
        var lengths: [Float] = []
        var total: Float = 0
        for i in 0..<points.count {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            let d = a.distance2D(to: b)
            lengths.append(d)
            total += d
        }
        guard total > 0 else {
            return Array(repeating: first, count: count)
        }
        var out: [Landmark3D] = []
        out.reserveCapacity(count)
        var seg = 0
        var acc: Float = 0
        for i in 0..<count {
            let target = total * Float(i) / Float(count)
            while seg < lengths.count - 1 && acc + lengths[seg] < target {
                acc += lengths[seg]
                seg += 1
            }
            let len = lengths[seg]
            let t = len > 0 ? min(max((target - acc) / len, 0), 1) : 0
            out.append(lerp(points[seg], points[(seg + 1) % points.count], t))
        }
        return out
    }

    private static func lerp(_ a: Landmark3D, _ b: Landmark3D, _ t: Float) -> Landmark3D {
        Landmark3D(
            x: a.x + (b.x - a.x) * t,
            y: a.y + (b.y - a.y) * t,
            z: a.z + (b.z - a.z) * t,
            confidence: 1
        )
    }

    // MARK: - Vision 坐标转换

    /// Vision 人脸地标 → 图像归一化坐标（左上原点）。
    ///
    /// Vision 契约（Apple 文档）：`normalizedPoints` 归一化到
    /// `VNFaceObservation.boundingBox` 内部、**原点在框左下**；
    /// `boundingBox` 本身是图像归一化矩形（原点同样左下）。
    /// 本工程统一左上原点（与 CIImage 像素方向、MediaPipe 一致）。
    public static func visionToImageNormalized(
        _ point: CGPoint, inFaceBox box: CGRect
    ) -> CGPoint {
        let xInBox = min(max(point.x, 0), 1)
        let yInBox = min(max(point.y, 0), 1)
        let imageX = box.minX + xInBox * box.width
        let imageYBottomOrigin = box.minY + yInBox * box.height
        return CGPoint(x: imageX, y: 1 - imageYBottomOrigin)
    }

    // MARK: - 辅助

    /// 实测槽位的包围盒（图像归一化、左上原点）。
    public static func boundingBox(of slots: [Landmark3D]) -> CGRect {
        var minX = Float.greatestFiniteMagnitude, minY = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        var found = false
        for p in slots where p.isMeasured {
            found = true
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        guard found else { return .zero }
        return CGRect(
            x: CGFloat(minX), y: CGFloat(minY),
            width: CGFloat(maxX - minX), height: CGFloat(maxY - minY)
        )
    }
}
