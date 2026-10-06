import Foundation

// MARK: - 曲线通道

/// 色调曲线通道：RGB 主通道 + R / G / B 三条分通道。
/// 语义：最终通道值 = 分通道曲线(RGB 主曲线(输入))。
public enum CurveChannel: String, Equatable, Sendable, CaseIterable, Codable {
    case rgb, red, green, blue

    public var displayName: String {
        switch self {
        case .rgb: return "RGB"
        case .red: return "红"
        case .green: return "绿"
        case .blue: return "蓝"
        }
    }

    /// 通道 Tab 缩写。
    public var compactName: String {
        switch self {
        case .rgb: return "RGB"
        case .red: return "R"
        case .green: return "G"
        case .blue: return "B"
        }
    }

    /// 通道强调色（sRGB 0...1，纯数据；App 层转 Color）。
    public var tint: (red: Double, green: Double, blue: Double) {
        switch self {
        case .rgb: return (0.90, 0.90, 0.92)
        case .red: return (0.95, 0.29, 0.27)
        case .green: return (0.24, 0.79, 0.42)
        case .blue: return (0.25, 0.55, 0.96)
        }
    }
}

// MARK: - 曲线控制点

/// 归一化控制点（x = 输入，y = 输出，均 0...1）。
public struct CurvePoint: Equatable, Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

// MARK: - 单条色调曲线

/// 单条色调曲线：控制点数组 + 单调三次插值。
/// - x 严格递增（回折被 sanitize 消除）；
/// - 端点 (0,0) / (1,1) 恒存在（可上下移动，不可删除）；
/// - 插值采用 Fritsch–Carlson 单调 Hermite，保证不过冲（暗部不反转）。
public struct ToneCurve: Equatable, Codable, Sendable {
    public static let maxPoints = 16
    public static let identityPoints: [CurvePoint] = [CurvePoint(0, 0), CurvePoint(1, 1)]

    public private(set) var points: [CurvePoint]

    public init() {
        points = ToneCurve.identityPoints
    }

    public init(points: [CurvePoint]) {
        self.points = ToneCurve.sanitize(points)
    }

    // MARK: 序列化

