import Foundation

// 拾光 · R010-B 系统集成 · shared/AppGroup.swift
// 编译目标：主 App Target + Widget Extension Target（双方共用）

/// 应用组（App Group）配置中心。
///
/// 主 App 与 Widget Extension 通过 App Group 共享容器交换
/// 「最近编辑」清单与缩略图文件（Widget 无法直接访问相册，
///  这是 WidgetKit 的标准做法）。
///
/// ⚠️ 合入主工程时只需改这一个常量，并同步修改双方 entitlements
///    （见 xcode/ShiguangWidget.entitlements 与主 App entitlements）：
public enum AppGroup {
    /// 应用组标识（请替换为与主工程一致的值）
    public static let identifier = "group.com.shiguang.app"

    /// 共享容器根目录；未配置 App Group 时返回 nil。
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// 缩略图子目录
    public static var thumbnailsDirectoryURL: URL? {
        containerURL?.appendingPathComponent("Thumbnails", isDirectory: true)
    }
}
