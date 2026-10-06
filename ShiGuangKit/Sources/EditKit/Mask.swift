import Foundation

// MARK: - 蒙版点位（归一化，左上原点，相对原图）

/// 归一化点位（0...1）。坐标系与原图一致：x 向右、y 向下（UIKit 惯例）。
/// 归一化的好处：蒙版与分辨率无关，换预览尺寸 / 导出全分辨率都不用换算。
public struct MaskPoint: Equatable, Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = min(max(x, -2), 3)
        self.y = min(max(y, -2), 3)
    }

    public init(_ x: Double, _ y: Double) { self.init(x: x, y: y) }

    public static let center = MaskPoint(0.5, 0.5)

    public func clampedToUnit() -> MaskPoint {
        MaskPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    public var isInsideUnit: Bool {
        x >= 0 && x <= 1 && y >= 0 && y <= 1
    }

    /// 到另一点的欧氏距离，按图片像素尺寸换算（width/height 单位与返回距离一致）。
    public func distance(to other: MaskPoint, imageWidth: Double, imageHeight: Double) -> Double {
        let dx = (x - other.x) * imageWidth
        let dy = (y - other.y) * imageHeight
        return (dx * dx + dy * dy).squareRoot()
    }

    /// 点到线段 ab 的最短距离（像素域）。
    public static func distance(
        from p: MaskPoint, toSegment a: MaskPoint, _ b: MaskPoint,
        imageWidth: Double, imageHeight: Double
    ) -> Double {
        let ax = a.x * imageWidth, ay = a.y * imageHeight
        let bx = b.x * imageWidth, by = b.y * imageHeight
        let px = p.x * imageWidth, py = p.y * imageHeight
        let vx = bx - ax, vy = by - ay
        let len2 = vx * vx + vy * vy
        guard len2 > 1e-12 else { return ((px - ax) * (px - ax) + (py - ay) * (py - ay)).squareRoot() }
        var t = ((px - ax) * vx + (py - ay) * vy) / len2
        t = min(max(t, 0), 1)
        let cx = ax + t * vx, cy = ay + t * vy
        return ((px - cx) * (px - cx) + (py - cy) * (py - cy)).squareRoot()
    }
}

// MARK: - 蒙版类型

/// 蒙版形状种类（UI 创建工具条用）。
public enum MaskKind: String, CaseIterable, Identifiable, Codable, Sendable, Equatable {
    case linear
    case radial
    case brush

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .linear: return "线性"
        case .radial: return "径向"
        case .brush: return "画笔"
        }
    }

    public var symbol: String {
        switch self {
        case .linear: return "line.diagonal"
        case .radial: return "circle.dashed.inset.filled"
        case .brush: return "paintbrush.pointed.fill"
        }
    }

    /// 创建时的默认蒙版（含一套"看得见效果"的起始几何：开箱即有变化，便于理解）。
    public func makeDefault() -> Mask {
        switch self {
        case .linear:
            return Mask(
                name: "线性",
                shape: .linear(LinearMask(start: MaskPoint(0.5, 0.10), end: MaskPoint(0.5, 0.60)))
            )
        case .radial:
            return Mask(name: "径向", shape: .radial(RadialMask()))
        case .brush:
            return Mask(name: "画笔", shape: .brush(BrushMask()))
        }
    }
}

// MARK: - 线性渐变

/// 线性渐变：沿 start → end 方向由「无效果」过渡到「全效果」，越过 end 之后保持全效果。
public struct LinearMask: Equatable, Codable, Sendable {
    public var start: MaskPoint
    public var end: MaskPoint

    public init(start: MaskPoint, end: MaskPoint) {
        self.start = start
        self.end = end
    }

    public var midpoint: MaskPoint {
        MaskPoint((start.x + end.x) / 2, (start.y + end.y) / 2)
    }

    /// 屏幕坐标系（y 向下）中的方向角，度；0° = 从左到右，顺时针为正。
    public var angleDegrees: Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        guard abs(dx) > 1e-9 || abs(dy) > 1e-9 else { return 0 }
        return atan2(dy, dx) * 180 / .pi
    }

    /// 归一化长度（按单位方框的欧氏长度，仅用于 UI 手感，不参与渲染）。
    public var length: Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// 绕中点旋转到指定角度，保持长度不变。
    public mutating func rotate(toDegrees degrees: Double) {
        let mid = midpoint
        let half = length / 2
        let r = degrees * .pi / 180
        let dx = cos(r) * half
        let dy = sin(r) * half
        start = MaskPoint(x: mid.x - dx, y: mid.y - dy)
        end = MaskPoint(x: mid.x + dx, y: mid.y + dy)
    }

    /// 绕中点缩放长度（UI 双手势 / 捏合）。
    public mutating func setLength(_ newLength: Double) {
        let mid = midpoint
        let half = max(newLength, 1e-4) / 2
        let r = angleDegrees * .pi / 180
        let dx = cos(r) * half
        let dy = sin(r) * half
        start = MaskPoint(x: mid.x - dx, y: mid.y - dy)
        end = MaskPoint(x: mid.x + dx, y: mid.y + dy)
    }
}

