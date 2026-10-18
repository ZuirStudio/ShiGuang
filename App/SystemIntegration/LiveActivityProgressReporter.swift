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

@available(iOS 16.1, *)
public final class LiveActivityProgressReporter: ProgressReporting {

    @MainActor
    public static let shared = LiveActivityProgressReporter()

    private init() {}

    private var activity: Activity<ExportProgressActivityAttributes>?

    // MARK: - ProgressReporting

    public func begin(task: ProgressTaskDescriptor) {
        // 同一 App 同时只允许一个进行中的实时活动：先结束旧的
        if let activity {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
            self.activity = nil
        }

        let attributes = ExportProgressActivityAttributes(title: task.title)
        let state = ExportProgressActivityAttributes.ContentState.running(
            completed: 0,
            total: task.total
        )
        let content = ActivityContent(state: state, staleDate: nil)

        do {
            activity = try Activity.request(
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

    public func report(_ snapshot: ProgressSnapshot) {
        guard let activity else { return }

        let state = ExportProgressActivityAttributes.ContentState.running(
            completed: snapshot.completed,
            total: snapshot.total,
            currentItemName: snapshot.currentItemName
        )
        let content = ActivityContent(state: state, staleDate: nil)

        Task { await activity.update(content) }
    }

    public func finish(summary: String) {
        guard let activity else { return }
        self.activity = nil

        let state = ExportProgressActivityAttributes.ContentState.finished(summary: summary)
        let content = ActivityContent(state: state, staleDate: nil)

        // 完成后停留 3 秒再消失，给用户确认反馈
        Task { await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(3))) }
    }

    public func fail(message: String) {
        guard let activity else { return }
        self.activity = nil

        let state = ExportProgressActivityAttributes.ContentState.failed(message: message)
        let content = ActivityContent(state: state, staleDate: nil)

        // 错误信息停留 4 秒再消失
        Task { await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(4))) }
    }

    public func cancel() {
        guard let activity else { return }
        self.activity = nil

        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
