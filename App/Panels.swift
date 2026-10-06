import SwiftUI
import UIKit
import UniformTypeIdentifiers
import EditKit
import RenderKit
import PhotoIO
import DesignSystem

// MARK: - LUT 存储（线程安全盒子 + 沙盒持久化）

/// 渲染线程与主线程共享的 LUT 数据盒（NSLock 保护；LUTCube 值类型安全）。
final class LUTBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cubes: [UUID: LUTCube] = [:]

    func cube(for id: UUID) -> LUTCube? {
        lock.lock()
        defer { lock.unlock() }
        return cubes[id]
    }

    func update(_ cube: LUTCube, for id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        cubes[id] = cube
    }

    func remove(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        cubes[id] = nil
    }
}

@Observable @MainActor
final class LUTStore {
    let box = LUTBox()
    private(set) var ordered: [LUTReference] = []
    /// 面向渲染器的提供方（捕获盒子引用，导入后即时生效）
    var provider: @Sendable (UUID) -> LUTCube? {
        let box = self.box
        return { id in box.cube(for: id) }
    }

    private var directory: URL?

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShiGuang/LUTs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directory = dir
        loadPersisted()
    }

    private func loadPersisted() {
        guard let dir = directory else { return }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension.lowercased() == "cube" } ?? []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let cube = try? LUTParser.parse(text)
            else { continue }
            let ref = LUTReference(
                id: uuidFromName(file.deletingPathExtension().lastPathComponent),
                name: cube.title ?? file.deletingPathExtension().lastPathComponent
            )
            box.update(cube, for: ref.id)
            ordered.append(ref)
        }
    }

    /// 导入 .cube（fileImporter 的安全作用域 URL）；拷贝到沙盒持久保存。
    @discardableResult
    func importCube(from url: URL) throws -> LUTReference {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let text = try String(contentsOf: url, encoding: .utf8)
        let cube = try LUTParser.parse(text)
        let name = cube.title ?? url.deletingPathExtension().lastPathComponent
        let ref = LUTReference(name: name)

        // 持久化（文件名用 UUID 的 hex，避免重名/特殊字符）
        if let dir = directory {
            let dest = dir.appendingPathComponent(ref.id.uuidString).appendingPathExtension("cube")
            try text.write(to: dest, atomically: true, encoding: .utf8)
        }
        box.update(cube, for: ref.id)
        ordered.append(ref)
        return ref
    }

    func delete(_ ref: LUTReference) {
        box.remove(ref.id)
        ordered.removeAll { $0.id == ref.id }
        if let dir = directory {
            let file = dir.appendingPathComponent(ref.id.uuidString).appendingPathExtension("cube")
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// 从持久化文件名重建稳定 UUID（保证跨会话 id 一致 → 编辑指令可复放）。
    private func uuidFromName(_ name: String) -> UUID {
        var hash: UInt64 = 1469598103934665603
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        var hex = String(format: "%016x%016x", hash, hash &+ 0x9E3779B97F4A7C15)
        hex.replaceSubrange(hex.startIndex...hex.index(hex.startIndex, offsetBy: 12),
                            with: String(format: "%012x", hash & 0xFFFF_FFFF_FFFF))
        // UUID 规范形态 8-4-4-4-12
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4),
                     hex.dropFirst(16).prefix(4), hex.dropFirst(20).prefix(12)]
        return UUID(uuidString: parts.joined(separator: "-")) ?? UUID()
    }
}

// MARK: - 自定义预设存储（JSON 持久化）

@Observable @MainActor
final class RecipeStore {
    private(set) var userRecipes: [Recipe] = []
    private var saveURL: URL?

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShiGuang", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("recipes.json")
        saveURL = url
        if let data = try? Data(contentsOf: url),
           let recipes = try? JSONDecoder().decode([Recipe].self, from: data) {
            userRecipes = recipes
        }
    }

    func save(_ recipe: Recipe) {
        userRecipes.insert(recipe, at: 0)
        persist()
    }

    func delete(_ recipe: Recipe) {
        userRecipes.removeAll { $0.id == recipe.id }
        persist()
    }

    private func persist() {
        guard let saveURL, let data = try? JSONEncoder().encode(userRecipes) else { return }
        try? data.write(to: saveURL, options: .atomic)
    }
}

// MARK: - 预设分类与缩略图（观感项：12 款内置预设四组视觉分组 + 真实预览）

