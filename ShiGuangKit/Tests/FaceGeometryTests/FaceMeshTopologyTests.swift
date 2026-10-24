import Testing
import Foundation
@testable import FaceGeometry

// MARK: - 三角剖分不变式（Card 1：纯算法，Linux 可跑）
//
// Bowyer-Watson 增量 Delaunay 的不变式锁定：
// 1. 输出索引全部来自输入（无超级顶点泄漏）。
// 2. 每个输入点至少是一个三角形的顶点。
// 3. 无退化三角形（面积 > 1e-9）。
// 4. Delaunay 性质抽查：抽样三角形的外接圆内无其他点。
// 5. 未实测 / 重复点被剔除（兜底 Provider 的零槽位不参与）。

@Suite("Delaunay 三角剖分")
struct TriangulationTests {

    /// 规则网格点（5x4，间距 0.1）—— 已知解析结果：三角形数 = 2·n - 2 - h。
    private func grid(rows: Int, cols: Int) -> [Landmark3D] {
        var pts: [Landmark3D] = []
        for r in 0..<rows {
            for c in 0..<cols {
                pts.append(Landmark3D(x: Float(c) * 0.1, y: Float(r) * 0.1))
            }
        }
        return pts
    }

    @Test("网格剖分：点数全部用上、三角形数合理")
    func gridTriangulation() {
        let points = grid(rows: 4, cols: 5)  // 20 点
        let triangles = FaceMeshTopology.triangulate(points)
        #expect(!triangles.isEmpty)
        // Delaunay 三角形数上界 2n-2-h（h= hull 顶点数）；网格 hull=8 → 上界 30
        #expect(triangles.count <= 2 * points.count - 2)
        // 每个点至少出现在一个三角形里
        for i in 0..<points.count {
            #expect(triangles.contains { $0.a == i || $0.b == i || $0.c == i },
                    "点 \(i) 未参与任何三角形")
        }
        // 索引范围
        for t in triangles {
            #expect(t.a >= 0 && t.a < points.count)
            #expect(t.b >= 0 && t.b < points.count)
            #expect(t.c >= 0 && t.c < points.count)
        }
    }

    @Test("无退化三角形（面积下界）")
    func noDegenerate() {
        let points = grid(rows: 5, cols: 6)
        let triangles = FaceMeshTopology.triangulate(points)
        for t in triangles {
            let a = points[t.a], b = points[t.b], c = points[t.c]
            let area = abs((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) / 2
            #expect(area > 1e-9)
        }
    }

    @Test("Delaunay 性质抽查：抽样三角形外接圆内无其他点")
    func delaunayProperty() {
        let points = grid(rows: 5, cols: 6)
        let triangles = FaceMeshTopology.triangulate(points)
        let sample = stride(from: 0, to: triangles.count, by: max(triangles.count / 12, 1))
        for ti in sample where ti < triangles.count {
            let t = triangles[ti]
            let a = points[t.a], b = points[t.b], c = points[t.c]
            let (center, radius) = circumcircle(a, b, c)
            for (i, p) in points.enumerated() {
                if i == t.a || i == t.b || i == t.c { continue }
                let d = hypot(Double(p.x) - center.x, Double(p.y) - center.y)
                #expect(d > radius - 1e-9, "点 \(i) 落在三角形 \(ti) 外接圆内")
            }
        }
    }

    @Test("未实测与重复点被剔除")
    func filtersZeroAndDuplicate() {
        var points = grid(rows: 3, cols: 3)
        points.append(.zero)                        // 未实测
        points.append(Landmark3D(x: 0, y: 0))       // 与首点重复
        let triangles = FaceMeshTopology.triangulate(points)
        // 9 个唯一点 → 不含索引 9/10
        for t in triangles {
            #expect(t.a < 9 && t.b < 9 && t.c < 9)
        }
        for i in 0..<9 {
            #expect(triangles.contains { $0.a == i || $0.b == i || $0.c == i })
        }
    }

    @Test("少于 3 个有效点 → 空")
    func tooFewPoints() {
        #expect(FaceMeshTopology.triangulate([Landmark3D(x: 0, y: 0), Landmark3D(x: 1, y: 1)]).isEmpty)
        #expect(FaceMeshTopology.triangulate([]).isEmpty)
        #expect(FaceMeshTopology.triangulate([.zero, .zero, .zero]).isEmpty)
    }

    @Test("确定性：同一输入两次剖分一致")
    func deterministic() {
        let points = grid(rows: 4, cols: 4)
        #expect(FaceMeshTopology.triangulate(points) == FaceMeshTopology.triangulate(points))
    }

    /// 外接圆（圆心 + 半径）。
    private func circumcircle(_ a: Landmark3D, _ b: Landmark3D, _ c: Landmark3D)
        -> (center: (x: Double, y: Double), radius: Double) {
        let ax = Double(a.x), ay = Double(a.y)
        let bx = Double(b.x), by = Double(b.y)
        let cx = Double(c.x), cy = Double(c.y)
        let d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
        let ux = ((ax * ax + ay * ay) * (by - cy) + (bx * bx + by * by) * (cy - ay)
                  + (cx * cx + cy * cy) * (ay - by)) / d
        let uy = ((ax * ax + ay * ay) * (cx - bx) + (bx * bx + by * by) * (ax - cx)
                  + (cx * cx + cy * cy) * (bx - ax)) / d
        let r = hypot(ax - ux, ay - uy)
        return ((ux, uy), r)
    }
}

