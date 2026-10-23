import ActivityKit
import Foundation

// 拾光 · R010-B 系统集成 · app/LiveActivityProgressReporter.swift
// 编译目标：仅主 App Target
//
// 基于 ActivityKit 的进度上报后端：驱动灵动岛 / 锁屏实时活动。
// 由 ProgressCenter 默认装配；调用方无需直接使用本类型。
//
// 前置条件：
//   1. 主 App Info.plist：NSSupportsLiveActivities = YES
//   2. Deployment Target ≥ iOS 16.1
//   3. 用户可能在系统设置里关闭实时活动：request 会抛错，已容错降级。
//
// 并发模型（Swift 6 严格并发，R010-B-Fix-10/11 CI 实测结论）：
//   - `Activity` 为非 Sendable 的 class，其 update / end 为 nonisolated async；
//     `Activity.request` 同为 nonisolated async 且返回非 Sendable 的 Activity。
//   - 因此非 Sendable 的 Activity 绝不跨隔离域传递：本类整体 @MainActor
//     隔离（可变态只在主线程读写），所有 ActivityKit 调用（request /
//     update / end）全部收敛进 `ActivityBox`（@unchecked Sendable）内部的
//     nonisolated 上下文 —— 与 SystemKit LiveActivityProgressCenter
//     （R006 实测解法）同款，盒子是唯一接触 ActivityKit 的网关。
//   - 上层 `Task { @MainActor in }` 只捕获 self（与闭包同为 MainActor
//     隔离）与 Sendable 参数，安全无竞争。

@available(iOS 16.1, *)
@MainActor
public final class LiveActivityProgressReporter: ProgressReporting {

    public static let shared = LiveActivityProgressReporter()

    private init() {}

    /// 当前实时活动的隔离盒；nil = 无进行中的活动。
    private var box: ActivityBox?

    // MARK: - ProgressReporting

    public func begin(task: ProgressTaskDescriptor) {
        // 同一 App 同时只允许一个进行中的实时活动：先结束旧的，再请求新的。
        // 全部逻辑放进 @MainActor Task：闭包内只接触 self.box（同 actor 隔离
        // 的 Sendable 盒子），非 Sendable 的 Activity 由盒子内部消化。
        Task { @MainActor in
            if let box = self.box {
                await box.end(nil)
                self.box = nil
            }

            let attributes = ExportProgressActivityAttributes(title: task.title)
            let state = ExportProgressActivityAttributes.ContentState.running(
                completed: 0,
                total: task.total
            )
            let content = ActivityContent(state: state, staleDate: nil)

            do {
                self.box = try await ActivityBox.request(attributes: attributes, content: content)
            } catch {
                #if DEBUG
                print("[ProgressCenter] 启动实时活动失败（可能未在 Info.plist 开启或用户已关闭）：\(error.localizedDescription)")
                #endif
            }
        }
    }

    public func report(_ snapshot: ProgressSnapshot) {
        Task { @MainActor in
            guard let box = self.box else { return }

            let state = ExportProgressActivityAttributes.ContentState.running(
                completed: snapshot.completed,
                total: snapshot.total,
                currentItemName: snapshot.currentItemName
            )
            let content = ActivityContent(state: state, staleDate: nil)

            await box.update(content)
        }
    }

    public func finish(summary: String) {
        Task { @MainActor in
            guard let box = self.box else { return }
            self.box = nil

            let state = ExportProgressActivityAttributes.ContentState.finished(summary: summary)
            let content = ActivityContent(state: state, staleDate: nil)

            // 完成后停留 3 秒再消失，给用户确认反馈
            await box.endAfter(content, delay: 3)
        }
    }

    public func fail(message: String) {
        Task { @MainActor in
            guard let box = self.box else { return }
            self.box = nil

            let state = ExportProgressActivityAttributes.ContentState.failed(message: message)
            let content = ActivityContent(state: state, staleDate: nil)

            // 错误信息停留 4 秒再消失
            await box.endAfter(content, delay: 4)
        }
    }

    public func cancel() {
        Task { @MainActor in
            guard let box = self.box else { return }
            self.box = nil

            await box.end(nil)
        }
    }
}

// MARK: - 隔离盒

/// ActivityKit 隔离盒（与 SystemKit `LiveActivityProgressCenter.ActivityBox`
/// 同款解法，R006 实测结论）：非 Sendable 的 `Activity` 从不跨隔离域传递，
/// 所有 ActivityKit 调用（request / update / end）全部发生在本盒子内部的
/// nonisolated 上下文；盒子自身 `@unchecked Sendable`，可存入 @MainActor
/// 隔离态并被 `Task { @MainActor in }` 安全捕获。
///
/// `@unchecked` 的依据：ActivityKit 的 API 设计为任意上下文可用（其方法均为
/// nonisolated async，内部自行同步），本类对 `activity` 的访问也全部收敛在
/// 这些 nonisolated 调用内，不存在跨线程的可变访问。
@available(iOS 16.1, *)
private final class ActivityBox: @unchecked Sendable {
    private let activity: Activity<ExportProgressActivityAttributes>

    private init(_ activity: Activity<ExportProgressActivityAttributes>) {
        self.activity = activity
    }

    /// 发起实时活动。request 为 nonisolated async 且返回非 Sendable 的
    /// Activity：在本盒子的 nonisolated 上下文内调用并直接装箱，
    /// Activity 不进入任何 actor 隔离域。
    static func request(
        attributes: ExportProgressActivityAttributes,
        content: ActivityContent<ExportProgressActivityAttributes.ContentState>
    ) async throws -> ActivityBox {
        let activity = try await Activity.request(
            attributes: attributes,
            content: content,
            pushType: nil
        )
        return ActivityBox(activity)
    }

    func update(_ content: ActivityContent<ExportProgressActivityAttributes.ContentState>) async {
        await activity.update(content)
    }

    /// 立即结束（用于取消 / 结束上一个活动）。
    func end(_ content: ActivityContent<ExportProgressActivityAttributes.ContentState>?) async {
        await activity.end(content, dismissalPolicy: .immediate)
    }

    /// 延迟消失（成功 3 秒 / 失败 4 秒，给用户确认反馈）。
    func endAfter(
        _ content: ActivityContent<ExportProgressActivityAttributes.ContentState>?,
        delay: TimeInterval
    ) async {
        await activity.end(content, dismissalPolicy: .after(Date(timeIntervalSinceNow: delay)))
    }
}
