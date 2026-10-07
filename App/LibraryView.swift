import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import PhotoIO
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
        await reload()
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

    var body: some View {
        NavigationStack {
            Group {
                if model.photos.isEmpty {
                    emptyState
                } else {
                    photoGrid
                }
            }
            .navigationTitle("拾光")
            // 新增入口唯一化（R007a P0-2）：标题栏右上不再放加号，
            // 只保留右下角大按钮（下方 overlay），空态与非空态都是同一入口。
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if model.importing {
                        ProgressView()
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                importButton
            }
            .navigationDestination(for: ImportedPhoto.self) { photo in
                EditorView(photo: photo, store: model.store)
            }
            .onChange(of: pickerItems) { _, items in
                let picked = items
                pickerItems = []
                Task { await model.importPicked(picked) }
            }
            .task { await model.loadStore() }
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
        .task {
            thumbnail = store?.thumbnailCGImage(for: photo, maxPixel: 300)
                .map { UIImage(cgImage: $0) }
        }
    }
}
