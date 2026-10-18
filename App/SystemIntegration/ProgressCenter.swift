import Foundation

// 拾光 · R010-B 系统集成 · app/ProgressCenter.swift
// 编译目标：仅主 App Target
//
// 设计：所有耗时任务的调用点只依赖本文件的 ProgressCenter，
//       不直接依赖任何具体后端。默认后端是灵动岛实时活动；
//       若主工程的 SystemKit.ProgressManager 才是权威进度源，
//       启动时一行切换：ProgressCenter.reporter = <你的桥接实现>。

// MARK: - 契约

/// 耗时任务进度上报契约。
public protocol ProgressReporting: AnyObject {
    func begin(task: ProgressTaskDescriptor)
    func report(_ snapshot: ProgressSnapshot)
    func finish(summary: String)
    func fail(message: String)
    func cancel()
}

/// 任务描述（begin 时一次性给定）
public struct ProgressTaskDescriptor {
    public var title: String
    /// 总数；0 = 不确定进度（AI 处理耗时未知）
    public var total: Int
    public var subtitle: String?

    public init(title: String, total: Int, subtitle: String? = nil) {
        self.title = title
        self.total = total
        self.subtitle = subtitle
    }
}

/// 进度快照（每次 step 时上报）
public struct ProgressSnapshot {
    public var completed: Int
    public var total: Int
    public var currentItemName: String

    public init(completed: Int, total: Int, currentItemName: String = "") {
        self.completed = completed
        self.total = total
        self.currentItemName = currentItemName
    }

    /// 进度 0...1；不确定进度返回 0
    public var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    public var isIndeterminate: Bool { total <= 0 }
}

// MARK: - 全局入口

/// 耗时任务进度全局入口。
///
/// 典型用法：
/// ```swift
/// ProgressCenter.begin("批量导出", total: photos.count)
/// ProgressCenter.step(completed: i + 1, total: photos.count, currentItem: name)
/// ProgressCenter.finish("已导出 3 张照片")
/// ```
///
/// 或使用便捷封装（自动处理 begin / fail / finish）：
/// ```swift
/// try await ProgressCenter.trackBatch(title: "批量导出", items: photos) { photo in
///     try await exporter.export(photo)
/// }
/// try await ProgressCenter.trackIndeterminate(title: "人像磨皮") {
///     try await retoucher.smooth(photo)
/// }
/// ```
// @MainActor：ProgressCenter 的 _reporter/reporter 是全局可变静态属性，
// Swift 6 要求隔离；调用点（含后台 AppIntents）使用时应已在主线程或显式 hop。
@MainActor
public enum ProgressCenter {

    private static var _reporter: ProgressReporting = {
        if #available(iOS 16.1, *) {
            return LiveActivityProgressReporter.shared
        } else {
            return NoopProgressReporter.shared
        }
    }()

    /// 当前后端。默认 LiveActivityProgressReporter（灵动岛）；
    /// 可在 App 启动时替换为 SystemKit.ProgressManager 的桥接实现。
    public static var reporter: ProgressReporting {
        get { _reporter }
        set { _reporter = newValue }
    }

    // MARK: 基础上报

    /// 开始一个耗时任务（会在灵动岛 / 锁屏显示实时活动）
    public static func begin(_ title: String, total: Int, subtitle: String? = nil) {
        reporter.begin(task: ProgressTaskDescriptor(title: title, total: total, subtitle: subtitle))
    }

    /// 上报确定进度
    public static func step(completed: Int, total: Int, currentItem: String? = nil) {
        reporter.report(
            ProgressSnapshot(completed: completed, total: total, currentItemName: currentItem ?? "")
        )
    }

    /// 上报不确定进度（AI 处理耗时未知；界面显示转圈）
    public static func stepIndeterminate(currentItem: String? = nil) {
        reporter.report(ProgressSnapshot(completed: 0, total: 0, currentItemName: currentItem ?? ""))
    }

    /// 成功结束
    public static func finish(_ summary: String = "已完成") {
        reporter.finish(summary: summary)
    }

    /// 失败结束（实时活动会展示错误信息后自动消失）
    public static func fail(_ message: String) {
        reporter.fail(message: message)
    }

    /// 用户取消（立即撤销实时活动）
    public static func cancel() {
        reporter.cancel()
    }

    // MARK: 便捷封装

    /// 不确定进度包裹：自动 begin / fail / finish。
    /// 适用于人像磨皮、未来消除等单次 AI 处理。
    public static func trackIndeterminate(
        title: String,
        currentItem: String? = nil,
        _ operation: () async throws -> Void
    ) async throws {
        begin(title, total: 0)
        stepIndeterminate(currentItem: currentItem)
        do {
            try await operation()
        } catch {
            fail(error.localizedDescription)
            throw error
        }
        finish("处理完成")
    }

    /// 批量进度包裹：按张推进，支持每项完成回调。
    /// 适用于批量导出、AI 批量处理。
    public static func trackBatch<Item>(
        title: String,
        items: [Item],
        name: ((Item) -> String)? = nil,
        onItemCompleted: ((Item) -> Void)? = nil,
        _ operation: (Item) async throws -> Void
    ) async throws {
        guard !items.isEmpty else { return }

        begin(title, total: items.count)
        for (index, item) in items.enumerated() {
            if Task.isCancelled {
                cancel()
                throw CancellationError()
            }
            do {
                try await operation(item)
            } catch {
                fail("处理失败：\(error.localizedDescription)")
                throw error
            }
            step(completed: index + 1, total: items.count, currentItem: name?(item) ?? "")
            onItemCompleted?(item)
        }
        finish("已处理 \(items.count) 项")
    }
}

// MARK: - 空实现（iOS < 16.1 兜底）

final class NoopProgressReporter: ProgressReporting, Sendable {
    static let shared = NoopProgressReporter()

    private init() {}

    func begin(task: ProgressTaskDescriptor) {}
    func report(_ snapshot: ProgressSnapshot) {}
    func finish(summary: String) {}
    func fail(message: String) {}
    func cancel() {}
}
