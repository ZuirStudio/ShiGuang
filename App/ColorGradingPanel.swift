import SwiftUI
import EditKit
import DesignSystem

/// 色轮分级面板：阴影 / 中间调 / 高光三个环形色轮 + 全局混合 / 平衡滑杆。
///
/// 交互范式借鉴 Lightroom / 像素蛋糕的三色轮（拖拽色轮改变染色方向与强度），
/// 视觉皮肤（圆盘 + 方向线 + 指示点 + 数值徽标）与全部代码均为本项目原创。
///
/// 数据流：面板只读 `ColorGrading`（由 EditorModel 从 EditGraph 折叠而来），
/// 拖拽经 `onChange` 整值提交（EditGraph 末条指令覆盖语义，与渲染管线一致）。
struct ColorGradingPanel: View {
    let grading: ColorGrading
    /// 整值提交（某一色轮 / 混合 / 平衡变化后的完整分级）。
    let onChange: (ColorGrading) -> Void
    /// 整条分级重置为恒等（单个原子历史步骤）。
    let onReset: () -> Void

    private var isAdjusted: Bool { !grading.isIdentity }

    var body: some View {
        VStack(spacing: DS.Spacing.sm) {
            wheelRow

            VStack(spacing: DS.Spacing.xs) {
                blendingRow
                balanceRow
            }

            footer
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .background(.regularMaterial)
    }

    // MARK: 三色轮

    private var wheelRow: some View {
        HStack(spacing: DS.Spacing.sm) {
            ColorWheelControl(
                title: "阴影",
                wheel: grading.shadows,
                tint: DS.accent
            ) { wheel in
                var g = grading
                g.shadows = wheel
                onChange(g)
            }

            ColorWheelControl(
                title: "中间调",
                wheel: grading.midtones,
                tint: DS.accent
            ) { wheel in
                var g = grading
                g.midtones = wheel
                onChange(g)
            }

            ColorWheelControl(
                title: "高光",
                wheel: grading.highlights,
                tint: DS.accent
            ) { wheel in
                var g = grading
                g.highlights = wheel
                onChange(g)
            }
        }
    }

    // MARK: 混合 / 平衡滑杆

    private var blendingRow: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text("混合")
                .font(DS.Typography.sliderLabel)
                .frame(width: 44, alignment: .leading)

            Slider(
                value: Binding(
                    get: { grading.blending },
                    set: { value in
                        var g = grading
                        g.blending = value
                        onChange(g)
                    }
                ),
                in: ColorGrading.blendingRange,
                step: 1
            )
            .tint(DS.accent)
            .accessibilityLabel("色彩分级混合强度")
            .accessibilityValue("\(Int(grading.blending.rounded()))")

            Text("\(Int(grading.blending.rounded()))")
                .font(DS.Typography.sliderValue)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private var balanceRow: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text("平衡")
                .font(DS.Typography.sliderLabel)
                .frame(width: 44, alignment: .leading)

            Slider(
                value: Binding(
                    get: { grading.balance },
                    set: { value in
                        var g = grading
                        g.balance = value
                        onChange(g)
                    }
                ),
                in: ColorGrading.balanceRange,
                step: 1
            )
            .tint(DS.accent)
            .accessibilityLabel("色彩分级阴影高光平衡")
            .accessibilityValue(balanceText(grading.balance))

            Text(balanceText(grading.balance))
                .font(DS.Typography.sliderValue)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: DS.Spacing.sm) {
            Button(action: onReset) {
                Label("重置分级", systemImage: "arrow.counterclockwise")
                    .font(DS.Typography.sliderLabel)
            }
            .buttonStyle(.plain)
            .disabled(!isAdjusted)
            .accessibilityLabel("重置色轮分级")

            Spacer()

            Text("拖动色轮改变染色方向 · 双击色轮复位")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func balanceText(_ v: Double) -> String {
        let n = Int(v.rounded())
        return n > 0 ? "+\(n)" : "\(n)"
    }
}

// MARK: - 单个环形色轮控件

/// 环形色轮：拖拽确定色相（角度，-180...180）与染色强度（半径比，0...100）。
/// 指示点即当前染色方向；双击归零。
struct ColorWheelControl: View {
    let title: String
    let wheel: ColorWheel
    /// 选中强调色（三个轮共用 DS.accent，预留差异化）。
    let tint: Color
    /// 拖拽产生的新色轮值（连续拖动由 EditorModel 合并为一个历史步骤）。
    let onChange: (ColorWheel) -> Void

