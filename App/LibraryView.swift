import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import PhotoIO
import EditKit
import DesignSystem

// MARK: - 照片库模型

@Observable @MainActor
final class LibraryModel {
    var photos: [ImportedPhoto] = []
    var store: FilePhotoStore?
    var importing = false

    func loadStore() async {
        guard store == nil else { return }
        store = try? FilePhotoStore()
        await seedDemoPhotoIfNeeded()
        await seedDemoPhotosIfNeeded()
        await reload()
    }

    /// R009/R010 CI 截图深链：截图模式下图库为空时自动生成一张演示照片，
    /// 供编辑器直接打开（生产启动无此参数，不走本路径）。
    func seedDemoPhotoIfNeeded() async {
        guard ScreenshotLaunch.isGradingPanelRun || ScreenshotLaunch.isHistoryPanelRun else { return }
        guard let store, photos.isEmpty else { return }
        if let data = DemoPhoto.jpegData() {
            _ = try? await store.save(imageData: data, preferredExtension: "jpg")
        }
    }

    /// R010 CI 截图深链：批量截图模式下预置多张演示照片
    /// （图库多选 + 批量面板需要多张可勾选的照片；尺寸取 2160×1440，
    /// 让「进行中」窗口足够宽，两次定时截图能分别捕获进度态与结果态）。
    func seedDemoPhotosIfNeeded(count: Int = 8) async {
        guard ScreenshotLaunch.isBatchRun else { return }
        guard let store, photos.isEmpty else { return }
        for _ in 0..<count {
            if let data = DemoPhoto.jpegData(width: 2160, height: 1440) {
                _ = try? await store.save(imageData: data, preferredExtension: "jpg")
            }
        }
    }

    func reload() async {
        guard let store else { return }
        photos = (try? await store.allPhotos()) ?? []
    }

    /// PhotosPicker 结果 → 沙盒拷贝（无需相册权限 — 合规 A2）
    func importPicked(_ items: [PhotosPickerItem]) async {
        guard let store, !items.isEmpty else { return }
        importing = true
        defer { importing = false }
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
            _ = try? await store.save(imageData: data, preferredExtension: ext)
        }
        await reload()
    }

    func delete(_ photo: ImportedPhoto) async {
        guard let store else { return }
        _ = try? await store.delete(photo)
        await reload()
    }
}

// MARK: - 照片库视图

struct LibraryView: View {
    @State private var model = LibraryModel()
    @State private var pickerItems: [PhotosPickerItem] = []
    /// P1-F：设置页（含隐藏的性能诊断开关）。
    @State private var showSettings = false
    /// R010：多选模式（勾选多张 → 批量处理）。
    @State private var isSelecting = false
    /// 已勾选的照片 id 集合。
    @State private var selection: Set<UUID> = []
    /// R010：批量处理面板。
    @State private var showBatch = false
    /// 批量面板的预设来源（用户自定义预设与编辑器共用同一份持久化）。
    @State private var recipeStore = RecipeStore()

