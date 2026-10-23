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
// 并发模型（Swift 6 严格并发）：
//   - ActivityKit 的 request/update/end 均为 async 且 @MainActor；
//   - Activity 句柄与 ActivityContent 均非 Sendable；
//   - 本类整体 @MainActor 隔离，activity 只在主线程读写；
//   - 异步收尾用 `Task { @MainActor in }`：闭包只捕获 self（与闭包
//     同为 MainActor 隔离，合法）与 Sendable 参数，所有非 Sendable
//     值的创建与访问全部发生在闭包内部，不跨 actor 边界发送。

@available(iOS 16.1, *)
@MainActor
public final class LiveActivityProgressReporter: ProgressReporting {

    public static let shared = LiveActivityProgressReporter()

    private init() {}

    private var activity: Activity<ExportProgressActivityAttributes>?

    // MARK: - ProgressReporting

    public func begin(task: ProgressTaskDescriptor) {
        // 同一 App 同时只允许一个进行中的实时活动：先结束旧的，再请求新的。
        // 全部逻辑放进 @MainActor Task：闭包内只接触 self.activity（同 actor），
        // 不捕获任何非 Sendable 局部值。
        Task { @MainActor in
            if let activity = self.activity {
                await activity.end(nil, dismissalPolicy: .immediate)
                self.activity = nil
            }

            let attributes = ExportProgressActivityAttributes(title: task.title)
            let state = ExportProgressActivityAttributes.ContentState.running(
                completed: 0,
                total: task.total
            )
            let content = ActivityContent(state: state, staleDate: nil)

            // request 为 async @MainActor：在 @MainActor Task 内直接 await
            do {
                self.activity = try await Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
            } catch {
                #if DEBUG
                print("[ProgressCenter] 启动实时活动失败（可能未在 Info.plist 开启或用户已关闭）：\(error.localizedDescription)")
                #endif
            }
        }
    }

    public func report(_ snapshot: ProgressSnapshot) {
        Task { @MainActor in
            guard let activity = self.activity else { return }

            let state = ExportProgressActivityAttributes.ContentState.running(
                completed: snapshot.completed,
                total: snapshot.total,
                currentItemName: snapshot.currentItemName
            )
            let content = ActivityContent(state: state, staleDate: nil)

            await activity.update(content)
        }
    }

    public func finish(summary: String) {
        Task { @MainActor in
            guard let activity = self.activity else { return }
            self.activity = nil

            let state = ExportProgressActivityAttributes.ContentState.finished(summary: summary)
            let content = ActivityContent(state: state, staleDate: nil)

            // 完成后停留 3 秒再消失，给用户确认反馈
            await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(3)))
        }
    }

    public func fail(message: String) {
        Task { @MainActor in
            guard let activity = self.activity else { return }
            self.activity = nil

            let state = ExportProgressActivityAttributes.ContentState.failed(message: message)
            let content = ActivityContent(state: state, staleDate: nil)

            // 错误信息停留 4 秒再消失
            await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(4)))
        }
    }

    public func cancel() {
        Task { @MainActor in
            guard let activity = self.activity else { return }
            self.activity = nil

            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
