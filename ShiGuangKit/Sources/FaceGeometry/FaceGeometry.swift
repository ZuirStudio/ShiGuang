import Foundation
// 跨平台：macOS/iOS 上 CoreGraphics 把 `CGRect`/`CGSize` 的 `Equatable`（及 `.zero`）等
// 扩展定义在 CoreGraphics 模块内，须显式 import 才可见；Linux 覆盖层由 Foundation 提供
// 同名类型与扩展，且无独立 `CoreGraphics` 模块，故条件导入避免破坏 Linux 构建。
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - 人脸几何模型（v1.5.0 Card 1 / P0）
//
// 定位：**跨平台纯逻辑层**（仅 Foundation + CoreGraphics 两端通用类型），
// 不 import Vision / MediaPipe / CoreImage —— 因此可在 Linux runner 上
// 秒级编译与单测（AGENTS.md 纪律：纯算法必须有 Linux 单测）。
//
// 平台相关部分（协议、Provider、注册表）在 AICore；MediaPipe 主路径
// Provider 在 FaceML 本地包（MediaPipeTasksVision 为 iOS-only 二进制框架，
// 不能进 ShiGuangKit 包图 —— 否则 macOS `swift test` 解析失败，见
// docs/v1.5.0-card1-architecture.md 的 ADR）。
//
// 槽位契约（**必须遵守**，RenderKit 液化护栏与网格叠加都依赖它）：
// - `landmarks` 恒为 468 个槽位，索引即 MediaPipe Face Mesh 规范槽位号
//   （0..<468；MediaPipe FaceLandmarker 的 478 输出中 468..<478 为虹膜，
//   单独放 `irisLandmarks`）。
// - 坐标系统一为**图像归一化、左上原点、x 右 y 下**（与 CIImage/CGImage
//   像素方向一致；MediaPipe normalized landmark 亦此约定）。
// - `z` 为相对深度（MediaPipe：与 x 同量级）；2D 来源（Vision）填 0。
// - `confidence == 0` 表示该槽位**未实测**（兜底 Provider 只填外壳区域，
//   内部密集网格槽位为零 —— 消费者按 `slotCoverage` 判断可用性）。

/// 单个 3D 关键点（归一化图像坐标 + 相对深度 + 置信度）。
public struct Landmark3D: Sendable, Equatable, Codable {
    public var x: Float
    public var y: Float
    public var z: Float
    /// 0 = 未实测（占位零值）；>0 = 实测置信度（0...1）。
    public var confidence: Float

    public init(x: Float, y: Float, z: Float = 0, confidence: Float = 1) {
        self.x = x
        self.y = y
        self.z = z
        self.confidence = confidence
    }

    public static let zero = Landmark3D(x: 0, y: 0, z: 0, confidence: 0)

    public var isMeasured: Bool { confidence > 0 }

