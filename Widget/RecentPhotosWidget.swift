import WidgetKit
import SwiftUI

// 拾光 · R010-B 系统集成 · widget/RecentPhotosWidget.swift
// 编译目标：仅 Widget Extension Target
//
// 桌面 Widget：展示最近编辑的 3 张照片，点击直接进入编辑。
//
// 数据流：主 App 完成编辑/导出 → RecentEditsStore 写入 App Group
//         → WidgetCenter.reloadAllTimelines() → 本 Widget 重新读取。
// 点击流：widgetURL(shiguang://edit/<id>) → 主 App onOpenURL
//         → DeepLinkRouter → 打开编辑器。

struct RecentPhotosWidget: Widget {
    let kind: String = "RecentPhotosWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RecentPhotosProvider()) { entry in
            RecentPhotosView(entry: entry)
        }
        .configurationDisplayName("最近编辑")
        .description("快速回到最近编辑的 3 张照片，点击继续编辑")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
