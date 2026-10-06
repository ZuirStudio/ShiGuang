import SwiftUI
import UIKit
import CoreImage
import CoreGraphics
import PhotoIO
import EditKit
import RenderKit
import AICore
import DesignSystem

// MARK: - 编辑器模型

@Observable @MainActor
final class EditorModel {
    let photo: ImportedPhoto
    let store: FilePhotoStore?
    var renderer: BasicAdjustmentRenderer
    private let context = CIContext()

    private var previewSource: CIImage?
    private var skinMaskFull: CIImage?
    private var stats: ImageStats?

    var preview: UIImage?
    var originalPreview: UIImage?
    var document = EditDocument()
    var loadFailed = false
    var isPreparingMask = false

    var canUndo: Bool { document.history.stepCount > 0 }
    var canRedo: Bool { document.history.redoSteps.isEmpty == false }

    init(
        photo: ImportedPhoto,
        store: FilePhotoStore?,
        lutProvider: (@Sendable (UUID) -> LUTCube?)? = nil
    ) {
        self.photo = photo
        self.store = store
        self.renderer = BasicAdjustmentRenderer(lutProvider: lutProvider)
        load()
        prepareSkinMask()
    }

    // MARK: 加载与掩码

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
        // 原图对比缓存（无编辑状态的预览）
        originalPreview = renderUIImage(graph: EditGraph())
        renderPreview()
        stats = previewSource.flatMap { ImageAnalyzer.analyze($0, context: context) }
    }

    /// 后台生成皮肤掩码（Vision + 肤色，端侧零联网）；完成后重新预览。
    /// 注意：CIImage 非 Sendable，须在 detached 任务内部创建，不跨界捕获。
    private func prepareSkinMask() {
        guard store != nil else { return }
        let photo = self.photo
        let store = self.store
        isPreparingMask = true
        Task { [weak self] in
            let boxed = await Task.detached(priority: .utility) {
                guard let source = store?.fullCIImage(for: photo) else { return nil }
                let ctx = CIContext()
                guard let cg = ctx.createCGImage(source, from: source.extent),
                      let maskCG = PortraitMaskAnalyzer.skinMask(for: cg)
                else { return nil }
                return SendableCGImage(image: maskCG)
            }.value
            guard let self else { return }
            self.isPreparingMask = false
            if let boxed, let mask = CIImage(cgImage: boxed.image) {
                self.skinMaskFull = mask
                self.installMaskForPreview()
                self.renderPreview()
            }
        }
    }

    private func installMaskForPreview() {
        guard let mask = skinMaskFull, let source = previewSource else { return }
        let scale = source.extent.width / mask.extent.width
        renderer.skinMask = scale < 0.999
            ? mask.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : mask
    }

    // MARK: 参数调整（直渲：拖动即时预览）

    /// 当前某参数的值（取该参数最后一条指令；缺省 0）
    func value(for parameter: EditParameter) -> Double {
        document.graph.operations.last(where: { $0.parameter == parameter })?.numericValue ?? 0
    }

    /// 滑杆 / 手势调值：图内合并 + 历史合并 + 立即渲染
    func sliderChanged(_ parameter: EditParameter, value: Double) {
        let op = EditOperation.make(parameter: parameter, value: value)
        document.graph.updateInteractive(op)
        document.history.commitInteractive(label: parameter.historyLabel, operation: op)
        renderPreview()
    }

    // MARK: AI 自动调色（端侧启发式引擎）

    /// 全自动修图：一次生成全部建议（原子历史步骤，可整体撤销再微调）
    func autoTune() {
        guard let stats else { return }
        let operations = AutoTune.autoOperations(for: stats)
        guard !operations.isEmpty else { return }
        for op in operations {
            document.graph.append(op)
        }
        document.history.commit(label: "AI 全自动修图", operations: operations)
        renderPreview()
    }

    /// 单参数 AI：只自动调整这一个参数
    func autoTuneSingle(_ parameter: EditParameter) {
        guard let stats,
              let value = AutoTune.suggestedValue(for: parameter, stats: stats)
        else { return }
        sliderChanged(parameter, value: value)
    }

    // MARK: 预设 / LUT / 导出

    func apply(recipe: Recipe, intensity: Double) {
        let effective = Recipe(name: recipe.name, operations: recipe.operations, intensity: intensity)
        let operations = effective.resolvedOperations()
        for op in operations {
            document.graph.append(op)
        }
        document.history.commit(label: "预设·\(recipe.name)", operations: operations)
        renderPreview()
    }

    func applyLUT(_ ref: LUTReference) {
        let op = EditOperation.lut(ref)
        document.graph.append(op)
        document.history.commit(label: "LUT·\(ref.name)", operations: [op])
        renderPreview()
    }

    func saveCurrentAsPreset(named name: String) -> Recipe {
        Recipe(name: name, operations: document.graph.operations, intensity: 1)
    }

    enum ExportFailure: Error, Sendable {
        case sourceUnavailable
        case renderFailed
    }

    /// 全分辨率渲染 + 导出（后台；CIContext 非 Sendable 注解 → 任务内新建）。
    /// renderer 为 struct：在 MainActor 侧先把掩码还原为全尺寸，再值捕获进任务。
    func export(options: ExportOptions) async throws -> URL {
        let graph = document.graph
        let photo = self.photo
        let store = self.store
        var renderer = self.renderer
        renderer.skinMask = skinMaskFull
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

    private func renderUIImage(graph: EditGraph) -> UIImage? {
        guard let source = previewSource else { return nil }
        let output = renderer.render(source: source, graph: graph)
        guard let cg = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// 立即渲染（拖动直出预览；真机 GPU 单遍毫秒级）
    private func renderPreview() {
        preview = renderUIImage(graph: document.graph)
    }
}

/// CGImage 不可变线程安全，跨 Task 边界用 @unchecked 包裹。
private struct SendableCGImage: @unchecked Sendable {
    let image: CGImage
}

// MARK: - 历史标签（P1.7 移入 String Catalog）

extension EditParameter {
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
        case .skinSmoothing: "磨皮"
        case .skinBrightening: "美白"
        case .lut: "LUT"
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
        case .skinSmoothing: "face.dashed"
        case .skinBrightening: "face.smiling"
        case .lut: "camera.filters"
        }
    }
}