// MARK: - 径向渐变

/// 径向渐变：中心向外的椭圆（aspectRatio = 宽 / 高），rotationDegrees 为屏幕坐标下的旋转角。
public struct RadialMask: Equatable, Codable, Sendable {
    public var center: MaskPoint
    /// 半径，相对图片短边（0.3 = 短边的 30%）。
    public var radius: Double
    public var aspectRatio: Double
    public var rotationDegrees: Double

    public init(
        center: MaskPoint = .center,
        radius: Double = 0.32,
        aspectRatio: Double = 1.0,
        rotationDegrees: Double = 0
    ) {
        self.center = center
        self.radius = min(max(radius, 0.01), 2.0)
        self.aspectRatio = min(max(aspectRatio, 0.1), 10)
        self.rotationDegrees = rotationDegrees
    }

    public mutating func setRadius(_ r: Double) { radius = min(max(r, 0.01), 2.0) }
    public mutating func setAspectRatio(_ a: Double) { aspectRatio = min(max(a, 0.1), 10) }
}

// MARK: - 画笔

/// 单笔画：一串归一化轨迹点 + 该笔的半径（归一化，相对短边）。
public struct BrushStroke: Equatable, Codable, Sendable {
    public var points: [MaskPoint]
    public var radius: Double

    public init(points: [MaskPoint] = [], radius: Double = 0.08) {
        self.points = points
        self.radius = radius
    }

    public var isEmpty: Bool { points.isEmpty }

    /// 轨迹点间的最短距离（像素域），单点笔画按点距处理。
    public func distance(to p: MaskPoint, imageWidth: Double, imageHeight: Double) -> Double {
        guard let first = points.first else { return .greatestFiniteMagnitude }
        guard points.count > 1 else {
            return p.distance(to: first, imageWidth: imageWidth, imageHeight: imageHeight)
        }
        var best = Double.greatestFiniteMagnitude
        for i in 1..<points.count {
            best = min(best, MaskPoint.distance(
                from: p, toSegment: points[i - 1], points[i],
                imageWidth: imageWidth, imageHeight: imageHeight
            ))
        }
        return best
    }
}

/// 画笔蒙版：多笔画 + 笔刷参数（半径 / 硬度 / 流量）。
/// 采样同时支持向量光栅化（Core Graphics 描线）与参考实现（纯几何 alpha）。
public struct BrushMask: Equatable, Codable, Sendable {
    public var strokes: [BrushStroke]
    /// 当前笔刷半径（归一化，相对短边）。
    public var radius: Double
    /// 边缘硬度 0...100（100 = 硬边）。
    public var hardness: Double
    /// 单笔最大不透明度 0...100。
    public var flow: Double

    public init(
        strokes: [BrushStroke] = [],
        radius: Double = 0.08,
        hardness: Double = 60,
        flow: Double = 100
    ) {
        self.strokes = strokes
        self.radius = min(max(radius, 0.005), 1.0)
        self.hardness = min(max(hardness, 0), 100)
        self.flow = min(max(flow, 0), 100)
    }

    public var isEmpty: Bool { strokes.allSatisfy(\.isEmpty) }

    public mutating func beginStroke(at p: MaskPoint) {
        strokes.append(BrushStroke(points: [p.clampedToUnit()], radius: radius))
    }

    public mutating func extendStroke(to p: MaskPoint) {
        guard !strokes.isEmpty else {
            beginStroke(at: p)
            return
        }
        strokes[strokes.count - 1].points.append(p.clampedToUnit())
    }

    /// 结束当前笔画（丢弃零点笔画，避免空笔进入历史）。
    @discardableResult
    public mutating func endStroke() -> Bool {
        guard let last = strokes.last else { return false }
        if last.isEmpty {
            strokes.removeLast()
            return false
        }
        return true
    }

    /// 撤销单笔画。
    @discardableResult
    public mutating func undoLastStroke() -> Bool {
        guard !strokes.isEmpty else { return false }
        strokes.removeLast()
        return true
    }

