import Testing
import Foundation
@testable import FaceGeometry

// MARK: - 头部位姿解算单测（Card 1 验收：纯算法，Linux 可跑）
//
// 两条锁定路径：
// 1. 合成旋转 → solve() 恢复 Euler（Horn + Jacobi + 提取全链路）。
// 2. rotationMatrix(roll:pitch:yaw:) → eulerFromRotation() 往返
//    （把坐标系约定本身钉死）。

@Suite("位姿解算")
struct HeadPoseSolverTests {

    /// 用规范锚点合成一组观测点：obs = R·model + t（无噪声）。
    private func syntheticObserved(
        roll: Double, pitch: Double, yaw: Double,
        translation: (Double, Double, Double) = (0.1, -0.05, 0.2)
    ) -> [Landmark3D] {
        let r = HeadPoseSolver.rotationMatrix(roll: roll, pitch: pitch, yaw: yaw)
        var landmarks = Array(repeating: Landmark3D.zero, count: FaceGeometry.slotCount)
        for anchor in FaceMeshTopology.poseAnchors {
            let x = r[0][0] * Double(anchor.x) + r[0][1] * Double(anchor.y) + r[0][2] * Double(anchor.z) + translation.0
            let y = r[1][0] * Double(anchor.x) + r[1][1] * Double(anchor.y) + r[1][2] * Double(anchor.z) + translation.1
            let z = r[2][0] * Double(anchor.x) + r[2][1] * Double(anchor.y) + r[2][2] * Double(anchor.z) + translation.2
            landmarks[anchor.slot] = Landmark3D(x: Float(x), y: Float(y), z: Float(z))
        }
        return landmarks
    }

    @Test("单位旋转 → 零姿态")
    func identityPose() throws {
        let pose = HeadPoseSolver.solve(observed: syntheticObserved(roll: 0, pitch: 0, yaw: 0))
        let p = try #require(pose)
        #expect(abs(p.roll) < 1e-4)
        #expect(abs(p.pitch) < 1e-4)
        #expect(abs(p.yaw) < 1e-4)
        #expect(p.confidence > 0.99)
    }

    @Test("纯 roll 20° → 恢复 roll，pitch/yaw 为零")
    func pureRoll() throws {
        let pose = HeadPoseSolver.solve(observed: syntheticObserved(roll: 0.35, pitch: 0, yaw: 0))
        let p = try #require(pose)
        #expect(abs(p.roll - 0.35) < 1e-3)
        #expect(abs(p.pitch) < 1e-3)
        #expect(abs(p.yaw) < 1e-3)
    }

    @Test("纯 pitch -15° → 恢复 pitch")
    func purePitch() throws {
        let pose = HeadPoseSolver.solve(observed: syntheticObserved(roll: 0, pitch: -0.26, yaw: 0))
        let p = try #require(pose)
        #expect(abs(p.pitch - (-0.26)) < 1e-3)
        #expect(abs(p.roll) < 1e-3)
        #expect(abs(p.yaw) < 1e-3)
    }

    @Test("纯 yaw 25° → 恢复 yaw")
    func pureYaw() throws {
        let pose = HeadPoseSolver.solve(observed: syntheticObserved(roll: 0, pitch: 0, yaw: 0.44))
        let p = try #require(pose)
        #expect(abs(p.yaw - 0.44) < 1e-3)
        #expect(abs(p.roll) < 1e-3)
        #expect(abs(p.pitch) < 1e-3)
    }

    @Test("组合旋转 roll10/pitch12/yaw18 → 三角同时恢复")
    func combined() throws {
        let pose = HeadPoseSolver.solve(observed: syntheticObserved(roll: 0.17, pitch: 0.21, yaw: 0.31))
        let p = try #require(pose)
        #expect(abs(p.roll - 0.17) < 2e-3)
        #expect(abs(p.pitch - 0.21) < 2e-3)
        #expect(abs(p.yaw - 0.31) < 2e-3)
    }

    @Test("尺度不影响旋转估计（观测放大 3 倍 + 平移）")
    func scaleInvariance() throws {
        let r = HeadPoseSolver.rotationMatrix(roll: 0.2, pitch: 0.1, yaw: -0.15)
        var landmarks = Array(repeating: Landmark3D.zero, count: FaceGeometry.slotCount)
        for anchor in FaceMeshTopology.poseAnchors {
            let x = (r[0][0] * Double(anchor.x) + r[0][1] * Double(anchor.y) + r[0][2] * Double(anchor.z)) * 3 + 0.4
            let y = (r[1][0] * Double(anchor.x) + r[1][1] * Double(anchor.y) + r[1][2] * Double(anchor.z)) * 3 - 0.2
            let z = (r[2][0] * Double(anchor.x) + r[2][1] * Double(anchor.y) + r[2][2] * Double(anchor.z)) * 3 + 1.0
            landmarks[anchor.slot] = Landmark3D(x: Float(x), y: Float(y), z: Float(z))
        }
        let p = try #require(HeadPoseSolver.solve(observed: landmarks))
        #expect(abs(p.roll - 0.2) < 1e-3)
        #expect(abs(p.pitch - 0.1) < 1e-3)
        #expect(abs(p.yaw - (-0.15)) < 1e-3)
    }