// MARK: - 编辑器视图

/// 调色交互（致敬 Snapseed 交互模式；视觉为本项目原创设计）：
/// - 图像区**上下滑**切换调整参数
/// - **左右滑**调整当前参数值
/// - **按住**图像查看原图对比
/// - 右上可切换「滑杆模式」（精调 + VoiceOver 无障碍）
struct EditorView: View {
    @State private var model: EditorModel
    @State private var recipeStore = RecipeStore()
    @State private var lutStore = LUTStore()
    @State private var showPresets = false
    @State private var showExport = false
    @State private var useSliders = false

    // 手势状态
    @State private var activeIndex = 0
    @State private var showOriginal = false
    @State private var gestureBase: Double?

    init(photo: ImportedPhoto, store: FilePhotoStore?) {
        let luts = LUTStore()
        _lutStore = State(initialValue: luts)
        _model = State(initialValue: EditorModel(
            photo: photo,
            store: store,
            lutProvider: luts.provider
        ))
    }

    private var gestureParameters: [EditParameter] {
        EditParameter.allCases.filter { $0.isGestureAdjustable }
    }

    private var activeParameter: EditParameter {
        gestureParameters[min(activeIndex, gestureParameters.count - 1)]
    }

    var body: some View {
        VStack(spacing: 0) {
            imageArea
            bottomBar
            if useSliders {
                sliderPanel
            }
        }
        .navigationTitle("编辑")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showPresets) {
            PresetPanel(
                builtinRecipes: BuiltinRecipes.all,
                userRecipes: recipeStore.userRecipes,
                luts: lutStore.ordered,
                onApply: { recipe, intensity in
                    model.apply(recipe: recipe, intensity: intensity)
                },
                onSaveCurrent: { name in
                    let recipe = model.saveCurrentAsPreset(named: name)
                    recipeStore.save(recipe)
                },
                onDeleteUser: { recipe in
                    recipeStore.delete(recipe)
                },
                onApplyLUT: { ref in
                    model.applyLUT(ref)
                },
                onImportLUT: { url in
                    try? lutStore.importCube(from: url)
                }
            )
        }
        .sheet(isPresented: $showExport) {
            ExportSheet { options in
                try await model.export(options: options)
            }
        }
    }

    // MARK: 图像区（手势调色）

    private var imageArea: some View {
        ZStack {
            let displayImage = showOriginal ? model.originalPreview : model.preview
            if let displayImage {
                Image(uiImage: displayImage)
                    .resizable()
                    .scaledToFit()
            } else if model.loadFailed {
                ContentUnavailableView("无法加载照片", systemImage: "exclamationmark.triangle")
            } else {
                ProgressView()
            }

            // 状态角标
            VStack {
                HStack {
                    if showOriginal {
                        Label("原图", systemImage: "eye")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.thinMaterial, in: Capsule())
                            .padding(.top, 10)
                    }
                    Spacer()
                    if model.isPreparingMask {
                        ProgressView()
                            .padding(.top, 10)
                    }
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.05))
        .contentShape(Rectangle())
        // 上下滑切参数 / 左右滑调值（Snapseed 式交互模式）
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .onChanged(handleDrag)
                .onEnded { _ in gestureBase = nil }
        )
        // 按住看原图
        .onLongPressGesture(
            minimumDuration: 0.12,
            maximumDistance: 24,
            perform: {},
            onPressingChanged: { pressing in
                showOriginal = pressing
            }
        )
    }

    private func handleDrag(_ g: DragGesture.Value) {
        let parameter = activeParameter
        // 方向判定：垂直显著主导 → 切参数；否则水平调值
        let isVertical = abs(g.translation.height) > abs(g.translation.width) * 1.2
        if isVertical {
            gestureBase = nil
            let steps = Int(g.translation.height / 48)
            let newIndex = min(max(activeIndex + steps, 0), gestureParameters.count - 1)
            if newIndex != activeIndex {
                activeIndex = newIndex
            }
        } else {
            if gestureBase == nil {
                gestureBase = model.value(for: parameter)
            }
            guard let base = gestureBase else { return }
            let range = parameter.defaultRange
            let span = range.upperBound - range.lowerBound
            // 280pt 全程拖动 = 参数满量程（手感系数，后续真机调）
            let delta = g.translation.width / 280 * span
            let value = min(max(base + delta, range.lowerBound), range.upperBound)
            model.sliderChanged(parameter, value: value)
        }
    }

    // MARK: 底部信息栏（当前参数 + AI + 模式切换）

    private var bottomBar: some View {
        HStack(spacing: DS.Spacing.md) {
            Button {
                model.autoTune()
            } label: {
                Label("AI 修图", systemImage: "sparkles")
                    .font(DS.Typography.panelTitle)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("AI 全自动修图")

            Spacer()

            // 当前手势参数胶囊（原创视觉）
            VStack(spacing: 2) {
                Label(activeParameter.historyLabel, systemImage: activeParameter.icon)
                    .font(DS.Typography.sliderLabel)
                Text(formatValue(model.value(for: activeParameter)))
                    .font(DS.Typography.sliderValue)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.xs)
            .background(.regularMaterial, in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("当前参数 \(activeParameter.historyLabel)")

            Spacer()

            Button {
                withAnimation(DS.Motion.standard) {
                    useSliders.toggle()
                }
            } label: {
                Image(systemName: useSliders ? "hand.draw" : "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(useSliders ? "切换到手势调色" : "切换到滑杆精调")
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .background(.regularMaterial)
    }

    private func formatValue(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%.1f", value)
    }

    // MARK: 滑杆模式（无障碍 + 精调，按像素蛋糕式分类分组）

    private var sliderPanel: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Spacing.lg, pinnedViews: .sectionHeaders) {
                ForEach(groupedParameters.indices, id: \.self) { index in
                    let group = groupedParameters[index].0
                    let parameters = groupedParameters[index].1
                    Section {
                        VStack(spacing: DS.Spacing.md) {
                            ForEach(parameters, id: \.self) { parameter in
                                AdjustmentSliderRow(
                                    parameter: parameter,
                                    value: Binding(
                                        get: { model.value(for: parameter) },
                                        set: { model.sliderChanged(parameter, value: $0) }
                                    ),
                                    onAuto: parameter.isAutoTunable
                                        ? { model.autoTuneSingle(parameter) }
                                        : nil
                                )
                            }
                        }
                    } header: {
                        Label(group.displayName, systemImage: group.symbol)
                            .font(DS.Typography.panelTitle)
                            .foregroundStyle(.secondary)
                            .padding(.top, DS.Spacing.xs)
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.bottom, DS.Spacing.lg)
        }
        .frame(maxHeight: 300)
    }

    private var groupedParameters: [(ParameterGroup, [EditParameter])] {
        let adjustable = EditParameter.allCases.filter { $0.isGestureAdjustable }
        return ParameterGroup.allCases.map { group in
            (group, adjustable.filter { $0.group == group })
        }.filter { !$0.1.isEmpty }
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showPresets = true
            } label: {
                Image(systemName: "wand.and.rays")
            }
            .accessibilityLabel("预设与 LUT")

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
}

// MARK: - 调整滑杆行（含单参数 AI 按钮）

private struct AdjustmentSliderRow: View {
    let parameter: EditParameter
    @Binding var value: Double
    var onAuto: (() -> Void)?

    var body: some View {
        VStack(spacing: DS.Spacing.xs) {
            HStack {
                Label(parameter.historyLabel, systemImage: parameter.icon)
                    .font(DS.Typography.sliderLabel)
                Spacer()
                if let onAuto {
                    Button {
                        onAuto()
                    } label: {
                        Image(systemName: "wand.and.stars")
                            .font(.caption)
                            .foregroundStyle(DS.accent)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("AI 自动调整\(parameter.historyLabel)")
                }
                Text(value, format: .number.precision(.fractionLength(0...1)))
                    .font(DS.Typography.sliderValue)
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
            Slider(value: $value, in: parameter.defaultRange)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(parameter.historyLabel)
    }
}
