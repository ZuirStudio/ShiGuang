import Foundation

// 拾光 · R010-B 系统集成 · shared/DeepLinks.swift
// 编译目标：主 App Target + Widget Extension Target（双方共用）

/// 深链目标。Widget 点击、快捷指令完成后都通过 URL 落回主 App。
public enum DeepLinkDestination: Equatable, Sendable {
    /// 打开某张照片的编辑器（Widget 点击照片）
    case editPhoto(id: String)
    /// 套用预设后打开编辑器（快捷指令「继续编辑」路径）
    case applyPreset(presetID: String, photoID: String?)
    /// 打开编辑器（不带照片）
    case openEditor
}

/// 深链协议。
///
/// URL 规范（scheme 需在主 App Info.plist 注册，见
/// xcode/Info.plist.app.additions.xml）：
///
///   shiguang://edit/<photoID>              打开某张照片的编辑器
///   shiguang://preset-export?preset=<id>   套用预设后打开编辑器（可选 &photo=<id>）
///   shiguang://editor                      打开编辑器
public enum DeepLinks {
    public static let scheme = "shiguang"

    /// 生成深链 URL
    public static func make(_ destination: DeepLinkDestination) -> URL {
        switch destination {
        case .editPhoto(let id):
            let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
            return URL(string: "\(scheme)://edit/\(escaped)")!

        case .applyPreset(let presetID, let photoID):
            var components = URLComponents()
            components.scheme = scheme
            components.host = "preset-export"
            var items = [URLQueryItem(name: "preset", value: presetID)]
            if let photoID {
                items.append(URLQueryItem(name: "photo", value: photoID))
            }
            components.queryItems = items
            return components.url ?? make(.openEditor)

        case .openEditor:
            return URL(string: "\(scheme)://editor")!
        }
    }

    /// 解析深链 URL；scheme 不匹配或参数缺失时返回 nil。
    public static func parse(_ url: URL) -> DeepLinkDestination? {
        guard url.scheme == scheme else { return nil }

        switch url.host {
        case "edit":
            // shiguang://edit/<id> → pathComponents = ["/", "<id>"]
            guard let raw = url.pathComponents.dropFirst().first, !raw.isEmpty else {
                return nil
            }
            return .editPhoto(id: raw.removingPercentEncoding ?? raw)

        case "preset-export":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let preset = query.first(where: { $0.name == "preset" })?.value,
                  !preset.isEmpty else {
                return nil
            }
            let photo = query.first(where: { $0.name == "photo" })?.value
            return .applyPreset(presetID: preset, photoID: photo)

        default:
            return .openEditor
        }
    }
}

/// 深链路由入口：主工程在 App 启动时设置 `onRoute`，
/// 在 App 的 `onOpenURL` 中调用 `handle(_:)`。
///
/// 路由目标如何导航由主工程决定（本交付不触碰 UI 主面板）。
public enum DeepLinkRouter {
    /// 把深链目标转成真实导航动作。默认空实现。
    public static var onRoute: (DeepLinkDestination) -> Void = { _ in }

    /// 解析并分发 URL。非本 App 的 URL 会被忽略。
    public static func handle(_ url: URL) {
        guard let destination = DeepLinks.parse(url) else { return }
        onRoute(destination)
    }
}
