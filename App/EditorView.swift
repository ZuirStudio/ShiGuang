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

    /// 曲线 / HSL 画布拖动的预览防抖任务（80ms 合并一帧）。
    private var previewTask: Task<Void, Never>?
    /// 预览防抖窗口。
    static let previewDebounce = Duration.milliseconds(80)

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
            let boxed = await Task.detached(priority: .utility) { () -> SendableCGImage? in
                guard let source = store?.fullCIImage(for: photo) else { return nil }
                let ctx = CIContext()
                guard let cg = ctx.createCGImage(source, from: source.extent),
                      let maskCG = PortraitMaskAnalyzer.skinMask(for: cg)
                else { return nil }
                return SendableCGImage(image: maskCG)
            }.value
            guard let self else { return }
            self.isPreparingMask = false
            if let boxed {
                let mask = CIImage(cgImage: boxed.image)
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

    // MARK: 曲线与色彩分级（Phase 4.1 / 4.2）

    /// 当前曲线状态。语义与渲染管线一致：最后一条曲线指令生效。
    var currentCurves: ToneCurveSet {
        for op in document.graph.operations.reversed() {
            if case .toneCurve(let set) = op { return set }
        }
        return ToneCurveSet()
    }

    /// 当前 HSL 状态。语义与渲染管线一致：逐参数吸收，后写覆盖。
    var currentHSL: HSLAdjustment {
        var hsl = HSLAdjustment()
        for op in document.graph.operations {
            _ = hsl.absorb(op)
        }
        return hsl
    }

    /// 曲线提交：同通道连续拖动合并为一个历史步骤，画布拖动期间预览按 80ms 防抖。
    func applyCurves(_ set: ToneCurveSet, label: String) {
        let op = EditOperation.toneCurve(set)
        document.graph.updateInteractive(op)
        document.history.commitInteractive(label: label, operation: op)
        schedulePreview()
    }

    /// HSL 单分量提交（历史标签由参数派生，保证同参数拖动合并）。
    func applyHSL(_ channel: HSLChannel, _ component: HSLComponent, value: Double) {
        let parameter = EditParameter.hsl(channel, component)
        let op = EditOperation.hsl(channel, component, value).clamped
        document.graph.updateInteractive(op)
        document.history.commitInteractive(label: parameter.historyLabel, operation: op)
        schedulePreview()
    }

    /// 重置整条色域（三分量归零）——作为**单个**原子历史步骤，撤销可整体回退。
    func resetHSL(_ channel: HSLChannel) {
        let operations = HSLComponent.allCases.map { component in
            EditOperation.hsl(channel, component, 0)
        }
        for op in operations {
            document.graph.updateInteractive(op)
        }
        document.history.commit(label: "重置\(channel.displayName)色域", operations: operations)
        renderPreview()
    }

    /// 高频预览防抖：拖动期间合并为 80ms 一帧（P1.6 预览性能预算）。
    func schedulePreview() {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: EditorModel.previewDebounce)
            guard let self, !Task.isCancelled else { return }
            self.previewTask = nil
            self.renderPreview()
        }
    }

    private func cancelPendingPreview() {
        previewTask?.cancel()
        previewTask = nil
        maskPreviewTask?.cancel()
        maskPreviewTask = nil
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
        // 合规底线：导出永远不含选区叠加色（叠加只属于预览）。
        renderer.maskOverlayID = nil
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
        cancelPendingPreview()
        document.graph = EditGraph(operations: document.history.operations)
        renderPreview()
    }

    // MARK: 蒙版（Phase 4.3：选区 + 局部调整）

    /// 当前选中的蒙版 id：局部调整与图上编辑的唯一对象。
    var selectedMaskID: UUID?
    /// 预览中是否叠加选区色（仅影响预览；导出始终不叠加）。
    var showMaskOverlay = true

    /// 蒙版预览调度：同样是 80ms 窗口合并，但**首帧立即出图**
    /// （涂抹 / 拖手柄需要即时反馈；纯尾部防抖会让连续拖动期间一帧都不出）。
    private var maskPreviewTask: Task<Void, Never>?

    var masks: [Mask] { document.graph.masks }

    var selectedMask: Mask? {
        guard let id = selectedMaskID else { return nil }
        return document.graph.mask(id: id)
    }

    /// 把「当前选中蒙版」同步给渲染管线（关闭叠加色时传 nil → 正常显示）。
    private func syncMaskOverlay() {
        renderer.maskOverlayID = showMaskOverlay ? selectedMaskID : nil
    }

    func scheduleMaskPreview() {
        if maskPreviewTask == nil { renderPreview() }
        maskPreviewTask?.cancel()
        maskPreviewTask = Task { [weak self] in
            try? await Task.sleep(for: EditorModel.previewDebounce)
            guard let self, !Task.isCancelled else { return }
            self.maskPreviewTask = nil
            self.renderPreview()
        }
    }

    /// 蒙版唯一写入口：图内就地替换（保持层级）+ 历史按 (蒙版 id, 标签) 合并提交。
    /// 同一手柄连续拖动 / 同一支滑杆连续调值 → 只落一步历史。
    /// - Parameter deferred: true = 高频手势（80ms 合并）；false = 离散操作（立即渲染）。
    func applyMask(_ mask: Mask, label: String, deferred: Bool) {
        document.graph.upsertMask(mask)
        document.history.commitMask(mask, label: label)
        syncMaskOverlay()
        if deferred {
            scheduleMaskPreview()
        } else {
            renderPreview()
        }
    }

    @discardableResult
    func addMask(kind: MaskKind) -> Mask {
        let mask = kind.makeDefault()
        document.graph.upsertMask(mask)
        document.history.commitMask(mask, label: "新建\(kind.displayName)选区")
        selectedMaskID = mask.id
        syncMaskOverlay()
        renderPreview()
        return mask
    }

    func selectMask(_ id: UUID) {
        selectedMaskID = id
        syncMaskOverlay()
        renderPreview()
    }

    func setMaskOverlayVisible(_ visible: Bool) {
        showMaskOverlay = visible
        syncMaskOverlay()
        renderPreview()
    }

    func renameMask(id: UUID, name: String) {
        guard var mask = document.graph.mask(id: id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != mask.name else { return }
        mask.name = trimmed
        applyMask(mask, label: "重命名选区", deferred: false)
    }

    func setMaskInverted(id: UUID, inverted: Bool) {
        guard var mask = document.graph.mask(id: id) else { return }
        mask.isInverted = inverted
        applyMask(mask, label: inverted ? "反选选区" : "取消选区反选", deferred: false)
    }

    func removeMask(id: UUID) {
        guard document.graph.removeMask(id: id) else { return }
        document.history.commitMaskRemoval(id: id, label: "删除选区")
        if selectedMaskID == id { selectedMaskID = nil }
        syncMaskOverlay()
        renderPreview()
    }

    func duplicateMask(id: UUID) {
        guard let source = document.graph.mask(id: id) else { return }
        let copy = source.duplicated().normalized()
        // 用 upsert（追加到末尾）而不是 graph.duplicateMask（插在源之后）：
        // EditHistory 的 operations 按「蒙版首次出现顺序」归并，没有重排原语，
        // 追加才能保证撤销 / 重做后图内层级与历史一致。
        document.graph.upsertMask(copy)
        document.history.commitMask(copy, label: "复制选区")
        selectedMaskID = copy.id
        syncMaskOverlay()
        renderPreview()
    }

    /// 上移 / 下移一层（offset>0 = 更靠上，后加在上）。
    /// - Note: v1 限制 —— 层级只写进 `EditGraph`，未进历史（历史无重排原语），
    ///   因此撤销 / 重做后蒙版层级会回到创建顺序；渲染与导出按当前图内顺序立即生效。
    func moveMask(id: UUID, by offset: Int) {
        guard document.graph.moveMask(id: id, by: offset) else { return }
        renderPreview()
    }

    // MARK: 局部调整（唯一写入目标是 mask.adjustments）

    func setMaskAdjustment(_ parameter: EditParameter, value: Double, in maskID: UUID) {
        guard var mask = document.graph.mask(id: maskID) else { return }
        mask.setAdjustment(EditOperation.make(parameter: parameter, value: value))
        applyMask(mask, label: "局部·\(parameter.historyLabel)", deferred: true)
    }

    func removeMaskAdjustment(_ parameter: EditParameter, id: UUID) {
        guard var mask = document.graph.mask(id: id) else { return }
        mask.removeAdjustment(for: parameter)
        applyMask(mask, label: "清除局部·\(parameter.historyLabel)", deferred: false)
    }

    func resetMaskAdjustments(id: UUID) {
        guard var mask = document.graph.mask(id: id) else { return }
        mask.resetAdjustments()
        applyMask(mask, label: "重置局部调整", deferred: false)
    }

    /// 选区通用属性（羽化 / 不透明度），0...100。
    func setMaskSoftness(id: UUID, feather: Double? = nil, opacity: Double? = nil) {
        guard var mask = document.graph.mask(id: id) else { return }
        if let feather { mask.feather = feather }
        if let opacity { mask.opacity = opacity }
        applyMask(mask, label: "选区羽化与不透明度", deferred: true)
    }

    /// 画笔参数（半径 / 硬度 / 流量）。
    func setBrushSettings(id: UUID, radius: Double? = nil, hardness: Double? = nil, flow: Double? = nil) {
        guard var mask = document.graph.mask(id: id), case .brush(var brush) = mask.shape else { return }
        if let radius { brush.radius = radius }
        if let hardness { brush.hardness = hardness }
        if let flow { brush.flow = flow }
        mask.shape = .brush(brush)
        applyMask(mask, label: "画笔参数", deferred: true)
    }

    /// 撤销最后一笔涂抹。
    func undoLastBrushStroke(id: UUID) {
        guard var mask = document.graph.mask(id: id), case .brush(var brush) = mask.shape else { return }
        guard brush.undoLastStroke() else { return }
        mask.shape = .brush(brush)
        applyMask(mask, label: "撤销笔画", deferred: false)
    }

    // MARK: 构图（裁剪 / 拉直）

    /// 追加一条裁剪指令并作为一步历史提交。
    /// - Note: `EditGraph.operations` 是 `private(set)`，App 层没有「移除指令」原语，
    ///   所以裁剪以**当前画面**为基准叠加（比例只能越来越小）；撤销可回退最近一次裁剪。
    func applyCrop(_ rect: CropRect, label: String) {
        let operation = EditOperation.crop(rect)
        document.graph.append(operation)
        document.history.commit(label: label, operations: [operation])
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
        case .toneCurve: "曲线"
        default:
            hslBinding.map { "\($0.channel.displayName)\($0.component.displayName)" } ?? rawValue
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
        case .toneCurve: "chart.xyaxis.line"
        default: "paintpalette.fill"
        }
    }
}

