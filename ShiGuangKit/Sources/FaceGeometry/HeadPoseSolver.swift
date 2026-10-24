import Foundation

// MARK: - 头部位姿解算（v1.5.0 Card 1）
//
// 纯算法、跨平台（Linux 可测）。两条路径：
// 1. **3D 解算**（MediaPipe 主路径）：Horn 绝对定向（四元数法）——
//    以规范 3D 锚点模型（FaceMeshTopology.poseAnchors）解观测点刚体旋转，
//    再提取 Euler 角。均匀尺度不影响旋转估计（中心化后尺度可分离）。
// 2. **2D 兜底**（Vision）：只能解 roll（双眼/瞳孔连线倾角），
//    pitch/yaw 置 0 并降低 confidence —— 兜底不假装能解 3D。
//
// 坐标系约定（单测锁定，见 HeadPoseSolverTests）：
// - 相机系：x 右、y 下、z 前（右手系）。
// - R = Ry(yaw)·Rx(pitch)·Rz(roll)，由 3x3 行主序矩阵提取：
//   yaw   = atan2(R02, R22)
//   pitch = asin(-R12)
//   roll  = atan2(R10, R11)
// - 语义：roll>0 右耳下沉；pitch>0 抬头；yaw>0 对象左转（鼻尖朝画面右）。

public enum HeadPoseSolver {

    // MARK: - 3D 解算（Horn 绝对定向）

    /// 用规范锚点解算头部姿态。
    /// - Parameters:
    ///   - observed: 观测关键点（468 槽位数组；内部按锚点槽位取值）。
    ///   - anchors: 规范锚点表（默认 `FaceMeshTopology.poseAnchors`）。
    /// - Returns: 解算失败（有效锚点 < 3 / 病态）返回 nil。
    public static func solve(
        observed: [Landmark3D],
        anchors: [CanonicalAnchor] = FaceMeshTopology.poseAnchors
    ) -> HeadPose? {
        // 取有效锚点对（实测）
        var obs: [Vec3] = []
        var mdl: [Vec3] = []
        for anchor in anchors {
            guard anchor.slot >= 0, anchor.slot < observed.count else { continue }
            let p = observed[anchor.slot]
            guard p.isMeasured else { continue }
            obs.append(Vec3(Double(p.x), Double(p.y), Double(p.z)))
            mdl.append(Vec3(Double(anchor.x), Double(anchor.y), Double(anchor.z)))
        }
        guard obs.count >= 3, obs.count == mdl.count else { return nil }

        // 中心化
        let oc = centroid(obs), mc = centroid(mdl)
        var h: [Vec3] = [], m: [Vec3] = []
        for i in 0..<obs.count {
            h.append(obs[i] - oc)
            m.append(mdl[i] - mc)
        }

        // 互协方差 M = Σ m_i ⊗ h_iᵀ（行 = 模型分量，列 = 观测分量）
        // —— Horn 1987 原论文约定：M = Σ (p_i - p̄)(P_i - P̄)ᵀ，p = 模型，P = 观测。
        // 早期实现误写为 Σ h⊗mᵀ（即 Mᵀ）：N 矩阵主特征向量对应的旋转整体取逆，
        // 恢复出的姿态三角符号全反（合成旋转单测 + 残差对比锁定：
        // err(Rᵀ·m→h) ≈ 0 而 err(R·m→h) ≈ 1e-2）。方向写反不会报错，
        // 只会让所有角度静默变负 —— 所以此契约必须由单测钉死。
        var s = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        for i in 0..<h.count {
            for r in 0..<3 {
                for c in 0..<3 {
                    s[r][c] += m[i][r] * h[i][c]
                }
            }
        }

        // Horn 4x4 对称矩阵 → 主特征向量（四元数 w,x,y,z）
        guard let q = largestEigenquaternion(s) else { return nil }
        let r = rotationMatrix(fromQuaternion: q) // 模型帧 → 相机帧
        let euler = eulerFromRotation(r)

        // 残差 → 置信度（归一化坐标下 RMS；0.05 ≈ 画面 5% 视为不可信）
        var sumSq = 0.0
        for i in 0..<h.count {
            let rp = apply(r, m[i])
            let d = rp - h[i]
            sumSq += d.x * d.x + d.y * d.y + d.z * d.z
        }
        let rms = (sumSq / Double(h.count)).squareRoot()
        let confidence = Float(max(0, 1 - rms / 0.05))
        return HeadPose(
            roll: euler.roll, pitch: euler.pitch, yaw: euler.yaw,
            confidence: min(confidence, 1)
        )
    }

