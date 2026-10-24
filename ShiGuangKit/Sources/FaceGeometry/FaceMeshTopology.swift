import Foundation

// MARK: - Face Mesh 拓扑（v1.5.0 Card 1）
//
// 数据来源（权威、可复现）：MediaPipe 官方
// `mediapipe/python/solutions/face_mesh_connections.py`（master，2026-10-24 取）：
// - FACEMESH_RIGHT_EYE / LEFT_EYE / RIGHT_EYEBROW / LEFT_EYEBROW /
//   FACE_OVAL / LIPS / NOSE 的**连接表逐字转写**为下列槽位序列。
// - 命名约定与 MediaPipe 一致：right = **对象解剖学右**（非镜像照片中
//   位于画面左半）；Vision 的 leftEye/rightEye 同为解剖学命名，可直接对应。
// - LIPS（40 条连接）拆为外唇 / 内唇两个闭合环；眉弓每侧两段连接序拼接；
//   NOSE 取鼻梁-鼻尖开放路径 [168..2]，鼻坎（nostril 环）单列 noseCrest。
//
// 槽位序列的用途：Vision 兜底 Provider 把各区域折线按弧长重采样到
// 对应槽位（见 LandmarkSlotMap）；MediaPipe 主路径直出 468 点，不经过本表。

/// 人脸网格语义区域（槽位序列 = MediaPipe 规范连接序）。
public enum FaceMeshRegion: String, Sendable, CaseIterable, Equatable {
    /// 解剖学右眼（画面左半）。
    case rightEye
    /// 解剖学左眼（画面右半）。
    case leftEye
    /// 解剖学右眉（两段连接序拼接）。
    case rightEyebrow
    /// 解剖学左眉（两段连接序拼接）。
    case leftEyebrow
    /// 脸部外轮廓（闭合环）。
    case faceOval
    /// 外唇（闭合环）。
    case lips
    /// 内唇（闭合环）。
    case innerLips
    /// 鼻梁-鼻尖（开放路径）。
    case nose
    /// 鼻坎 / 鼻孔底（开放路径，双侧鼻翼经鼻底相连）。
    case noseCrest

    /// 该区域的槽位序列（顺序即连接序；闭合区域的末点与首点相邻）。
    public var slots: [Int] {
        switch self {
        case .rightEye:
            return [33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246]
        case .leftEye:
            return [263, 249, 390, 373, 374, 380, 381, 382, 362, 398, 384, 385, 386, 387, 388, 466]
        case .rightEyebrow:
            // (46,53),(53,52),(52,65),(65,55) + (70,63),(63,105),(105,66),(66,107)
            return [46, 53, 52, 65, 55, 70, 63, 105, 66, 107]
        case .leftEyebrow:
            // (276,283),(283,282),(282,295),(295,285) + (300,293),(293,334),(334,296),(296,336)
            return [276, 283, 282, 295, 285, 300, 293, 334, 296, 336]
        case .faceOval:
            return [10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288, 397, 365,
                    379, 378, 400, 377, 152, 148, 176, 149, 150, 136, 172, 58, 132, 93,
                    234, 127, 162, 21, 54, 103, 67, 109]
        case .lips:
            return [61, 146, 91, 181, 84, 17, 314, 405, 321, 375, 291, 409, 270, 269,
                    267, 0, 37, 39, 40, 185]
        case .innerLips:
            return [78, 95, 88, 178, 87, 14, 317, 402, 318, 324, 308, 415, 310, 311,
                    312, 13, 82, 81, 80, 191]
        case .nose:
            return [168, 6, 197, 195, 5, 4, 1, 19, 94, 2]
        case .noseCrest:
            // 鼻孔底环去掉与鼻梁共享的 2（鼻尖）与 4（鼻底）：鼻翼→鼻底→鼻翼
            return [326, 327, 294, 278, 344, 440, 275, 45, 220, 115, 48, 64, 98, 97]
        }
    }

    /// 是否为闭合环（弧长重采样时末点与首点相连）。
    public var isClosed: Bool {
        switch self {
        case .rightEye, .leftEye, .faceOval, .lips, .innerLips: return true
        case .rightEyebrow, .leftEyebrow, .nose, .noseCrest: return false
        }
    }

    public var displayName: String {
        switch self {
        case .rightEye: return "右眼"
        case .leftEye: return "左眼"
        case .rightEyebrow: return "右眉"
        case .leftEyebrow: return "左眉"
        case .faceOval: return "脸部轮廓"
        case .lips: return "外唇"
        case .innerLips: return "内唇"
        case .nose: return "鼻梁"
        case .noseCrest: return "鼻坎"
        }
    }
}

// MARK: - 规范锚点（位姿解算的模型侧）

/// 位姿解算用的规范 3D 锚点（头部坐标系：X 右、Y 上、Z 前，单位米，
/// 取成年人脸近似测量值 —— Procrustes 只解旋转，尺度不影响角度）。
public struct CanonicalAnchor: Sendable, Equatable {
    /// MediaPipe 槽位号。
    public let slot: Int
    public let x: Float
    public let y: Float
    public let z: Float

    public init(slot: Int, x: Float, y: Float, z: Float) {
        self.slot = slot
        self.x = x
        self.y = y
        self.z = z
    }
}