/// 预设缩略图提供者类型别名：让**不导入 UIKit** 的文件也能声明该参数（如 `EditorModules`）。
typealias PresetThumbnailProvider = (Recipe) -> UIImage?

/// 预设分类：产品定义的视觉分组（人像 / 风光 / 电影 / 创意），用户自定义预设归入「我的」。
enum PresetCategory: String, CaseIterable, Identifiable {
    case portrait = "人像"
    case landscape = "风光"
    case film = "电影"
    case creative = "创意"
    case mine = "我的"

    var id: String { rawValue }
    var displayName: String { rawValue }

    var symbol: String {
        switch self {
        case .portrait: "person.crop.circle"
        case .landscape: "mountain.2"
        case .film: "film"
        case .creative: "sparkles"
        case .mine: "person.crop.square"
        }
    }
}

extension Recipe {
    /// 分类归属：内置 12 款按固定表映射；名称不在表内（用户自定义预设）→「我的」。
    var presetCategory: PresetCategory { Self.builtinCategoryTable[name] ?? .mine }

    private static let builtinCategoryTable: [String: PresetCategory] = [
        "通透": .portrait,
        "日系写真人像": .portrait,
        "奶油肌人像": .portrait,
        "风光大片": .landscape,
        "北欧冷调": .landscape,
        "锐利纪实": .landscape,
        "胶片": .film,
        "暖阳午后": .film,
        "褪色灰调": .film,
        "经典黑白": .creative,
        "暗夜氛围": .creative,
        "赛博霓虹": .creative,
    ]
}

/// 预设缩略图：`onAppear` 时向加载闭包索取一次（闭包内部按 `Recipe.id` 缓存），加载前显示占位。
/// 用 `onAppear` 而非 `task`：动作闭包非 @Sendable，可安全捕获主线程上的渲染闭包。
struct PresetThumbnail: View {
    let side: CGFloat
    /// 已绑定到具体预设的加载闭包（返回 nil → 显示占位）
    let load: () -> UIImage?

    @State private var image: UIImage?

    /// 显式 init：`@State private` 会让合成的 memberwise init 降级为 private，跨文件无法构造
    init(side: CGFloat, load: @escaping () -> UIImage?) {
        self.side = side
        self.load = load
        _image = State(initialValue: nil)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                    )
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
        .onAppear { if image == nil { image = load() } }
        .accessibilityHidden(true)
    }
}

// MARK: - 预设面板（P2.1 + LUT 导入）

struct PresetPanel: View {
    @Environment(\.dismiss) private var dismiss
    let builtinRecipes: [Recipe]
    let userRecipes: [Recipe]
    let luts: [LUTReference]
    let onApply: (Recipe, Double) -> Void
    let onSaveCurrent: (String) -> Void
    let onDeleteUser: (Recipe) -> Void
    let onApplyLUT: (LUTReference) -> Void
    let onImportLUT: (URL) -> Void
    /// 预设缩略图提供者（用当前照片实时渲染；nil → 显示占位）。带默认值，旧调用点不受影响。
    var thumbnail: PresetThumbnailProvider? = nil

    @State private var intensity: Double = 1
    @State private var showSaveDialog = false
    @State private var showLUTImporter = false
    @State private var newPresetName = ""
    @State private var importError: String?

    private static let cubeType: UTType =
        UTType(filenameExtension: "cube") ?? UTType.data

