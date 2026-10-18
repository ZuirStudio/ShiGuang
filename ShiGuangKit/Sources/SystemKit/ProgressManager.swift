import Foundation

// MARK: - 进度上报器（R009：后续所有耗时任务的唯一进度入口）

/// 耗时任务的进度上报门面：`ProgressTracker`（纯逻辑）× `ProgressPresenting`（灵动岛/锁屏）。
///
/// **纪律（AGENTS.md 第 4 节，R009 写入）**：后续开发凡涉及「批量导出」「AI 消除」
/// 等耗时任务，**必须**通过本门面上报进度 —— 不允许再私接 `Activity.request`。
/// 理由：App 内浮层、锁屏卡片、将来的 Widget 与通知必须同源，否则会出现
/// 「浮层 90% / 灵动岛 40%」的割裂体验（R006 追加 C 的实测教训）。
///
/// 线程模型：`@MainActor` 单例；内部把重活交给 tracker（值类型），
/// 卡片更新走 presenter 协议（可整体替换为 Mock / 空实现）。
@MainActor
public final class ProgressManager {
    /// 进程级单例（UI 浮层与系统卡片共用同一进度源）。
    public static let shared = ProgressManager()

    private var tracker: ProgressTracker
    private let presenter: any ProgressPresenting
    private var title: String
    private var active = false

    /// Live Activity 更新最小间隔（系统对卡片刷新本就限流；300ms 兼顾跟手与配额）。
    private let minUpdateInterval: TimeInterval = 0.3
    private var lastUpdateAt: Date?

    /// - Parameters:
    ///   - presenter: 进度呈现器（默认：Apple 平台用 LiveActivityProgressCenter，
    ///     其他平台用 NullProgressPresenter；测试可注入 Mock）。
    ///   - tracker: 进度跟踪器（默认单步自由式）。
    public init(
        presenter: (any ProgressPresenting)? = nil,
        tracker: ProgressTracker = ProgressTracker()
    ) {
        #if canImport(ActivityKit)
        self.presenter = presenter ?? LiveActivityProgressCenter()
        #else
        self.presenter = presenter ?? NullProgressPresenter()
        #endif
        self.tracker = tracker
        self.title = tracker.steps[0].title
    }

    // MARK: 状态查询（UI 浮层与卡片同源）

    /// 是否有任务在进行。
    public var isActive: Bool { active }

    /// 当前总进度 0...1。
    public var fraction: Double { tracker.fraction }

    /// 当前阶段文案。
    public var phaseTitle: String { tracker.phaseTitle }

    /// 当前任务标题（卡片标题与 App 内提示同源）。
    public var currentTitle: String { title }

    /// 当前步骤（未开始时为第一步）。
    public var currentStep: ProgressStep { tracker.currentStep }

    // MARK: 生命周期

    /// 开始一次任务（幂等：已在进行时忽略，避免重复 request 卡片）。
    /// - Parameter steps: 步骤表；nil = 单步自由式（之后用 `report` 直接给分数）。
    public func begin(title: String, steps: [ProgressStep]? = nil) {
        guard !active else { return }
        if let steps { tracker = ProgressTracker(steps: steps) }
        else { tracker = ProgressTracker() }
        self.title = title
        tracker.begin()
        active = true
        lastUpdateAt = nil
        let snapshot = (tracker.fraction, tracker.phaseTitle)
        let task = Task { [presenter] in
            await presenter.present(
                title: title,
                fraction: snapshot.0,
                phase: snapshot.1,
                detail: detailText()
            )
        }
        _ = task   // 火照忘：卡片请求失败已在 presenter 内静默降级
    }

    /// 前进到某步骤（未知 ID 静默忽略）。
    public func advance(toStepID id: String, detail: String? = nil) {
        guard active else { return }
        guard tracker.advance(toStepID: id) else { return }
        pushUpdate(detail: detail, force: false)
    }

    /// 自由式进度上报（0...1）：AI 消除等无明确步骤的任务直接用。
    public func report(fraction: Double, phase: String, detail: String) {
        guard active else { return }
        tracker.setProgress(fraction)
        tracker.setPhase(phase)
        pushUpdate(detail: detail, force: false)
    }

    /// 成功收尾：进度拉满、卡片以完成态移除。
    public func finish(phase: String = "已完成", detail: String = "") {
        guard active else { return }
        tracker.complete()
        active = false
        let snapshot = (tracker.fraction, phase)
        let task = Task { [presenter] in
            await presenter.dismiss(fraction: snapshot.0, phase: snapshot.1, detail: detail)
        }
        _ = task
    }

    /// 取消 / 失败收尾：卡片立即移除，不残留。
    public func cancel(phase: String = "已取消", detail: String = "") {
        guard active else { return }
        active = false
        let snapshot = (tracker.fraction, phase)
        let task = Task { [presenter] in
            await presenter.dismiss(fraction: snapshot.0, phase: snapshot.1, detail: detail)
        }
        _ = task
    }

    // MARK: 私有

    /// 卡片刷新（带 300ms 节流；阶段切换不受限 —— 阶段信息比高频分数更重要）。
    private func pushUpdate(detail: String?, force: Bool) {
        let now = Date()
        if !force, let last = lastUpdateAt, now.timeIntervalSince(last) < minUpdateInterval {
            return
        }
        lastUpdateAt = now
        let snapshot = (tracker.fraction, tracker.phaseTitle)
        let text = detail ?? detailText()
        let task = Task { [presenter] in
            await presenter.update(fraction: snapshot.0, phase: snapshot.1, detail: text)
        }
        _ = task
    }

    /// 次要说明文案：步骤式任务显示「第 x / n 步」。
    private func detailText() -> String {
        let index = tracker.currentIndex + 1
        let total = tracker.steps.count
        guard total > 1 else { return tracker.currentStep.title }
        return "第 \(max(index, 1)) / \(total) 步"
    }
}
