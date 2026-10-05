import Foundation

// MARK: - 端侧 AI 能力清单（ADR-005）

/// Phase 3 交付。技术路径已在 ADR-005 定案：
/// - subjectMask / faceLandmarks：Apple Vision 内置（零许可风险）
/// - skinSmoothing：Metal 引导滤波 + Vision 皮肤掩码（自有实现）
/// - inpainting：LaMa → Core ML（Apache-2.0）
/// - superResolution：Real-ESRGAN 蒸馏（BSD-3，权重许可打包前核实）
public enum AIFeature: String, Equatable, Sendable, CaseIterable {
    case subjectMask         // 主体/人像抠图
    case faceLandmarks       // 人脸地标
    case skinSmoothing       // 磨皮
    case skinBrightening     // 美白
    case inpainting          // AI 消除
    case superResolution     // 画质增强
}

/// 端侧 AI 提供方抽象：App 层依赖此协议而非具体实现，便于测试与渐进交付。
public protocol OnDeviceAIProviding: Sendable {
    /// 该功能在当前设备是否可用（模型已下载 / 算力满足）。
    func isAvailable(_ feature: AIFeature) -> Bool
}

/// 未实现占位（Phase 3 替换为 Vision/Core ML 真实现）。
public struct UnimplementedAICore: OnDeviceAIProviding {
    public init() {}
    public func isAvailable(_ feature: AIFeature) -> Bool { false }
}