    // MARK: - 2D 兜底（roll only）

    /// 双眼连线求 roll（弧度）。参数为**解剖学**右/左眼（Vision/MediaPipe
    /// 命名一致：右眼在非镜像画面左半）。
    /// 右耳下沉（右眼 y 大于左眼 y）→ 正值，与 3D roll 语义一致。
    public static func rollFromEyeLine(rightEye: Landmark3D, leftEye: Landmark3D) -> Float {
        let dy = rightEye.y - leftEye.y
        let dx = leftEye.x - rightEye.x
        guard dx != 0 || dy != 0 else { return 0 }
        return atan2(dy, dx)
    }

    // MARK: - Euler 提取

    /// 由旋转矩阵（行主序 3x3）提取 (roll, pitch, yaw)（弧度）。
    public static func eulerFromRotation(_ m: [[Double]]) -> (roll: Float, pitch: Float, yaw: Float) {
        let pitch = asin(min(max(-m[1][2], -1), 1))
        let yaw = atan2(m[0][2], m[2][2])
        let roll = atan2(m[1][0], m[1][1])
        return (Float(roll), Float(pitch), Float(yaw))
    }

    // MARK: - 内部：小型线性代数

    /// 三维向量（Double；避免依赖 SIMD —— 保证 Linux stdlib 可用性）。
    struct Vec3 {
        var x: Double, y: Double, z: Double
        init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
        subscript(_ i: Int) -> Double {
            switch i { case 0: x; case 1: y; default: z }
        }
        static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    }

    /// 四元数（w 为标量部）。
    struct Quat {
        var w: Double, x: Double, y: Double, z: Double
        init(_ w: Double, _ x: Double, _ y: Double, _ z: Double) {
            self.w = w; self.x = x; self.y = y; self.z = z
        }
    }

    static func centroid(_ pts: [Vec3]) -> Vec3 {
        var sx = 0.0, sy = 0.0, sz = 0.0
        for p in pts { sx += p.x; sy += p.y; sz += p.z }
        let n = Double(pts.count)
        return Vec3(sx / n, sy / n, sz / n)
    }

    static func apply(_ m: [[Double]], _ v: Vec3) -> Vec3 {
        Vec3(
            m[0][0] * v.x + m[0][1] * v.y + m[0][2] * v.z,
            m[1][0] * v.x + m[1][1] * v.y + m[1][2] * v.z,
            m[2][0] * v.x + m[2][1] * v.y + m[2][2] * v.z
        )
    }

