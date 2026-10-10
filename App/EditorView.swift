import SwiftUI
import UIKit
import Combine
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
    /// R006 性能专项：复用进程级 `CIContext`。原来这里是一个、导出里又建一个、掩码生成里再建一个，
    /// 每次新建都要重新分配 GPU/CPU 侧资源（实测数十毫秒），且互相之间无法复用中间结果。
    private let context = RenderContext.shared

    private var previewSource: CIImage?
    private var skinMaskFull: CIImage?
    private var stats: ImageStats?

    var preview: UIImage?
    var originalPreview: UIImage?
    var document = EditDocument()
    var loadFailed = false

    // MARK: - R006 追加 C：AI 处理状态

    /// AI 处理进度（替代原来的 `isPreparingMask` 布尔：一个布尔表达不了阶段、进度与后台状态）。
    let ai = AIProcessingState()
    private let activityBridge = ProcessingActivityBridge()
    private let aiProgressReporter = ProgressReporter()
    private var aiProgressTask: Task<Void, Never>?
    /// 用户点了「取消」：结果到达时直接丢弃（detached 任务本身无法中断）。
    private var aiCancelled = false

    /// 兼容既有视图层的布尔读法：人像面板的「正在识别人像…」与图像区角标仍在读它。
    /// 语义完全等价于「AI 处理正在进行中」。
    var isPreparingMask: Bool { ai.isRunning }

    // MARK: - R006 性能专项：预览渲染调度

    /// 渲染代次。只有「最新一代」的结果会写回 UI，过期帧直接丢弃（否则拖动时画面会来回跳）。
    private var renderGeneration = 0
    /// 是否有渲染在飞。用于**合并连续请求**：飞行中不再排队，只记一笔「还欠一帧」。
    private var isRenderingPreview = false
    private var pendingRender = false
    /// 当前渲染档位：拖动中降采样，松手升回。
    private var previewQuality: PreviewQuality = .still
    /// 最近一次成功出图。**任何路径都不把 `preview` 置回 nil** —— 这是「不黑屏」的结构性保证。
    private var lastGoodPreview: UIImage?

    var canUndo: Bool { document.history.stepCount > 0 }
    var canRedo: Bool { document.history.redoSteps.isEmpty == false }

    /// 曲线 / HSL 画布拖动的预览防抖任务。
    private var previewTask: Task<Void, Never>?
    /// 蒙版编辑的自动升档任务。
    private var autoStillTask: Task<Void, Never>?
    /// 静止档防抖窗口。
    static let previewDebounce = Duration.milliseconds(80)
    /// 交互档防抖窗口。配合「飞行中合并」，滑杆跟随更紧、同时不会堆积渲染任务。
    static let interactiveDebounce = Duration.milliseconds(24)

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
        let scale = min(1, EditorModel.stillLongEdge / maxDim)
        previewSource = scale < 1
            ? full.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : full
        stats = previewSource.flatMap { ImageAnalyzer.analyze($0, context: context) }
        // R006 性能专项：首帧改为异步。
        // 原来这里在主线程**同步**跑两次全链路渲染（原图对比缓存 + 编辑态预览），
        // 1600px 全链路 + createCGImage 全压在主线程上，冷启动必然掉帧。
        // 现在交给渲染调度器（异步 + 飞行中合并 + 过期帧丢弃），主线程只做赋值。
        requestPreview(interactive: false, alsoRenderOriginal: true)
    }

    /// 后台生成皮肤掩码（Vision + 肤色，端侧零联网）；**分阶段上报真实进度**，完成后重新预览。
    /// 注意：CIImage 非 Sendable，须在 detached 任务内部创建，不跨界捕获。
    ///
    /// R006 追加 C：这条路径原来有三个体验问题 ——
    /// ① 只有一个 `isPreparingMask` 布尔，UI 只能转一个「不知道要多久」的圈；
    /// ② 结束时若还没出图，视图会回落到空态（用户观感就是「黑屏」）；
    /// ③ 每次调用都新建一个 `CIContext`。
    /// 现在：阶段进度可见 / 可转后台 / 复用共享 context / 全程保留上一张预览。
    private func prepareSkinMask() {
        guard store != nil else { return }
        let photo = self.photo
        let store = self.store
        let reporter = aiProgressReporter
        reporter.reset()
        aiCancelled = false
        ai.begin()
        startAIProgressPolling(reporter)

        Task { [weak self] in
            let boxed = await Task.detached(priority: .userInitiated) { () -> SendableCGImage? in
                guard let source = store?.fullCIImage(for: photo) else { return nil }
                guard let cg = RenderContext.shared.createCGImage(source, from: source.extent) else { return nil }
                guard let maskCG = PortraitMaskAnalyzer.skinMask(for: cg, progress: { done, total in
                    reporter.report(done: done, total: total)
                }) else { return nil }
                return SendableCGImage(image: maskCG)
            }.value
            guard let self else { return }
            // 用户已取消：结果到达也不落地（不装掩码、不弹完成提示）。
            guard !self.aiCancelled else { return }
            self.aiProgressTask?.cancel()
            let wasBackgrounded = self.ai.isBackground
            if let boxed {
                let mask = CIImage(cgImage: boxed.image)
                self.skinMaskFull = mask
                self.installMaskForPreview()
                self.ai.finish(success: true)
                self.renderPreview()
                self.activityBridge.end(fraction: 1, phaseTitle: "已完成",
                                        detail: "人像美化就绪", finished: true)
                if wasBackgrounded {
                    // 用户当时在后台：系统通知 + 强触觉（追加 C 第 7 条）
                    ProcessingNotifications.postCompletion(title: "拾光 · 处理完成",
                                                          body: "人像美化掩码已生成，可以继续编辑了。")
                    EditorHaptics.completed()
                }
            } else {
                self.ai.finish(success: false)
                self.activityBridge.end(fraction: 0, phaseTitle: "未完成",
                                        detail: "没有识别到可用的人像区域", finished: false)
            }
        }
    }

    /// 轮询真实阶段并同步到 UI 与 Live Activity（100ms 一次，开销可忽略）。
    private func startAIProgressPolling(_ reporter: ProgressReporter) {
        aiProgressTask?.cancel()
        aiProgressTask = Task { [weak self] in
            var lastDone = -1
            while !Task.isCancelled {
                guard let self else { return }
                let snap = reporter.snapshot()
                if snap.done != lastDone {
                    lastDone = snap.done
                    self.ai.update(done: snap.done, total: snap.total)
                    self.activityBridge.update(fraction: self.ai.fraction,
                                               phaseTitle: self.ai.stage.title,
                                               detail: "人像美化", finished: false)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: - AI 处理：用户动作（追加 C 第 4/5/6 条）

    /// 「后台处理」：浮层收起、左上角常驻进度、点亮 Live Activity、请求通知授权。
    func sendAIToBackground() {
        guard ai.isRunning else { return }
        ai.moveToBackground()
        activityBridge.startIfNeeded(title: "AI 人像美化")
        activityBridge.update(fraction: ai.fraction, phaseTitle: ai.stage.title,
                              detail: "人像美化", finished: false)
        ProcessingNotifications.requestAuthorizationIfNeeded()
    }

    /// 「回到前台看进度」。
    func bringAIToForeground() {
        guard ai.isRunning else { return }
        ai.resurface()
    }

    /// 「取消」：停止进度轮询、丢弃本次结果、收起浮层与实时活动。
    /// 视图层 `ProcessingHUD(onCancel:)` 直接调用。
    func cancelAIProcessing() {
        guard ai.isRunning else { return }
        aiCancelled = true
        aiProgressTask?.cancel()
        aiProgressTask = nil
        ai.reset()
        activityBridge.end(fraction: 0, phaseTitle: "已取消",
                           detail: "人像美化已取消", finished: false)
        EditorHaptics.cancelled()
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

    /// 滑杆调值：图内合并 + 历史合并 + **异步**渲染。
    ///
    /// R006 性能专项：原来是 `renderPreview()` 直渲 —— 每次 `onChanged`（拖动时可达 60 次/秒）
    /// 都在主线程同步跑一遍全链路渲染 + `createCGImage`，这是滑杆卡顿和机身发热的头号原因。
    /// 现在走交互档：24ms 防抖 + 降采样 + 「飞行中合并」（见 `requestPreview`）。
    func sliderChanged(_ parameter: EditParameter, value: Double) {
        let op = EditOperation.make(parameter: parameter, value: value)
        document.graph.updateInteractive(op)
        document.history.commitInteractive(label: parameter.historyLabel, operation: op)
        schedulePreview(delay: EditorModel.interactiveDebounce, interactive: true)
        // 兜底：未接线 `onEditingChanged` 的调用点（人像面板 / 蒙版面板）也会在静默 900ms 后升档。
        scheduleAutoStillPreview()
    }

    /// 滑杆按下（`onEditingChanged(true)`）：切交互档 + 预热触觉发生器（首次反馈不掉帧）。
    func beginInteractiveEditing() {
        previewQuality = .interactive
        EditorHaptics.warmUp()
    }

    /// 滑杆松手（`onEditingChanged(false)`）：升回静止档，补一帧高质量预览。
    func endInteractiveEditing() {
        previewQuality = .still
        cancelPendingPreview()
        requestPreview(interactive: false)
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

    /// 高频预览防抖：拖动期间合并为一帧；`interactive` 为真时用更短窗口 + 降采样档。
    func schedulePreview(delay: Duration = EditorModel.previewDebounce, interactive: Bool = false) {
        if interactive { previewQuality = .interactive }
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.previewTask = nil
            self.requestPreview(interactive: interactive)
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

    // MARK: 预设缩略图（观感项：预设面板显示真实预览而非纯文字）

    /// 预设缩略图缓存（R007a P0-3：容量 24 的 LRU，key = 配方 id + 侧边像素）。
    /// 旧实现是「主线程同步全渲染 + 无上限字典」，首屏 12 张缩略图会把主线程占满。
    private var presetThumbCache: [String: UIImage] = [:]
    private var presetThumbOrder: [String] = []
    private let presetThumbCapacity = 24
    /// 生成中的缩略图任务（按 key 去重：同一预设不会被重复排队/重复渲染）。
    private var presetThumbJobs: [String: Task<Void, Never>] = [:]
    /// 缩略图版本号：后台生成完成后自增，视图据此把占位图静默替换成真图。
    private(set) var presetThumbnailRevision = 0

    private func presetThumbKey(_ recipe: Recipe, side: CGFloat) -> String {
        "\(recipe.id.uuidString)@\(Int(side))"
    }

    /// 取预设缩略图（R007a P0-3）：**纯缓存读取，绝不触发渲染**，在 `body` / `onAppear` 里同步调用安全。
    /// 未命中返回 nil（视图显示占位图），由 `prefetchPresetThumbnails` 在后台补齐；
    /// 补齐后 `presetThumbnailRevision` 自增，宿主视图重算并把占位图静默换成真图。
    func presetThumbnail(for recipe: Recipe, side: CGFloat = 60) -> UIImage? {
        presetThumbCache[presetThumbKey(recipe, side: side)]
    }

    private func storePresetThumbnail(_ image: UIImage, key: String) {
        presetThumbOrder.removeAll { $0 == key }
        presetThumbOrder.append(key)
        presetThumbCache[key] = image
        while presetThumbOrder.count > presetThumbCapacity {
            let oldest = presetThumbOrder.removeFirst()
            presetThumbCache[oldest] = nil
        }
        presetThumbnailRevision &+= 1
    }

    /// 内存压力响应：清空缩略图缓存（列表回到占位图，下次进入重新生成）。
    func clearPresetThumbnailCache() {
        presetThumbCache.removeAll()
        presetThumbOrder.removeAll()
        presetThumbnailRevision &+= 1
    }

    /// 批量预热：进入预设面板时一次性排队（.utility 优先级），滚动时基本都已命中缓存。
    func prefetchPresetThumbnails(_ recipes: [Recipe], sides: [CGFloat] = [60]) {
        for side in sides {
            for recipe in recipes {
                let key = presetThumbKey(recipe, side: side)
                guard presetThumbCache[key] == nil, presetThumbJobs[key] == nil else { continue }
                _ = startPresetThumbnailJob(recipe: recipe, side: side, key: key)
            }
        }
    }

    @discardableResult
    private func startPresetThumbnailJob(recipe: Recipe, side: CGFloat, key: String) -> Task<Void, Never> {
        // 配方在 MainActor 侧解析成操作数组，避免把 Recipe 带过并发边界
        let operations = recipe.resolvedOperations()
        let job = Task { @MainActor in
            defer { presetThumbJobs[key] = nil }
            guard let source = previewSource else { return }
            let sourceBox = SendableCIImage(image: source)
            let rendererBox = SendableRendererBox(renderer: renderer)
            let boxed = await Task.detached(priority: .utility) { () -> SendableCGImage? in
                renderPresetThumbnailImage(
                    sourceBox: sourceBox,
                    rendererBox: rendererBox,
                    operations: operations,
                    side: side
                )
            }.value
            if let boxed {
                storePresetThumbnail(UIImage(cgImage: boxed.image), key: key)
            }
        }
        presetThumbJobs[key] = job
        return job
    }

    /// 进入蒙版图上编辑前的预热（R007a P0-4）：先让当前选区走一遍既有的防抖预览管线，
    /// 把 CIContext / 内核 / 缓冲的开销挪到用户落笔之前，首笔只负责「收点」。
    func warmUpMaskEditing() {
        guard selectedMask != nil else { return }
        syncMaskOverlay()
        scheduleMaskPreview()
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
            // R006：复用进程级 CIContext（导出不再单独构造一个）
            let context = RenderContext.shared
            guard let cg = context.createCGImage(rendered, from: rendered.extent) else {
                throw ExportFailure.renderFailed
            }
            // P1-5：原图 URL 用于按策略搬运 EXIF / GPS / IPTC
            let originalURL = store?.sourceURL(of: photo)
            return try PhotoExporter.exportToTemporary(cg, options: options, originalURL: originalURL)
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

    /// 蒙版编辑中的预览：交互档 + 短防抖。
    /// 松手后没有明确的结束回调，所以用「静默 900ms 自动升档」兜底 ——
    /// 连续拖动时每次调用都会重置这个计时器，不会在拖动中途升档。
    func scheduleMaskPreview() {
        previewQuality = .interactive
        if maskPreviewTask == nil { requestPreview(interactive: true) }
        maskPreviewTask?.cancel()
        maskPreviewTask = Task { [weak self] in
            try? await Task.sleep(for: EditorModel.interactiveDebounce)
            guard let self, !Task.isCancelled else { return }
            self.maskPreviewTask = nil
            self.requestPreview(interactive: true)
        }
        scheduleAutoStillPreview()
    }

    /// 静默 900ms 后自动升回静止档的兜底（滑杆 / 蒙版两类高频调用点共用）。
    /// 连续拖动时每次调用都会重置计时器，因此不会在拖动中途升档。
    private func scheduleAutoStillPreview() {
        autoStillTask?.cancel()
        autoStillTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, !Task.isCancelled else { return }
            self.autoStillTask = nil
            self.endInteractiveEditing()
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

    // MARK: - 渲染（R006 性能专项重写）

    /// 静止档长边（与 R005 一致：1600px）。
    /// `nonisolated`：`PreviewQuality.longEdge`（嵌套类型的计算属性）在**非隔离**上下文里读它，
    /// 不加会被 Swift 6 判为「main actor 隔离的静态属性不能在非隔离上下文引用」。
    nonisolated static let stillLongEdge: CGFloat = 1600
    /// 交互档长边。像素量约为静止档的 41%，拖动时明显更轻，松手立刻升回静止档。
    nonisolated static let interactiveLongEdge: CGFloat = 1024

    /// 帧档位。
    enum PreviewQuality {
        case still
        case interactive

        var longEdge: CGFloat {
            switch self {
            case .still: return EditorModel.stillLongEdge
            case .interactive: return EditorModel.interactiveLongEdge
            }
        }
    }

    /// 把预览源缩到目标档（只缩不放大）。
    private func source(for quality: PreviewQuality) -> CIImage? {
        guard let previewSource else { return nil }
        let maxDim = max(previewSource.extent.width, previewSource.extent.height)
        let scale = min(1, quality.longEdge / maxDim)
        guard scale < 1 else { return previewSource }
        return previewSource.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    /// 掩码按当前渲染域缩放（掩码是原图尺度的，预览域更小）。
    private func scaledSkinMask(to extent: CGRect) -> CIImage? {
        guard let mask = skinMaskFull, mask.extent.width > 0 else { return skinMaskFull }
        let scale = extent.width / mask.extent.width
        guard scale < 0.999 || scale > 1.001 else { return mask }
        return mask.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    /// 同步渲染一张。只用于一次性用途（预设缩略图等），**不参与交互循环**。
    private func renderUIImage(graph: EditGraph, quality: PreviewQuality = .still) -> UIImage? {
        guard let source = source(for: quality) else { return nil }
        var snapshot = renderer
        snapshot.skinMask = scaledSkinMask(to: source.extent)
        guard let boxed = renderToCGImage(snapshot, source: source, graph: graph) else { return nil }
        return UIImage(cgImage: boxed.image)
    }

    /// 兼容旧调用点：按当前档位走统一异步入口。
    private func renderPreview() {
        requestPreview(interactive: previewQuality == .interactive)
    }

    /// **统一渲染入口**：异步 + 飞行中合并 + 过期帧丢弃。
    ///
    /// - 异步：`render` 与 `createCGImage` 全部丢到 detached 线程，主线程一次都不阻塞。
    /// - 合并：已有渲染在飞时不再排新任务，只记一笔「还欠一帧」；落地后立刻用**最新**图谱补渲。
    ///   连续拖动 100 次最多只产生 2 次渲染，且永远画在最新状态上（不会出现画面回跳）。
    /// - 过期丢弃：用代次号比对，晚到的旧帧直接扔掉。
    private func requestPreview(interactive: Bool, alsoRenderOriginal: Bool = false) {
        renderGeneration &+= 1
        let generation = renderGeneration
        let graph = document.graph
        let quality: PreviewQuality = interactive ? .interactive : .still

        if isRenderingPreview {
            pendingRender = true
            return
        }
        guard let source = source(for: quality) else { return }

        var snapshot = renderer
        snapshot.skinMask = scaledSkinMask(to: source.extent)
        isRenderingPreview = true

        // CIImage 不可变但未标注 Sendable，跨边界用 @unchecked 显式包裹。
        let sourceBox = SendableCIImage(image: source)
        // 渲染器快照同理：`renderer` 是主 actor 隔离的存储属性，值拷贝仍与主 actor 同区，
        // 直接进 detached 闭包会被判「passing closure as a 'sending' parameter」。
        let snapshotBox = SendableRendererBox(renderer: snapshot)
        let needsOriginal = alsoRenderOriginal && originalPreview == nil
        let priority: TaskPriority = interactive ? .userInitiated : .utility

        Task { [weak self] in
            let result = await Task.detached(priority: priority) {
                () -> (edited: SendableCGImage?, original: SendableCGImage?) in
                let edited = renderToCGImage(snapshotBox.renderer, source: sourceBox.image, graph: graph)
                guard needsOriginal else { return (edited, nil) }
                let plain = renderToCGImage(snapshotBox.renderer, source: sourceBox.image, graph: EditGraph())
                return (edited, plain)
            }.value

            guard let self else { return }
            self.isRenderingPreview = false

            if generation == self.renderGeneration {
                if let edited = result.edited {
                    let image = UIImage(cgImage: edited.image)
                    self.preview = image
                    self.lastGoodPreview = image
                }
                if let original = result.original {
                    self.originalPreview = UIImage(cgImage: original.image)
                }
            }

            if self.pendingRender {
                self.pendingRender = false
                self.requestPreview(interactive: self.previewQuality == .interactive)
            }
        }
    }
}

/// 在后台线程做一次完整渲染并出 CGImage。
///
/// 刻意写成**文件级函数**而不是 `EditorModel` 的静态方法：
/// `EditorModel` 是 `@MainActor`，写在类里的静态方法会继承主 actor 隔离，无法从 detached 任务调用。
/// 共享 `CIContext` 在闭包内部取（`RenderContext.shared`），避免把 `CIContext` 跨隔离域捕获。
private func renderToCGImage(_ renderer: BasicAdjustmentRenderer,
                             source: CIImage,
                             graph: EditGraph) -> SendableCGImage? {
    let output = renderer.render(source: source, graph: graph)
    guard output.extent.width >= 1, output.extent.height >= 1 else { return nil }
    guard let cg = RenderContext.shared.createCGImage(output, from: output.extent) else { return nil }
    return SendableCGImage(image: cg)
}

/// 预设缩略图渲染（R007a P0-3）：**文件级函数**，理由同 `renderToCGImage`
/// ——不继承 `EditorModel` 的主 actor 隔离，可从 detached 任务调用。
/// 先把源降采样到 `side * 3` 像素再套用配方（全分辨率渲染正是首屏卡顿的根源）。
private func renderPresetThumbnailImage(sourceBox: SendableCIImage,
                                        rendererBox: SendableRendererBox,
                                        operations: [EditOperation],
                                        side: CGFloat) -> SendableCGImage? {
    let source = sourceBox.image
    let target = side * 3
    let maxDim = max(source.extent.width, source.extent.height)
    let scale = maxDim > target ? target / maxDim : 1
    let small = scale < 1
        ? source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        : source
    var graph = EditGraph()
    for operation in operations { graph.append(operation) }
    let output = rendererBox.renderer.render(source: small, graph: graph)
    guard output.extent.width >= 1, output.extent.height >= 1 else { return nil }
    guard let cg = RenderContext.shared.createCGImage(output, from: output.extent) else { return nil }
    return SendableCGImage(image: cg)
}

/// CGImage 不可变线程安全，跨 Task 边界用 @unchecked 包裹。
private struct SendableCGImage: @unchecked Sendable {
    let image: CGImage
}

/// CIImage 不可变线程安全，跨 Task 边界用 @unchecked 包裹。
private struct SendableCIImage: @unchecked Sendable {
    let image: CIImage
}

/// `BasicAdjustmentRenderer` 是值类型但未标注 `Sendable`；预览渲染跑在 detached 任务里，
/// 与 `SendableCIImage` 同套路用 `@unchecked` 显式承诺（渲染器只读，无可变共享状态）。
private struct SendableRendererBox: @unchecked Sendable {
    let renderer: BasicAdjustmentRenderer
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
    /// R006 追加 B：上下滑切参数期间浮现「参数列表浮层」。
    @State private var isSwitchingParameter = false
    /// 「归零」后的短暂停顿窗口（此期间忽略切参数，给用户明确的节奏点）。
    @State private var settleUntil: Date?
    /// 每次拖动只触发一次的分级触觉闩锁。
    @State private var didFireZeroHaptic = false
    @State private var didFireLimitHaptic = false

    init(photo: ImportedPhoto, store: FilePhotoStore?) {
        let luts = LUTStore()
        _lutStore = State(initialValue: luts)
        _model = State(initialValue: EditorModel(
            photo: photo,
            store: store,
            lutProvider: luts.provider
        ))
    }

    /// 图像区手势可切换的参数序列（R007a P0-5：由「仅色彩」扩展为按当前模块给出）。
    /// - 色彩 / 预设 / 蒙版：全部手势可调参数（预设=套用后微调；蒙版=选区局部调整）
    /// - 人像：人像组（磨皮 / 提亮）
    /// - 构图：仅「拉直」——该参数在 EditKit 里标为不进入全局手势序列，
    ///   这里按模块语义（构图=地平线）显式放开，只在本模块内生效
    private var gestureParameters: [EditParameter] {
        switch activeModule {
        case .portrait:
            return EditParameter.allCases.filter { $0.isGestureAdjustable && $0.group == .portrait }
        case .composition:
            return [.straighten]
        case .color, .presets, .mask:
            return EditParameter.allCases.filter { $0.isGestureAdjustable }
        default:
            return []
        }
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
                // R007a P0-4：进入蒙版图上编辑前预热渲染管线（首笔不再为编译内核买单）
                .onChange(of: isMaskEditing) { _, editing in
                    if editing { model.warmUpMaskEditing() }
                }
                // R007a P0-3：内存压力时丢弃缩略图缓存
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    model.clearPresetThumbnailCache()
                }
                // R007a P0-3：订阅缩略图版本号——后台补齐一张就自增一次，
                // 本视图随之重算，预设库 sheet 里的占位图被静默换成真图。
                // 动作为空是刻意的：只借 `.onChange` 的参数求值在 body 期注册 @Observable 依赖。
                .onChange(of: model.presetThumbnailRevision) { _, _ in }
        }
        .overlay { editorOverlays }
        .navigationTitle("编辑")
        .navigationBarTitleDisplayMode(.inline)
        // 顶部工具栏统一材质：与模块条 / 底部面板保持一致（同为 .regularMaterial）
        .toolbarBackground(.regularMaterial, for: .navigationBar)
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
                },
                thumbnail: { recipe in model.presetThumbnail(for: recipe) },
                thumbnailRevision: model.presetThumbnailRevision
            )
            .onAppear {
                // R007a P0-3：面板一出现就按 .utility 后台排队，滚动时基本已命中缓存
                model.prefetchPresetThumbnails(BuiltinRecipes.all + recipeStore.userRecipes, sides: [44])
            }
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
                // 离开「蒙版」模块即退出蒙版图上编辑，避免手势被选区吞掉
                if module != .mask { isMaskEditing = false }
                // R007a P0-5：切模块后参数序列变了，索引与浮层状态一起复位
                activeIndex = 0
                gestureBase = nil
                isSwitchingParameter = false
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
                .onEnded { _ in
                    gestureBase = nil
                    isSwitchingParameter = false
                    settleUntil = nil
                    didFireZeroHaptic = false
                    didFireLimitHaptic = false
                    // R006 追加 A：图像区拖动手势结束 → 升回静止档，补一帧高质量预览。
                    model.endInteractiveEditing()
                }
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
        // R007a P0-5：任何有参数序列的模块（预设/构图/色彩/人像/蒙版）都响应图像区调值；
        // 蒙版图上编辑时优先给选区手势，曲线 / 分级面板自带画布手势。
        guard !gestureParameters.isEmpty, !isMaskEditing,
              panelMode == .gesture || panelMode == .sliders else { return }
        let parameter = activeParameter
        // 方向判定：垂直显著主导 → 切参数；否则水平调值
        let isVertical = abs(g.translation.height) > abs(g.translation.width) * 1.2
        if isVertical {
            gestureBase = nil
            // 归零后的「短暂停顿」窗口内不响应切参数（R006 追加 B2 第 2 条）
            if let until = settleUntil, Date() < until { return }
            // R006 追加 B1：切参数时浮现全屏参数列表浮层
            if !isSwitchingParameter {
                withAnimation(DS.Motion.standard) { isSwitchingParameter = true }
            }
            let steps = Int(g.translation.height / 48)
            let newIndex = min(max(activeIndex + steps, 0), gestureParameters.count - 1)
            if newIndex != activeIndex {
                activeIndex = newIndex
                EditorHaptics.parameterSwitch()   // 分级 1：selection 轻触觉
            }
        } else {
            if isSwitchingParameter {
                withAnimation(DS.Motion.standard) { isSwitchingParameter = false }
            }
            if gestureBase == nil {
                // R007a P0-5：蒙版模块读选区局部值，其余模块读全局值
                if activeModule == .mask, model.selectedMask != nil {
                    gestureBase = model.selectedMask?.value(for: parameter) ?? 0
                } else {
                    gestureBase = model.value(for: parameter)
                }
                didFireZeroHaptic = false
                didFireLimitHaptic = false
                EditorHaptics.warmUp()
            }
            guard let base = gestureBase else { return }
            let range = parameter.defaultRange
            let span = range.upperBound - range.lowerBound
            // 280pt 全程拖动 = 参数满量程（手感系数，后续真机调）
            let delta = g.translation.width / 280 * span
            let value = min(max(base + delta, range.lowerBound), range.upperBound)
            // R007a P0-5：蒙版模块写入选区局部值，其余模块写全局值
            if activeModule == .mask, let maskID = model.selectedMask?.id {
                model.setMaskAdjustment(parameter, value: value, in: maskID)
            } else {
                model.sliderChanged(parameter, value: value)
            }
            fireSliderHaptics(parameter: parameter, base: base, value: value, range: range)
        }
    }

    /// 滑杆触觉分级（R006 追加 B2）：
    /// - **归零**（从非 0 落到 0）→ `medium` 加强震动 + 250ms 停顿窗口（每次拖动只触发一次）
    /// - 触到上下限 → `light` 边界反馈（每次拖动只触发一次）
    private func fireSliderHaptics(parameter: EditParameter,
                                   base: Double,
                                   value: Double,
                                   range: ClosedRange<Double>) {
        if !didFireZeroHaptic, base != 0, value == 0, range.contains(0) {
            didFireZeroHaptic = true
            settleUntil = Date().addingTimeInterval(0.25)
            EditorHaptics.reset()
        }
        if !didFireLimitHaptic, value <= range.lowerBound || value >= range.upperBound {
            didFireLimitHaptic = true
            EditorHaptics.limit()
        }
    }

    /// 全屏叠加层（R006 追加 B1 + 追加 C）。
    @ViewBuilder
    private var editorOverlays: some View {
        ZStack {
            if isSwitchingParameter, !gestureParameters.isEmpty {
                ParameterListOverlay(
                    title: activeModule.label,
                    parameters: gestureParameters,
                    activeIndex: activeIndex,
                    value: { parameter in
                        // R007a P0-5：蒙版模块显示选区局部值，其余模块显示全局值
                        if activeModule == .mask, model.selectedMask != nil {
                            return model.selectedMask?.value(for: parameter) ?? 0
                        }
                        return model.value(for: parameter)
                    },
                    onSelect: { index in
                        guard gestureParameters.indices.contains(index) else { return }
                        activeIndex = index
                        EditorHaptics.parameterSwitch()
                    }
                )
                .transition(.opacity)
                .zIndex(2)
            }

            if model.ai.showsOverlay {
                ProcessingHUD(
                    state: model.ai,
                    onBackground: { model.sendAIToBackground() },
                    onCancel: { model.cancelAIProcessing() }
                )
                .transition(.opacity)
                .zIndex(3)
            }

            if model.ai.isRunning, model.ai.isBackground {
                VStack {
                    HStack {
                        BackgroundProcessingPill(state: model.ai) {
                            model.bringAIToForeground()
                        }
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                }
                .padding(DS.Spacing.md)
                .zIndex(4)
            }
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
                onOpenLibrary: { showPresets = true },
                thumbnail: { recipe in model.presetThumbnail(for: recipe) },
                thumbnailRevision: model.presetThumbnailRevision
            )
            .onAppear {
                model.prefetchPresetThumbnails(BuiltinRecipes.all + recipeStore.userRecipes, sides: [60])
            }
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
        case .mask:
            MaskPanel(model: model, isEditing: $isMaskEditing)
        case .retouch, .clothing, .liquify:
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
            LazyVStack(alignment: .leading, spacing: DS.Spacing.md, pinnedViews: .sectionHeaders) {
                ForEach(groupedParameters.indices, id: \.self) { index in
                    let group = groupedParameters[index].0
                    let parameters = groupedParameters[index].1
                    Section {
                        // 行距交给每行自身的上下留白（各 8pt → 相邻两行视觉间距 16pt，落在 12–16pt 目标带）
                        VStack(spacing: 0) {
                            ForEach(parameters, id: \.self) { parameter in
                                AdjustmentSliderRow(
                                    parameter: parameter,
                                    value: Binding(
                                        get: { model.value(for: parameter) },
                                        set: { model.sliderChanged(parameter, value: $0) }
                                    ),
                                    onAuto: parameter.isAutoTunable
                                        ? { model.autoTuneSingle(parameter) }
                                        : nil,
                                    onReset: { model.sliderChanged(parameter, value: 0) },
                                    onEditingChanged: { editing in
                                        editing ? model.beginInteractiveEditing()
                                                : model.endInteractiveEditing()
                                    }
                                )
                            }
                        }
                    } header: {
                        Label(group.displayName, systemImage: group.symbol)
                            .font(DS.Typography.panelTitle)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, DS.Spacing.sm)
                            .padding(.bottom, DS.Spacing.xs)
                            // 吸顶分组标题必须有实底，否则滚动时滑杆会透出与标题叠字
                            .background(.regularMaterial)
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.bottom, DS.Spacing.xl)
        }
        .frame(maxHeight: 340)
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
    /// 双击数值复位到 0（0 即本项目的中性值：未编辑时 `value(for:)` 返回 0）。带默认值，旧调用点不变。
    var onReset: (() -> Void)?
    /// R006 追加 A：滑杆按下 / 松手（按下切交互档降采样、松手补一帧静止档）。
    /// 与 `onReset` 一样带默认值，未接线的调用点行为不变。
    var onEditingChanged: ((Bool) -> Void)?

    /// 显式 init：新增参数一律带默认值，`MaskPanels` / 模块面板的既有调用点无需改动。
    init(
        parameter: EditParameter,
        value: Binding<Double>,
        onAuto: (() -> Void)? = nil,
        onReset: (() -> Void)? = nil,
        onEditingChanged: ((Bool) -> Void)? = nil
    ) {
        self.parameter = parameter
        self._value = value
        self.onAuto = onAuto
        self.onReset = onReset
        self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: DS.Spacing.sm) {
                Label(parameter.historyLabel, systemImage: parameter.icon)
                    .font(DS.Typography.sliderLabel)
                    .lineLimit(1)
                Spacer(minLength: DS.Spacing.sm)
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
                valueLabel
            }
            Slider(value: $value, in: parameter.defaultRange) { editing in
                onEditingChanged?(editing)
            }
                .tint(DS.accent)
                .padding(.vertical, 2)
        }
        // 行内上下各 8pt → 相邻两行视觉间距 16pt：滑杆不再紧贴上一行的文字
        .padding(.vertical, DS.Spacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(parameter.historyLabel)
        .accessibilityValue(value.formatted(.number.precision(.fractionLength(0...1))))
    }

    /// 数值区：等宽字体（`sliderValue` 自带 monospacedDigit）+ 固定宽度右对齐 → 拖动时不抖动。
    private var valueLabel: some View {
        Text(value, format: .number.precision(.fractionLength(0...1)))
            .font(DS.Typography.sliderValue)
            .foregroundStyle(.secondary)
            .frame(width: 52, alignment: .trailing)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onReset?() }
            .accessibilityHint("双击复位")
    }
}
