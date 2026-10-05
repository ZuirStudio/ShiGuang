import SwiftUI
import EditKit
import PhotoIO
import DesignSystem

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

// MARK: - 预设面板（P2.1）

struct PresetPanel: View {
    @Environment(\.dismiss) private var dismiss
    let builtinRecipes: [Recipe]
    let userRecipes: [Recipe]
    let onApply: (Recipe, Double) -> Void
    let onSaveCurrent: (String) -> Void
    let onDeleteUser: (Recipe) -> Void

    @State private var intensity: Double = 1
    @State private var showSaveDialog = false
    @State private var newPresetName = ""

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

                Section("内置预设") {
                    ForEach(builtinRecipes) { recipe in
                        applyButton(recipe)
                    }
                }

                Section("我的预设") {
                    if userRecipes.isEmpty {
                        Text("暂无自定义预设")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(userRecipes) { recipe in
                        applyButton(recipe)
                                       .swipeActions {
                            Button(role: .destructive) {
                                onDeleteUser(recipe)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
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

    private func applyButton(_ recipe: Recipe) -> some View {
        Button {
            onApply(recipe, intensity)
            dismiss()
        } label: {
            HStack {
                Text(recipe.name)
                Spacer()
                Image(systemName: "sparkles")
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - 导出面板（P2.2）

struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// 执行导出：返回导出文件 URL
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
