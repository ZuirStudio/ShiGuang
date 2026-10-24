import Foundation
import CoreGraphics
import CoreImage
import Vision
import os
import RenderKit
import FaceGeometry

// MARK: - Vision 人脸地标兜底 Provider（v1.5.0 Card 1 / P0）
//
// 定位：**兜底轨**。FaceML 的 MediaPipe 主路径不可用时（模型未入包/加载失败），
// 本 Provider 保证「检测人脸几何」能力永远存在（注册表不变量：Vision 轨常驻）。
//
// 能力边界（诚实声明，消费者按 `FaceGeometry.slotCoverage` 判断，≈0.32）：
// - 只填 **152 个外壳槽位**（眼/眉/轮廓/唇/鼻），内部密集网格槽位为零 ——
//   Vision 各区域点数远少于 MediaPipe 槽位（眼 6 vs 16 等），经弧长重采样映射；
// - 虹膜槽位为空（`irisLandmarks == []`）：MediaPipe 478 输出才携带 10 个虹膜点；
// - 位姿只能解 **roll**（双眼连线倾角），pitch/yaw 置 0、confidence 折半 ——
//   2D 观测不假装能解 3D（HeadPose 文档同此约定）；
// - 语义对齐不保证逐点精确（眉弓两段连接序 vs Vision 整条折线等）——
//   兜底只用于圈定面部区域（Card 2 液化护栏），不用于渲染。
//
// 与 `VisionPersonSegmenter` 同构（R007b-1 模式）：actor 串行推理、请求/context
// 只建一次、os_signpost + 累加器、降采样到工作分辨率。
public actor VisionLandmarksProvider: FaceGeometryProviding {
    /// 稳定标识（注册表键 / 诊断显示）。
    public static let providerID = "vision.landmarks.rev3"

    /// 协议要求的实例属性（静态常量不满足实例成员要求）。
    /// nonisolated：只读静态常量，不触达 actor 隔离状态。
    public nonisolated var providerID: String { Self.providerID }

    /// 共享实例（进程内只注册一次）。
    public static let shared = VisionLandmarksProvider()

    /// 推理输入最长边。地标对分辨率不敏感，1024 已足够且显著快于全尺寸
    /// （与 `VisionPersonSegmenter.workingLongEdge` 一致，同一套降采样纪律）。
    public static let workingLongEdge: CGFloat = 1024

    /// 2D 兜底位姿的置信度：只解出 roll（三角中一角），pitch/yaw 未知 → 折半。
    /// 消费者看到 < 1 的 pose.confidence 即知「此姿态不可用于 3D 决策」。
    public static let twoDPoseConfidence: Float = 0.5

    /// 运行期统计（`snapshot()` 返回；供报告与诊断引用真实数字）。
    public struct Stats: Sendable, Equatable {
        public var requestCreations = 0
        public var inferences = 0
        public var faceFound = 0
        public var noFace = 0
        public var failures = 0
        public var firstLoadMillis = 0.0
        public var lastInferenceMillis = 0.0
        public var maxInferenceMillis = 0.0
        public var totalInferenceMillis = 0.0
        /// 最近一次实测槽位覆盖率（0...1；未测量 = -1）。Vision 兜底 ≈ 152/468 ≈ 0.32。
        public var lastSlotCoverage: Float = -1
        public var meanInferenceMillis: Double {
            inferences > 0 ? totalInferenceMillis / Double(inferences) : 0
        }
    }

    private var request: VNDetectFaceLandmarksRequest?
    private var context: CIContext?
    private var stats = Stats()
    private let log = OSLog(subsystem: "studio.zuir.shiguang", category: "faceGeometry")

    public init() {}

    /// 运行期可用性。部署目标 iOS 27.0（VNDetectFaceLandmarksRequest Rev3 = iOS 15+
    /// 起提供，含瞳孔），故恒为 true；仍保留为方法，与 `VisionPersonSegmenter` 对齐，
    /// 方便将来/CI 如实上报「请求真的能创建」。
    ///
    /// nonisolated：协议 `isAvailable()` 为非隔离要求（诊断 UI 在任意隔离域同步查询），
    /// 恒真常量不触达 actor 隔离状态，满足要求无需 await。
    public nonisolated func isAvailable() -> Bool { true }

    /// 读取累计统计。
    public func snapshot() -> Stats { stats }

    /// 只创建请求（不计推理），用于单独测量「首次加载」成本。
    @discardableResult
    public func warmUp() -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        _ = requestIfNeeded()
        _ = contextIfNeeded()
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    }

    /// 检测人脸几何。返回 nil = **未检出人脸**（调用方据此降级，不视为错误）。
    public func detect(_ boxed: SendableSegmentImage) async throws -> FaceGeometry? {
        let image = boxed.image
        let t0 = DispatchTime.now().uptimeNanoseconds
        let req = requestIfNeeded()
        let ctx = contextIfNeeded()

        let extent = image.extent
        guard extent.width >= 2, extent.height >= 2, extent.isInfinite == false,
              !extent.isEmpty else {
            throw FaceGeometryError.invalidInput
        }

        // 1) 降采样到工作分辨率（地标为归一化坐标，缩放不改变映射结果）
        let longEdge = max(extent.width, extent.height)
        let scale = min(1, Self.workingLongEdge / longEdge)
        let working = scale < 1
            ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : image

        // 出图点带尺寸与上下文埋点（R007d 纪律：性能结论不靠代码推断）
        guard let cg = PerfSignpost.shared.measure(
            .cgImage,
            detail: String(format: "faceGeometryInfer %dx%d",
                           Int(working.extent.width), Int(working.extent.height)),
            { ctx.createCGImage(working, from: working.extent) }
        ) else {
            throw FaceGeometryError.invalidInput
        }

        // 2) Vision 推理（同步；actor 保证串行，不会并发覆写同一请求的输出缓冲）
        let signpostID = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "faceGeometryInfer", signpostID: signpostID)
        defer { os_signpost(.end, log: log, name: "faceGeometryInfer", signpostID: signpostID) }

        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        do {
            try handler.perform([req])
        } catch {
            stats.failures += 1
            throw FaceGeometryError.inferenceFailed(String(describing: error))
        }

        // 取第一张脸（Vision 不保证按面积排序；编辑场景单主体为主，与
        // `VisionPersonSegmenter` 的 `.first` 口径一致）
        guard let observation = req.results?.first as? VNFaceObservation,
              let landmarks2D = observation.landmarks else {
            stats.noFace += 1
            return nil
        }

        // 3) 区域折线 → 468 槽位（坐标转换 + 弧长重采样，见 FaceGeometry 纯逻辑层）
        let box = observation.boundingBox   // 图像归一化、左下原点（Vision 契约）
        var regions: LandmarkSlotMap.RegionInput = [:]
        if let c = landmarks2D.faceContour { regions[.faceOval] = Self.regionPoints(c, inFaceBox: box) }
        if let r = landmarks2D.rightEye { regions[.rightEye] = Self.regionPoints(r, inFaceBox: box) }
        if let l = landmarks2D.leftEye { regions[.leftEye] = Self.regionPoints(l, inFaceBox: box) }
        if let r = landmarks2D.rightEyebrow { regions[.rightEyebrow] = Self.regionPoints(r, inFaceBox: box) }
        if let l = landmarks2D.leftEyebrow { regions[.leftEyebrow] = Self.regionPoints(l, inFaceBox: box) }
        if let o = landmarks2D.outerLips { regions[.lips] = Self.regionPoints(o, inFaceBox: box) }
        if let i = landmarks2D.innerLips { regions[.innerLips] = Self.regionPoints(i, inFaceBox: box) }
        if let n = landmarks2D.nose { regions[.nose] = Self.regionPoints(n, inFaceBox: box) }
        if let n = landmarks2D.noseCrest { regions[.noseCrest] = Self.regionPoints(n, inFaceBox: box) }

        let slots = LandmarkSlotMap.assign(regions)
        let coverage = Float(slots.count(where: \.isMeasured)) / Float(FaceGeometry.slotCount)
        stats.lastSlotCoverage = coverage
        os_signpost(.event, log: log, name: "slotCoverage",
                    "%{public}d-permille", Int((coverage * 1000).rounded()))

        // 检出观测但零实测槽位（病态输出）→ 按未检出处理，不产出空壳几何
        guard coverage > 0 else {
            stats.noFace += 1
            return nil
        }

        // 4) 位姿：2D 兜底只解 roll（双眼形心连线）；pitch/yaw 置 0、置信度折半
        let pose = Self.poseFromRegions(regions)

        // 5) 包围盒翻转到左上原点（FaceGeometry 契约；与 CIImage 像素方向一致）
        let imageBox = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)

        // 6) 统计
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        stats.inferences += 1
        stats.faceFound += 1
        stats.lastInferenceMillis = ms
        stats.maxInferenceMillis = max(stats.maxInferenceMillis, ms)
        stats.totalInferenceMillis += ms
        if stats.firstLoadMillis == 0 { stats.firstLoadMillis = ms }

        // 7) 组装（assign 恒产 468 槽位，init 的 468 校验不会失败）
        return try FaceGeometry(
            landmarks: slots,
            irisLandmarks: [],   // 诚实边界：Vision 不产出虹膜点（仅 MediaPipe 478 携带）
            pose: pose,
            boundingBox: imageBox,
            providerID: Self.providerID,
            imageSize: CGSize(width: cg.width, height: cg.height)
        )
    }

    // MARK: - 私有

    /// Vision 区域折线（框内归一化、左下原点）→ 图像归一化左上原点槽位输入。
    private static func regionPoints(_ region: VNFaceLandmarkRegion2D, inFaceBox box: CGRect) -> [Landmark3D] {
        region.normalizedPoints.map { p in
            let ip = LandmarkSlotMap.visionToImageNormalized(p, inFaceBox: box)
            return Landmark3D(x: Float(ip.x), y: Float(ip.y), z: 0, confidence: 1)
        }
    }

    /// 双眼形心 → roll（弧度）。缺任一眼区域 → 全零姿态（confidence 0，消费者可判不可用）。
    private static func poseFromRegions(_ regions: LandmarkSlotMap.RegionInput) -> HeadPose {
        guard let right = regions[.rightEye], let left = regions[.leftEye],
              let rc = centroid(of: right), let lc = centroid(of: left) else {
            return .zero
        }
        let roll = HeadPoseSolver.rollFromEyeLine(rightEye: rc, leftEye: lc)
        return HeadPose(roll: roll, pitch: 0, yaw: 0, confidence: Self.twoDPoseConfidence)
    }

    /// 折线形心（2D；z 忽略）。
    private static func centroid(of points: [Landmark3D]) -> Landmark3D? {
        guard !points.isEmpty else { return nil }
        var sx = Float(0), sy = Float(0)
        for p in points { sx += p.x; sy += p.y }
        let n = Float(points.count)
        return Landmark3D(x: sx / n, y: sy / n, z: 0, confidence: 1)
    }

    private func requestIfNeeded() -> VNDetectFaceLandmarksRequest {
        if let request { return request }
        // 显式钉死 Rev3（iOS 15+，含瞳孔时代拓扑）：providerID 即 "rev3"，
        // 行为不随系统默认修订版漂移 —— 契约确定性与单测锁定同一纪律。
        // （若不钉，新版 OS 默认修订可能改变各区域点数，重采样结果随之漂移。）
        let r = VNDetectFaceLandmarksRequest()
        r.revision = VNDetectFaceLandmarksRequestRevision3
        request = r
        stats.requestCreations += 1
        return r
    }

    private func contextIfNeeded() -> CIContext {
        if let context { return context }
        // 复用同一 context：R006 踩过「每次调用新建 CIContext」的坑
        let c = CIContext(options: [.cacheIntermediates: false])
        context = c
        return c
    }
}