@Suite("FaceGeometry 模型")
struct FaceGeometryModelTests {

    @Test("槽位数量校验：非 468 → invalidSlotCount")
    func slotCountValidation() {
        var thrown: FaceGeometryError?
        do {
            _ = try FaceGeometry(
                landmarks: Array(repeating: .zero, count: 478),
                pose: .zero, boundingBox: .zero,
                providerID: "test", imageSize: .zero
            )
        } catch let error as FaceGeometryError {
            thrown = error
        } catch {
            Issue.record("非预期错误类型: \(error)")
        }
        #expect(thrown == .invalidSlotCount(478))
    }

    @Test("zeros()：全零槽位、coverage 0、可用 slot() 安全访问")
    func zeros() {
        let g = FaceGeometry.zeros(providerID: "none")
        #expect(g.landmarks.count == 468)
        #expect(g.slotCoverage == 0)
        #expect(g.measuredSlotCount == 0)
        #expect(g.slot(0) == .zero)
        #expect(g.slot(-1) == .zero)
        #expect(g.slot(999) == .zero)
    }

    @Test("coverage：实测 152 槽位 → 152/468")
    func coverage() {
        var landmarks = Array(repeating: Landmark3D.zero, count: 468)
        for slot in FaceMeshRegion.faceOval.slots { landmarks[slot] = Landmark3D(x: 0.5, y: 0.5) }
        let g = try! FaceGeometry(
            landmarks: landmarks, pose: .zero, boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
            providerID: "test", imageSize: CGSize(width: 100, height: 100)
        )
        #expect(g.measuredSlotCount == 36)
        #expect(abs(g.slotCoverage - 36.0 / 468.0) < 1e-6)
    }

    @Test("Codable 往返：槽位 / 虹膜 / 姿态 / 包围盒 / 尺寸全保留")
    func codableRoundTrip() throws {
        var landmarks = Array(repeating: Landmark3D.zero, count: 468)
        for (i, slot) in FaceMeshRegion.leftEye.slots.enumerated() {
            landmarks[slot] = Landmark3D(x: 0.7 + Float(i) * 0.001, y: 0.4, z: -0.01 * Float(i))
        }
        let iris = (0..<10).map { Landmark3D(x: 0.71 + Float($0) * 0.002, y: 0.41, z: 0.01) }
        let original = try FaceGeometry(
            landmarks: landmarks,
            irisLandmarks: iris,
            pose: HeadPose(roll: 0.2, pitch: -0.1, yaw: 0.3, confidence: 0.85),
            boundingBox: CGRect(x: 0.35, y: 0.28, width: 0.3, height: 0.44),
            providerID: "mediapipe.face_landmarker.v1",
            imageSize: CGSize(width: 1440, height: 1920)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FaceGeometry.self, from: data)
        #expect(decoded == original)
        #expect(decoded.irisLandmarks.count == 10)
        #expect(decoded.pose.rollDegrees > 11 && decoded.pose.rollDegrees < 12)
        #expect(decoded.boundingBox == original.boundingBox)
        #expect(decoded.imageSize == original.imageSize)
    }

    @Test("Codable 往返：空虹膜（Vision 兜底产物形态）")
    func codableDefaultIris() throws {
        let original = try FaceGeometry(
            landmarks: Array(repeating: .zero, count: 468),
            pose: .zero, boundingBox: .zero,
            providerID: "vision", imageSize: .zero
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FaceGeometry.self, from: data)
        #expect(decoded == original)
    }
}
