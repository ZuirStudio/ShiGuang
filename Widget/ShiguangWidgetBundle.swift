import WidgetKit
import SwiftUI

// 拾光 · R010-B 系统集成 · widget/ShiguangWidgetBundle.swift
// 编译目标：仅 Widget Extension Target
//
// Widget 扩展入口。整个 Target 只允许一个 @main WidgetBundle。
//
// 组成：
//   1. RecentPhotosWidget        桌面 Widget（最近编辑 3 张照片）
//   2. ActivityConfiguration     实时活动配置（锁屏 + 灵动岛），
//                               由主 App 的耗时任务通过 ActivityKit 驱动。

@main
struct ShiguangWidgetBundle: WidgetBundle {
    var body: some Widget {
        // 桌面 Widget
        RecentPhotosWidget()

        // 实时活动：锁屏视图 + 灵动岛
        ActivityConfiguration(for: ExportProgressActivityAttributes.self) { context in
            ExportLockScreenActivityView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // 展开态 · 左
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "photo.stack")
                        .font(.title3)
                        .foregroundStyle(.orange)
                }
                // 展开态 · 右
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.total > 0 {
                        Text("\(context.state.completed)/\(context.state.total)")
                            .font(.caption)
                            .monospacedDigit()
                    } else {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(.secondary)
                    }
                }
                // 展开态 · 中
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(context.state.total > 0 ? "导出进度 \(Int(context.state.fraction * 100))%" : "正在处理…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                // 展开态 · 底
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.total > 0 {
                        ProgressView(value: context.state.fraction)
                            .progressViewStyle(.linear)
                            .tint(.orange)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(.orange)
                    }
                    Text(activityStatusText(context.state))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } compactLeading: {
                Image(systemName: "photo.stack")
                    .foregroundStyle(.orange)
            } compactTrailing: {
                if context.state.total > 0 {
                    ProgressView(value: context.state.fraction)
                        .progressViewStyle(.circular)
                        .tint(.orange)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.orange)
                }
            } minimal: {
                if context.state.total > 0 {
                    ProgressView(value: context.state.fraction)
                        .progressViewStyle(.circular)
                        .tint(.orange)
                } else {
                    Image(systemName: "photo.stack")
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

/// 灵动岛底部辅助文案
@available(iOS 16.1, *)
private func activityStatusText(
    _ state: ExportProgressActivityAttributes.ContentState
) -> String {
    if !state.currentItemName.isEmpty {
        return state.currentItemName
    }
    return state.total > 0 ? "正在导出 \(state.completed)/\(state.total)" : "正在处理…"
}
