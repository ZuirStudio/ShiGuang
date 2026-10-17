import SwiftUI
import UIKit

// MARK: - P0-C（R007c）：图像区手势的 UIKit 顶层覆盖层

/// 为什么换掉 SwiftUI 手势（v0.7.0 → v0.7.2 的真机反复失败记录）：
///
/// 图像区原来挂的是 SwiftUI 的 `highPriorityGesture(DragGesture)` +
/// `onLongPressGesture`。真机表现：按住 0.2s 出现「原图」后再水平拖动，**依然定格卡死**、
/// 参数不跟手。根因不是优先级不够，而是 **SwiftUI 手势状态机在复杂 ZStack 里
/// 无法保证「长按已成立后拖拽仍能接管」**：长按一旦 recognize，竞争中的拖拽会被
/// 取消/冻结，回调时序还依赖 `onPressingChanged(false)` 的到达（真机上会晚到或不触发）。
/// 两轮修复（simultaneousGesture → highPriorityGesture）都只在同一套状态机里换优先级，
/// 治标不治本。
///
/// R007c 终极方案：**UIKit 手势识别器顶层覆盖层**。
/// - 覆盖层盖在画布之上（ZStack 最上层），但**只覆盖图像区** —— 底部滑杆面板在它之外，
///   面板内的 ScrollView / 滑杆手势完全不受影响；
/// - `UIPanGestureRecognizer` 是覆盖层上最顶层的连续识别器：按下即跟踪、移动即recognize，
///   SwiftUI 下层任何 `onLongPress` / `ScrollView` 都不可能把它「冻结」或抢走；
/// - 长按看原图改用 `UILongPressGestureRecognizer`，与拖拽这一对**允许并发**
///   （delegate 显式放行，且只放行这一对）—— 长按按下后拖拽立刻接管，信号层
///   （轴向锁定即退出原图）保证状态自洽；
/// - 蒙版图上编辑期整个覆盖层**不挂载**，画笔/涂抹手势完整留给 `MaskCanvasOverlay`。
struct ScrubGestureOverlay: UIViewRepresentable {
    /// 拖拽中（translation = 距手势起点的累计位移，与 SwiftUI `DragGesture.Value.translation` 同语义）。
    var onChange: (CGSize) -> Void
    /// 拖拽结束/取消（调用方重置手势状态并升回静止档预览）。
    var onEnded: () -> Void
    /// 长按按压状态变化（true = 按住看原图）。
    var onPressingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> PassthroughScrubView {
        let view = PassthroughScrubView()
        view.backgroundColor = .clear

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        // 不取消对下层的触摸投递：单击（拖拽失败）时触摸继续传给画布上的 SwiftUI 视图，
        // 覆盖层存在与否对点击语义零影响。
        pan.cancelsTouchesInView = false
        pan.minimumNumberOfTouches = 1
        view.addGestureRecognizer(pan)

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:)))
        longPress.delegate = context.coordinator
        longPress.minimumPressDuration = 0.12   // 与旧 onLongPressGesture(minimumDuration:) 一致
        longPress.allowableMovement = 24        // 与旧 maximumDistance: 24 一致
        view.addGestureRecognizer(longPress)

        context.coordinator.pan = pan
        context.coordinator.longPress = longPress
        return view
    }

    func updateUIView(_ uiView: PassthroughScrubView, context: Context) {
        // SwiftUI 每次更新都重建 value 语义的 parent；Coordinator 持有最新副本，
        // 保证回调（@escaping）指向最新的捕获状态（@State 包装值在闭包里是引用语义）。
        context.coordinator.parent = self
    }

    /// 手势回调转发 + 「长按 × 拖拽」并发放行。
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ScrubGestureOverlay
        weak var pan: UIPanGestureRecognizer?
        weak var longPress: UILongPressGestureRecognizer?

        init(parent: ScrubGestureOverlay) {
            self.parent = parent
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began, .changed:
                parent.onChange(gesture.translation(in: gesture.view))
            case .ended, .cancelled, .failed:
                parent.onEnded()
            default:
                break
            }
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                parent.onPressingChanged(true)
            case .ended, .cancelled, .failed:
                parent.onPressingChanged(false)
            default:
                break
            }
        }

        /// 只放行「长按 × 拖拽」这一对并发：长按按住时拖拽要能立即 recognize，
        /// 其余组合（不存在，但防御）不放行，避免识别器互相稀释。
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            (gestureRecognizer === pan && other === longPress)
                || (gestureRecognizer === longPress && other === pan)
        }
    }
}

/// 覆盖层宿主视图：透明、可交互、无子视图。
/// 只挂两个识别器；触摸未形成手势时（单击）自动落空，不吞事件。
final class PassthroughScrubView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