// MARK: - 编辑器视图

/// 调色交互（致敬 Snapseed 交互模式；视觉为本项目原创设计）：
/// - 图像区**上下滑**切换调整参数
/// - **左右滑**调整当前参数值
/// - **按住**图像查看原图对比
/// - 底部可在「手势调色 / 滑杆精调 / 曲线 / 色彩分级」四种面板间切换
struct EditorView: View {
    @State private var model: EditorModel
    @State private var recipeStore = RecipeStore()
    @State private var lutStore = LUTStore()
    @State private var showPresets = false
    @State private var showExport = false
    @State private var panelMode: EditorPanelMode = .gesture
    /// 七大模块入口（Phase 4.4 重组）：预设 / 构图 / 色彩 / 人像 / 衣物 / 液化 / 修复
    @State private var activeModule: EditorModule = .color
    /// 蒙版「图上编辑」态：只有选中选区且打开时，画布才可拖手柄 / 涂抹。
    @State private var isMaskEditing = false

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
            moduleStrip
            bottomBar
            panelContent
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

    // MARK: 七大模块入口条（预设 / 构图 / 色彩 / 人像 / 衣物 / 液化 / 修复）

    private var moduleStrip: some View {
        ModuleStrip(selected: activeModule, maskCount: model.masks.count) { module in
            withAnimation(DS.Motion.standard) {
                activeModule = module
                // 离开「修复」模块即退出蒙版图上编辑，避免手势被选区吞掉
                if module != .retouch { isMaskEditing = false }
            }
        }
    }

