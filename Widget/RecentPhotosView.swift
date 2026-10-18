import SwiftUI
import UIKit
import WidgetKit

// 拾光 · R010-B 系统集成 · widget/RecentPhotosView.swift
// 编译目标：仅 Widget Extension Target
//
// Widget 主视图：
//   - 空态：引导用户打开 App
//   - 中尺寸：3 张并排
//   - 小尺寸：2 + 1 布局
// 每张照片可点击（widgetURL 深链），左下角显示本次预设角标。

struct RecentPhotosView: View {
    let entry: RecentPhotosEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        if entry.photos.isEmpty {
            emptyState
        } else {
            switch family {
            case .systemMedium:
                mediumLayout
            default:
                smallLayout
            }
        }
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("打开拾光")
                .font(.headline)
            Text("编辑照片后显示在这里")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(DeepLinks.make(.openEditor))
    }

    // MARK: - 中尺寸：三张并排

    private var mediumLayout: some View {
        HStack(spacing: 6) {
            ForEach(Array(entry.photos.prefix(3))) { photo in
                photoCell(photo)
            }
        }
        .padding(6)
    }

    // MARK: - 小尺寸：2 + 1

    private var smallLayout: some View {
        let photos = Array(entry.photos.prefix(3))
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                photoCell(photos[0])
                if photos.count > 1 {
                    photoCell(photos[1])
                }
            }
            if photos.count > 2 {
                HStack(spacing: 6) {
                    photoCell(photos[2])
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(6)
    }

    // MARK: - 照片单元格（点击 → 进入编辑）

    private func photoCell(_ photo: WidgetPhoto) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                PhotoThumbnailImage(url: photo.thumbnailURL)

                if let preset = photo.presetName, !preset.isEmpty {
                    Text(preset)
                        .font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(4)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .aspectRatio(1, contentMode: .fit)
        .widgetURL(DeepLinks.make(.editPhoto(id: photo.id)))
    }
}

/// 缩略图加载（App Group 容器内文件；读取失败显示渐变占位）
struct PhotoThumbnailImage: View {
    let url: URL

    var body: some View {
        if let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            LinearGradient(
                colors: [.orange.opacity(0.35), .pink.opacity(0.25)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay {
                Image(systemName: "photo")
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }
}