extension FaceMeshTopology {
    /// 位姿锚点表（9 点，非共面，满足 Horn 绝对定向的最小稳定集）。
    public static let poseAnchors: [CanonicalAnchor] = [
        CanonicalAnchor(slot: 33, x: 0.052, y: 0.018, z: 0.028),   // 右眼外角
        CanonicalAnchor(slot: 133, x: 0.021, y: 0.018, z: 0.026),  // 右眼内角
        CanonicalAnchor(slot: 362, x: -0.021, y: 0.018, z: 0.026), // 左眼内角
        CanonicalAnchor(slot: 398, x: -0.052, y: 0.018, z: 0.028), // 左眼外角
        CanonicalAnchor(slot: 1, x: 0.0, y: -0.012, z: 0.062),     // 鼻尖
        CanonicalAnchor(slot: 61, x: 0.026, y: -0.048, z: 0.040),  // 右嘴角
        CanonicalAnchor(slot: 291, x: -0.026, y: -0.048, z: 0.040),// 左嘴角
        CanonicalAnchor(slot: 152, x: 0.0, y: -0.098, z: 0.030),   // 下巴
        CanonicalAnchor(slot: 10, x: 0.0, y: 0.085, z: 0.045)      // 额顶中
    ]
}

// MARK: - 三角剖分（Bowyer-Watson 增量 Delaunay）

/// 三角剖分三角形（landmark 索引三元组）。
public struct MeshTriangle: Sendable, Equatable {
    public var a: Int
    public var b: Int
    public var c: Int

    public init(a: Int, b: Int, c: Int) {
        self.a = a
        self.b = b
        self.c = c
    }
}

public enum FaceMeshTopology {

    /// 对给定点集做增量 Delaunay 三角剖分（Bowyer-Watson）。
    ///
    /// - 输入点用 (x, y)（z 忽略）；`confidence == 0` 的零槽位与重复点
    ///   （间距 < 1e-7）会被剔除 —— 兜底 Provider 的未实测槽位不参与剖分。
    /// - 结果确定性强（同一输入 → 同一输出），供网格叠加渲染与 Card 2
    ///   液化护栏的三角查询使用。
    public static func triangulate(_ points: [Landmark3D]) -> [MeshTriangle] {
        // 1) 过滤未实测与重复点（保留首个）
        var unique: [(index: Int, x: Double, y: Double)] = []
        for (i, p) in points.enumerated() where p.isMeasured {
            if unique.contains(where: { abs($0.x - Double(p.x)) < 1e-7 && abs($0.y - Double(p.y)) < 1e-7 }) {
                continue
            }
            unique.append((i, Double(p.x), Double(p.y)))
        }
        guard unique.count >= 3 else { return [] }

        // 2) 超级三角形（覆盖全部点）
        var minX = unique[0].x, maxX = unique[0].x, minY = unique[0].y, maxY = unique[0].y
        for p in unique {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let dx = maxX - minX, dy = maxY - minY
        let deltaMax = max(dx, dy)
        let midX = (minX + maxX) / 2, midY = (minY + maxY) / 2
        let p0 = unique.count, p1 = unique.count + 1, p2 = unique.count + 2
        let superPoints = [
            (p0, midX - 20 * deltaMax, midY - deltaMax),
            (p1, midX, midY + 20 * deltaMax),
            (p2, midX + 20 * deltaMax, midY - deltaMax)
        ]
        var all: [(x: Double, y: Double)] = unique.map { ($0.x, $0.y) } + superPoints.map { ($0.1, $0.2) }

        // 3) 增量插入
        var triangles: [MeshTriangle] = [MeshTriangle(a: p0, b: p1, c: p2)]
        for i in 0..<unique.count {
            let px = all[i].x, py = all[i].y
            // 找外接圆包含该点的三角形
            var bad: [MeshTriangle] = []
            var good: [MeshTriangle] = []
            for t in triangles {
                if inCircumcircle(t, all, px, py) { bad.append(t) } else { good.append(t) }
            }
            // 收集空腔边界（只被一个坏三角形包含的边）
            var boundary: [(Int, Int)] = []
            for t in bad {
                for edge in [(t.a, t.b), (t.b, t.c), (t.c, t.a)] {
                    let shared = bad.contains { other in
                        other != t && (other.edges.contains { $0 == edge || $0 == (edge.1, edge.0) })
                    }
                    if !shared { boundary.append(edge) }
                }
            }
            triangles = good
            for edge in boundary {
                triangles.append(MeshTriangle(a: edge.0, b: edge.1, c: i))
            }
        }

        // 4) 移除含超级顶点的三角形
        return triangles.filter { t in
            t.a < p0 && t.b < p0 && t.c < p0
        }
    }

    /// 点 (px, py) 是否在三角形外接圆内（含边界，容差 1e-12）。
    private static func inCircumcircle(_ t: MeshTriangle, _ points: [(x: Double, y: Double)],
                                       _ px: Double, _ py: Double) -> Bool {
        let ax = points[t.a].x, ay = points[t.a].y
        let bx = points[t.b].x, by = points[t.b].y
        let cx = points[t.c].x, cy = points[t.c].y
        let ad = ax - px, ae = ay - py
        let bd = bx - px, be = by - py
        let cd = cx - px, ce = cy - py
        let abdet = ad * be - bd * ae
        let bcdet = bd * ce - cd * be
        let cadet = cd * ae - ad * ce
        let alift = ad * ad + ae * ae
        let blift = bd * bd + be * be
        let clift = cd * cd + ce * ce
        let det = alift * bcdet + blift * cadet + clift * abdet
        // 三角形顶点顺时针时 det > 0 为圆内；统一按面积符号归一
        let area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
        return area > 0 ? det > 1e-12 : det < -1e-12
    }
}

extension MeshTriangle {
    /// 三条有向边（含方向，用于空腔边界判定）。
    var edges: [(Int, Int)] { [(a, b), (b, c), (c, a)] }
}
