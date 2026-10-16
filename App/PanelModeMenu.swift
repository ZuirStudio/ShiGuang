import Foundation
import SwiftUI
import DesignSystem

// MARK: - 色彩模块面板切换菜单（R007c P0-A 修复）

/// 面板模式菜单：**独立子视图 + `.equatable()` 隔离**。
///
/// 为什么要拆出来（P0-A 根因）：
/// 原来这个 `Menu` 直接写在 `EditorView.bottomBar` 里，而 `EditorView.body` 读了
/// `model.preview` / `model.value(for:)` —— 这些属性在拖动调色（或任何一次预览渲染）
/// 时每帧都在变，于是整棵 body（含 Menu 的 label 与菜单内容闭包）被反复重建。
/// 弹层在展开 / 收起的动画过程中被重算打断，真机表现就是「点完没反应、极度卡顿」。
///
/// 现在它只依赖一个 `EditorPanelMode` 值：
/// - 不读任何 `@Observable` 依赖 → 图像渲染不再让它失效；
/// - `.equatable()` 让 SwiftUI 在 `mode` 未变时**直接跳过 body 重算**，
///   弹层生命周期与渲染帧率彻底解耦。
///
/// 另外：label 给了固定的 44×34 命中区（44pt 是 iOS 最小可点击边长），
/// 避免裸 `Image` 只有图标本身可点、误触多。
struct PanelModeMenu: View, Equatable {
    let mode: EditorPanelMode
    let onSelect: (EditorPanelMode) -> Void

    /// 只比 `mode`：`onSelect` 是闭包（每次求值都是新值），
    /// 若参与比较会让 `.equatable()` 永远失效；闭包本身无状态，复用旧值是安全的。
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.mode == rhs.mode
    }

    var body: some View {
        Menu {
            ForEach(EditorPanelMode.allCases) { item in
                Button {
                    // 埋点：菜单项点击时刻（面板真正出现时再记一次，得端到端延迟）
                    PanelModeSwitchLog.shared.recordTap(to: item)
                    onSelect(item)
                } label: {
                    Label(item.label, systemImage: mode == item ? "checkmark" : item.icon)
                }
                .accessibilityLabel(item.label)
            }
        } label: {
            Image(systemName: mode.icon)
                .font(.system(size: DS.IconSize.medium, weight: .semibold))
                .frame(width: 44, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("调色面板")
        .accessibilityValue(mode.label)
        .accessibilityHint("可切换\(EditorPanelMode.allCases.map(\.label).joined(separator: "、"))")
    }
}

// MARK: - 面板出现埋点视图修饰器

/// 「面板已就绪」标记：给无法直接挂 `onAppear` 的面板提供承载。
struct PanelAppearMarker: View {
    let mode: EditorPanelMode

    var body: some View {
        Color.clear
            .frame(height: 0)
            .onAppear { PanelModeSwitchLog.shared.recordPanelAppear(mode) }
    }
}

/// 同上的修饰器形态（给已经有内容的真实面板用）。
struct PanelAppearTracking: ViewModifier {
    let mode: EditorPanelMode

    func body(content: Content) -> some View {
        content.onAppear { PanelModeSwitchLog.shared.recordPanelAppear(mode) }
    }
}

// MARK: - 当前参数胶囊（同款隔离）

/// 底部「当前手势参数 + 数值」胶囊。
///
/// 拖动调色时数值每帧都变，如果它写在 `bottomBar` 里，会连带把同级的模式菜单一起重算。
/// 拆成 `.equatable()` 子视图后：只有数值文本变化时才重算这一小块（约 20pt 高），
/// 菜单 / AI 按钮所在层级不再被高频数值刷新牵连。
struct ParameterValueCapsule: View, Equatable {
    let title: String
    let systemImage: String
    let valueText: String

    var body: some View {
        VStack(spacing: 2) {
            Label(title, systemImage: systemImage)
                .font(DS.Typography.sliderLabel)
            Text(valueText)
                .font(DS.Typography.sliderValue)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.xs)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("当前参数 \(title)")
        .accessibilityValue(valueText)
    }
}

// MARK: - 面板切换耗时取证（P0-A 验收）

/// 「菜单项点击 → 目标面板出现」的端到端耗时记录。
///
/// 为什么要有它：P0-A 的验收线是「弹出 < 100ms、色彩分级能打开」，
/// 而 CI 只能证明编译与逻辑，真机延迟必须能被**看到**。
/// 它把端到端延迟打到控制台（`[PanelMode]` 前缀）并留一份最近 20 条摘要，
/// 真机取证方式：点 4 次面板菜单项 → Xcode Console 过滤 `[PanelMode]` 读数字。
@MainActor
final class PanelModeSwitchLog {
    static let shared = PanelModeSwitchLog()

    private var pendingTap: (mode: EditorPanelMode, at: Date)?
    private(set) var samples: [String] = []

    private init() {}

    /// 菜单项被点下的瞬间。
    func recordTap(to mode: EditorPanelMode) {
        pendingTap = (mode, Date())
    }

    /// 目标面板首次求值（`onAppear`）的瞬间。
    func recordPanelAppear(_ mode: EditorPanelMode) {
        guard let tap = pendingTap, tap.mode == mode else { return }
        pendingTap = nil
        let elapsed = Date().timeIntervalSince(tap.at) * 1000
        let line = String(format: "%@ 面板：点击→出现 %.1fms", mode.label, elapsed)
        samples.append(line)
        if samples.count > 20 { samples.removeFirst(samples.count - 20) }
        print("[PanelMode] \(line)")
    }

    var summary: String {
        samples.isEmpty ? "（暂无记录：先去点几下底部面板菜单）" : samples.joined(separator: "\n")
    }

    func reset() {
        samples.removeAll()
        pendingTap = nil
    }
}
