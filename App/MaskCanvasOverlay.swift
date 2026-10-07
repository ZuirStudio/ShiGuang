import SwiftUI
import EditKit
import DesignSystem

// MARK: - 图上蒙版编辑层

/// 蒙版选区在图像上的编辑层。
///
/// 坐标约定：**归一化、左上原点 0...1**，与 `MaskPoint` / `CropRect` / 渲染管线一致。
/// 本层只负责「画手柄 + 采集手势」，不持有编辑状态：
/// - 几何手势用「按下时的快照 + 绝对位置」计算，因此父级（80ms 防抖）暂时落后的值不会让手柄抖动；
/// - 画笔在本地累积 `liveBrush`，涂抹即时可见，同时把最新值推给父级（父级走防抖渲染）。
/// 视觉为项目原创：细白虚线引导 + 圆形手柄（强调色区分旋转/长宽比手柄）。
struct MaskCanvasOverlay: View {
    let mask: Mask
    /// 拖动中的高频更新（父级走 80ms 防抖）。
    let onChange: (Mask, String) -> Void
    /// 手势结束（父级立即渲染一次）。
    let onCommit: (Mask, String) -> Void

    /// 正在拖动的手柄。
    private enum Handle: Hashable {
        case linearStart, linearEnd, linearMid, linearRotate
        case radialCenter, radialRadius, radialAspect, radialRotate
    }

    @State private var activeHandle: Handle?
    @State private var snapshot: Mask?
    @State private var liveBrush: BrushMask?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                switch mask.shape {
                case .linear(let linear):
                    linearLayer(linear, size: geo.size)
                case .radial(let radial):
                    radialLayer(radial, size: geo.size)
                case .brush:
                    brushLayer(size: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("蒙版选区编辑层")
    }

    // MARK: 线性

    private func linearLayer(_ linear: LinearMask, size: CGSize) -> some View {
        let a = screenPoint(linear.start, in: size)
        let b = screenPoint(linear.end, in: size)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let rot = rotateHandle(a: a, b: b, size: size)

        return ZStack {
            Path { path in
                path.move(to: a)
                path.addLine(to: b)
                let n = perpendicularUnit(a: a, b: b)
                let ext = max(min(size.width, size.height) * 0.07, 14)
                for p in [a, b] {
                    path.move(to: CGPoint(x: p.x - n.x * ext, y: p.y - n.y * ext))
                    path.addLine(to: CGPoint(x: p.x + n.x * ext, y: p.y + n.y * ext))
                }
            }
            .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .shadow(color: .black.opacity(0.4), radius: 1)
            .allowsHitTesting(false)

            handle(.linearStart, at: a, size: size, label: "过渡起点", accent: false)
            handle(.linearEnd, at: b, size: size, label: "过渡终点", accent: false)
            handle(.linearMid, at: mid, size: size, label: "整体平移", accent: false)
            handle(.linearRotate, at: rot, size: size, label: "旋转与长度", accent: true)
        }
    }

    /// 旋转 + 长度手柄：沿垂直于选区的方向外移一个固定间距。
    private func rotateHandle(a: CGPoint, b: CGPoint, size: CGSize) -> CGPoint {
        let n = perpendicularUnit(a: a, b: b)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let half = hypot(b.x - a.x, b.y - a.y) / 2
        let gap = rotateGap(size: size)
        return CGPoint(x: mid.x + n.x * (half + gap), y: mid.y + n.y * (half + gap))
    }

    private func rotateGap(size: CGSize) -> CGFloat {
        max(min(size.width, size.height) * 0.10, 30)
    }

    // MARK: 径向

    private func radialLayer(_ radial: RadialMask, size: CGSize) -> some View {
        let minDim = Double(min(size.width, size.height))
        let center = screenPoint(radial.center, in: size)
        let semiX = radial.radius * minDim * radial.aspectRatio
        let semiY = radial.radius * minDim
        let degrees = radial.rotationDegrees

        let radiusHandle = ellipsePoint(center: center, semiX: semiX, semiY: semiY, degrees: degrees, t: .pi / 2)
        let aspectHandle = ellipsePoint(center: center, semiX: semiX, semiY: semiY, degrees: degrees, t: 0)
        let rotDir = CGPoint(x: cos((degrees + 90) * .pi / 180), y: sin((degrees + 90) * .pi / 180))
        let rotDistance = CGFloat(semiY) + rotateGap(size: size)
        let rotHandle = CGPoint(x: center.x + rotDir.x * rotDistance, y: center.y + rotDir.y * rotDistance)

        return ZStack {
            Path { path in
                let steps = 64
                for index in 0...steps {
                    let t = Double(index) / Double(steps) * 2 * .pi
                    let p = ellipsePoint(center: center, semiX: semiX, semiY: semiY, degrees: degrees, t: t)
                    if index == 0 {
                        path.move(to: p)
                    } else {
                        path.addLine(to: p)
                    }
                }
                path.closeSubpath()
                // 两条主轴（帮助判断旋转与长宽比）
                let negAspect = ellipsePoint(center: center, semiX: semiX, semiY: semiY, degrees: degrees, t: .pi)
                let negRadius = ellipsePoint(center: center, semiX: semiX, semiY: semiY, degrees: degrees, t: -.pi / 2)
                path.move(to: aspectHandle)
                path.addLine(to: negAspect)
                path.move(to: radiusHandle)
                path.addLine(to: negRadius)
            }
            .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .shadow(color: .black.opacity(0.4), radius: 1)
            .allowsHitTesting(false)

            handle(.radialCenter, at: center, size: size, label: "选区中心", accent: false)
            handle(.radialRadius, at: radiusHandle, size: size, label: "半径", accent: false)
            handle(.radialAspect, at: aspectHandle, size: size, label: "长宽比", accent: true)
            handle(.radialRotate, at: rotHandle, size: size, label: "旋转", accent: true)
        }
    }

    // MARK: 画笔

    private func brushLayer(size: CGSize) -> some View {
        let brush = liveBrush ?? mask.brushShape ?? BrushMask()
        let minDim = Double(min(size.width, size.height))
        let lineWidth = max(brush.radius * minDim * 2, 2)

        return ZStack {
            // 手势承接层（放在最底层，覆盖整个画幅）
            Color.clear
                .contentShape(Rectangle())
                .gesture(brushGesture(size: size))

            ForEach(brush.strokes.indices, id: \.self) { index in
                strokeShape(brush.strokes[index], size: size, lineWidth: lineWidth)
            }
        }
    }

    @ViewBuilder
    private func strokeShape(_ stroke: BrushStroke, size: CGSize, lineWidth: Double) -> some View {
        if stroke.points.count == 1 {
            Circle()
                .fill(DS.accent.opacity(0.30))
                .frame(width: lineWidth, height: lineWidth)
                .position(screenPoint(stroke.points[0], in: size))
                .allowsHitTesting(false)
        } else if stroke.points.count > 1 {
            Path { path in
                path.move(to: screenPoint(stroke.points[0], in: size))
                for p in stroke.points.dropFirst() {
                    path.addLine(to: screenPoint(p, in: size))
                }
            }
            .stroke(
                DS.accent.opacity(0.30),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
            .allowsHitTesting(false)
        }
    }

    private func brushGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                // R007a P0-4：笔迹只在本地累积（主线程只收集点）。
                // 旧实现在每个点都 onChange → applyMask(deferred:) → 图重建 + 历史提交，
                // 一次涂抹会生成几百条撤销记录，首笔因此被拖住。
                var brush = liveBrush ?? mask.brushShape ?? BrushMask()
                let p = normalizedPoint(value.location, in: size)
                if liveBrush == nil {
                    brush.beginStroke(at: p)
                } else {
                    brush.extendStroke(to: p)
                }
                liveBrush = brush
            }
            .onEnded { _ in
                guard var brush = liveBrush else { return }
                _ = brush.endStroke()
                liveBrush = nil
                var updated = mask
                updated.shape = .brush(brush)
                // 整笔一次提交：历史只有一条，预览一次重渲染
                onCommit(updated, "涂抹选区")
            }
    }

