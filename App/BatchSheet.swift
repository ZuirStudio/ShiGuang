import SwiftUI
import UIKit
import PhotoIO
import DesignSystem

// MARK: - 批量处理面板（R010）

/// 批量修图入口：选预设 → 开始处理 → 进度 → 结果。
///
/// 三种状态一屏流转（配置 / 进行中 / 结果），全部由 `BatchProcessModel`
/// 的 `@Observable` 状态驱动；本视图不碰渲染与导出的任何细节。
struct BatchSheet: View {
    let model: BatchProcessModel
    let store: FilePhotoStore?

    /// R010 CI 截图深链：打开即自动开始处理（生产路径恒为 false）。
    var autoStart: Bool = false

    @Environment(\.dismiss) private var dismiss
    /// 深链只自动触发一次（onAppear 可能因状态变化重复触发）。
    @State private var autoStarted = false

    var body: some View {
        NavigationStack {
            content
                .background(DS.Brand.void)
                .navigationTitle("批量处理")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(DS.Brand.void, for: .navigationBar)
                .toolbar { toolbarContent }
        }
        // 与图库/编辑器一致的深色外观
        .environment(\.colorScheme, .dark)
        .onAppear {
            guard autoStart, !autoStarted else { return }
            autoStarted = true
            model.start(store: store)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isRunning {
            runningView
        } else if model.stage == .done {
            resultView
        } else {
            configView
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if model.isRunning {
                Button("取消") { model.cancel() }
            } else {
                Button("关闭") { dismiss() }
            }
        }
    }

    // MARK: 配置态：照片 + 预设选择

    private var configView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    photoStrip
                    recipePicker
                }
                .padding(DS.Spacing.md)
            }
            startBar
        }
    }

    /// 已选照片缩略图横条（数量 + 全选来源由图库多选态决定）。
    private var photoStrip: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("已选 \(model.photos.count) 张照片")
                .font(DS.Typography.panelTitle)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Spacing.sm) {
                    ForEach(model.photos) { photo in
                        BatchPhotoThumb(photo: photo, store: store)
                    }
                }
            }
        }
    }

    /// 预设列表（内置 + 用户自定义；单选）。
    private var recipePicker: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("选择预设")
                .font(DS.Typography.panelTitle)
                .foregroundStyle(.secondary)
            VStack(spacing: DS.Spacing.xs) {
                ForEach(model.recipes) { recipe in
                    Button {
                        model.selectedRecipeID = recipe.id
                    } label: {
                        HStack(spacing: DS.Spacing.sm) {
                            Image(systemName: recipe.id == model.selectedRecipeID
                                  ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(recipe.id == model.selectedRecipeID ? DS.accent : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(recipe.name)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Text("\(recipe.operations.count) 项调整")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, DS.Spacing.xs)
                        .padding(.horizontal, DS.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.small)
                                .fill(recipe.id == model.selectedRecipeID
                                      ? DS.accent.opacity(0.16) : Color.white.opacity(0.06))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 底部开始条（预设强度沿用预设自带值；导出格式固定 JPEG 高质量原尺寸）。
    private var startBar: some View {
        VStack(spacing: DS.Spacing.sm) {
            if let errorText = model.errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button {
                model.start(store: store)
            } label: {
                Text("开始处理")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Spacing.sm)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.medium).fill(DS.accent))
            }
            .disabled(!model.canStart)
            .opacity(model.canStart ? 1 : 0.5)
            .padding(.horizontal, DS.Spacing.md)
            .padding(.bottom, DS.Spacing.md)
        }
    }

    // MARK: 进行中：进度条

    private var runningView: some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 44))
                .foregroundStyle(DS.accent)
            Text(model.phase.isEmpty ? "正在准备" : model.phase)
                .font(.title3.weight(.semibold))
            ProgressView(value: model.fraction)
                .progressViewStyle(.linear)
                .frame(maxWidth: 320)
            Text("\(Int(model.fraction * 100))%")
                .font(.system(.title2, design: .rounded).weight(.bold).monospacedDigit())
                .foregroundStyle(DS.accent)
            Text("后台并发处理中，可切到其它应用 —— 进度会同步到灵动岛与锁屏。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.Spacing.xl)
            Spacer()
        }
        .padding(DS.Spacing.lg)
    }

    // MARK: 结果态：汇总

    private var resultView: some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()
            Image(systemName: model.failureCount == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(model.failureCount == 0 ? .green : .orange)
            Text("处理完成")
                .font(.title2.weight(.semibold))
            VStack(spacing: DS.Spacing.xs) {
                summaryRow(icon: "checkmark.circle", color: .green,
                           text: "成功 \(model.successCount) 张")
                if model.failureCount > 0 {
                    summaryRow(icon: "xmark.circle", color: .red,
                               text: "失败 \(model.failureCount) 张")
                }
                if model.savedCount > 0 {
                    summaryRow(icon: "photo.on.rectangle.angled", color: DS.accent,
                               text: "已存回照片库 \(model.savedCount) 张")
                }
            }
            .font(.body)
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("完成")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Spacing.sm)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.medium).fill(DS.accent))
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.bottom, DS.Spacing.lg)
        }
    }

    private func summaryRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - 批量照片缩略图

/// 批量面板里的单张缩略图（与图库 PhotoCell 同路径：ImageIO 降采样，异步加载）。
private struct BatchPhotoThumb: View {
    let photo: ImportedPhoto
    let store: FilePhotoStore?
    @State private var thumbnail: UIImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small))
        .task {
            thumbnail = store?.thumbnailCGImage(for: photo, maxPixel: 160)
                .map { UIImage(cgImage: $0) }
        }
    }
}
