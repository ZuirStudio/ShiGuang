import Foundation
import CoreImage
import PhotoIO
import EditKit
import RenderKit
import SystemKit

// MARK: - 批量处理编排（R010：v1.5.0「批量修图」的 App 侧装配）

/// 把「多张照片 × 同一份 Recipe」跑完：加载 → 渲染 → 导出 → 存回照片库。
///
/// 分工（AGENTS.md 第 2 节：UI 层只做组装，可测逻辑在模块里）：
/// - 渲染并发编排在 `RenderKit.BatchRenderer`（TaskGroup 限流 + 单张失败不中断）
/// - 导出并发编排在 `PhotoIO.BatchExporter`（同构）
/// - 进度真源在 `SystemKit.ProgressManager`（第 4.3 节纪律：唯一进度入口，
///   驱动 App 内浮层 / 灵动岛 / 锁屏卡片；**禁止**私接第二套进度源）
/// - 本类只做三段的接线、进度折算（渲染 0…0.6 / 导出 0.6…1.0）与结果汇总
///
/// 取消语义（R010 务实口径）：渲染/导出子任务内部不观测取消（与既有
/// `BatchExporter` 一致），cancel 后在**阶段边界**生效 —— 在飞的那张跑完
/// 即整体作废，不会写回照片库。
@Observable @MainActor
final class BatchProcessModel {
    /// 处理阶段（驱动进度折算区间与文案）。
    enum Stage: Equatable {
        case preparing
        case render
        case export
        case done

        /// 本阶段进度在总进度里的占比区间。
        var range: ClosedRange<Double> {
            switch self {
            case .preparing, .done: return 0...1
            case .render: return 0...0.6
            case .export: return 0.6...1
            }
        }
    }

    // MARK: 输入

    /// 待处理照片（顺序即结果顺序）。
    let photos: [ImportedPhoto]
    /// 可选预设（内置 + 用户自定义）。
    let recipes: [Recipe]
    /// 当前选中的预设 id。
    var selectedRecipeID: UUID?

    // MARK: 运行态（视图只读）

    private(set) var isRunning = false
    private(set) var stage: Stage = .preparing
    /// 当前阶段已完成数（与 `total` 同口径）。
    private(set) var completed = 0
    /// 当前阶段总数。
    private(set) var total = 0
    /// 当前阶段文案（如「正在渲染 2/5」）。
    private(set) var phase = ""
    private(set) var successCount = 0
    private(set) var failureCount = 0
    /// 成功件已存回照片库的数量。
    private(set) var savedCount = 0
    private(set) var errorText: String?
    /// 用户取消了本次处理（结果作废，不写回）。
    private(set) var wasCancelled = false

    private var runTask: Task<Void, Never>?

    init(photos: [ImportedPhoto], recipes: [Recipe], selectedRecipeID: UUID? = nil) {
        self.photos = photos
        self.recipes = recipes
        self.selectedRecipeID = selectedRecipeID ?? recipes.first?.id
    }

    var selectedRecipe: Recipe? {
        recipes.first { $0.id == selectedRecipeID }
    }

    /// 总进度 0...1（渲染段 60% + 导出段 40% 折算）。
    var fraction: Double {
        guard total > 0 else { return 0 }
        let local = min(max(Double(completed) / Double(total), 0), 1)
        let range = stage.range
        return range.lowerBound + (range.upperBound - range.lowerBound) * local
    }

    var canStart: Bool {
        !isRunning && selectedRecipe != nil && !photos.isEmpty
    }

    // MARK: 生命周期

