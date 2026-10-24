import Foundation
import FaceGeometry

// MARK: - 人脸几何提供方协议 + 注册表（v1.5.0 Card 1 / P0）
//
// 架构位置（ADR-008 依赖方向 App → 全部）：
// - 协议与注册表在 **AICore**；生产兜底实现 `VisionLandmarksProvider` 同在 AICore；
//   主路径 `MediaPipeFaceMeshProvider` 在 **FaceML 本地包**（iOS-only 二进制框架
//   MediaPipeTasksVision 不能进 ShiGuangKit 包图 —— 否则 macOS `swift test`
//   解析整个包图时失败，见 docs/v1.5.0-card1-architecture.md ADR-1）。
// - 消费方（App 编辑管线 / 诊断 UI）只面对本协议；**RenderKit 禁直连 Vision/MediaPipe**
//   （铁律）——RenderKit 只消费纯逻辑层的 `FaceGeometry` 模型（Card 2 液化护栏的输入）。
//
// 与 `PersonMaskProviding` 的同构设计（R007b-1 立下的模式，刻意保持一致）：
// - **「未检出人脸」不是错误**：`detect` 返回 nil，调用方优雅降级；
// - 协议**不继承 Sendable**（测试 stub 可显式标 @unchecked；生产实现是 actor）；
// - 跨隔离传图复用 `SendableSegmentImage` 装箱（CIImage 不可变，@unchecked 成立）。

/// 人脸几何提供方（抽象层）。
///
/// 实现方契约：
/// - `landmarks` 恒 468 槽位（MediaPipe 规范槽位号）、图像归一化左上原点；
/// - 返回 nil = 未检出人脸（不是错误）；throw 只用于真实失败（输入非法 / 推理失败）；
/// - `providerID` 稳定唯一（注册表键 + 诊断显示 + 写入 `FaceGeometry.providerID`）。
public protocol FaceGeometryProviding {
    /// 提供方稳定标识。约定：`"vision.landmarks.rev3"` / `"mediapipe.face_landmarker"`。
    var providerID: String { get }

    /// 运行期可用性（模型就绪 / 系统支持）。false 时调用方应显示降级原因而非静默失败。
    func isAvailable() -> Bool

    /// 检测人脸几何。
    /// - Parameter image: 待检测图像（须为「上为正」的正立图；坐标归一化到其尺寸）。
    /// - Returns: 人脸几何；**未检出人脸返回 nil**（调用方据此降级，不视为错误）。
    func detect(_ image: SendableSegmentImage) async throws -> FaceGeometry?
}

/// 人脸几何提供方注册表（进程级、热插拔）。
///
/// 设计约束：
/// - **Vision 兜底轨常驻不可注销**：`init` 即注册 `VisionLandmarksProvider` 为主路径，
///   `unregister` 拒绝移除它 —— 保证任意时刻 `primary` 都非 nil（无脸时可降级，
///   但不存在「没有提供方」的状态）。
/// - **主路径可热替换**：FaceML 的 MediaPipe Provider 在 App 启动时（模型加载成功后）
///   `register(asPrimary: true)` 顶替 Vision；失败/不可用时 App 不注册，自动留在兜底轨。
/// - 线程安全：`NSLock` 保护字典与主路径 ID（沿用 `PerfSignpost` / `AlphaMemo` 惯例）；
///   `detect` 在锁外调用（异步推理不持锁）。
public final class FaceGeometryRegistry: @unchecked Sendable {
    /// 共享注册表。
    public static let shared = FaceGeometryRegistry()

    private let lock = NSLock()
    private var providers: [String: any FaceGeometryProviding & Sendable] = [:]
    private var primaryID: String

    /// 当前主路径提供方 ID（诊断 / UI 显示）。
    public var currentPrimaryID: String {
        lock.lock(); defer { lock.unlock() }
        return primaryID
    }

    /// 已注册的提供方 ID（字典序；仅诊断用）。
    public var registeredIDs: [String] {
        lock.lock(); defer { lock.unlock() }
        return providers.keys.sorted()
    }

    private init() {
        // 兜底轨常驻：Vision 地标（部署目标 iOS 27，Rev3 无条件可用）
        let vision = VisionLandmarksProvider.shared
        self.primaryID = VisionLandmarksProvider.providerID
        self.providers = [VisionLandmarksProvider.providerID: vision]
    }

    /// 注册（或替换同 ID 的）提供方。
    /// - Parameters:
    ///   - provider: 提供方实例（actor 天然 Sendable）。
    ///   - asPrimary: true = 同时顶替主路径（MediaPipe 启动注册用）。
    public func register(_ provider: any FaceGeometryProviding & Sendable, asPrimary: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        providers[provider.providerID] = provider
        if asPrimary { primaryID = provider.providerID }
    }

    /// 注销提供方。**Vision 兜底轨不可注销**（注册表不变量）；注销主路径时自动回退到兜底轨。
    public func unregister(id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard id != VisionLandmarksProvider.providerID else { return }
        providers.removeValue(forKey: id)
        if primaryID == id { primaryID = VisionLandmarksProvider.providerID }
    }

    /// 按 ID 取提供方（不存在返回 nil）。
    public func provider(withID id: String) -> (any FaceGeometryProviding & Sendable)? {
        lock.lock(); defer { lock.unlock() }
        return providers[id]
    }

    /// 当前主路径提供方。主路径缺失（未注册/被注销）时退回 Vision 兜底轨；
    /// 兜底轨理论上永在（init 注册 + 不可注销），末尾的 `shared` 只是防御性死代码。
    public var primary: any FaceGeometryProviding & Sendable {
        lock.lock(); defer { lock.unlock() }
        if let p = providers[primaryID] { return p }
        if let v = providers[VisionLandmarksProvider.providerID] { return v }
        return VisionLandmarksProvider.shared
    }

    /// 便捷入口：经主路径检测（App / 诊断 UI 直接调它，不自己选提供方）。
    public func detect(_ image: SendableSegmentImage) async throws -> FaceGeometry? {
        try await primary.detect(image)
    }
}
