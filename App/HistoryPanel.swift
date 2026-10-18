import SwiftUI
import EditKit
import DesignSystem

// MARK: - 历史面板（R010）

/// `EditHistory` 的 UI 化：步骤列表（序号 + 操作名 + 时间戳）+ 任意回溯。
///
/// 语义与工具栏的撤销/重做完全同源 —— 都落在 `EditorModel.jumpToHistory(at:)`
/// （底层 `EditHistory.jump(to:)`）：点第 n 行 = 保留前 n 步、其余进 redo 缓冲，
/// 之后仍可用工具栏重做回来。面板不自建第二套历史逻辑。
///
/// 行序 = 时间正序（最早在上）；当前状态行打勾。被跳过的步骤不会消失，
/// 只是回到 redo 缓冲（页脚提示可重做步数）。
struct HistoryPanelSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss

    /// 步骤时间戳格式（HH:mm:ss；面板只需到秒）。
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        NavigationStack {
            Group {
                if model.historySteps.isEmpty {
                    ContentUnavailableView {
                        Label("暂无历史步骤", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("调整参数、套用预设或添加选区后，每一步都会列在这里，点任意一步即可回到那个状态。")
                    }
                } else {
                    stepList
                }
            }
            .background(DS.Brand.void)
            .navigationTitle("历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DS.Brand.void, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        // 与编辑器一致的深色外观（修图器深色画布语言）
        .environment(\.colorScheme, .dark)
    }

    private var stepList: some View {
        List {
            // 第 0 行：原图（jump(to: 0) = 全部回退）
            stepRow(index: 0, label: "原图", timestamp: nil,
                    isCurrent: model.historySteps.isEmpty)
                .listRowBackground(DS.Brand.void)

            ForEach(Array(model.historySteps.enumerated()), id: \.element.id) { index, step in
                stepRow(index: index + 1, label: step.label, timestamp: step.timestamp,
                        isCurrent: index == model.historySteps.count - 1)
                    .listRowBackground(DS.Brand.void)
            }

            // 页脚：redo 缓冲提示（跳过后仍可重做回来）
            if !model.historyRedoSteps.isEmpty {
                Section {
                    Text("已回溯 \(model.historyRedoSteps.count) 步 —— 用编辑器右上角的重做按钮可逐条找回。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(DS.Brand.void)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// 单行：序号徽标 + 操作名 + 时间戳；当前行打勾。
    private func stepRow(index: Int, label: String, timestamp: Date?, isCurrent: Bool) -> some View {
        Button {
            jump(to: index)
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                // 序号徽标（0 = 原图）
                Text("\(index)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(isCurrent ? DS.accent : Color.white.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.body.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? DS.accent : .primary)
                    if let timestamp {
                        Text(Self.timeFormatter.string(from: timestamp))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("初始状态")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(DS.accent)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText(label: label, timestamp: timestamp))
    }

    /// 无障碍标签（避免字符串插值里套闭包插值）。
    private func accessibilityText(label: String, timestamp: Date?) -> String {
        guard let timestamp else { return label }
        return label + "，" + Self.timeFormatter.string(from: timestamp)
    }

    /// 回溯到指定步骤数（0 = 原图）。点当前行 = 空操作（不关面板）。
    private func jump(to index: Int) {
        guard index != model.historySteps.count else { return }
        model.jumpToHistory(at: index)
        dismiss()
    }
}