    /// 参考实现：某点的 alpha（0 = 无效果、1 = 全效果）。
    /// 与 Core Graphics 光栅化路径语义一致；用于单测与几何断言。
    public func alpha(at p: MaskPoint, imageWidth: Double, imageHeight: Double) -> Double {
        guard !isEmpty else { return 0 }
        var best = 0.0
        let shortSide = min(imageWidth, imageHeight)
        for stroke in strokes where !stroke.isEmpty {
            let r = max(stroke.radius, 1e-6) * shortSide
            let d = stroke.distance(to: p, imageWidth: imageWidth, imageHeight: imageHeight)
            let soft = 1 - hardness / 100
            let inner = r * (1 - soft)
            let a: Double
            if d <= inner {
                a = 1
            } else if d >= r {
                a = 0
            } else {
                a = (r - d) / (r - inner)
            }
            best = max(best, a * flow / 100)
        }
        return min(max(best, 0), 1)
    }
}

// MARK: - 形状

/// 三种蒙版子类型（可扩展：Phase 4 后续接 AI 主体 / 天空蒙版时新增 case）。
public enum MaskShape: Equatable, Codable, Sendable {
    case linear(LinearMask)
    case radial(RadialMask)
    case brush(BrushMask)

    public var kind: MaskKind {
        switch self {
        case .linear: return .linear
        case .radial: return .radial
        case .brush: return .brush
        }
    }
}

// MARK: - 蒙版

/// 蒙版：形状 + 显示属性 + **局部调整**（复用全量参数集）。
/// - 作为独立指令进入 `EditGraph`（`EditOperation.mask`），历史原子提交；
/// - 局部调整的渲染 = 先用现有管线作用于整图，再按蒙版 alpha 与原图混合。
public struct Mask: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var shape: MaskShape
    /// 反选。
    public var isInverted: Bool
    /// 边缘羽化 0...100。
    public var feather: Double
    /// 整体不透明度 0...100。
    public var opacity: Double
    /// 局部调整（不含嵌套蒙版）。
    public var adjustments: [EditOperation]

    public init(
        id: UUID = UUID(),
        name: String,
        shape: MaskShape,
        isInverted: Bool = false,
        feather: Double = 40,
        opacity: Double = 100,
        adjustments: [EditOperation] = []
    ) {
        self.id = id
        self.name = name
        self.shape = shape
        self.isInverted = isInverted
        self.feather = min(max(feather, 0), 100)
        self.opacity = min(max(opacity, 0), 100)
        self.adjustments = adjustments.filter { !$0.isMask }
    }

    public var kind: MaskKind { shape.kind }

    /// 空画笔蒙版（尚未涂抹）——渲染时跳过。
    public var isEffectivelyEmpty: Bool {
        if case .brush(let b) = shape { return b.isEmpty }
        return false
    }

    /// 渲染/序列化前的几何归一化（幂等）。手写 JSON 或旧版本数据也能安全进入管线。
    public func normalized() -> Mask {
        var copy = self
        copy.feather = min(max(feather, 0), 100)
        copy.opacity = min(max(opacity, 0), 100)
        switch shape {
        case .linear(var l):
            l.start = l.start.clampedToUnit()
            l.end = l.end.clampedToUnit()
            copy.shape = .linear(l)
        case .radial(var r):
            r.center = r.center.clampedToUnit()
            r.radius = min(max(r.radius, 0.01), 2)
            r.aspectRatio = min(max(r.aspectRatio, 0.1), 10)
            copy.shape = .radial(r)
        case .brush(var b):
            b.radius = min(max(b.radius, 0.005), 1)
            b.hardness = min(max(b.hardness, 0), 100)
            b.flow = min(max(b.flow, 0), 100)
            for i in b.strokes.indices {
                b.strokes[i].radius = min(max(b.strokes[i].radius, 0.002), 1)
                b.strokes[i].points = b.strokes[i].points.map { $0.clampedToUnit() }
            }
            copy.shape = .brush(b)
        }
        copy.adjustments = adjustments.filter { !$0.isMask }.map(\.clamped)
        return copy
    }

    /// 别名：空画笔蒙版不产生视觉效果。
    public var isEmpty: Bool { isEffectivelyEmpty }

    // MARK: 局部调整编辑（与 EditGraph 同语义：同参数后写覆盖）

    public func value(for parameter: EditParameter) -> Double {
        adjustments.last(where: { $0.parameter == parameter })?.numericValue ?? 0
    }

    /// 写入/覆盖一个参数（保持参数在数组中的位置，避免顺序漂移）。
    public mutating func setAdjustment(_ operation: EditOperation) {
        guard !operation.isMask else { return }
        let clamped = operation.clamped
        if let index = adjustments.lastIndex(where: { $0.parameter == clamped.parameter }) {
            adjustments[index] = clamped
        } else {
            adjustments.append(clamped)
        }
    }

    public mutating func removeAdjustment(for parameter: EditParameter) {
        adjustments.removeAll { $0.parameter == parameter }
    }

    public mutating func resetAdjustments() {
        adjustments.removeAll()
    }

    /// 是否已有任何局部调整（UI 徽标）。
    public var hasAdjustments: Bool { !adjustments.isEmpty }

    /// 已被局部调整过的参数（用于面板高亮）。
    public var adjustedParameters: [EditParameter] {
        var seen: [EditParameter] = []
        for op in adjustments where !seen.contains(op.parameter) {
            seen.append(op.parameter)
        }
        return seen
    }

    /// 复制（新 id，用于「复制蒙版」）。
    public func duplicated(nameSuffix: String = " 副本") -> Mask {
        Mask(
            name: name + nameSuffix,
            shape: shape,
            isInverted: isInverted,
            feather: feather,
            opacity: opacity,
            adjustments: adjustments
        )
    }
}

