import Foundation
import CoreGraphics
import ImageIO

// MARK: - 批量导出（R009 架构预留）

/// 批量导出请求：一组图像 + 统一导出选项。
///
/// 为 v1.5.0「批量修图」预留：多张照片共享同一份编辑结果（Recipe）时，
/// 经后台并发队列一次性导出，进度由 `progress` 闭包实时上报
/// （App 层桥接到 SystemKit `ProgressManager` → 灵动岛 / 锁屏）。
///
/// CGImage 为不可变位图，跨并发边界安全（与 SDK 的 Sendable 标注一致）；
/// 但 CGImage 无 Equatable，故本结构只承诺 Sendable。
public struct BatchExportRequest: Sendable {
    /// 待导出图像（顺序即结果顺序，与调用方图集一一对应）。
    public var images: [CGImage]
    /// 统一导出选项（格式 / 质量 / 尺寸 / 色彩空间 / 元数据 / 水印）。
    public var options: ExportOptions
    /// 输出目录（nil → 系统临时目录；文件名带 UUID，并行互不覆盖）。
    public var directory: URL?
    /// 并发度上限（nil → 按 CPU 核心数与图数自适应，封顶 8）。
    public var maxConcurrentTasks: Int?

    public init(
        images: [CGImage],
        options: ExportOptions = ExportOptions(),
        directory: URL? = nil,
        maxConcurrentTasks: Int? = nil
    ) {
        self.images = images
        self.options = options
        self.directory = directory
        self.maxConcurrentTasks = maxConcurrentTasks
    }

    /// 默认并发上限：核心数与图数的较小值，封顶 8（避免 I/O 抖动与内存峰值）。
    public static let defaultMaxConcurrent = 8

    /// 实际采用的并发度（纯计算，可单测）。
    public func effectiveConcurrency() -> Int {
        let cap = max(1, min(maxConcurrentTasks ?? Self.defaultMaxConcurrent, Self.defaultMaxConcurrent))
        return max(1, min(cap, images.count))
    }
}

/// 批量导出进度（`completed / total`，供进度条与灵动岛消费）。
public struct BatchExportProgress: Sendable, Equatable {
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

/// 单张导出结果：成功给 URL，失败给错误描述（**批量不因单张失败中断**）。
public struct BatchExportResult: Sendable, Equatable {
    /// 在请求 `images` 中的下标（结果数组按下标归位，保证与输入同序）。
    public var index: Int
    /// 成功时的文件 URL。
    public var url: URL?
    /// 失败时的错误描述（nil = 成功）。
    public var errorDescription: String?

    public init(index: Int, url: URL?, errorDescription: String?) {
        self.index = index
        self.url = url
        self.errorDescription = errorDescription
    }

    public var isSuccess: Bool { url != nil && errorDescription == nil }
}

/// 批量导出能力协议（与 AICore 的协议化风格一致：App 只依赖协议，可替换实现 / 可 Mock）。
public protocol BatchExportProviding: Sendable {
    func export(
        _ request: BatchExportRequest,
        progress: @escaping @Sendable (BatchExportProgress) -> Void
    ) async throws -> [BatchExportResult]
}

// MARK: - 实现

/// 并发批量导出器：TaskGroup 限流调度，逐张写盘，单张失败不中断整批。
public struct BatchExporter: BatchExportProviding {
    public init() {}

    public func export(
        _ request: BatchExportRequest,
        progress: @escaping @Sendable (BatchExportProgress) -> Void
    ) async throws -> [BatchExportResult] {
        let total = request.images.count
        guard total > 0 else { return [] }

        let accumulator = ResultAccumulator(count: total)
        let limit = request.effectiveConcurrency()
        let directory = request.directory ?? FileManager.default.temporaryDirectory

        // 固定索引数组在闭包间共享（值类型，无数据竞争）
        await withTaskGroup(of: (Int, BatchExportResult).self) { group in
            var nextIndex = 0

            // 播种：先填满并发窗口
            // 注意：TaskGroup 子任务是 @Sendable 闭包，可变局部变量必须先绑定为
            // 常量再捕获（Swift 6 严格并发），否则编译期报「并发执行中捕获可变变量」。
            while nextIndex < min(limit, total) {
                let index = nextIndex
                group.addTask {
                    Self.exportOne(
                        request.images[index],
                        index: index,
                        options: request.options,
                        directory: directory
                    )
                }
                nextIndex += 1
            }

            // 滑窗：完成一张补一张，窗口大小恒为 limit
            while let (index, result) = await group.next() {
                await accumulator.record(result, at: index) { snapshot in
                    progress(BatchExportProgress(completed: snapshot, total: total))
                }
                if nextIndex < total {
                    let index = nextIndex
                    group.addTask {
                        Self.exportOne(
                            request.images[index],
                            index: index,
                            options: request.options,
                            directory: directory
                        )
                    }
                    nextIndex += 1
                }
            }
        }

        return await accumulator.results()
    }

    /// 单张导出（nonisolated static：TaskGroup 子任务直接调用）。
    /// autoreleasepool 包裹：批量 100+ 张时及时释放中间位图，压低内存峰值。
    private nonisolated static func exportOne(
        _ image: CGImage,
        index: Int,
        options: ExportOptions,
        directory: URL
    ) -> (Int, BatchExportResult) {
        let result = autoreleasepool { () -> BatchExportResult in
            let url = directory
                .appendingPathComponent("ShiGuang-Batch-\(UUID().uuidString)")
                .appendingPathExtension(options.format.fileExtension)
            do {
                try PhotoExporter.write(image, options: options, to: url)
                return BatchExportResult(index: index, url: url, errorDescription: nil)
            } catch {
                return BatchExportResult(index: index, url: nil, errorDescription: String(describing: error))
            }
        }
        return (index, result)
    }
}

/// 结果收集 + 进度上报（actor 隔离，规避 Swift 6 严格并发下的共享可变状态）。
private actor ResultAccumulator {
    private var slots: [BatchExportResult?]
    private var completed = 0

    init(count: Int) {
        slots = Array(repeating: nil, count: count)
    }

    /// 记录一张结果；`onProgress` 在记录后同步调用（带最新完成数）。
    func record(_ result: BatchExportResult, at index: Int, onProgress: @escaping @Sendable (Int) -> Void) {
        guard slots.indices.contains(index), slots[index] == nil else { return }
        slots[index] = result
        completed += 1
        onProgress(completed)
    }

    /// 按下标归位的结果数组（与请求 `images` 同序）。
    func results() -> [BatchExportResult] {
        slots.compactMap { $0 }
    }
}