    /// 自定义编解码：**解码必经 sanitize**。
    /// 合成的 Decodable 会直接写入存储属性，绕过归一化 → 外部（预设文件 / 迁移数据）
    /// 带入乱序、越界或同 x 的控制点会让二分查找与插值给出错误结果。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([CurvePoint].self)
        self.points = ToneCurve.sanitize(raw)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(points)
    }

    public static var identity: ToneCurve { ToneCurve() }

    /// 恒等（y == x）判定：预设强度混合与"是否烘焙"依赖此判断。
    public var isIdentity: Bool {
        points.allSatisfy { abs($0.y - $0.x) < 1e-6 }
    }

    /// 中间控制点数量（不含两端锚点）。
    public var interiorCount: Int { max(points.count - 2, 0) }

    // MARK: 采样

    public func sample(at x: Double) -> Double {
        let p = points
        guard p.count >= 2 else { return ToneCurve.clamp01(x) }
        let t = ToneCurve.clamp01(x)
        if t <= p[0].x { return p[0].y }
        if t >= p[p.count - 1].x { return p[p.count - 1].y }

        var lo = 0
        var hi = p.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if p[mid].x <= t { lo = mid } else { hi = mid }
        }

        let h = p[hi].x - p[lo].x
        guard h > 1e-9 else { return p[lo].y }
        let m = ToneCurve.tangents(p)
        let s = (t - p[lo].x) / h
        let s2 = s * s
        let s3 = s2 * s
        let h00 = 2 * s3 - 3 * s2 + 1
        let h10 = s3 - 2 * s2 + s
        let h01 = -2 * s3 + 3 * s2
        let h11 = s3 - s2
        let y = h00 * p[lo].y + h10 * h * m[lo] + h01 * p[hi].y + h11 * h * m[hi]
        return ToneCurve.clamp01(y)
    }

    /// 采样表（count 个等距采样，含两端）。
    public func table(count: Int) -> [Double] {
        guard count > 1 else { return [0] }
        let last = Double(count - 1)
        var out = [Double](repeating: 0, count: count)
        for i in 0..<count {
            out[i] = sample(at: Double(i) / last)
        }
        return out
    }

    // MARK: 编辑

    /// 增加控制点；x 与已有点过近或超出上限时返回 false。
    @discardableResult
    public mutating func addPoint(_ point: CurvePoint) -> Bool {
        guard points.count < ToneCurve.maxPoints else { return false }
        let p = CurvePoint(ToneCurve.clamp01(point.x), ToneCurve.clamp01(point.y))
        guard !points.contains(where: { abs($0.x - p.x) < 1e-3 }) else { return false }
        points.append(p)
        points = ToneCurve.sanitize(points)
        return true
    }

    /// 拖动控制点（x 被夹在相邻点之间，保持严格递增）。
    @discardableResult
    public mutating func movePoint(at index: Int, to point: CurvePoint) -> Bool {
        guard points.indices.contains(index) else { return false }
        var p = point
        p.y = ToneCurve.clamp01(p.y)
        if index == 0 {
            p.x = points[0].x
        } else if index == points.count - 1 {
            p.x = points[points.count - 1].x
        } else {
            let lo = points[index - 1].x + 1e-3
            let hi = points[index + 1].x - 1e-3
            p.x = min(max(p.x, lo), hi)
        }
        points[index] = p
        return true
    }

    /// 删除控制点；端点不可删除。
    @discardableResult
    public mutating func removePoint(at index: Int) -> Bool {
        guard index > 0, index < points.count - 1 else { return false }
        points.remove(at: index)
        return true
    }

    /// 预设强度混合：控制点 y 向对角线收敛（x 不变 → 单调性天然保持）。
    public func blended(towardsIdentity amount: Double) -> ToneCurve {
        let t = ToneCurve.clamp01(amount)
        if t >= 0.999 { return self }
        guard t > 0.001 else { return ToneCurve() }
        let blended = points.map { CurvePoint($0.x, $0.x + ($0.y - $0.x) * t) }
        return ToneCurve(points: blended)
    }

    // MARK: 内部

    static func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }

    /// 归一化：夹紧 → 排序 → 去重 → 补端点。
    static func sanitize(_ input: [CurvePoint]) -> [CurvePoint] {
        let sorted = input
            .map { CurvePoint(clamp01($0.x), clamp01($0.y)) }
            .sorted { $0.x < $1.x }

        var result: [CurvePoint] = []
        for p in sorted {
            if let last = result.last, abs(last.x - p.x) < 1e-3 {
                result[result.count - 1] = p   // 同 x 取后者
                continue
            }
            result.append(p)
        }

        guard !result.isEmpty else { return ToneCurve.identityPoints }
        if result[0].x > 1e-6 {
            result.insert(CurvePoint(0, 0), at: 0)
        } else {
            result[0] = CurvePoint(0, result[0].y)
        }
        if let last = result.last, last.x < 1 - 1e-6 {
            result.append(CurvePoint(1, 1))
        } else {
            let lastIndex = result.count - 1
            result[lastIndex] = CurvePoint(1, result[lastIndex].y)
        }
        return result
    }

    /// Fritsch–Carlson 单调切线。
    static func tangents(_ p: [CurvePoint]) -> [Double] {
        let n = p.count
        guard n >= 2 else { return [] }
        var d = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx = p[i + 1].x - p[i].x
            d[i] = dx > 1e-12 ? (p[i + 1].y - p[i].y) / dx : 0
        }
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) {
            if d[i - 1] * d[i] <= 0 {
                m[i] = 0
            } else {
                m[i] = (d[i - 1] + d[i]) / 2
            }
        }
        for i in 0..<(n - 1) {
            if abs(d[i]) < 1e-12 {
                m[i] = 0
                m[i + 1] = 0
                continue
            }
            let a = m[i] / d[i]
            let b = m[i + 1] / d[i]
            let s = a * a + b * b
            if s > 9 {
                let tau = 3 / s.squareRoot()
                m[i] = tau * a * d[i]
                m[i + 1] = tau * b * d[i]
            }
        }
        return m
    }
}

// MARK: - 四通道曲线集合

/// 4 条独立曲线（RGB 主 + R / G / B）。
public struct ToneCurveSet: Equatable, Codable, Sendable {
    public var rgb: ToneCurve
    public var red: ToneCurve
    public var green: ToneCurve
    public var blue: ToneCurve

