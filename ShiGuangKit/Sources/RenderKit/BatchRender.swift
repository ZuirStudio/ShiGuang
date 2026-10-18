import CoreImage
import CoreGraphics
import EditKit

// MARK: - 批量渲染（R010：v1.5.0「批量修图」的渲染侧）

/// 批量渲染进度（`completed / total`）。
///
/// 与 `PhotoIO.BatchExportProgress` 同构但**不跨模块依赖**：RenderKit 只依赖
/// EditKit（模块图纪律），PhotoIO 不依赖 RenderKit；两边各自持同形状值类型，
/// App 层负责把两段进度折算成同一条 0...1 进度（经 `SystemKit.ProgressManager`）。
public struct BatchRenderProgress: Sendable, Equatable {
    public var completed: Int
    public var total: Int

    public init(completed: Int, total: Int) {
        self.completed = completed
        self.total = total
    }

    /// 0...1（total = 0 时定义为 0）。
    public var fraction: Double {
        total > 0 ? min(max(Double(completed) / Double(total), 0), 1) : 0
    }
}

/// 批量渲染选项。
public struct BatchRenderOptions: Sendable, Equatable {
    /// 管线输入长边上限（只缩不放大）。
    ///
    /// 与 `EditorModel.exportPipelineLongEdge`（4096）同值：48MP 原图直进
    /// Core Image 管线是真机 cgImage 峰值 13.9s 的直接嫌疑人（R007d 取证），
    /// 封顶后最坏出图耗时被硬截断，对手机端成片仍视觉无损。
    public var longEdge: CGFloat

    /// 并发度上限（nil → 按 CPU 核心数与图数自适应，封顶 `defaultMaxConcurrent`）。
    public var maxConcurrentTasks: Int?

    public static let defaultLongEdge: CGFloat = 4096
    /// 默认并发上限：封顶 4 —— 批量渲染的峰值内存 = 并发数 × 单张 CGImage
    /// （4096 长边 ≈ 16MP ≈ 64MB/张），4 路约 256MB 量级，留足系统余量。
    public static let defaultMaxConcurrent = 4

    public init(longEdge: CGFloat = BatchRenderOptions.defaultLongEdge,
                maxConcurrentTasks: Int? = nil) {
        self.longEdge = longEdge
        self.maxConcurrentTasks = maxConcurrentTasks
    }

    /// 实际采用的并发度（纯计算，可单测）。
    public func effectiveConcurrency(imageCount: Int) -> Int {
        let cap = max(1, min(maxConcurrentTasks ?? Self.defaultMaxConcurrent, Self.defaultMaxConcurrent))
        return max(1, min(cap, imageCount))
    }
}

/// 批量渲染能力协议（与 `PhotoIO.BatchExportProviding` / AICore 协议化风格一致：
/// App 只依赖协议，可替换实现 / 可 Mock）。
public protocol BatchRenderProviding: Sendable {
    /// 把同一份编辑指令应用到多张图。结果与输入**同序**（失败位为 nil，
    /// 不因单张失败中断整批）。
    func render(
        _ images: [CIImage],
        operations: [EditOperation],
        options: BatchRenderOptions,
        progress: @escaping @Sendable (BatchRenderProgress) -> Void
    ) async -> [CGImage?]
}

// MARK: - 实现

/// 并发批量渲染器：TaskGroup 限流调度，单张失败不中断整批。
///
/// 设计口径（与 `PhotoIO.BatchExporter` 对偶）：
/// - **渲染上下文复用 `RenderContext.export`**：CIContext 线程安全但不并行，
///   并发提交会在其队列里自动串行（R007c 取证结论）—— 既不会与预览热路径
///   争抢（导出独占 context），也无需每张图新建 context（10–30ms/个）。
/// - **降采样进模块**：长边钳制（只缩不放大）在此完成，调用方只交原图。
/// - **跨任务边界只传不可变 CGImage**（SDK 标注 Sendable），CIImage 不进结果。
public struct BatchRenderer: BatchRenderProviding {
    public init() {}