    func start(store: FilePhotoStore?) {
        guard canStart, let recipe = selectedRecipe else { return }
        isRunning = true
        wasCancelled = false
        errorText = nil
        stage = .preparing
        completed = 0
        total = photos.count
        successCount = 0
        failureCount = 0
        savedCount = 0
        phase = "正在准备"

        ProgressManager.shared.begin(title: "批量处理 · \(recipe.name)")

        // 全部输入先落地为局部常量：detached 闭包不捕获 @MainActor 的 self
        // （与 `EditorModel.export` 同模式 —— 那边也只捕获 graph/photo/store）。
        let photos = self.photos
        let operations = recipe.resolvedOperations()
        let recipeName = recipe.name

        runTask = Task.detached(priority: .userInitiated) {
            // 阶段 0：载入全图（`fullCIImage` 是 nonisolated，actor 外可调；
            // 缺失/损坏的源记空图 → 渲染段按失败位处理，不炸整批）
            let images: [CIImage] = photos.map { store?.fullCIImage(for: $0) ?? CIImage() }
            guard !Task.isCancelled else {
                await Self.finishCancelled()
                return
            }

            // 阶段 1：渲染（TaskGroup 限流并发；进度折算到 0...0.6）
            let rendered: [CGImage?] = await BatchRenderer().render(
                images, operations: operations
            ) { progress in
                guard !Task.isCancelled else { return }
                Task { @MainActor [weak self] in
                    guard let self, !self.wasCancelled else { return }
                    self.stage = .render
                    self.completed = progress.completed
                    self.total = progress.total
                    self.phase = "正在渲染 \(progress.completed)/\(progress.total)"
                    ProgressManager.shared.report(
                        fraction: progress.fraction * 0.6,
                        phase: "正在渲染", detail: "\(progress.completed)/\(progress.total)")
                }
            }
            guard !Task.isCancelled else {
                await Self.finishCancelled()
                return
            }

            // 阶段 2：导出（渲染成功的才进导出；失败位计入失败数）
            var exportImages: [CGImage] = []
            for image in rendered {
                if let image { exportImages.append(image) }
            }

            var results: [BatchExportResult] = []
            if !exportImages.isEmpty {
                let request = BatchExportRequest(images: exportImages)
                results = (try? await BatchExporter().export(request) { progress in
                    guard !Task.isCancelled else { return }
                    Task { @MainActor [weak self] in
                        guard let self, !self.wasCancelled else { return }
                        self.stage = .export
                        self.completed = progress.completed
                        self.total = progress.total
                        self.phase = "正在导出 \(progress.completed)/\(progress.total)"
                        ProgressManager.shared.report(
                            fraction: 0.6 + 0.4 * progress.fraction,
                            phase: "正在导出", detail: "\(progress.completed)/\(progress.total)")
                    }
                }) ?? []
            }
            guard !Task.isCancelled else {
                await Self.finishCancelled()
                return
            }

            // 阶段 3：成功件存回照片库（App 沙盒内，无需相册权限；
            // 之后在「拾光」图库里可见，可继续编辑）。
            // 取消后跑到这里也不写回（用户已看到「已取消」）。
            guard !Task.isCancelled else {
                await Self.finishCancelled()
                return
            }
            var successURLs: [URL] = []
            for result in results where result.isSuccess {
                if let url = result.url { successURLs.append(url) }
            }
            var saved = 0
            if let store {
                for url in successURLs {
                    guard let data = try? Data(contentsOf: url) else { continue }
                    if (try? await store.save(imageData: data, preferredExtension: "jpg")) != nil {
                        saved += 1
                    }
                }
            }

            let successes = successURLs.count
            let failures = photos.count - successes

            Task { @MainActor [weak self] in
                guard let self, !self.wasCancelled else { return }
                self.isRunning = false
                self.stage = .done
                self.completed = self.total
                self.phase = saved > 0 ? "完成 · 已存回照片库" : "完成"
                self.successCount = successes
                self.failureCount = failures
                self.savedCount = saved
                ProgressManager.shared.finish(
                    phase: "已完成",
                    detail: "「\(recipeName)」成功 \(successes) 张 / 失败 \(failures) 张")
                EditorHaptics.completed()
            }
        }
    }

    /// 用户取消：任务在下一阶段边界作废（在飞的那张跑完即弃）。
    func cancel() {
        guard isRunning else { return }
        wasCancelled = true
        runTask?.cancel()
        runTask = nil
        isRunning = false
        phase = "已取消"
        ProgressManager.shared.cancel(phase: "已取消", detail: "批量处理已取消")
        EditorHaptics.cancelled()
    }

    /// 阶段边界取消收尾（detached 上下文经 await 切回 MainActor）。
    @MainActor
    private static func finishCancelled() {
        ProgressManager.shared.cancel(phase: "已取消", detail: "批量处理已取消")
        EditorHaptics.cancelled()
    }
}