    public init(
        rgb: ToneCurve = ToneCurve(),
        red: ToneCurve = ToneCurve(),
        green: ToneCurve = ToneCurve(),
        blue: ToneCurve = ToneCurve()
    ) {
        self.rgb = rgb
        self.red = red
        self.green = green
        self.blue = blue
    }

    public subscript(channel: CurveChannel) -> ToneCurve {
        get {
            switch channel {
            case .rgb: return rgb
            case .red: return red
            case .green: return green
            case .blue: return blue
            }
        }
        set {
            switch channel {
            case .rgb: rgb = newValue
            case .red: red = newValue
            case .green: green = newValue
            case .blue: blue = newValue
            }
        }
    }

    public var isIdentity: Bool {
        rgb.isIdentity && red.isIdentity && green.isIdentity && blue.isIdentity
    }

    public func isIdentity(for channel: CurveChannel) -> Bool {
        self[channel].isIdentity
    }

    /// 合成后的通道采样表：分通道曲线 ∘ RGB 主曲线。
    public func table(for channel: CurveChannel, count: Int) -> [Double] {
        let master = rgb.table(count: count)
        guard channel != .rgb else { return master }
        let sub = self[channel]
        guard !sub.isIdentity else { return master }
        let subTable = sub.table(count: count)
        let last = Double(count - 1)
        return master.map { v in
            let pos = min(max(v, 0), 1) * last
            let i0 = min(max(Int(pos.rounded(.down)), 0), count - 1)
            let i1 = min(i0 + 1, count - 1)
            let f = pos - Double(i0)
            return subTable[i0] * (1 - f) + subTable[i1] * f
        }
    }

    public func blended(towardsIdentity amount: Double) -> ToneCurveSet {
        ToneCurveSet(
            rgb: rgb.blended(towardsIdentity: amount),
            red: red.blended(towardsIdentity: amount),
            green: green.blended(towardsIdentity: amount),
            blue: blue.blended(towardsIdentity: amount)
        )
    }
}

// MARK: - HSL 分通道

/// HSL 8 通道（色轮等分，中心色相为经典分色标准）。
public enum HSLChannel: String, Equatable, Sendable, CaseIterable, Codable {
    case red, orange, yellow, green, aqua, blue, purple, magenta

    public var displayName: String {
        switch self {
        case .red: return "红"
        case .orange: return "橙"
        case .yellow: return "黄"
        case .green: return "绿"
        case .aqua: return "青"
        case .blue: return "蓝"
        case .purple: return "紫"
        case .magenta: return "洋红"
        }
    }

    /// 通道中心色相（度，0...360）。
    public var hueCenterDegrees: Double {
        switch self {
        case .red: return 0
        case .orange: return 30
        case .yellow: return 60
        case .green: return 120
        case .aqua: return 180
        case .blue: return 240
        case .purple: return 280
        case .magenta: return 320
        }
    }

    /// 通道中心色相（归一化 0...1）。
    public var hueCenter: Double { hueCenterDegrees / 360 }

    /// 通道代表色（sRGB 0...1，UI 色块用）。
    public var swatch: (red: Double, green: Double, blue: Double) {
        switch self {
        case .red: return (0.92, 0.20, 0.20)
        case .orange: return (0.95, 0.55, 0.13)
        case .yellow: return (0.92, 0.82, 0.16)
        case .green: return (0.26, 0.72, 0.28)
        case .aqua: return (0.16, 0.72, 0.76)
        case .blue: return (0.20, 0.42, 0.90)
        case .purple: return (0.55, 0.30, 0.86)
        case .magenta: return (0.85, 0.26, 0.68)
        }
    }

    /// 24 参数表中的通道槽位（0...7）。
    public var slot: Int {
        switch self {
        case .red: return 0
        case .orange: return 1
        case .yellow: return 2
        case .green: return 3
        case .aqua: return 4
        case .blue: return 5
        case .purple: return 6
        case .magenta: return 7
        }
    }
}

/// HSL 每通道三分量。
public enum HSLComponent: String, Equatable, Sendable, CaseIterable, Codable {
    case hue, saturation, luminance

    public var displayName: String {
        switch self {
        case .hue: return "色相"
        case .saturation: return "饱和度"
        case .luminance: return "明度"
        }
    }

    /// 0 / 1 / 2，用于 24 参数表索引。
    public var slot: Int {
        switch self {
        case .hue: return 0
        case .saturation: return 1
        case .luminance: return 2
        }
    }
}