    /// Horn 的 N 矩阵主特征向量 → 单位四元数。
    static func largestEigenquaternion(_ s: [[Double]]) -> Quat? {
        let s00 = s[0][0], s01 = s[0][1], s02 = s[0][2]
        let s10 = s[1][0], s11 = s[1][1], s12 = s[1][2]
        let s20 = s[2][0], s21 = s[2][1], s22 = s[2][2]
        // 4x4 对称矩阵（Horn 1987, eq. 29 构造；首分量 = 标量 w）
        var n = Array(repeating: Array(repeating: 0.0, count: 4), count: 4)
        n[0][0] = s00 + s11 + s22
        n[0][1] = s12 - s21; n[1][0] = n[0][1]
        n[0][2] = s20 - s02; n[2][0] = n[0][2]
        n[0][3] = s01 - s10; n[3][0] = n[0][3]
        n[1][1] = s00 - s11 - s22
        n[1][2] = s01 + s10; n[2][1] = n[1][2]
        n[1][3] = s20 + s02; n[3][1] = n[1][3]
        n[2][2] = -s00 + s11 - s22
        n[2][3] = s12 + s21; n[3][2] = n[2][3]
        n[3][3] = -s00 - s11 + s22

        guard let (values, vectors) = jacobiEigen(n) else { return nil }
        // 最大特征值索引
        var best = 0
        for i in 1..<4 where values[i] > values[best] { best = i }
        let q = vectors[best]
        let norm = (q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]).squareRoot()
        guard norm > 1e-12 else { return nil }
        return Quat(q[0] / norm, q[1] / norm, q[2] / norm, q[3] / norm)
    }

    /// 单位四元数 → 旋转矩阵（行主序 3x3）。
    static func rotationMatrix(fromQuaternion q: Quat) -> [[Double]] {
        let w = q.w, x = q.x, y = q.y, z = q.z
        return [
            [1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
            [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
            [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)]
        ]
    }

    /// 对称矩阵 Jacobi 旋转特征值分解。返回 (特征值, 特征向量列)。
    static func jacobiEigen(_ input: [[Double]]) -> (values: [Double], vectors: [[Double]])? {
        guard input.count == 4 else { return nil }
        var a = input
        var v = Array(repeating: Array(repeating: 0.0, count: 4), count: 4)
        for i in 0..<4 { v[i][i] = 1 }
        let maxSweeps = 100
        for _ in 0..<maxSweeps {
            // 找最大非对角元
            var p = 0, q = 1
            var maxAbs = abs(a[0][1])
            for i in 0..<4 {
                for j in (i + 1)..<4 where abs(a[i][j]) > maxAbs {
                    maxAbs = abs(a[i][j]); p = i; q = j
                }
            }
            if maxAbs < 1e-15 { break }
            let app = a[p][p], aqq = a[q][q], apq = a[p][q]
            let phi = 0.5 * atan2(2 * apq, aqq - app)
            let c = cos(phi), s = sin(phi)
            // A' = JᵀAJ（先列后行，均为原地线性操作）
            for k in 0..<4 {
                let akp = a[k][p], akq = a[k][q]
                a[k][p] = c * akp - s * akq
                a[k][q] = s * akp + c * akq
            }
            for k in 0..<4 {
                let apk = a[p][k], aqk = a[q][k]
                a[p][k] = c * apk - s * aqk
                a[q][k] = s * apk + c * aqk
            }
            // V' = V·J
            for k in 0..<4 {
                let vkp = v[k][p], vkq = v[k][q]
                v[k][p] = c * vkp - s * vkq
                v[k][q] = s * vkp + c * vkq
            }
        }
        let values = (0..<4).map { a[$0][$0] }
        let vectors = (0..<4).map { i in (0..<4).map { v[$0][i] } }
        return (values, vectors)
    }

    // MARK: - 测试辅助（公开：供 Linux 单测构造合成旋转）

    /// 由 (roll, pitch, yaw) 构造旋转矩阵 R = Ry(yaw)·Rx(pitch)·Rz(roll)。
    public static func rotationMatrix(roll: Double, pitch: Double, yaw: Double) -> [[Double]] {
        let cr = cos(roll), sr = sin(roll)
        let cp = cos(pitch), sp = sin(pitch)
        let cy = cos(yaw), sy = sin(yaw)
        let rz = [[cr, -sr, 0], [sr, cr, 0], [0, 0, 1]]
        let rx = [[1, 0, 0], [0, cp, -sp], [0, sp, cp]]
        let ry = [[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]]
        return multiply(multiply(ry, rx), rz)
    }

    /// 3x3 矩阵乘。
    public static func multiply(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        var out = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        for i in 0..<3 {
            for j in 0..<3 {
                var sum = 0.0
                for k in 0..<3 { sum += a[i][k] * b[k][j] }
                out[i][j] = sum
            }
        }
        return out
    }
}
