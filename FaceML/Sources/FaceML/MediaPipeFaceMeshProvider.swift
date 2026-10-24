import Foundation
import CoreGraphics
import CoreImage
import os
import UIKit
import MediaPipeTasksVision
import AICore
import RenderKit
import FaceGeometry

// MARK: - MediaPipe Face Landmarker 主路径 Provider（v1.5.0 Card 1 / P0）
//
// 主路径（兜底轨是 AICore 的 `VisionLandmarksProvider`）：
// - 模型 = Google 官方 `face_landmarker.task`（Apache-2.0，随包入仓，
//   sha256 见 NOTICE.md）；产出 **478 点**（468 网格 + 468..<478 虹膜 10 点）。
// - 坐标：MediaPipe normalized landmark 即「图像归一化、左上原点、x 右 y 下」，
//   与 `FaceGeometry` 契约逐字一致 —— 无需任何坐标变换（Vision 兜底轨才需要翻转）。
// - 位姿：与兜底轨**同一套** `HeadPoseSolver`（Horn 四元数，3D 锚点解算）——
//   两条 Provider 的 roll/pitch/yaw 语义不可能漂移（Card 1 验收的一致性要求）。
// - 本类禁直连 Vision / RenderKit（铁律）；只经 AICore 协议 + FaceGeometry 模型层。
//
// 隔离与并发：`FaceLandmarker`（NSObject）与 `CIContext` 为 actor 隔离状态，
// 只创建一次并缓存；推理串行执行（actor 保证），不会并发覆写同一请求的输出缓冲。