/// 24 个 HSL 参数的折叠容器（8 通道 × 3 分量，值域 -100...100，全 0 = 恒等）。
public struct HSLAdjustment: Equatable, Sendable {
    public static let count = HSLChannel.allCases.count * HSLComponent.allCases.count
    /// 每个单位对应的色相角（度）：±100 → ±180°。
    public static let hueDegreesPerUnit = 1.8

    private var values: [Double]

    public init() {
        values = [Double](repeating: 0, count: HSLAdjustment.count)
    }

    private func index(_ channel: HSLChannel, _ component: HSLComponent) -> Int {
        channel.slot * HSLComponent.allCases.count + component.slot
    }

    public subscript(channel: HSLChannel, component: HSLComponent) -> Double {
        get { values[index(channel, component)] }
        set { values[index(channel, component)] = min(max(newValue, -100), 100) }
    }

    public var isIdentity: Bool {
        values.allSatisfy { abs($0) < 1e-9 }
    }

    /// 该通道是否被调整过。
    public func isAdjusted(_ channel: HSLChannel) -> Bool {
        HSLComponent.allCases.contains { abs(self[channel, $0]) > 1e-9 }
    }

    /// 吸收一个指令；返回 false 表示该指令不属于 HSL 折叠。
    public mutating func absorb(_ operation: EditOperation) -> Bool {
        guard case .hsl(let channel, let component, let value) = operation else { return false }
        self[channel, component] = value
        return true
    }

    /// 色相偏移（度）。
    public func hueShiftDegrees(_ channel: HSLChannel) -> Double {
        self[channel, .hue] * HSLAdjustment.hueDegreesPerUnit
    }
}

// MARK: - 参数标识映射（HSL 24 参数）

extension EditParameter {
    /// HSL 参数 →（通道，分量）；非 HSL 参数返回 nil。
    public var hslBinding: (channel: HSLChannel, component: HSLComponent)? {
        switch self {
        case .hslRedHue: return (.red, .hue)
        case .hslRedSaturation: return (.red, .saturation)
        case .hslRedLuminance: return (.red, .luminance)
        case .hslOrangeHue: return (.orange, .hue)
        case .hslOrangeSaturation: return (.orange, .saturation)
        case .hslOrangeLuminance: return (.orange, .luminance)
        case .hslYellowHue: return (.yellow, .hue)
        case .hslYellowSaturation: return (.yellow, .saturation)
        case .hslYellowLuminance: return (.yellow, .luminance)
        case .hslGreenHue: return (.green, .hue)
        case .hslGreenSaturation: return (.green, .saturation)
        case .hslGreenLuminance: return (.green, .luminance)
        case .hslAquaHue: return (.aqua, .hue)
        case .hslAquaSaturation: return (.aqua, .saturation)
        case .hslAquaLuminance: return (.aqua, .luminance)
        case .hslBlueHue: return (.blue, .hue)
        case .hslBlueSaturation: return (.blue, .saturation)
        case .hslBlueLuminance: return (.blue, .luminance)
        case .hslPurpleHue: return (.purple, .hue)
        case .hslPurpleSaturation: return (.purple, .saturation)
        case .hslPurpleLuminance: return (.purple, .luminance)
        case .hslMagentaHue: return (.magenta, .hue)
        case .hslMagentaSaturation: return (.magenta, .saturation)
        case .hslMagentaLuminance: return (.magenta, .luminance)
        default: return nil
        }
    }

    /// 由（通道，分量）反查参数标识（单一真源：从 allCases 派生）。
    public static func hsl(_ channel: HSLChannel, _ component: HSLComponent) -> EditParameter {
        allCases.first { $0.hslBinding?.channel == channel && $0.hslBinding?.component == component }
            ?? .saturation
    }

    /// 当前取值是否代表"已偏移"（用于 HSL 面板高亮）。
    /// 语义与渲染管线一致：对图中全部指令做 HSL 折叠（后写覆盖）。
    public static func isAdjusted(_ channel: HSLChannel, in graph: EditGraph) -> Bool {
        var hsl = HSLAdjustment()
        for operation in graph.operations {
            _ = hsl.absorb(operation)
        }
        return hsl.isAdjusted(channel)
    }
}