    var body: some View {
        NavigationStack {
            Group {
                if ScreenshotLaunch.isHistoryPanelRun, let photo = model.photos.first {
                    // R010 CI 截图深链：直接进编辑器（初始分级由
                    // applyInitialDebugStateIfNeeded 的历史分支自行施加，
                    // 顺带构成两步真实历史），并弹出历史面板。
                    EditorView(photo: photo, store: model.store, initialPanelMode: .grading)
                } else if ScreenshotLaunch.isGradingPanelRun, let photo = model.photos.first {
                    // R009 CI 截图深链：直接进编辑器并落到「色彩 → 色轮分级」，
                    // 附带一份非恒等分级让色轮指示点在截图里可见。
                    EditorView(
                        photo: photo,
                        store: model.store,
                        initialPanelMode: .grading,
                        initialGrading: ColorGrading(
                            shadows: ColorWheel(hue: 210, saturation: 30),
                            midtones: ColorWheel(hue: 95, saturation: 45),
                            highlights: ColorWheel(hue: 45, saturation: 35),
                            blending: 85,
                            balance: 10
                        )
                    )
                } else if model.photos.isEmpty {
                    emptyState
                } else {
                    photoGrid
                }
            }
            // P1-C（R007d）：根导航容器显式深空黑 —— 空态（ContentUnavailableView）
            // 与网格滚动区都不再透出系统窗口底色（浅色设备上的「全局白底」根因）。
            .background(DS.Brand.void)
            .navigationTitle("拾光")
            // 新增入口唯一化（R007a P0-2）：标题栏右上不再放加号，
            // 只保留右下角大按钮（下方 overlay），空态与非空态都是同一入口。
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if model.importing {
                        ProgressView()
                    }
                    if isSelecting {
                        // R010 多选态：全选 + 取消（批量入口在底部条）
                        Button {
                            selection = Set(model.photos.map(\.id))
                        } label: {
                            Text("全选")
                        }
                        .disabled(model.photos.isEmpty)

                        Button {
                            exitSelectionMode()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("取消多选")
                    } else {
                        // R010：多选入口（批量处理前置）。
                        Button {
                            enterSelectionMode()
                        } label: {
                            Image(systemName: "checklist")
                        }
                        .accessibilityLabel("多选")
                        .disabled(model.photos.isEmpty)

                        // P1-F：设置入口（齿轮）。设置页内连点版本号 7 次解锁性能诊断。
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("设置")
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // 多选态隐藏新增按钮（底部让位给批量条）
                if !isSelecting {
                    importButton
                }
            }
            .overlay(alignment: .bottom) {
                if isSelecting && !selection.isEmpty {
                    batchActionBar
                }
            }
            .navigationDestination(for: ImportedPhoto.self) { photo in
                EditorView(photo: photo, store: model.store)
            }
            .sheet(isPresented: $showSettings) {
                SettingsSheet()
            }
            .sheet(isPresented: $showBatch) {
                batchSheet
            }
            .onChange(of: pickerItems) { _, items in
                let picked = items
                pickerItems = []
                Task { await model.importPicked(picked) }
            }
            .task {
                await model.loadStore()
                // R010 CI 截图深链：演示照片就位后进入多选态（全选）；
                // config/run 模式再打开批量面板（run 模式由面板自动开跑）。
                if let mode = ScreenshotLaunch.batchMode, !model.photos.isEmpty {
                    isSelecting = true
                    selection = Set(model.photos.map(\.id))
                    if mode != .select {
                        showBatch = true
                    }
                }
            }
        }
    }

    // MARK: R010：多选模式

    private func enterSelectionMode() {
        isSelecting = true
    }

    private func exitSelectionMode() {
        isSelecting = false
        selection = []
    }

    private func toggleSelection(_ photo: ImportedPhoto) {
        if selection.contains(photo.id) {
            selection.remove(photo.id)
        } else {
            selection.insert(photo.id)
        }
    }

    /// 底部批量条：已选数量 + 「批量处理」入口。
    private var batchActionBar: some View {
        HStack(spacing: DS.Spacing.md) {
            Text("已选 \(selection.count) 张")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            Button {
                showBatch = true
            } label: {
                Label("批量处理", systemImage: "square.stack.3d.up")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.vertical, DS.Spacing.sm)
                    .background(Capsule().fill(DS.accent))
            }
            .accessibilityLabel("批量处理已选照片")
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.bottom, DS.Spacing.sm)
    }

    /// 批量面板内容（`@ViewBuilder`：store 就绪前不展示 —— 实践中照片来自
    /// store，能进多选态即说明 store 已就绪）。
    @ViewBuilder
    private var batchSheet: some View {
        if let store = model.store {
            BatchSheet(
                model: BatchProcessModel(
                    photos: model.photos.filter { selection.contains($0.id) },
                    recipes: BuiltinRecipes.all + recipeStore.userRecipes
                ),
                store: store,
                // R010 CI 截图深链：run 模式自动开跑，分两次定时截图
                // 分别捕获「进行中（进度条）」与「结果」两个状态
                autoStart: ScreenshotLaunch.batchMode == .run
            )
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("开始修图", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("从照片库导入照片开始编辑。所有处理都在你的设备本地完成。")
        }
    }

    /// 唯一的新增入口（右下角 56pt 大按钮，空态与非空态共用 — R007a P0-2）。
    private var importButton: some View {
        PhotosPicker(selection: $pickerItems, matching: .images) {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(DS.accent))
                .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
        }
        .accessibilityLabel("导入照片")
        .accessibilityHint("从系统照片库选择照片并导入到拾光")
        .padding(.trailing, DS.Spacing.md)
        .padding(.bottom, DS.Spacing.lg)
    }

    private var photoGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 110), spacing: DS.Spacing.sm)],
                spacing: DS.Spacing.sm
            ) {
                ForEach(model.photos) { photo in
                    if isSelecting {
                        // R010 多选态：点格子 = 勾选/取消勾选（不导航）
                        Button {
                            toggleSelection(photo)
                        } label: {
                            PhotoCell(
                                photo: photo,
                                store: model.store,
                                showSelectionBadge: true,
                                isSelected: selection.contains(photo.id)
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink(value: photo) {
                            PhotoCell(photo: photo, store: model.store)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                Task { await model.delete(photo) }
                            } label: {
                                Label("从拾光移除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, DS.Spacing.sm)
            // 给右下角新增按钮留出高度，避免遮住最后一行
            .padding(.bottom, 92)
        }
    }
}

// MARK: - 照片格子

private struct PhotoCell: View {
    let photo: ImportedPhoto
    let store: FilePhotoStore?
    /// R010 多选态：是否显示勾选徽标（空态也要显示空心圈）。
    var showSelectionBadge = false
    var isSelected = false
    @State private var thumbnail: UIImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
            }
        }
        .frame(height: 110)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: DS.Radius.small)
                    .stroke(DS.accent, lineWidth: 3)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showSelectionBadge {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? DS.accent : .white)
                    .shadow(color: .black.opacity(0.45), radius: 2)
                    .padding(DS.Spacing.xs)
            }
        }
        .task {
            thumbnail = store?.thumbnailCGImage(for: photo, maxPixel: 300)
                .map { UIImage(cgImage: $0) }
        }
    }
}
