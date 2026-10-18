import SwiftUI
import WidgetKit

// 拾光 · R010-B 系统集成 · widget/ExportProgressActivityView.swift
// 编译目标：仅 Widget Extension Target
//
// 实时活动（Live Activity）锁屏视图：展示批量导出 / AI 处理进度。
// 由主 App 的 LiveActivityProgressReporter 驱动；
// 灵动岛部分在 ShiguangWidgetBundle.swift 中定义。

struct ExportLockScreenActivityView: View {
    let context: ActivityViewContext<ExportProgressActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 标题行
            HStack {
                Image(systemName: "photo.stack")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(context.attributes.title)
                    .font(.headline)
                Spacer()
                Text(progressText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // 进度条 / 转圈
            if context.state.total > 0 {
                ProgressView(value: context.state.fraction)
                    .tint(.orange)
            } else {
                ProgressView()
                    .tint(.orange)
            }

            // 状态行
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .activityBackgroundTint(.orange.opacity(0.12))
        .activitySystemActionForegroundColor(.orange)
    }

    private var progressText: String {
        context.state.total > 0 ? "\(Int(context.state.fraction * 100))%" : "处理中"
    }

    private var statusText: String {
        if context.state.phase == .failed, let message = context.state.errorMessage {
            return message
        }
        if !context.state.currentItemName.isEmpty {
            return context.state.currentItemName
        }
        return context.state.total > 0
            ? "正在导出 \(context.state.completed)/\(context.state.total)"
            : "正在处理…"
    }
}
