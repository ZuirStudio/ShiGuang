import SwiftUI
import DesignSystem

/// P1-F：设置页。
///
/// 默认只露「版本」一行——版本号即隐藏开关：**连点 7 次（相邻间隔 < 2 秒）**
/// 解锁性能诊断。解锁后本页出现「开发者」分区（性能诊断入口 + 重新隐藏），
/// 编辑器工具栏同步出现性能诊断按钮。解锁状态经 `DebugGate` 持久化。
///
/// 为什么这样设计：性能诊断是给真机验收/排障用的内部工具，
/// 不该常驻在普通用户的工具栏里（像素蛋糕同样把这类能力收在隐藏入口）。
struct SettingsSheet: View {
    /// 连点窗口：相邻两次点击超过该间隔则重新计数（防长时间误触积累出解锁）。
    private static let tapWindow: TimeInterval = 2
    /// 激活所需连点次数。
    private static let requiredTaps = 7

    @Environment(\.dismiss) private var dismiss
    /// 版本号连点计数与上次点击时刻（重置时机：达到次数或超窗）。
    @State private var versionTaps = 0
    @State private var lastTapAt: Date?
    /// 解锁后的诊断页导航（仅 `DebugGate.shared.unlocked` 时有点击机会）。
    @State private var showDiagnostics = false
    /// 刚解锁的短提示（2 秒后自动收起）。
    @State private var justUnlocked = false

    /// CFBundleShortVersionString (CFBundleVersion)，与 project.yml 一致。
    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { handleVersionTap() }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("版本 \(appVersion)")
                    .accessibilityHint("连续轻点 7 次可解锁性能诊断")
                } footer: {
                    Text("拾光 · 开源项目（GPL-3.0）。照片仅在本机处理。")
                }

                // P1-F：开发者分区默认不存在——未解锁时整个 Section 不出现在列表里。
                if DebugGate.shared.unlocked {
                    Section("开发者") {
                        Button {
                            showDiagnostics = true
                        } label: {
                            Label("性能诊断", systemImage: "gauge.with.dots.needle.33percent")
                        }

                        Button(role: .destructive) {
                            DebugGate.shared.lock()
                            versionTaps = 0
                            lastTapAt = nil
                        } label: {
                            Label("隐藏性能诊断", systemImage: "eye.slash")
                        }
                    }
                }
            }
            // P1-C（R007d）：列表容器显式深空黑 —— List 默认取系统分组底色
            // （浅色模式下为白），UIUserInterfaceStyle=Dark 已强制深色，
            // 这里再钉一层 DS.Brand.void，双保险不漏白边。
            .scrollContentBackground(.hidden)
            .background(DS.Brand.void)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .navigationDestination(isPresented: $showDiagnostics) {
                // 从设置页打开：没有 EditorModel，只展示 PerfSignpost 进程级实测数据。
                PerfReportSheet(model: nil)
            }
            .overlay(alignment: .top) {
                if justUnlocked {
                    unlockedBanner
                }
            }
        }
    }

    /// 版本号连点：窗口内累计到 7 次即解锁（重置计数 + 持久化 + 触觉 + 短提示）。
    private func handleVersionTap() {
        let now = Date()
        if let lastTapAt, now.timeIntervalSince(lastTapAt) > Self.tapWindow {
            versionTaps = 0
        }
        lastTapAt = now
        versionTaps += 1

        if versionTaps >= Self.requiredTaps {
            versionTaps = 0
            lastTapAt = nil
            DebugGate.shared.unlock()
            EditorHaptics.completed()
            withAnimation(DS.Motion.standard) { justUnlocked = true }
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation(DS.Motion.standard) { justUnlocked = false }
            }
        }
    }

    private var unlockedBanner: some View {
        Label("性能诊断已解锁", systemImage: "checkmark.seal.fill")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