    /// 内置预设按分类分组（空组不显示；顺序与 `PresetCategory.allCases` 声明一致）
    private var groupedBuiltins: [(PresetCategory, [Recipe])] {
        PresetCategory.allCases
            .map { category in (category, builtinRecipes.filter { $0.presetCategory == category }) }
            .filter { !$0.1.isEmpty }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("应用强度 \(Int(intensity * 100))%")
                            .font(DS.Typography.sliderValue)
                            .foregroundStyle(.secondary)
                        Slider(value: $intensity, in: 0...1)
                    }
                } header: {
                    Text("强度")
                }

                // 12 款内置预设拆成四组视觉分组：人像 / 风光 / 电影 / 创意
                ForEach(groupedBuiltins.indices, id: \.self) { index in
                    let category = groupedBuiltins[index].0
                    let items = groupedBuiltins[index].1
                    Section {
                        ForEach(items) { recipe in
                            presetButton(recipe)
                        }
                    } header: {
                        Label(category.displayName, systemImage: category.symbol)
                    }
                }

                Section("我的预设") {
                    if userRecipes.isEmpty {
                        Text("暂无自定义预设")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(userRecipes) { recipe in
                        presetButton(recipe)
                            .swipeActions {
                                Button(role: .destructive) {
                                    onDeleteUser(recipe)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }

                Section {
                    Button {
                        showLUTImporter = true
                    } label: {
                        Label("导入 LUT（.cube）", systemImage: "square.and.arrow.down")
                    }
                    if let importError {
                        Text(importError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    ForEach(luts) { lut in
                        Button {
                            onApplyLUT(lut)
                            dismiss()
                        } label: {
                            HStack {
                                Text(lut.name)
                                Spacer()
                                Image(systemName: "camera.filters")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                } header: {
                    Text("LUT 风格")
                } footer: {
                    Text("导入你合法获取的 .cube 3D LUT 文件（相机厂商或第三方调色工具输出的通用格式）。LUT 仅在本机使用，不会上传；App 不内置任何受版权保护的 LUT。")
                }
            }
            .navigationTitle("预设")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSaveDialog = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("把当前编辑保存为预设")
                }
            }
            .fileImporter(
                isPresented: $showLUTImporter,
                allowedContentTypes: [Self.cubeType],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        onImportLUT(url)
                    }
                case .failure(let error):
                    importError = error.localizedDescription
                }
            }
            .alert("保存当前编辑为预设", isPresented: $showSaveDialog) {
                TextField("预设名称", text: $newPresetName)
                Button("保存") {
                    let name = newPresetName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        onSaveCurrent(name)
                    }
                    newPresetName = ""
                }
                Button("取消", role: .cancel) { newPresetName = "" }
            } message: {
                Text("预设将保存当前全部调整，可在任意照片上复用")
            }
        }
    }

    private func presetButton(_ recipe: Recipe) -> some View {
        Button {
            onApply(recipe, intensity)
            dismiss()
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                // 真实照片缩略图（惰性渲染 + 按 Recipe.id 缓存），替代原来的纯文字行
                PresetThumbnail(side: 44, load: { thumbnail.flatMap { $0(recipe) } })
                VStack(alignment: .leading, spacing: 2) {
                    Text(recipe.name)
                    Text(recipe.presetCategory.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: DS.Spacing.sm)
                // 语义化：原 sparkles 易被读作「收藏」→ wand.and.rays 与工具栏「预设」同义（套用）
                Image(systemName: "wand.and.rays")
                    .foregroundStyle(DS.accent)
            }
        }
        .accessibilityLabel("套用预设 \(recipe.name)，\(recipe.presetCategory.displayName)")
    }
}

// MARK: - 导出面板（P2.2）

struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onExport: (ExportOptions) async throws -> URL

    @State private var format: ExportFormat = .jpeg
    @State private var quality: Double = 0.9
    @State private var exportedURL: URL?
    @State private var isExporting = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("格式") {
                    Picker("格式", selection: $format) {
                        ForEach(ExportFormat.allCases) { fmt in
                            Text(fmt.displayName).tag(fmt)
                        }
                    }
                    .pickerStyle(.segmented)

                    if format.isLossy {
                        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                            Text("质量 \(Int(quality * 100))")
                                .font(DS.Typography.sliderValue)
                                .foregroundStyle(.secondary)
                            Slider(value: $quality, in: 0.05...1)
                        }
                    }
                }

                Section {
                    Button {
                        export()
                    } label: {
                        if isExporting {
                            HStack {
                                ProgressView()
                                Text("正在渲染全分辨率…")
                            }
                        } else {
                            Label("以当前设置导出", systemImage: "square.and.arrow.up")
                        }
                    }
                    .disabled(isExporting)
                }

                if let exportedURL {
                    Section("已导出") {
                        ShareLink(item: exportedURL) {
                            Label("分享 / 存储到…", systemImage: "square.and.arrow.up.on.square")
                        }
                        Text(exportedURL.lastPathComponent)
                            .font(DS.Typography.sliderValue)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("导出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("关闭") { dismiss() }
            }
        }
    }

    private func export() {
        isExporting = true
        errorText = nil
        Task {
            do {
                exportedURL = try await onExport(ExportOptions(format: format, quality: quality))
            } catch {
                errorText = "导出失败：\(error.localizedDescription)"
            }
            isExporting = false
        }
    }
}
