import SwiftUI
import EditKit

/// 底部面板模式：手势 / 滑杆 / 曲线 / 色彩分级（HSL）
enum EditorPanelMode: String, CaseIterable, Identifiable {
    case gesture, sliders, curve, hsl

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gesture: return "手势调色"
        case .sliders: return "滑杆精调"
        case .curve: return "曲线"
        case .hsl: return "色彩分级"
        }
    }

    var icon: String {
        switch self {
        case .gesture: return "hand.draw"
        case .sliders: return "slider.horizontal.3"
        case .curve: return "chart.xyaxis.line"
        case .hsl: return "paintpalette.fill"
        }
    }
}

/// Snapseed 式「上下滑切换」通用手势（原创实现，仅借鉴交互范式）。
/// 仅当纵向位移明显大于横向时才触发，避免与画布内拖动冲突。
func verticalSwipeGesture<T: Equatable>(
    _ items: [T],
    current: T,
    onStep: @escaping (T) -> Void
) -> some Gesture {
    DragGesture(minimumDistance: 24)
        .onEnded { value in
            let dy = value.translation.height
            let dx = value.translation.width
            guard abs(dy) > 24, abs(dy) > abs(dx) * 1.5 else { return }
            guard let index = items.firstIndex(of: current) else { return }
            let next = dy > 0 ? index + 1 : index - 1
            guard items.indices.contains(next) else { return }
            withAnimation(DS.Motion.standard) { onStep(items[next]) }
        }
}

// MARK: - 曲线编辑器

/// 曲线编辑器面板：4 通道 Tab + 可交互画布 + 实时预览联动。
/// 交互范式借鉴行业通用做法，视觉皮肤、文案与配色均为原创。
struct CurveEditorPanel: View {
    let curves: ToneCurveSet
    let onChange: (ToneCurveSet, String) -> Void

    @State private var channel: CurveChannel = .rgb

    private var current: ToneCurve { curves[channel] }

    private var tint: Color {
        let t = channel.tint
        return Color(red: t.red, green: t.green, blue: t.blue)
    }