// MARK: - 指令辅助

extension EditOperation {
    /// 是否为蒙版指令（结构化，不参与折叠 / 混合 / 手势序列）。
    public var isMask: Bool {
        if case .mask = self { return true }
        return false
    }

    public var maskValue: Mask? {
        if case .mask(let m) = self { return m }
        return nil
    }
}

// MARK: - EditGraph 蒙版操作

extension EditGraph {
    /// 当前蒙版列表（保持指令顺序 = 叠加顺序，后者在上）。
    public var masks: [Mask] {
        operations.compactMap(\.maskValue)
    }

    public func mask(id: UUID) -> Mask? {
        masks.last { $0.id == id }
    }

    /// 插入或就地替换（**保持原位置**，从而保持叠加顺序稳定）。
    /// 返回 true 表示是就地替换（而非新增）。
    @discardableResult
    public mutating func upsertMask(_ mask: Mask) -> Bool {
        let op = EditOperation.mask(mask)
        if let index = operations.lastIndex(where: { $0.maskValue?.id == mask.id }) {
            operations[index] = op
            return true
        }
        operations.append(op)
        return false
    }

    @discardableResult
    public mutating func removeMask(id: UUID) -> Bool {
        let before = operations.count
        operations.removeAll { $0.maskValue?.id == id }
        return operations.count != before
    }

    /// 蒙版在指令数组中的位置（叠放顺序即层级）。
    public func maskIndex(of id: UUID) -> Int? {
        operations.firstIndex { $0.maskValue?.id == id }
    }

    /// 最上层蒙版（新建后自动选中）。
    public var lastMask: Mask? { masks.last }

    /// 上移 / 下移一层：只与**相邻的蒙版指令**交换，不会越过调色指令。
    @discardableResult
    public mutating func moveMask(id: UUID, by offset: Int) -> Bool {
        guard let index = maskIndex(of: id) else { return false }
        // 找出相邻的蒙版位置
        let step = offset > 0 ? 1 : -1
        var remaining = abs(offset)
        var cursor = index
        while remaining > 0 {
            var probe = cursor + step
            while probe >= 0, probe < operations.count, !operations[probe].isMask {
                probe += step
            }
            guard probe >= 0, probe < operations.count else { return false }
            operations.swapAt(cursor, probe)
            cursor = probe
            remaining -= 1
        }
        return true
    }

    /// 复制蒙版：新 id，插在原蒙版之后（副本紧随其源，层级直观）。
    @discardableResult
    public mutating func duplicateMask(id: UUID) -> Mask? {
        guard let index = maskIndex(of: id), let source = operations[index].maskValue else { return nil }
        let copy = source.duplicated().normalized()
        operations.insert(.mask(copy), at: index + 1)
        return copy
    }
}

// MARK: - 历史：蒙版与调色并列的独立提交路径

extension EditHistory {
    /// 蒙版提交：同蒙版同标签的连续拖动合并为一步（滑杆手感），否则新增一步。
    public mutating func commitMask(_ mask: Mask, label: String) {
        if let last = steps.last,
           last.label == label,
           last.operations.count == 1,
           last.operations[0].maskValue?.id == mask.id {
            steps[steps.count - 1] = HistoryStep(label: label, operations: [.mask(mask)])
        } else {
            steps.append(HistoryStep(label: label, operations: [.mask(mask)]))
        }
        redoSteps.removeAll()
    }

    /// 删除蒙版：从所有历史步骤中剥离该蒙版的指令。
    /// ⚠️ v1 限制：删除不可撤销（其余编辑的撤销/重做不受影响）。
    public mutating func commitMaskRemoval(id: UUID, label: String) {
        steps = steps.compactMap { step in
            let kept = step.operations.filter { $0.maskValue?.id != id }
            return kept.isEmpty ? nil : HistoryStep(id: step.id, label: step.label, operations: kept)
        }
        redoSteps.removeAll()
    }
}