    public func render(
        _ images: [CIImage],
        operations: [EditOperation],
        options: BatchRenderOptions = BatchRenderOptions(),
        progress: @escaping @Sendable (BatchRenderProgress) -> Void
    ) async -> [CGImage?] {
        let total = images.count
        guard total > 0 else { return [] }

        // R007b-1 铁律：跨隔离域（TaskGroup 子任务）传值显式装箱 ——
        // CIImage 不可变，装箱后不被其它持有者改写，@unchecked 断言成立
        //（与 AICore `SendableSegmentImage` / App `SendableCGImage` 同模式）。
        let box = ImageBox(images)
        let accumulator = SlotAccumulator(count: total)
        let limit = options.effectiveConcurrency(imageCount: total)

        await withTaskGroup(of: (Int, CGImage?).self) { group in
            var nextIndex = 0

            // 播种：先填满并发窗口
            // 注意：TaskGroup 子任务是 @Sendable 闭包，可变局部变量必须先绑定为
            // 常量再捕获（Swift 6 严格并发），否则编译期报「并发执行中捕获可变变量」。
            while nextIndex < min(limit, total) {
                let index = nextIndex
                group.addTask {
                    Self.renderOne(
                        box.images[index],
                        index: index,
                        operations: operations,
                        longEdge: options.longEdge
                    )
                }
                nextIndex += 1
            }

            // 滑窗：完成一张补一张，窗口大小恒为 limit
            while let (index, image) = await group.next() {
                await accumulator.record(image, at: index) { snapshot in
                    progress(BatchRenderProgress(completed: snapshot, total: total))
                }
                if nextIndex < total {
                    let index = nextIndex
                    group.addTask {
                        Self.renderOne(
                            box.images[index],
                            index: index,
                            operations: operations,
                            longEdge: options.longEdge
                        )
                    }
                    nextIndex += 1
                }
            }
        }

        return await accumulator.results()
    }

    /// 单张渲染（nonisolated static：TaskGroup 子任务直接调用）。
    /// autoreleasepool 包裹：批量 N 张时及时释放中间位图，压低内存峰值。
    /// 空 / 无限 extent 的输入直接记失败（nil）—— `createCGImage` 对
    /// 无限 extent 会抛 NSException（Swift do/catch 兜不住），必须在前面截断。
    private nonisolated static func renderOne(
        _ image: CIImage,
        index: Int,
        operations: [EditOperation],
        longEdge: CGFloat
    ) -> (Int, CGImage?) {
        let result = autoreleasepool { () -> CGImage? in
            let extent = image.extent
            guard extent.width >= 1, extent.height >= 1,
                  !extent.isInfinite, !extent.isEmpty else { return nil }
            let source = downscaled(image, longEdge: longEdge)
            let rendered = BasicAdjustmentRenderer()
                .render(source: source, graph: EditGraph(operations: operations))
            let outExtent = rendered.extent
            guard outExtent.width >= 1, outExtent.height >= 1,
                  !outExtent.isInfinite, !outExtent.isEmpty else { return nil }
            return RenderContext.export.createCGImage(rendered, from: outExtent)
        }
        return (index, result)
    }

    /// 把图像钳到指定长边以内（只缩不放大；与导出路径同构的懒变换 + 整数裁剪）。
    /// internal（非 private）：供 `@testable` 单测直接验证钳制行为。
    nonisolated static func downscaled(_ image: CIImage, longEdge: CGFloat) -> CIImage {
        let maxDim = max(image.extent.width, image.extent.height)
        let scale = min(1, longEdge / maxDim)
        guard scale < 1, maxDim >= 1 else { return image }
        let transformed = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return transformed.cropped(to: CGRect(
            x: 0, y: 0,
            width: (image.extent.width * scale).rounded(),
            height: (image.extent.height * scale).rounded()
        ))
    }
}

/// 结果收集 + 进度上报（actor 隔离，规避 Swift 6 严格并发下的共享可变状态）。
/// 与 `PhotoIO.ResultAccumulator` 同构；`recorded` 位图区分「未记录」与
/// 「记录为失败（nil）」—— 失败也是有效结果，要计入 completed。
private actor SlotAccumulator {
    private var slots: [CGImage?]
    private var recorded: [Bool]
    private var completed = 0

    init(count: Int) {
        slots = Array(repeating: nil, count: count)
        recorded = Array(repeating: false, count: count)
    }

    /// 记录一张结果；`onProgress` 在记录后同步调用（带最新完成数）。
    func record(_ image: CGImage?, at index: Int, onProgress: @escaping @Sendable (Int) -> Void) {
        guard slots.indices.contains(index), !recorded[index] else { return }
        slots[index] = image
        recorded[index] = true
        completed += 1
        onProgress(completed)
    }

    /// 按下标归位的结果数组（与输入同序）。
    func results() -> [CGImage?] { slots }
}

/// 跨 TaskGroup 边界传递的不可变图像箱（R007b-1 铁律：显式装箱）。
/// CIImage 不可变且文档承诺线程安全 → `@unchecked` 断言成立。
private final class ImageBox: @unchecked Sendable {
    let images: [CIImage]
    init(_ images: [CIImage]) { self.images = images }
}