    // MARK: 手柄

    private func handle(_ id: Handle, at location: CGPoint, size: CGSize, label: String, accent: Bool) -> some View {
        ZStack {
            Circle()
                .fill(accent ? DS.accent : Color.white)
                .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
                .frame(width: 20, height: 20)
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .position(location)
        .gesture(handleGesture(id, size: size))
        .accessibilityLabel(label)
        .accessibilityHint("拖动以调整选区")
    }

    private func handleGesture(_ id: Handle, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if activeHandle != id {
                    activeHandle = id
                    snapshot = mask
                }
                guard let base = snapshot,
                      let updated = updatedMask(base: base, handle: id, drag: value, size: size) else { return }
                onChange(updated, label(for: id))
            }
            .onEnded { value in
                if let base = snapshot,
                   let updated = updatedMask(base: base, handle: id, drag: value, size: size) {
                    onCommit(updated, label(for: id))
                }
                activeHandle = nil
                snapshot = nil
            }
    }

    private func label(for handle: Handle) -> String {
        switch handle {
        case .linearStart: return "选区·过渡起点"
        case .linearEnd: return "选区·过渡终点"
        case .linearMid: return "选区·平移"
        case .linearRotate: return "选区·角度与长度"
        case .radialCenter: return "选区·中心"
        case .radialRadius: return "选区·半径"
        case .radialAspect: return "选区·长宽比"
        case .radialRotate: return "选区·旋转"
        }
    }

    // MARK: 手势 → 蒙版