    /// 2D 平面距离（忽略 z）。
    public func distance2D(to other: Landmark3D) -> Float {
        let dx = x - other.x, dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// 头部姿态（弧度）。相机坐标系约定：**x 右、y 下、z 前**（右手系）。
///
/// - roll（绕 z / 视线轴）：正 = 对象右耳下沉（头向右倾）
/// - pitch（绕 x / 右向轴）：正 = 抬头（鼻尖朝天）
/// - yaw（绕 y / 下向轴）：正 = 对象向左转（鼻尖转向画面右）
///
/// 该约定由 `HeadPoseSolver` 的合成旋转单测锁定（测试构造已知
/// R = Ry(yaw)·Rx(pitch)·Rz(roll)，断言解算恢复），不是口头约定。
public struct HeadPose: Sendable, Equatable, Codable {
    public var roll: Float
    public var pitch: Float
    public var yaw: Float
    /// 0...1；2D 来源只能解 roll 时显著降低（见 VisionLandmarksProvider）。
    public var confidence: Float

    public init(roll: Float, pitch: Float = 0, yaw: Float = 0, confidence: Float = 1) {
        self.roll = roll
        self.pitch = pitch
        self.yaw = yaw
        self.confidence = confidence
    }

    public static let zero = HeadPose(roll: 0, pitch: 0, yaw: 0, confidence: 0)

    /// 角度制（UI 显示用；内部一律弧度）。
    public var rollDegrees: Float { roll * 180 / .pi }
    public var pitchDegrees: Float { pitch * 180 / .pi }
    public var yawDegrees: Float { yaw * 180 / .pi }
}

/// 人脸几何检测失败原因（**「未检出人脸」不是错误** —— 用返回 nil 表达，
/// 与 `PersonMaskProviding` 的降级语义一致）。
public enum FaceGeometryError: Error, Equatable, Sendable {
    /// 输入图不可用（0 尺寸等）。
    case invalidInput
    /// landmarks 数量不等于 468（Provider 产出违约）。
    case invalidSlotCount(Int)
    /// 推理失败（附原始描述，便于真机定位）。
    case inferenceFailed(String)
}

/// 一次人脸几何检测的完整产物（值类型、Sendable、Codable ——
/// Card 2 的 LiquifyWarpNode 状态要能整体序列化进 EditGraph）。
public struct FaceGeometry: Sendable, Equatable, Codable {
    public static let slotCount = 468

    /// 468 个槽位（索引 = MediaPipe 规范槽位号）。
    public var landmarks: [Landmark3D]
    /// 虹膜关键点（0 或 10 个；仅 MediaPipe 478 输出携带）。
    public var irisLandmarks: [Landmark3D]
    public var pose: HeadPose
    /// 人脸框（图像归一化、左上原点）。
    public var boundingBox: CGRect
    /// 提供方标识（UI 切换 / 诊断）。
    public var providerID: String
    /// 检测所用图像像素尺寸（坐标归一化的参照）。
    public var imageSize: CGSize

    public init(
        landmarks: [Landmark3D],
        irisLandmarks: [Landmark3D] = [],
        pose: HeadPose,
        boundingBox: CGRect,
        providerID: String,
        imageSize: CGSize
    ) throws {
        guard landmarks.count == Self.slotCount else {
            throw FaceGeometryError.invalidSlotCount(landmarks.count)
        }
        self.landmarks = landmarks
        self.irisLandmarks = irisLandmarks
        self.pose = pose
        self.boundingBox = boundingBox
        self.providerID = providerID
        self.imageSize = imageSize
    }

    /// 全零槽位的占位产物（无脸 / 失败时使用；`slotCoverage == 0`）。
    public static func zeros(providerID: String, imageSize: CGSize = CGSize(width: 0, height: 0)) -> FaceGeometry {
        // 不会 throw：count 恒等于 slotCount
        // swiftlint:disable:next force_try
        try! FaceGeometry(
            landmarks: Array(repeating: .zero, count: Self.slotCount),
            pose: .zero,
            boundingBox: .zero,
            providerID: providerID,
            imageSize: imageSize
        )
    }

    public func slot(_ index: Int) -> Landmark3D {
        guard index >= 0, index < landmarks.count else { return .zero }
        return landmarks[index]
    }

    /// 实测槽位数。
    public var measuredSlotCount: Int {
        landmarks.reduce(0) { $0 + ($1.isMeasured ? 1 : 0) }
    }

    /// 实测槽位覆盖率（0...1）。Vision 兜底 ≈ 152/468 ≈ 0.32；
    /// MediaPipe 主路径 = 1.0。消费者据此判断能否做密集网格渲染。
    public var slotCoverage: Float {
        Float(measuredSlotCount) / Float(Self.slotCount)
    }
}

// MARK: - Codable 桥接
//
// CGRect / CGSize 在 Linux corelibs-foundation 的 Codable 支持不完整，
// 而本 target 必须能在 Linux 编译测试 —— 编码载荷一律拆成四个 Float，
// 对外仍暴露 CGRect/CGSize 计算属性（读写都经桥接，外部无感）。

extension FaceGeometry {
    private enum CodingKeys: String, CodingKey {
        case landmarks, irisLandmarks, pose, providerID
        case boxMinX, boxMinY, boxWidth, boxHeight
        case imageWidth, imageHeight
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let landmarks = try c.decode([Landmark3D].self, forKey: .landmarks)
        guard landmarks.count == Self.slotCount else {
            throw FaceGeometryError.invalidSlotCount(landmarks.count)
        }
        self.landmarks = landmarks
        self.irisLandmarks = try c.decodeIfPresent([Landmark3D].self, forKey: .irisLandmarks) ?? []
        self.pose = try c.decode(HeadPose.self, forKey: .pose)
        self.providerID = try c.decode(String.self, forKey: .providerID)
        let minX = try c.decode(CGFloat.self, forKey: .boxMinX)
        let minY = try c.decode(CGFloat.self, forKey: .boxMinY)
        let w = try c.decode(CGFloat.self, forKey: .boxWidth)
        let h = try c.decode(CGFloat.self, forKey: .boxHeight)
        self.boundingBox = CGRect(x: minX, y: minY, width: w, height: h)
        let iw = try c.decode(CGFloat.self, forKey: .imageWidth)
        let ih = try c.decode(CGFloat.self, forKey: .imageHeight)
        self.imageSize = CGSize(width: iw, height: ih)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(landmarks, forKey: .landmarks)
        try c.encode(irisLandmarks, forKey: .irisLandmarks)
        try c.encode(pose, forKey: .pose)
        try c.encode(providerID, forKey: .providerID)
        try c.encode(boundingBox.minX, forKey: .boxMinX)
        try c.encode(boundingBox.minY, forKey: .boxMinY)
        try c.encode(boundingBox.width, forKey: .boxWidth)
        try c.encode(boundingBox.height, forKey: .boxHeight)
        try c.encode(imageSize.width, forKey: .imageWidth)
        try c.encode(imageSize.height, forKey: .imageHeight)
    }
}