    @Test("有效锚点不足 3 → nil")
    func insufficientAnchors() {
        var landmarks = Array(repeating: Landmark3D.zero, count: FaceGeometry.slotCount)
        landmarks[33] = Landmark3D(x: 0.1, y: 0.2, z: 0.3)
        landmarks[133] = Landmark3D(x: 0.2, y: 0.3, z: 0.1)
        #expect(HeadPoseSolver.solve(observed: landmarks) == nil)
    }

    @Test("2D 观测（z 全零）不崩溃（结果可为 nil 或低置信）")
    func twoDimensionalObservation() {
        var landmarks = syntheticObserved(roll: 0.3, pitch: 0, yaw: 0)
        for anchor in FaceMeshTopology.poseAnchors {
            let p = landmarks[anchor.slot]
            landmarks[anchor.slot] = Landmark3D(x: p.x, y: p.y, z: 0)
        }
        if let p = HeadPoseSolver.solve(observed: landmarks) {
            #expect(p.confidence <= 1)
        }
    }
}

@Suite("Euler 约定往返")
struct EulerConventionTests {

    @Test("rotationMatrix → eulerFromRotation 往返（多组角度）")
    func roundTrip() {
        let cases: [(Double, Double, Double)] = [
            (0, 0, 0),
            (0.35, 0, 0),
            (0, 0.26, 0),
            (0, 0, 0.44),
            (0.17, 0.21, 0.31),
            (-0.4, -0.3, 0.5),
            (1.2, -0.8, -1.0)
        ]
        for (roll, pitch, yaw) in cases {
            let m = HeadPoseSolver.rotationMatrix(roll: roll, pitch: pitch, yaw: yaw)
            let e = HeadPoseSolver.eulerFromRotation(m)
            // 容差 1e-6：HeadPose 角以 Float 存储，往返经 Float32 量化，
            // 极限误差 ≈ 1e-8（弧度制）—— 远紧于任何实际使用需求，
            // 但不做不可能达到的 1e-9 断言。
            #expect(abs(Double(e.roll) - roll) < 1e-6, "roll \(roll) → \(e.roll)")
            #expect(abs(Double(e.pitch) - pitch) < 1e-6, "pitch \(pitch) → \(e.pitch)")
            #expect(abs(Double(e.yaw) - yaw) < 1e-6, "yaw \(yaw) → \(e.yaw)")
        }
    }

    @Test("旋转矩阵正交性（R·Rᵀ = I）")
    func orthogonality() {
        let m = HeadPoseSolver.rotationMatrix(roll: 0.3, pitch: -0.2, yaw: 0.5)
        let prod = HeadPoseSolver.multiply(m, transpose(m))
        for i in 0..<3 {
            for j in 0..<3 {
                let expected = i == j ? 1.0 : 0.0
                #expect(abs(prod[i][j] - expected) < 1e-12)
            }
        }
    }
}

@Suite("2D roll 兜底")
struct RollFromEyeLineTests {

    @Test("水平双眼 → roll 0")
    func horizontal() {
        let roll = HeadPoseSolver.rollFromEyeLine(
            rightEye: Landmark3D(x: 0.4, y: 0.5),
            leftEye: Landmark3D(x: 0.6, y: 0.5)
        )
        #expect(abs(roll) < 1e-6)
    }

    @Test("右耳下沉（右眼更低）→ roll 为正（与 3D 语义一致）")
    func rightEarDown() {
        let roll = HeadPoseSolver.rollFromEyeLine(
            rightEye: Landmark3D(x: 0.4, y: 0.6),
            leftEye: Landmark3D(x: 0.6, y: 0.5)
        )
        // atan2(0.1, 0.2) ≈ 0.4636 rad（≈26.6°）
        #expect(abs(roll - 0.4636) < 1e-3)
    }

    @Test("45° 倾斜 → π/4")
    func fortyFive() {
        let roll = HeadPoseSolver.rollFromEyeLine(
            rightEye: Landmark3D(x: 0.4, y: 0.7),
            leftEye: Landmark3D(x: 0.6, y: 0.5)
        )
        #expect(abs(roll - .pi / 4) < 1e-6)
    }

    @Test("重合点 → 0（不发散）")
    func coincident() {
        let roll = HeadPoseSolver.rollFromEyeLine(
            rightEye: Landmark3D(x: 0.5, y: 0.5),
            leftEye: Landmark3D(x: 0.5, y: 0.5)
        )
        #expect(roll == 0)
    }
}

private func transpose(_ m: [[Double]]) -> [[Double]] {
    (0..<3).map { i in (0..<3).map { j in m[j][i] } }
}
