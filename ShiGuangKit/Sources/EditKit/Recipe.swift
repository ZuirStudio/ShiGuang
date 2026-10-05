import Foundation

// MARK: - 预设

/// 预设（Recipe）：可分享的指令组合 + 应用强度。
/// - PRD 2.4：内置预设 + 用户自定义 + 强度滑杆（0-100%）
/// - 序列化格式与 EditGraph 一致，天然支持 App Intents 复放与分享导入
public struct Recipe: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var operations: [EditOperation]
    /// 应用强度 0...1；渲染时对可混合指令线性插值，结构化指令原样保留。
    public var intensity: Double

    public init(
        id: UUID = UUID(),
        name: String,
        operations: [EditOperation],
        intensity: Double = 1
    ) {
        self.id = id
        self.name = name
        self.operations = operations
        self.intensity = min(max(intensity, 0), 1)
    }

    /// 渲染时实际应用的指令序列。
    public func resolvedOperations() -> [EditOperation] {
        guard intensity < 0.999 else { return operations }
        return operations.map { $0.blended(amount: intensity) }
    }
}
