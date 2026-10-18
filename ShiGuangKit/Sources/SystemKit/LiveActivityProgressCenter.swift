import Foundation

// MARK: - Live Activity 属性契约（R009 入主 SystemKit）

/// 实时活动的属性契约（原 `Shared/ProcessingActivityAttributes.swift`，
/// R009 起以 SystemKit 为唯一真源；`Shared/` 保留 typealias 兼容既有引用）。
///
/// 同时编译进主 App 与（将来的）Widget 扩展 —— 只依赖 Foundation 与 ActivityKit。
#if canImport(ActivityKit)
import ActivityKit

public struct ShiGuangProgressAttributes: ActivityAttributes, Sendable {

    /// 可变状态：由 App 在处理期间不断刷新（与 App 内浮层同源）。
    public struct ContentState: Codable, Hashable, Sendable {
        /// 0...1
        public var fraction: Double
        /// 当前阶段文案，例如「识别人像轮廓」
        public var phaseTitle: String
        /// 次要说明，例如「第 2 / 3 步」
        public var detail: String

        public init(fraction: Double, phaseTitle: String, detail: String) {
            self.fraction = fraction
            self.phaseTitle = phaseTitle
            self.detail = detail
        }
    }

    /// 固定属性：一次处理任务的标题。
    public var title: String

    public init(title: String = "拾光 · 处理中") {
        self.title = title
    }
}
#endif

// MARK: - 进度呈现协议

/// 进度呈现能力（灵动岛 / 锁屏 / 将来的 Widget）。
/// 协议化动机（R008-2 宪法规范 3）：App 只依赖协议，可替换实现、可 Mock、可静默降级。
public protocol ProgressPresenting: Sendable {
    /// 设备 / 系统是否可用（实时活动被关闭时整体降级为「只有 App 内浮层」）。
    var isAvailable: Bool { get }
    /// 新建一张进度卡片（幂等由调用方保证）。
    func present(title: String, fraction: Double, phase: String, detail: String) async
    /// 刷新进度。
    func update(fraction: Double, phase: String, detail: String) async
    /// 收尾并移除卡片（成功 / 取消 / 失败都立即移除，不残留）。
    func dismiss(fraction: Double, phase: String, detail: String) async
}

/// 空实现：不支持实时活动的平台 / 测试替身。
public struct NullProgressPresenter: ProgressPresenting {
    public init() {}

    public var isAvailable: Bool { false }

    public func present(title: String, fraction: Double, phase: String, detail: String) async {}
    public func update(fraction: Double, phase: String, detail: String) async {}
    public func dismiss(fraction: Double, phase: String, detail: String) async {}
}

// MARK: - Live Activity 呈现器

#if canImport(ActivityKit)
/// ActivityKit 呈现器：把进度镜像到锁屏卡片 / 灵动岛。
///
/// 隔离模式沿用主 App 既有解法（R006 追加 C 的 CI 实测结论）：
/// `Activity` 是非 Sendable 的 class，其 `update/end` 是 nonisolated async ——
/// 直接 `await` 会触发 Swift 6「sending non-Sendable 值」报错。
/// 因此把 `Activity` 关进 `@unchecked Sendable` 盒子里，所有跨隔离 async
/// 调用都发生在盒子内部的 nonisolated 上下文里。
///
/// 降级路径：`ActivityAuthorizationInfo().areActivitiesEnabled` 为 false
/// 或 `Activity.request` 抛错（权限被拒 / 系统限制）时，静默转为无卡片模式，
/// 绝不影响主流程。
@MainActor
public final class LiveActivityProgressCenter: ProgressPresenting {
    private var box: ActivityBox?

    public init() {}

    /// nonisolated：可用性查询不触碰隔离状态（`ActivityAuthorizationInfo` 为值类型），
    /// 且协议要求是 nonisolated 的（Swift 6：隔离属性不能作 nonisolated 需求的见证）。
    public nonisolated var isAvailable: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    public var isActive: Bool { box != nil }

    public func present(title: String, fraction: Double, phase: String, detail: String) async {
        guard box == nil, isAvailable else { return }
        let attributes = ShiGuangProgressAttributes(title: title)
        let state = ShiGuangProgressAttributes.ContentState(
            fraction: min(max(fraction, 0), 1),
            phaseTitle: phase,
            detail: detail
        )
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            box = ActivityBox(activity)
        } catch {
            box = nil
        }
    }

    public func update(fraction: Double, phase: String, detail: String) async {
        guard let box else { return }
        let state = ShiGuangProgressAttributes.ContentState(
            fraction: min(max(fraction, 0), 1),
            phaseTitle: phase,
            detail: detail
        )
        let content = ActivityContent(state: state, staleDate: nil)
        Task { await box.update(content) }
    }

    public func dismiss(fraction: Double, phase: String, detail: String) async {
        guard let box else { return }
        self.box = nil
        let state = ShiGuangProgressAttributes.ContentState(
            fraction: min(max(fraction, 0), 1),
            phaseTitle: phase,
            detail: detail
        )
        let content = ActivityContent(state: state, staleDate: nil)
        Task { await box.end(content) }
    }
}

/// 隔离盒：非 Sendable 的 `Activity` 从不跨隔离域传递，
/// 所有 async 调用收敛在盒子内部的 nonisolated 上下文。
private final class ActivityBox: @unchecked Sendable {
    private let activity: Activity<ShiGuangProgressAttributes>

    init(_ activity: Activity<ShiGuangProgressAttributes>) {
        self.activity = activity
    }

    func update(_ content: ActivityContent<ShiGuangProgressAttributes.ContentState>) async {
        await activity.update(content)
    }

    func end(_ content: ActivityContent<ShiGuangProgressAttributes.ContentState>) async {
        await activity.end(content, dismissalPolicy: .immediate)
    }
}
#endif
