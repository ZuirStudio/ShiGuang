import Foundation
import UIKit
import WidgetKit

// 拾光 · R010-B 系统集成 · shared/RecentEditsStore.swift
// 编译目标：主 App Target + Widget Extension Target（双方共用）
//
// 用途：把「最近编辑的 N 张照片」写入 App Group 共享容器，
//       驱动桌面 Widget 展示；Widget 侧只读。
// 线程模型：串行队列 + 原子写；Widget 读到的永远是一致快照。

/// 一条最近编辑记录
public struct RecentEditRecord: Codable, Identifiable, Equatable {
    /// 照片标识（与主工程相册体系一致，用于深链回编辑器）
    public var id: String
    /// 缩略图文件名（位于 App Group 容器 Thumbnails/ 下）
    public var thumbnailFileName: String
    public var editedAt: Date
    /// 本次套用的预设（Widget 角标展示）
    public var presetID: String?
    public var presetName: String?

    public init(
        id: String,
        thumbnailFileName: String,
        editedAt: Date = Date(),
        presetID: String? = nil,
        presetName: String? = nil
    ) {
        self.id = id
        self.thumbnailFileName = thumbnailFileName
        self.editedAt = editedAt
        self.presetID = presetID
        self.presetName = presetName
    }
}

public final class RecentEditsStore {

    public static let shared = RecentEditsStore()

    private init() {}

    private let queue = DispatchQueue(label: "com.shiguang.recent-edits")
    private let manifestName = "recent-edits.json"
    /// 清单最多保留的条数（Widget 只取前 3 条）
    private let maxRecords = 20

    private var manifestURL: URL? {
        AppGroup.containerURL?.appendingPathComponent(manifestName)
    }

    // MARK: - 写入（主 App 调用）

    /// 记录一次编辑 / 导出：写缩略图 → 更新清单 → 刷新 Widget 时间线。
    ///
    /// - Parameters:
    ///   - photoID: 照片标识
    ///   - thumbnail: 缩略图 UIImage；内部压缩为最长边 400px 的 JPEG
    ///   - presetID / presetName: 本次套用的预设（可选）
    ///
    /// 说明：同照片再次编辑会去重置顶；传入 nil 缩略图且无历史记录时跳过。
    public func record(
        photoID: String,
        thumbnail: UIImage?,
        presetID: String? = nil,
        presetName: String? = nil
    ) {
        queue.async {
            guard let container = AppGroup.containerURL else {
                #if DEBUG
                print("[RecentEditsStore] App Group 未配置（identifier: \(AppGroup.identifier)），跳过记录")
                #endif
                return
            }

            let thumbsDir = AppGroup.thumbnailsDirectoryURL
                ?? container.appendingPathComponent("Thumbnails", isDirectory: true)
            try? FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)

            var records = self.loadAll()
            let previous = records.first { $0.id == photoID }
            records.removeAll { $0.id == photoID }

            // 复用旧文件名或新建；写缩略图
            var fileName = previous?.thumbnailFileName ?? UUID().uuidString + ".jpg"
            if let data = RecentEditsStore.compressThumbnail(thumbnail) {
                do {
                    try data.write(to: thumbsDir.appendingPathComponent(fileName), options: .atomic)
                } catch {
                    #if DEBUG
                    print("[RecentEditsStore] 缩略图写入失败：\(error.localizedDescription)")
                    #endif
                    // 写失败则沿用旧文件；没有旧文件则放弃记录
                    guard previous != nil else { return }
                    fileName = previous?.thumbnailFileName ?? ""
                }
            } else {
                // 无新图：沿用旧文件；没有旧文件则放弃记录
                guard let previous else { return }
                fileName = previous.thumbnailFileName
            }

            records.insert(
                RecentEditRecord(
                    id: photoID,
                    thumbnailFileName: fileName,
                    presetID: presetID,
                    presetName: presetName
                ),
                at: 0
            )

            // 裁剪超量记录并清理其缩略图
            let trimmed = Array(records.prefix(self.maxRecords))
            for dropped in records.dropFirst(self.maxRecords) {
                try? FileManager.default.removeItem(at: thumbsDir.appendingPathComponent(dropped.thumbnailFileName))
            }

            // 原子写清单
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(trimmed), let manifestURL = self.manifestURL {
                try? data.write(to: manifestURL, options: .atomic)
            }

            // 刷新 Widget 时间线
            DispatchQueue.main.async {
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    // MARK: - 读取（App / Widget 均可调用）

    /// 最近 N 条记录（默认 3 = Widget 展示数量）
    public func recentRecords(limit: Int = 3) -> [RecentEditRecord] {
        queue.sync { Array(self.loadAll().prefix(limit)) }
    }

    /// 某条记录的缩略图文件 URL
    public func thumbnailURL(for record: RecentEditRecord) -> URL? {
        let dir = AppGroup.thumbnailsDirectoryURL
            ?? AppGroup.containerURL?.appendingPathComponent("Thumbnails", isDirectory: true)
        return dir?.appendingPathComponent(record.thumbnailFileName)
    }

    // MARK: - 私有

    private func loadAll() -> [RecentEditRecord] {
        guard let url = manifestURL,
              let data = try? Data(contentsOf: url) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateEncodingStrategy = .iso8601
        return (try? decoder.decode([RecentEditRecord].self, from: data)) ?? []
    }

    /// 压缩缩略图：最长边 ≤ 400pt，JPEG 0.7。
    static func compressThumbnail(_ image: UIImage?) -> Data? {
        guard let image else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let maxSide: CGFloat = 400
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(
            width: (size.width * scale).rounded(),
            height: (size.height * scale).rounded()
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.jpegData(withCompressionQuality: 0.7) { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