    var body: some View {
        VStack(spacing: DS.Spacing.sm) {
            CurveChannelTabs(channel: $channel, onReset: reset)

            CurveCanvas(curve: current, tint: tint, onEdit: commit)
                .frame(height: 172)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("色调曲线画布，通道 \(channel.displayName)，控制点 \(current.points.count) 个")

            HStack(spacing: DS.Spacing.sm) {
                Text(current.isIdentity ? "拖动控制点调整明暗分布" : "已调整 · \(current.points.count) 个控制点")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("长按空白加点 · 长按点删除 · 双击重置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .background(.regularMaterial)
        .gesture(verticalSwipeGesture(CurveChannel.allCases, current: channel) { channel = $0 })
    }

    private func commit(_ updated: ToneCurve) {
        var set = curves
        set[channel] = updated
        onChange(set, "\(channel.displayName)曲线")
    }

    private func reset() {
        var set = curves
        set[channel] = ToneCurve()
        onChange(set, "重置\(channel.displayName)曲线")
    }
}

// MARK: - 曲线通道 Tab

struct CurveChannelTabs: View {
    @Binding var channel: CurveChannel
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            ForEach(CurveChannel.allCases, id: \.self) { item in
                let t = item.tint
                let selected = channel == item
                Button {
                    withAnimation(DS.Motion.standard) { channel = item }
                } label: {
                    Text(item.compactName)
                        .font(DS.Typography.sliderLabel)
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(
                                selected
                                ? Color(red: t.red, green: t.green, blue: t.blue).opacity(0.30)
                                : Color.primary.opacity(0.06)
                            )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.displayName)通道")
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }

            Spacer()

            Button(action: onReset) {
                Image(systemName: "arrow.counterclockwise")
                    .font(DS.Typography.sliderLabel)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("重置当前通道曲线")
        }
    }
}

// MARK: - 曲线画布

/// 曲线画布：拖动控制点调整；长按空白加点；长按控制点删除；双击恢复恒等。
struct CurveCanvas: View {
    let curve: ToneCurve
    let tint: Color
    let onEdit: (ToneCurve) -> Void

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                grid(size: size).allowsHitTesting(false)
                identityLine(size: size).allowsHitTesting(false)
                curveShape(size: size).allowsHitTesting(false)

                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(addPointGesture(size: size))
                    .onTapGesture(count: 2) { onEdit(ToneCurve()) }

                ForEach(curve.points.indices, id: \.self) { index in
                    handle(at: index, size: size)
                }
            }
        }
    }

    private func handle(at index: Int, size: CGSize) -> some View {
        let point = curve.points[index]
        let isEndpoint = index == 0 || index == curve.points.count - 1
        return Circle()
            .fill(tint)
            .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
            .frame(width: 15, height: 15)
            .position(
                x: CGFloat(point.x) * size.width,
                y: CGFloat(1 - point.y) * size.height
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        var updated = curve
                        _ = updated.movePoint(
                            at: index,
                            to: CurvePoint(
                                Double(value.location.x / max(size.width, 1)),
                                Double(1 - value.location.y / max(size.height, 1))
                            )
                        )
                        onEdit(updated)
                    }
            )
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.45)
                    .onEnded { _ in
                        guard !isEndpoint else { return }
                        var updated = curve
                        if updated.removePoint(at: index) { onEdit(updated) }
                    }
            )
            .accessibilityLabel(isEndpoint ? "曲线端点 \(index + 1)" : "曲线控制点 \(index + 1)")
            .accessibilityValue("输入 \(Int(point.x * 100))%，输出 \(Int(point.y * 100))%")
    }

    private func addPointGesture(size: CGSize) -> some Gesture {
        LongPressGesture(minimumDuration: 0.4)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onEnded { value in
                switch value {
                case .second(true, let drag):
                    guard let location = drag?.location else { return }
                    var updated = curve
                    let added = updated.addPoint(
                        CurvePoint(
                            Double(location.x / max(size.width, 1)),
                            Double(1 - location.y / max(size.height, 1))
                        )
                    )
                    if added { onEdit(updated) }
                default:
                    break
                }
            }
    }

    private func grid(size: CGSize) -> some View {
        Path { path in
            for i in 1..<4 {
                let f = CGFloat(i) / 4
                path.move(to: CGPoint(x: size.width * f, y: 0))
                path.addLine(to: CGPoint(x: size.width * f, y: size.height))
                path.move(to: CGPoint(x: 0, y: size.height * f))
                path.addLine(to: CGPoint(x: size.width, y: size.height * f))
            }
        }
        .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
    }

    private func identityLine(size: CGSize) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: size.height))
            path.addLine(to: CGPoint(x: size.width, y: 0))
        }
        .stroke(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
    }

    private func curveShape(size: CGSize) -> some View {
        Path { path in
            let samples = 64
            for i in 0...samples {
                let x = Double(i) / Double(samples)
                let y = curve.sample(at: x)
                let point = CGPoint(x: CGFloat(x) * size.width, y: CGFloat(1 - y) * size.height)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }
}

// MARK: - 色彩分级（HSL 8 通道）

/// HSL 分通道面板：8 个色域通道（色块表示）× 每通道 3 个分量滑杆。
/// 交互范式借鉴行业通用做法（上下滑切换色块、单通道独立微调），
/// 视觉皮肤（色块环 + 调整标记 + 文案）与原代码实现均为本项目原创。
struct HSLPanel: View {
    let adjustment: HSLAdjustment
    /// (通道, 分量, 新值)
    let onChange: (HSLChannel, HSLComponent, Double) -> Void
    /// 重置整条通道（三分量归零，作为单个原子历史步骤）
    let onReset: (HSLChannel) -> Void

    @State private var channel: HSLChannel = .red

    private var channelColor: Color {
        let c = channel.swatch
        return Color(red: c.red, green: c.green, blue: c.blue)
    }

    var body: some View {
        VStack(spacing: DS.Spacing.sm) {
            channelStrip

            VStack(spacing: DS.Spacing.xs) {
                ForEach(HSLComponent.allCases, id: \.self) { component in
                    sliderRow(component)
                }
            }

            footer
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .background(.regularMaterial)
        // 上下滑切换色域（与图像区一致的交互范式）
        .gesture(verticalSwipeGesture(HSLChannel.allCases, current: channel) { channel = $0 })
    }

    // MARK: 色域通道条

    private var channelStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.sm) {
                ForEach(HSLChannel.allCases, id: \.self) { item in
                    swatchButton(item)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .accessibilityLabel("色域通道")
    }

    private func swatchButton(_ item: HSLChannel) -> some View {
        let selected = item == channel
        let adjusted = adjustment.isAdjusted(item)
        let c = item.swatch
        return Button {
            withAnimation(DS.Motion.standard) { channel = item }
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    if adjusted {
                        Circle()
                            .stroke(DS.accent, lineWidth: 2)
                            .frame(width: 32, height: 32)
                    }
                    Circle()
                        .fill(Color(red: c.red, green: c.green, blue: c.blue))
                        .frame(width: 24, height: 24)
                        .overlay(
                            Circle().stroke(
                                Color.white.opacity(selected ? 0.95 : 0.35),
                                lineWidth: selected ? 2 : 1
                            )
                        )
                }
                .frame(width: 34, height: 34)
                .scaleEffect(selected ? 1 : 0.92)

                Text(item.displayName)
                    .font(.caption2)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.displayName)色域通道")
        .accessibilityValue(adjusted ? "已调整" : "未调整")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: 分量滑杆

    private func sliderRow(_ component: HSLComponent) -> some View {
        let value = adjustment[channel, component]
        let label = "\(channel.displayName)\(component.displayName)"
        return VStack(spacing: 0) {
            HStack {
                Text(component.displayName)
                    .font(DS.Typography.sliderLabel)
                Spacer()
                Text(valueText(value))
                    .font(DS.Typography.sliderValue)
                    .foregroundStyle(value == 0 ? Color.secondary : Color.primary)
                    .frame(width: 44, alignment: .trailing)
            }
            Slider(
                value: Binding(
                    get: { value },
                    set: { onChange(channel, component, $0) }
                ),
                in: -100...100,
                step: 1
            )
            .tint(channelColor)
            .accessibilityLabel(label)
            .accessibilityValue("\(Int(value.rounded()))")
        }
    }

    private func valueText(_ v: Double) -> String {
        let n = Int(v.rounded())
        return n > 0 ? "+\(n)" : "\(n)"
    }

    private var footer: some View {
        HStack(spacing: DS.Spacing.sm) {
            Button {
                onReset(channel)
            } label: {
                Label("重置\(channel.displayName)", systemImage: "arrow.counterclockwise")
                    .font(DS.Typography.sliderLabel)
            }
            .buttonStyle(.plain)
            .disabled(!adjustment.isAdjusted(channel))
            .accessibilityLabel("重置\(channel.displayName)色域")

            Spacer()

            Text("上下滑切换色域 · 色相 ±100 ≈ ±180°")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
