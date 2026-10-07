import SwiftUI
import Observation
import DesignSystem

// MARK: - 状态

/// R006 追加 C：AI 处理（磨皮 / 美白）的可观测状态。
///
/// 设计目标（对齐用户给的参考标准 + 拾光差异化）：
/// 1. **不黑屏**：处理期间调用方保留上一帧预览，本状态只负责叠一层浮层
/// 2. 浮层提示「正在处理中」
/// 3. 有**真实**进度（来自 `PortraitMaskAnalyzer` 的分阶段回调，不是假动画）
/// 4. 用户可选「后台处理」
/// 5. 后台后左上角持续显示进度
/// 6. 后台后仍可继续编辑其他参数（渲染管线本身已异步）
@MainActor
@Observable
final class AIProcessingState {
    enum Stage: Int, CaseIterable {
        case preparing = 0
        case skinTone
        case portrait
        case applying

        var title: String {
            switch self {
            case .preparing: return "准备图像"
            case .skinTone: return "分析肤色区域"
            case .portrait: return "识别人像轮廓"
            case .applying: return "生成柔化掩码"
            }
        }

        /// 各阶段完成后的进度值（真实里程碑，不是线性补间）
        var fraction: Double {
            switch self {
            case .preparing: return 0.08
            case .skinTone: return 0.34
            case .portrait: return 0.67
            case .applying: return 0.92
            }
        }
    }

    var stage: Stage = .preparing
    var isRunning = false
    /// 用户点了「后台处理」：浮层收起，只留左上角角标
    var isBackground = false
    /// 处理完成后短暂显示「已完成」再自动消失
    var isFinishing = false
    var didFail = false

    var fraction: Double { didFail ? 1.0 : (isFinishing ? 1.0 : stage.fraction) }

    var headline: String {
        if didFail { return "处理失败" }
        if isFinishing { return "处理完成" }
        return stage.title
    }

    var stepText: String {
        if didFail || isFinishing { return "" }
        return "第 \(stage.rawValue + 1) / \(Stage.allCases.count) 步"
    }

    /// 是否应该在图像区显示全屏浮层（后台或收尾时不显示）
    var showsOverlay: Bool { isRunning && !isBackground }

    func begin() {
        stage = .preparing
        isRunning = true
        isBackground = false
        isFinishing = false
        didFail = false
    }

    func advance(to stage: Stage) {
        guard isRunning else { return }
        self.stage = stage
    }

    /// 由**真实**阶段回调驱动（来自 `PortraitMaskAnalyzer` 的 `done/total`）。
    /// 0/3 准备 → 1/3 肤色 → 2/3 人像 → 3/3 生成掩码。
    func update(done: Int, total: Int) {
        guard isRunning else { return }
        let bounded = max(0, min(done, max(1, total)))
        stage = Stage(rawValue: bounded) ?? .applying
    }

    func moveToBackground() { isBackground = true }
    func resurface() { isBackground = false }

    func finish(success: Bool) {
        isRunning = false
        isFinishing = success
        didFail = !success
    }

    func reset() {
        isRunning = false
        isBackground = false
        isFinishing = false
        didFail = false
        stage = .preparing
    }
}

// MARK: - 进度上报（跨线程）

/// 分析在线程池里跑、进度要回报到 UI。
/// 刻意**不用 actor**：`PortraitMaskAnalyzer` 的阶段回调是**同步**闭包，走 actor 就必须 `await`，
/// 会把同步回调逼成异步。这里用一把锁做单向传递，主线程侧轮询读取。
final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = 0
    private var total = 3

    func report(done: Int, total newTotal: Int) {
        lock.lock()
        defer { lock.unlock() }
        completed = done
        total = max(1, newTotal)
    }

    func snapshot() -> (done: Int, total: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (completed, total)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        completed = 0
        total = 3
    }
}

// MARK: - 全屏浮层

/// 处理中浮层：**压暗但不遮死**上一帧预览（不黑屏），中间是环形进度 + 阶段文案 + 两个动作。
struct ProcessingHUD: View {
    let state: AIProcessingState
    var onBackground: () -> Void
    var onCancel: () -> Void

    @State private var shimmer = false

    var body: some View {
        ZStack {
            // 只压暗，不涂黑 —— 用户始终看得见自己的照片
            Color.black.opacity(0.28)
                .ignoresSafeArea(edges: .horizontal)

            VStack(spacing: DS.Spacing.md) {
                ProgressRing(fraction: state.fraction, lineWidth: 5)
                    .frame(width: 68, height: 68)
                    .overlay {
                        Text("\(Int(state.fraction * 100))%")
                            .font(DS.Typography.sliderValue)
                            .foregroundStyle(.white)
                            .monospacedDigit()
                    }

                VStack(spacing: DS.Spacing.xs) {
                    Text(state.headline)
                        .font(DS.Typography.panelTitle)
                        .foregroundStyle(.white)
                    if !state.stepText.isEmpty {
                        Text(state.stepText)
                            .font(DS.Typography.sliderLabel)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                HStack(spacing: DS.Spacing.sm) {
                    Button("后台处理", action: onBackground)
                        .buttonStyle(.borderedProminent)
                        .tint(DS.Brand.gold)
                    Button("取消", role: .cancel, action: onCancel)
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
                .font(DS.Typography.sliderLabel)
                .padding(.top, DS.Spacing.xs)
            }
            .padding(DS.Spacing.lg)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        }
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(state.headline)，已完成 \(Int(state.fraction * 100))%")
    }
}

// MARK: - 左上角后台角标

/// 后台处理时左上角**持续**显示的进度角标（点一下可把浮层叫回来）。
struct BackgroundProcessingPill: View {
    let state: AIProcessingState
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                ProgressRing(fraction: state.fraction, lineWidth: 2.5, showsTrack: true)
                    .frame(width: 18, height: 18)
                Text("\(Int(state.fraction * 100))%")
                    .font(DS.Typography.sliderValue)
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(DS.Brand.gold.opacity(0.45), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("后台处理中，已完成 \(Int(state.fraction * 100))%，轻点返回")
    }
}

// MARK: - 环形进度

/// 细环形进度（品牌色渐变），用于浮层与角标。
struct ProgressRing: View {
    let fraction: Double
    var lineWidth: CGFloat = 5
    var showsTrack: Bool = true

    var body: some View {
        ZStack {
            if showsTrack {
                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: lineWidth)
            }
            Circle()
                .trim(from: 0, to: max(0.001, min(fraction, 1)))
                .stroke(
                    AngularGradient(
                        colors: [DS.Brand.gold, DS.Brand.ember, DS.Brand.gold],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(DS.Motion.standard, value: fraction)
        }
    }
}