    // MARK: 图像区（手势调色）

    private var imageArea: some View {
        GeometryReader { geo in
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

                // 蒙版图上编辑层：只覆盖「图像实际显示区域」（scaledToFit 的结果），
                // 手势在归一化坐标（左上原点 0...1）里计算，与 EditKit 的 MaskPoint 一致。
                if let mask = model.selectedMask, isMaskEditing {
                    let fitted = fittedImageSize(in: geo.size)
                    MaskCanvasOverlay(
                        mask: mask,
                        onChange: { updated, label in
                            model.applyMask(updated, label: label, deferred: true)
                        },
                        onCommit: { updated, label in
                            model.applyMask(updated, label: label, deferred: false)
                        }
                    )
                    .frame(width: fitted.width, height: fitted.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .transition(.opacity)
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
                        if isMaskEditing, let mask = model.selectedMask {
                            Label(mask.kind.displayName, systemImage: mask.kind.symbol)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.thinMaterial, in: Capsule())
                                .padding(.top, 10)
                                .accessibilityLabel("正在编辑\(mask.kind.displayName)选区 \(mask.name)")
                        }
                    }
                    Spacer()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.05))
        .contentShape(Rectangle())
        // 上下滑切参数 / 左右滑调值（手势调色，视觉为本项目原创）
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
                showOriginal = pressing && !isMaskEditing
            }
        )
    }

    /// 预览图在图像区内的实际显示尺寸（scaledToFit 结果）：蒙版手势靠它做归一化坐标映射。
    private func fittedImageSize(in container: CGSize) -> CGSize {
        guard let size = model.preview?.size, size.width > 1, size.height > 1,
              container.width > 1, container.height > 1 else { return container }
        let scale = min(container.width / size.width, container.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// 预览图当前宽高比（构图面板用它把「比例」换算成归一化裁剪矩形）。
    private var previewAspect: Double {
        guard let size = model.preview?.size, size.height > 1 else { return 1 }
        return Double(size.width / size.height)
    }

    private func handleDrag(_ g: DragGesture.Value) {
        // 只有「色彩」模块的手势 / 调色子面板才响应图像区调值；
        // 蒙版图上编辑时优先给选区手势，曲线 / 分级面板自带画布手势。
        guard activeModule == .color, !isMaskEditing,
              panelMode == .gesture || panelMode == .sliders else { return }
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

            if activeModule == .color {
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

                Menu {
                    ForEach(EditorPanelMode.allCases) { mode in
                        Button {
                            withAnimation(DS.Motion.standard) { panelMode = mode }
                        } label: {
                            Label(mode.label, systemImage: panelMode == mode ? "checkmark" : mode.icon)
                        }
                    }
                } label: {
                    Image(systemName: panelMode.icon)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("调色面板：\(panelMode.label)")
                .accessibilityHint("可切换手势调色、滑杆精调、曲线、色彩分级")
            } else {
                Label(activeModule.label, systemImage: activeModule.symbol)
                    .font(DS.Typography.sliderLabel)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("当前模块 \(activeModule.label)")
                Spacer()
            }
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

    // MARK: 面板（模块 → 面板）

    /// 模块路由：色彩模块内部再按 `panelMode` 切子面板，其余模块各有专属面板。
    /// 未实现的模块走「即将上线」占位页（可点、说明清楚，不留空白入口）。
    @ViewBuilder
    private var panelContent: some View {
        switch activeModule {
        case .presets:
            PresetsQuickPanel(
                recipes: BuiltinRecipes.all + recipeStore.userRecipes,
                luts: lutStore.ordered,
                onApply: { recipe, intensity in
                    model.apply(recipe: recipe, intensity: intensity)
                },
                onApplyLUT: { ref in
                    model.applyLUT(ref)
                },
                onOpenLibrary: { showPresets = true }
            )
        case .composition:
            CompositionPanel(
                imageAspect: previewAspect,
                straighten: model.value(for: .straighten),
                onChangeStraighten: { model.sliderChanged(.straighten, value: $0) },
                onApplyCrop: { rect in
                    model.applyCrop(rect, label: "裁剪")
                }
            )
        case .color:
            colorPanel
        case .portrait:
            PortraitPanel(
                smoothing: model.value(for: .skinSmoothing),
                brightening: model.value(for: .skinBrightening),
                isPreparingMask: model.isPreparingMask,
                onChange: { parameter, value in
                    model.sliderChanged(parameter, value: value)
                },
                onAuto: { parameter in
                    model.autoTuneSingle(parameter)
                }
            )
        case .retouch:
            MaskPanel(model: model, isEditing: $isMaskEditing)
        case .clothing, .liquify:
            ComingSoonPanel(module: activeModule)
        }
    }

    // MARK: 色彩模块面板（手势 / 滑杆 / 曲线 / 分级）

    @ViewBuilder
    private var colorPanel: some View {
        switch panelMode {
        case .gesture:
            EmptyView()
        case .sliders:
            sliderPanel
        case .curve:
            CurveEditorPanel(curves: model.currentCurves) { set, label in
                model.applyCurves(set, label: label)
            }
        case .hsl:
            HSLPanel(
                adjustment: model.currentHSL,
                onChange: { channel, component, value in
                    model.applyHSL(channel, component, value: value)
                },
                onReset: { channel in
                    model.resetHSL(channel)
                }
            )
        }
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

/// 全局面板与模块面板共用的参数滑杆行（internal：`EditorModules` / `MaskPanels` 亦复用）。
struct AdjustmentSliderRow: View {
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