public actor MediaPipeFaceMeshProvider: FaceGeometryProviding {
    /// 稳定标识（注册表键 / 诊断显示）。
    public static let providerID = "mediapipe.face_landmarker"

    /// 共享实例（进程内模型只加载一次）。
    public static let shared = MediaPipeFaceMeshProvider()

    /// 推理输入最长边。MediaPipe 内部工作分辨率远低于此（face mesh 模型输入
    /// ~192x256 量级），1024 已无增益且显著快于全尺寸（与 Vision 兜底轨同口径）。
    public static let workingLongEdge: CGFloat = 1024

    /// MediaPipe Face Mesh V2 输出点数（468 网格 + 10 虹膜）。模型随包入仓
    /// （sha256 锁定），输出点数恒定；不足 468 按契约抛 `invalidSlotCount`。
    public static let expectedLandmarkCount = 478

    /// 运行期统计（`snapshot()` 返回；供报告与诊断引用真实数字）。
    public struct Stats: Sendable, Equatable {
        public var modelLoads = 0
        public var inferences = 0
        public var faceFound = 0
        public var noFace = 0
        public var failures = 0
        public var firstLoadMillis = 0.0
        public var lastInferenceMillis = 0.0
        public var maxInferenceMillis = 0.0
        public var totalInferenceMillis = 0.0
        public var meanInferenceMillis: Double {
            inferences > 0 ? totalInferenceMillis / Double(inferences) : 0
        }
    }

    /// 可用性标志盒。协议 `isAvailable()` 为 **nonisolated** 要求（诊断 UI /
    /// 深链验收可能在任意隔离域同步查询），而「模型是否已加载」是 actor 隔离
    /// 状态 —— 跨隔离同步读取必须经由 @unchecked Sendable 盒（沿用 PerfSignpost /
    /// FaceGeometryRegistry 的 NSLock 惯例）。
    private final class AvailabilityFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: Bool) { lock.lock(); defer { lock.unlock() }; value = newValue }
    }

    private var landmarker: FaceLandmarker?
    private var context: CIContext?
    private var stats = Stats()
    private let log = OSLog(subsystem: "studio.zuir.shiguang", category: "faceML")
    /// 模型可用性（`isAvailable` 的 nonisolated 读取源；`landmarkerIfNeeded` 成功即置 true）。
    private nonisolated let availability = AvailabilityFlag()

    public init() {}

    /// 协议要求的实例属性（静态常量不满足实例成员要求）。
    public nonisolated var providerID: String { Self.providerID }

    /// 模型已加载才算可用。App 启动流程：`warmUp()` 成功 → 注册为主路径；
    /// 失败（模型缺失/损坏）→ 不注册，注册表自动留在 Vision 兜底轨。
    ///
    /// nonisolated：协议要求；状态经 `AvailabilityFlag` 盒跨隔离同步读。
    public nonisolated func isAvailable() -> Bool { availability.get() }

    /// 读取累计统计。
    public func snapshot() -> Stats { stats }

    /// 加载模型（只建不推理），供 App 启动期决定是否注册为主路径。
    /// - Returns: 首次模型加载耗时（ms）。
    /// - Throws: `FaceGeometryError.inferenceFailed`（模型文件缺失 / FaceLandmarker 初始化失败）。
    @discardableResult
    public func warmUp() throws -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        _ = try landmarkerIfNeeded()
        _ = contextIfNeeded()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        if stats.firstLoadMillis == 0 { stats.firstLoadMillis = ms }
        return ms
    }

    /// 检测人脸几何。返回 nil = **未检出人脸**（调用方据此降级，不视为错误）。
    public func detect(_ boxed: SendableSegmentImage) async throws -> FaceGeometry? {
        let image = boxed.image
        let t0 = DispatchTime.now().uptimeNanoseconds
        let landmarker = try landmarkerIfNeeded()
        let ctx = contextIfNeeded()

        let extent = image.extent
        guard extent.width >= 2, extent.height >= 2, extent.isInfinite == false,
              !extent.isEmpty else {
            throw FaceGeometryError.invalidInput
        }

        // 1) 降采样到工作分辨率（归一化坐标不受缩放影响）
        let longEdge = max(extent.width, extent.height)
        let scale = min(1, Self.workingLongEdge / longEdge)
        let working = scale < 1
            ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : image

        // 出图点带尺寸与上下文埋点（R007d 纪律：性能结论不靠代码推断）
        guard let cg = PerfSignpost.shared.measure(
            .cgImage,
            detail: String(format: "faceMeshInfer %dx%d",
                           Int(working.extent.width), Int(working.extent.height)),
            { ctx.createCGImage(working, from: working.extent) }
        ) else {
            throw FaceGeometryError.invalidInput
        }

        // 2) MPImage 只接受 UIImage / CVPixelBuffer / CMSampleBuffer；
        // 工程既有链路是 CIImage → CGImage（与 Vision 兜底轨同一出图点），
        // 此处 UIImage(cgImage:) 桥接（orientation 恒 .up，正立图契约）。
        // 注：本版 MediaPipeTasksVision 的 MPImage(uiImage:) 为非 Optional + throws，
        // 失败经 try 抛出，不走 Optional 绑定。
        let mpImage = try MPImage(uiImage: UIImage(cgImage: cg))

        // 3) 推理（同步；actor 保证串行）
        // 注：本版 MediaPipeTasksVision 的 detect(image:) 为非 Optional + throws；
        // 「未检出人脸」由下方 result.faceLandmarks.first 的 guard 兜底（含 stats.noFace 计数）。
        let signpostID = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "faceMeshInfer", signpostID: signpostID)
        defer { os_signpost(.end, log: log, name: "faceMeshInfer", signpostID: signpostID) }

        let result = try landmarker.detect(image: mpImage)

        // 取第一张脸（numFaces = 1，编辑场景单主体为主；与 Vision 兜底轨同口径）
        guard let firstFace = result.faceLandmarks.first else {
            stats.noFace += 1
            return nil
        }
        guard firstFace.count >= FaceGeometry.slotCount else {
            // 模型输出与契约不符（换模型未改常量）—— 响亮失败，不静默错位
            stats.failures += 1
            throw FaceGeometryError.invalidSlotCount(firstFace.count)
        }

        // 4) 478 → 468 网格 + 10 虹膜（契约：468..<478 为虹膜）
        let mesh = firstFace.prefix(FaceGeometry.slotCount).map(Self.landmark(_:))
        let iris = firstFace.count >= Self.expectedLandmarkCount
            ? firstFace[FaceGeometry.slotCount..<Self.expectedLandmarkCount].map(Self.landmark(_:))
            : []

        // 5) 位姿（与兜底轨同一 Horn 解算；468 实测锚点恒 ≥ 3，nil 仅为防御）
        let pose = HeadPoseSolver.solve(observed: mesh) ?? .zero

        // 6) 包围盒（468 实测槽位极值；MediaPipe 坐标即图像归一化左上原点）
        let box = LandmarkSlotMap.boundingBox(of: mesh)

        // 7) 统计
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        stats.inferences += 1
        stats.faceFound += 1
        stats.lastInferenceMillis = ms
        stats.maxInferenceMillis = max(stats.maxInferenceMillis, ms)
        stats.totalInferenceMillis += ms
        if stats.firstLoadMillis == 0 { stats.firstLoadMillis = ms }

        return try FaceGeometry(
            landmarks: mesh,
            irisLandmarks: iris,
            pose: pose,
            boundingBox: box,
            providerID: Self.providerID,
            imageSize: CGSize(width: cg.width, height: cg.height)
        )
    }

    // MARK: - 私有

    /// NormalizedLandmark → 槽位（confidence 恒 1：MediaPipe 主路径 468 点全部实测，
    /// `slotCoverage == 1.0` 是文档化契约；visibility/presence 仅用于 blendshapes 场景）。
    private static func landmark(_ l: NormalizedLandmark) -> Landmark3D {
        Landmark3D(x: l.x, y: l.y, z: l.z, confidence: 1)
    }

    private func landmarkerIfNeeded() throws -> FaceLandmarker {
        if let landmarker { return landmarker }
        guard let modelPath = Self.modelURL()?.path else {
            throw FaceGeometryError.inferenceFailed(
                "face_landmarker.task 不在 Bundle.module（资源未随包入仓？）")
        }
        let options = FaceLandmarkerOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.runningMode = .image
        options.numFaces = 1
        // blendshapes / 变换矩阵本工程不用（位姿走共享 Horn 解算，语义不漂移）
        options.outputFaceBlendshapes = false
        options.outputFacialTransformationMatrixes = false
        do {
            let l = try FaceLandmarker(options: options)
            landmarker = l
            availability.set(true)
            stats.modelLoads += 1
            return l
        } catch {
            throw FaceGeometryError.inferenceFailed("FaceLandmarker 初始化失败: \(error)")
        }
    }

    private func contextIfNeeded() -> CIContext {
        if let context { return context }
        // 复用同一 context：R006 踩过「每次调用新建 CIContext」的坑
        let c = CIContext(options: [.cacheIntermediates: false])
        context = c
        return c
    }

    /// 模型文件定位。SPM `.copy("Resources/…")` 的落盘布局在不同工具链版本上
    /// 有「bundle 根 / Resources 子目录」两种先例 —— 两种都试，不赌单一布局。
    private static func modelURL() -> URL? {
        Bundle.module.url(forResource: "face_landmarker", withExtension: "task")
            ?? Bundle.module.url(
                forResource: "face_landmarker", withExtension: "task", subdirectory: "Resources")
    }
}
