import SwiftUI
import UIKit
import CoreImage
import CoreGraphics
import PhotoIO
import EditKit
import RenderKit
import DesignSystem

// MARK: - 编辑器模型

@Observable @MainActor
final class EditorModel {
    let photo: ImportedPhoto
    let store: FilePhotoStore?
    private let renderer = BasicAdjustmentRenderer()
    private let context = CIContext()
    /// 防抖渲染任务（P1.6）：拖动期间 ~80ms 合并渲染，松手即出图
    private var renderTask: Task<Void, Never>?

    private var previewSource: CIImage?
    var preview: UIImage?
    var document = EditDocument()
    var loadFailed = false

    var canUndo: Bool { document.history.stepCount > 0 }
    var canRedo: Bool { document.history.redoSteps.isEmpty == false }

    init(photo: ImportedPhoto, store: FilePhotoStore?) {
        self.photo = photo
        self.store = store
        load()
    }

    /// 解码 + 预览降采样（长边 ≤ 1600，交互帧预算内单遍 kernel）
    private func load() {
        guard let full = store?.fullCIImage(for: photo) else {
            loadFailed = true
            return
        }
        let maxDim = max(full.extent.width, full.extent.height)
        let scale = min(1, 1600 / maxDim)
        previewSource = scale < 1
            ? full.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : full
        renderPreview()
    }

    /// 当前某参数的滑杆值（取该参数最后一条指令；缺省 0）
    func value(for parameter: EditParameter) -> Double {
        document.graph.operations.last(where: { $0.parameter == parameter })?.numericValue ?? 0
    }

    /// 滑杆连续拖动：图内合并 + 历史合并（不刷屏）+ 防抖渲染
    func sliderChanged(_ parameter: EditParameter, value: Double) {
        let op = EditOperation.make(parameter: parameter, value: value)
        document.graph.updateInteractive(op)
        document.history.commitInteractive(label: parameter.historyLabel, operation: op)
        schedulePreviewRender()
    }

    // MARK: 预设（P2.1）

    /// 应用预设（强度 0-1 实时插值），作为一个原子历史步骤提交
    func apply(recipe: Recipe, intensity: Double) {
        let effective = Recipe(name: recipe.name, operations: recipe.operations, intensity: intensity)
        let operations = effective.resolvedOperations()
        for op in operations {
            document.graph.append(op)
        }
        document.history.commit(label: "预设·\(recipe.name)", operations: operations)
        renderPreview()
    }

    /// 把当前编辑保存为自定义预设
    func saveCurrentAsPreset(named name: String) -> Recipe {
        Recipe(name: name, operations: document.graph.operations, intensity: 1)
    }

    // MARK: 导出（P2.2）

    enum ExportFailure: Error, Sendable {
        case sourceUnavailable
        case renderFailed
    }

    /// 全分辨率渲染 + 导出（后台执行；CIContext 非 Sendable 注解，导出用一次性上下文）
    func export(options: ExportOptions) async throws -> URL {
        let graph = document.graph
        let photo = self.photo
        let store = self.store
        let renderer = self.renderer
        return try await Task.detached(priority: .userInitiated) {
            guard let source = store?.fullCIImage(for: photo) else {
                throw ExportFailure.sourceUnavailable
            }
            let rendered = renderer.render(source: source, graph: graph)
            let context = CIContext()
            guard let cg = context.createCGImage(rendered, from: rendered.extent) else {
                throw ExportFailure.renderFailed
            }
            return try PhotoExporter.exportToTemporary(cg, options: options)
        }.value
    }

    // MARK: 历史

    func undo() {
        document.history.undo()
        resyncFromHistory()
    }

    func redo() {
        document.history.redo()
        resyncFromHistory()
    }

    private func resyncFromHistory() {
        document.graph = EditGraph(operations: document.history.operations)
        renderPreview()
    }

    // MARK: 渲染

    /// 拖动防抖：合并 80ms 内的连续渲染请求
    private func schedulePreviewRender() {
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            self?.renderPreview()
        }
    }

    private func renderPreview() {
        guard let source = previewSource else { return }
        let output = renderer.render(source: source, graph: document.graph)
        if let cg = context.createCGImage(output, from: output.extent) {
            preview = UIImage(cgImage: cg)
        }
    }
}

// MARK: - 历史标签（P1.7 移入 String Catalog）