    /// 圆盘直径（含外环）。
    private let diameter: CGFloat = 84

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(DS.Typography.sliderLabel)
                .foregroundStyle(wheel.isIdentity ? Color.secondary : Color.primary)

            wheelPad
                .frame(width: diameter, height: diameter)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(title)色轮")
                .accessibilityValue(
                    wheel.isIdentity
                        ? "未调整"
                        : "色相 \(Int(wheel.hue.rounded())) 度，强度 \(Int(wheel.saturation.rounded()))%"
                )

            Text(wheel.isIdentity ? "—" : "\(Int(wheel.saturation.rounded()))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(wheel.isIdentity ? Color.secondary : tint)
        }
    }

    /// 圆盘：外环 + 十字基准 + 中心点 + 方向线 + 指示点。
    private var wheelPad: some View {
        let radius = diameter / 2
        let ratio = CGFloat(min(max(wheel.saturation / 100, 0), 1))
        let angle = CGFloat(wheel.hue) * .pi / 180
        let dot = CGPoint(
            x: radius + cos(angle) * (radius - 10) * ratio,
            y: radius + sin(angle) * (radius - 10) * ratio
        )
        return ZStack {
            // 底盘
            Circle()
                .fill(Color.primary.opacity(0.05))
            // 外环（选中强调色描边提示当前域）
            Circle()
                .stroke(
                    wheel.isIdentity ? Color.primary.opacity(0.18) : tint.opacity(0.55),
                    lineWidth: wheel.isIdentity ? 1 : 2
                )
            // 十字基准（恒等参考）
            Path { path in
                path.move(to: CGPoint(x: radius, y: 8))
                path.addLine(to: CGPoint(x: radius, y: diameter - 8))
                path.move(to: CGPoint(x: 8, y: radius))
                path.addLine(to: CGPoint(x: diameter - 8, y: radius))
            }
            .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            // 中心恒等点
            Circle()
                .fill(Color.primary.opacity(0.35))
                .frame(width: 4, height: 4)

            if !wheel.isIdentity {
                // 方向线：中心 → 指示点
                Path { path in
                    path.move(to: CGPoint(x: radius, y: radius))
                    path.addLine(to: dot)
                }
                .stroke(tint.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                // 指示点：染色方向的全饱和色 + 白色描边
                Circle()
                    .fill(directionColor)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
                    .position(dot)
            }
        }
        .contentShape(Circle())
        .gesture(dragGesture)
        .onTapGesture(count: 2) { onChange(.identity) }
    }

    /// 指示点颜色：当前色相的满饱和方向色（与 EditKit tintVector 的 S=1 方向一致）。
    private var directionColor: Color {
        let normalized = (wheel.hue.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) / 360
        return Color(hue: normalized, saturation: 1, brightness: 1)
    }

    /// 拖拽：触点相对圆心的极坐标 → 色相（atan2，度）+ 强度（半径比 × 100，钳制 0...100）。
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let center = CGPoint(x: diameter / 2, y: diameter / 2)
                let dx = value.location.x - center.x
                let dy = value.location.y - center.y
                let maxRadius = diameter / 2 - 10
                let radius = min(max(hypot(dx, dy), 0), maxRadius)
                var hue = atan2(dy, dx) * 180 / .pi
                // R009-Fix-6：atan2 值域是 -180...180，折算到整圆 0...360。
                // 不折算的话：① 色相范围改整圆后，下半圆会被钳成 0（红）；
                // ② 旧逻辑下负色相还会经 tintVector 的 default 分支产出越界分量。
                if hue < 0 { hue += 360 }
                hue = min(max(hue, ColorWheel.hueRange.lowerBound), ColorWheel.hueRange.upperBound)
                let saturation = radius / maxRadius * 100
                onChange(ColorWheel(hue: hue, saturation: saturation))
            }
    }
}
