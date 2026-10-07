import SwiftUI
import DesignSystem
import EditKit

/// R006 追加 B1：上下滑切参数时浮现的**全屏参数列表浮层**。
///
/// 交互模型（保留底层「分组吸顶滑杆面板」不动，两者叠加）：
/// - 平时：滑杆面板（现有 UI）
/// - 手指在图像区上下滑 → 本浮层淡入，列出当前模块**全部**参数
/// - 当前参数**整行高亮**，用拾光品牌色暖金橙 `#FFB347`（原创，非参考品的黄色）
/// - 离中心越远的行越低透明、越缩小，形成「轮盘」式的视觉焦点
/// - 每行右侧有一条细电平条，显示当前值在量程中的位置（相对 `defaultRange`）
/// - 松手 → 淡出消失（`isPresented` 由调用方控制）
///
/// 无手势逻辑：本视图只负责画，`onSelect` 供点击行直接跳参数（无障碍与点睛用）。
struct ParameterListOverlay: View {
    let title: String
    let parameters: [EditParameter]
    let activeIndex: Int
    /// 取值闭包（当前值），用于电平条
    let value: (EditParameter) -> Double
    /// 点某一行直接跳到该参数
    var onSelect: ((Int) -> Void)? = nil

    /// 行高（用于把「离中心的距离」换算成视觉权重）
    private let rowHeight: CGFloat = 44

    var body: some View {
        ZStack {
            // 压暗背景：让列表成为焦点，但不完全遮住照片（照片要能继续看得见）
            Color.black.opacity(0.42)
                .ignoresSafeArea()

            VStack(spacing: DS.Spacing.sm) {
                Text(title)
                    .font(DS.Typography.sliderLabel)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.bottom, DS.Spacing.xs)

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            ForEach(Array(parameters.enumerated()), id: \.offset) { index, parameter in
                                row(index: index, parameter: parameter)
                                    .id(index)
                            }
                        }
                        .padding(.vertical, 90)
                    }
                    .scrollDisabled(true)
                    .frame(maxHeight: 320)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.22),
                                .init(color: .black, location: 0.78),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .onChange(of: activeIndex) { _, newValue in
                        withAnimation(DS.Motion.standard) {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                    .onAppear {
                        proxy.scrollTo(activeIndex, anchor: .center)
                    }
                }
            }
            .padding(.vertical, DS.Spacing.lg)
        }
        .allowsHitTesting(onSelect != nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("参数列表，当前 \(currentName)")
    }

    private var currentName: String {
        guard parameters.indices.contains(activeIndex) else { return "" }
        return parameters[activeIndex].historyLabel
    }

    // MARK: 行

    @ViewBuilder
    private func row(index: Int, parameter: EditParameter) -> some View {
        let distance = abs(index - activeIndex)
        let isActive = index == activeIndex
        // 视觉权重：0.34 起步，随距离衰减；当前行为 1.0
        let weight = max(0.34, 1.0 - Double(distance) * 0.34)

        Button {
            onSelect?(index)
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                // 品牌色指示条：仅当前行亮起
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(isActive ? DS.Brand.gold : Color.clear)
                    .frame(width: 3, height: 22)

                Text(parameter.historyLabel)
                    .font(isActive ? DS.Typography.panelTitle : DS.Typography.sliderLabel)
                    .foregroundStyle(isActive ? DS.Brand.gold : Color.white.opacity(0.85))

                Spacer(minLength: DS.Spacing.md)

                levelBar(for: parameter, isActive: isActive)
            }
            .padding(.horizontal, DS.Spacing.md)
            .frame(height: rowHeight)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .fill(isActive ? DS.Brand.gold.opacity(0.14) : Color.clear)
                    .padding(.horizontal, DS.Spacing.sm)
            )
            .opacity(weight)
            .scaleEffect(isActive ? 1.0 : 0.94, anchor: .center)
        }
        .buttonStyle(.plain)
        .disabled(!isActive && onSelect == nil)
        .animation(DS.Motion.standard, value: activeIndex)
    }

    /// 当前值在 `defaultRange` 中的位置（0...1），中间值为中性点。
    @ViewBuilder
    private func levelBar(for parameter: EditParameter, isActive: Bool) -> some View {
        let range = parameter.defaultRange
        let span = range.upperBound - range.lowerBound
        let raw = span > 0 ? (value(parameter) - range.lowerBound) / span : 0.5
        let fraction = min(max(raw, 0), 1)
        // 中性点（0 值）在量程中的位置 —— 本项目多数参数下界为负、上界为正
        let neutral = span > 0 ? min(max((0 - range.lowerBound) / span, 0), 1) : 0.5

        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(width: 56, height: 2)
            Rectangle()
                .fill(Color.white.opacity(0.4))
                .frame(width: 1, height: 8)
                .offset(x: 56 * neutral - 0.5)
            Capsule()
                .fill(isActive ? DS.Brand.gold : Color.white.opacity(0.55))
                .frame(width: 56 * fraction, height: 3)
        }
        .frame(width: 56, height: 10)
    }
}
