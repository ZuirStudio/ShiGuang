import WidgetKit
import SwiftUI

// 拾光 · R010-B 系统集成 · widget/RecentPhotosProvider.swift
// 编译目标：仅 Widget Extension Target
//
// 时间线提供器：从 App Group 共享容器读取「最近编辑」清单。
//
// 更新策略：.never（不自动过期）。
//   数据变化完全由主 App 显式触发 reloadAllTimelines()，
//   避免无谓的后台刷新、省电。

/// Widget 展示用的照片模型
struct WidgetPhoto: Identifiable, Equatable {
    var id: String
    var thumbnailURL: URL
    var presetName: String?
}

struct RecentPhotosEntry: TimelineEntry {
    let date: Date
    let photos: [WidgetPhoto]
}

struct RecentPhotosProvider: TimelineProvider {

    /// 占位（Widget 画廊 / 添加 Widget 时展示）
    func placeholder(in context: Context) -> RecentPhotosEntry {
        RecentPhotosEntry(date: Date(), photos: Self.previewPhotos)
    }

    func getSnapshot(in context: Context, completion: @escaping (RecentPhotosEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentPhotosEntry>) -> Void) {
        completion(Timeline(entries: [loadEntry()], policy: .never))
    }

    /// 从共享容器读取最近 3 条记录
    private func loadEntry() -> RecentPhotosEntry {
        let records = RecentEditsStore.shared.recentRecords(limit: 3)
        let photos: [WidgetPhoto] = records.compactMap { record in
            guard let url = RecentEditsStore.shared.thumbnailURL(for: record) else { return nil }
            return WidgetPhoto(id: record.id, thumbnailURL: url, presetName: record.presetName)
        }
        return RecentPhotosEntry(date: Date(), photos: photos)
    }

    /// 预览用占位照片（缩略图路径不存在，视图会渲染渐变占位）
    static var previewPhotos: [WidgetPhoto] {
        (0..<3).map { index in
            WidgetPhoto(
                id: "preview-\(index)",
                thumbnailURL: URL(fileURLWithPath: NSTemporaryDirectory()),
                presetName: nil
            )
        }
    }
}
