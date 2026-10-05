import Foundation

// MARK: - BYOK 云端直连（ADR-006）

/// 用户自带 Key（BYOK）的云服务商配置。
/// - App 直连用户配置的 baseURL，不经手任何中间服务器
/// - Token 存 Keychain（kSecAttrAccessibleAfterUnlockedThisDeviceOnly，不同步 iCloud）
/// - 每次上传前 App 内显式确认（合规 C4）
public struct CloudProviderConfig: Equatable, Codable, Sendable {
    public var name: String
    public var baseURL: URL
    public var modelHint: String?
    /// 路径覆盖（兼容 OpenAI 兼容中转 / 自建代理）。
    public var pathOverride: String?

    public init(
        name: String,
        baseURL: URL,
        modelHint: String? = nil,
        pathOverride: String? = nil
    ) {
        self.name = name
        self.baseURL = baseURL
        self.modelHint = modelHint
        self.pathOverride = pathOverride
    }
}

/// 云端图像编辑提供方抽象（Phase 3 交付真实实现）。
public protocol CloudEditProviding: Sendable {
    var config: CloudProviderConfig { get }
}
