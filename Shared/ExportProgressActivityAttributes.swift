import ActivityKit
import Foundation

// 拾光 · R010-B 系统集成 · shared/ExportProgressActivityAttributes.swift
// 编译目标：主 App Target + Widget Extension Target（双方共用）
//
// 用途：定义「耗时任务进度」实时活动的数据契约。
//   - 主 App：发起 / 更新 / 结束实时活动（LiveActivityProgressReporter）
//   - Widget Extension：渲染锁屏与灵动岛界面（ExportProgressActivityView）
//
// 前置条件：
//   1. Deployment Target ≥ iOS 16.1
//   2. 主 App Info.plist：NSSupportsLiveActivities = YES
//      （见 xcode/Info.plist.app.additions.xml）
//   3. 同一 App 同时只允许一个进行中的实时活动（ begin 会自动结束上一个）。

@available(iOS 16.1, *)
public struct ExportProgressActivityAttributes: ActivityAttributes {

    /// 动态状态：随进度更新，会被整体序列化，请保持精简。
    public struct ContentState: Codable, Hashable {
        public var completed: Int
        /// 总数；0 表示不确定进度（AI 处理耗时未知，界面显示转圈）
        public var total: Int
        /// 当前处理项名称（如照片文件名），可为空
        public var currentItemName: String
        public var phase: Phase
        /// 失败原因（phase == .failed 时展示）
        public var errorMessage: String?

        public enum Phase: String, Codable, Hashable {
            case running
            case finished
            case failed
        }

        public init(
            completed: Int,
            total: Int,
            currentItemName: String = "",
            phase: Phase = .running,
            errorMessage: String? = nil
        ) {
            self.completed = completed
            self.total = total
            self.currentItemName = currentItemName
            self.phase = phase
            self.errorMessage = errorMessage
        }

        public static func running(completed: Int, total: Int, currentItemName: String = "") -> ContentState {
            ContentState(completed: completed, total: total, currentItemName: currentItemName, phase: .running)
        }

        public static func finished(summary: String = "") -> ContentState {
            ContentState(completed: 1, total: 1, currentItemName: summary, phase: .finished)
        }

        public static func failed(message: String) -> ContentState {
            ContentState(completed: 0, total: 0, currentItemName: message, phase: .failed, errorMessage: message)
        }

        /// 进度 0...1；不确定进度返回 0。
        public var fraction: Double {
            guard total > 0 else { return 0 }
            return min(1, max(0, Double(completed) / Double(total)))
        }

        public var isIndeterminate: Bool { total <= 0 }
    }

    /// 静态属性：任务标题（发起后不再变化，如「批量导出」「人像磨皮」）
    public var title: String

    public init(title: String) {
        self.title = title
    }
}