private extension EditParameter {
    var historyLabel: String {
        switch self {
        case .exposure: "曝光"
        case .contrast: "对比度"
        case .highlights: "高光"
        case .shadows: "阴影"
        case .whitePoint: "白点"
        case .blackPoint: "黑点"
        case .temperature: "色温"
        case .tint: "色调"
        case .saturation: "饱和度"
        case .vibrance: "自然饱和度"
        case .clarity: "清晰度"
        case .dehaze: "去雾"
        case .sharpen: "锐化"
        case .noiseReduction: "降噪"
        case .vignette: "暗角"
        case .crop: "裁剪"
        case .straighten: "拉直"
        }
    }

    var icon: String {
        switch self {
        case .exposure: "sun.max.fill"
        case .contrast: "circle.lefthalf.filled"
        case .highlights: "sun.dust.fill"
        case .shadows: "moon.stars.fill"
        case .whitePoint: "sun.min.fill"
        case .blackPoint: "moon.fill"
        case .temperature: "thermometer.medium"
        case .tint: "drop.degreesign"
        case .saturation: "paintpalette.fill"
        case .vibrance: "wand.and.stars"
        case .clarity: "text.magnifyingglass"
        case .dehaze: "wind"
        case .sharpen: "triangle.fill"
        case .noiseReduction: "waveform.path"
        case .vignette: "circle.dashed"
        case .crop: "crop.rotate"
        case .straighten: "arrow.up.left.and.arrow.down.right"
        }
    }
}

// MARK: - 编辑器视图

struct EditorView: View {
    @State private var model: EditorModel
    @State private var recipeStore = RecipeStore()
    @State private var showPresets = false
    @State private var showExport = false
    @State private var showSavePresetDialog = false
    @State private var newPresetName = ""

    init(photo: ImportedPhoto, store: FilePhotoStore?) {
        _model = State(initialValue: EditorModel(photo: photo, store: store))
    }

    private var adjustableParameters: [EditParameter] {
        EditParameter.allCases.filter { $0 != .crop && $0 != .straighten }
    }

    var body: some View {
        VStack(spacing: 0) {
            imageArea
            controls
        }
        .navigationTitle("编辑")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showPresets = true
                } label: {
                    Image(systemName: "wand.and.rays")
                }
                .accessibilityLabel("预设")

                Button {
                    showExport = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("导出")

                Button {
                    model.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!model.canUndo)
                .accessibilityLabel("撤销")

                Button {
                    model.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!model.canRedo)
                .accessibilityLabel("重做")
            }
        }
        .sheet(isPresented: $showPresets) {
            PresetPanel(
                builtinRecipes: BuiltinRecipes.all,
                userRecipes: recipeStore.userRecipes,
                onApply: { recipe, intensity in
                    model.apply(recipe: recipe, intensity: intensity)
                },
                onSaveCurrent: { name in
                    let recipe = model.saveCurrentAsPreset(named: name)
                    recipeStore.save(recipe)
                },
                onDeleteUser: { recipe in
                    recipeStore.delete(recipe)
                }
            )
        }
        .sheet(isPresented: $showExport) {
            ExportSheet { options in
                try await model.export(options: options)
            }
        }
    }

    private var imageArea: some View {
        ZStack {
            if let preview = model.preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
            } else if model.loadFailed {
                ContentUnavailableView("无法加载照片", systemImage: "exclamationmark.triangle")
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.05))
    }

    private var controls: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.md) {
                ForEach(adjustableParameters, id: \.self) { parameter in
                    AdjustmentSliderRow(
                        parameter: parameter,
                        value: Binding(
                            get: { model.value(for: parameter) },
                            set: { model.sliderChanged(parameter, value: $0) }
                        )
                    )
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.lg)
        }
        .frame(maxHeight: 360)
        .background(.regularMaterial)
    }
}

// MARK: - 调整滑杆行

private struct AdjustmentSliderRow: View {
    let parameter: EditParameter
    @Binding var value: Double

    var body: some View {
        VStack(spacing: DS.Spacing.xs) {
            HStack {
                Label(parameter.historyLabel, systemImage: parameter.icon)
                    .font(DS.Typography.sliderLabel)
                    .foregroundStyle(.primary)
                Spacer()
                Text(value, format: .number.precision(.fractionLength(0)))
                    .font(DS.Typography.sliderValue)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            Slider(value: $value, in: parameter.defaultRange)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(parameter.historyLabel)
    }
}