    private func updatedMask(base: Mask, handle: Handle, drag: DragGesture.Value, size: CGSize) -> Mask? {
        var updated = base
        switch handle {
        case .linearStart:
            guard case .linear(var linear) = updated.shape else { return nil }
            linear.start = normalizedPoint(drag.location, in: size).clampedToUnit()
            updated.shape = .linear(linear)

        case .linearEnd:
            guard case .linear(var linear) = updated.shape else { return nil }
            linear.end = normalizedPoint(drag.location, in: size).clampedToUnit()
            updated.shape = .linear(linear)

        case .linearMid:
            guard case .linear(var linear) = updated.shape else { return nil }
            let dx = Double(drag.translation.width / max(size.width, 1))
            let dy = Double(drag.translation.height / max(size.height, 1))
            linear.start = MaskPoint(linear.start.x + dx, linear.start.y + dy).clampedToUnit()
            linear.end = MaskPoint(linear.end.x + dx, linear.end.y + dy).clampedToUnit()
            updated.shape = .linear(linear)

        case .linearRotate:
            guard case .linear(var linear) = updated.shape else { return nil }
            let mid = screenPoint(linear.midpoint, in: size)
            let vx = Double(drag.location.x - mid.x)
            let vy = Double(drag.location.y - mid.y)
            let span = hypot(vx, vy)
            guard span > 1 else { return nil }
            let degrees = atan2(vy, vx) * 180 / .pi
            // 手柄放在 mid + 单位法向 * (半长 + 间距)：
            // 先把「点长度」换算成「归一化长度」（x/y 方向的比例尺不同，逐轴换算）。
            let ux = vx / span
            let uy = vy / span
            let scale = ((ux / max(Double(size.width), 1)) * (ux / max(Double(size.width), 1))
                + (uy / max(Double(size.height), 1)) * (uy / max(Double(size.height), 1))).squareRoot()
            let normalizedHalf = scale * max(span - Double(rotateGap(size: size)), 0)
            linear.rotate(toDegrees: degrees)
            linear.setLength(max(normalizedHalf * 2, 0.02))
            updated.shape = .linear(linear)

        case .radialCenter:
            guard case .radial(var radial) = updated.shape else { return nil }
            radial.center = normalizedPoint(drag.location, in: size).clampedToUnit()
            updated.shape = .radial(radial)

        case .radialRadius:
            guard case .radial(var radial) = updated.shape else { return nil }
            let center = screenPoint(radial.center, in: size)
            let local = unrotated(
                CGPoint(x: drag.location.x - center.x, y: drag.location.y - center.y),
                degrees: radial.rotationDegrees
            )
            let minDim = Double(min(size.width, size.height))
            radial.setRadius(abs(Double(local.y)) / max(minDim, 1))
            updated.shape = .radial(radial)

        case .radialAspect:
            guard case .radial(var radial) = updated.shape else { return nil }
            let center = screenPoint(radial.center, in: size)
            let local = unrotated(
                CGPoint(x: drag.location.x - center.x, y: drag.location.y - center.y),
                degrees: radial.rotationDegrees
            )
            let minDim = Double(min(size.width, size.height))
            let semiY = max(radial.radius * minDim, 1)
            radial.setAspectRatio(abs(Double(local.x)) / semiY)
            updated.shape = .radial(radial)

        case .radialRotate:
            guard case .radial(var radial) = updated.shape else { return nil }
            let center = screenPoint(radial.center, in: size)
            let vx = Double(drag.location.x - center.x)
            let vy = Double(drag.location.y - center.y)
            guard abs(vx) > 0.5 || abs(vy) > 0.5 else { return nil }
            radial.rotationDegrees = atan2(vy, vx) * 180 / .pi - 90
            updated.shape = .radial(radial)
        }

        return updated
    }

    // MARK: 几何工具

    private func screenPoint(_ p: MaskPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(p.x) * size.width, y: CGFloat(p.y) * size.height)
    }

    private func normalizedPoint(_ p: CGPoint, in size: CGSize) -> MaskPoint {
        MaskPoint(
            x: Double(p.x / max(size.width, 1)),
            y: Double(p.y / max(size.height, 1))
        )
    }

    private func perpendicularUnit(a: CGPoint, b: CGPoint) -> CGPoint {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0.001 else { return CGPoint(x: 0, y: -1) }
        return CGPoint(x: -dy / length, y: dx / length)
    }

    /// 椭圆上参数 t 对应的点（屏幕坐标；旋转顺时针为正，与 `LinearMask.angleDegrees` 同向）。
    private func ellipsePoint(center: CGPoint, semiX: Double, semiY: Double, degrees: Double, t: Double) -> CGPoint {
        let lx = semiX * cos(t)
        let ly = semiY * sin(t)
        let r = degrees * .pi / 180
        return CGPoint(
            x: center.x + CGFloat(lx * cos(r) - ly * sin(r)),
            y: center.y + CGFloat(lx * sin(r) + ly * cos(r))
        )
    }

    /// 反向旋转（把屏幕向量转回椭圆本地坐标）。
    private func unrotated(_ v: CGPoint, degrees: Double) -> CGPoint {
        let r = -degrees * .pi / 180
        let c = cos(r)
        let s = sin(r)
        let x = Double(v.x)
        let y = Double(v.y)
        return CGPoint(x: x * c - y * s, y: x * s + y * c)
    }
}
