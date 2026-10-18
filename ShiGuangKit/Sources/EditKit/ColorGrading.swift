import Foundation

// MARK: - 色彩分级（Color Grading）

/// 单个色轮（阴影 / 中间调 / 高光各一个）。
///
/// 语义（Lightroom / 像素蛋糕式三色轮）：
/// - `hue`：色轮上的**绝对色相**（度，0...360；0 = 红，120 = 绿，240 = 蓝）
/// - `saturation`：染色强度（0...100；0 = 不染色）
///
/// 纯值类型：`Equatable / Codable / Sendable`，零平台依赖（Linux 可测）。
public struct ColorWheel: Equatable, Codable, Sendable {
    /// 绝对色相（度）。
    public var hue: Double
    /// 染色强度（0...100）。
    public var saturation: Double

    /// R009-Fix-6：色相范围改为**整圆 0...360**。
    ///
    /// 原为 -180...180（语义写成「色相偏移」），但 `tintVector` 实现的是**绝对色相**
    /// 的 HSV 整圆 —— 两者语义冲突，后果是**静默截断**：
    /// - 渲染测试与 App 预设按 0-360 语义书写（`hue: 240` 蓝 / `210` / `230`），
    ///   被截到 180 后变成**青色 (0, s, s)** —— 绿通道被污染，三色轮的「分域独立」
    ///   语义随之失效；
    /// - 这正是 CI 上 `ColorGradingRenderTests` 3 个失败用例的根因（**非 kernel 问题**，
    ///   kernel 与色彩空间转换经逐档扫描验证完全正确）。
    /// 改整圆后 `240 → 蓝`、`210/230 → 蓝青`，与全部调用方语义一致。
    public static let hueRange: ClosedRange<Double> = 0...360
    public static let saturationRange: ClosedRange<Double> = 0...100

    public init(hue: Double = 0, saturation: Double = 0) {
        self.hue = min(max(hue, Self.hueRange.lowerBound), Self.hueRange.upperBound)
        self.saturation = min(max(saturation, Self.saturationRange.lowerBound), Self.saturationRange.upperBound)
    }

    /// 恒等色轮（无偏移）。
    public static let identity = ColorWheel()

    public var isIdentity: Bool { self == .identity }

    /// 向恒等收敛（Recipe 强度混合用）：`t` = 0 完全恒等，1 完全保留。
    public func blended(towardsIdentity t: Double) -> ColorWheel {
        let k = min(max(t, 0), 1)
        return ColorWheel(hue: hue * k, saturation: saturation * k)
    }

    /// 色轮指向的染色偏移向量：**色相方向（S=1 的 HSV 方向）× 饱和度幅度**。
    /// 语义：saturation=0 → 零偏移（不染色）；saturation=100 → 满幅单向偏移
    /// （方向不随饱和度改变 —— 半饱和是同方向减半，不是「变白」）。
    public var tintVector: (red: Double, green: Double, blue: Double) {
        let s = saturation / 100
        guard s > 0 else { return (0, 0, 0) }
        // 归一化到整圆 [0,1)：负色相折算（如 -120° ≡ 240° 蓝）。
        // 不归一化时 `Int(h * 6)` 对负 h 得负数 → `i % 6` 为负 → 落到 default 分支，
        // 且 `q = 1 - f` 会算出 2.0 这类**越界分量**（R009-Fix-6 修复）。
        var h = hue.truncatingRemainder(dividingBy: 360) / 360
        if h < 0 { h += 1 }
        // HSV → RGB（固定 V=1, S=1：得到单位色相方向），再乘饱和度幅度
        let i = Int(h * 6)
        let f = h * 6 - Double(i)
        let v = 1.0
        let p = 0.0
        let q = v * (1 - f)
        let t = v * (1 - (1 - f))
        switch i % 6 {
        case 0: return (v * s, t * s, p * s)
        case 1: return (q * s, v * s, p * s)
        case 2: return (p * s, v * s, t * s)
        case 3: return (p * s, q * s, v * s)
        case 4: return (t * s, p * s, v * s)
        default: return (v * s, p * s, q * s)
        }
    }
}

/// 三域色彩分级：阴影 / 中间调 / 高光各自一个色轮 + 全局混合与平衡。
///
/// 与 8 通道 HSL 的分工：HSL 改的是**色相环上既有颜色的分量**；
/// 色彩分级做的是**按亮度分域的整体染色偏移**（LR / 像素蛋糕的核心功能）。
///
/// - `blending`：全局混合强度（0...100；0 = 整条指令恒等）
/// - `balance`：阴影轮与高光轮的权重再分配（-100...100；
///   正值把影响压向阴影侧，负值压向高光侧，中间调不受影响）
public struct ColorGrading: Equatable, Codable, Sendable {
    public var shadows: ColorWheel
    public var midtones: ColorWheel
    public var highlights: ColorWheel
    /// 全局混合强度（0...100）。
    public var blending: Double
    /// 阴影/高光权重平衡（-100...100）。
    public var balance: Double

    public static let blendingRange: ClosedRange<Double> = 0...100
    public static let balanceRange: ClosedRange<Double> = -100...100

    public init(
        shadows: ColorWheel = .identity,
        midtones: ColorWheel = .identity,
        highlights: ColorWheel = .identity,
        blending: Double = 100,
        balance: Double = 0
    ) {
        self.shadows = shadows
        self.midtones = midtones
        self.highlights = highlights
        self.blending = min(max(blending, Self.blendingRange.lowerBound), Self.blendingRange.upperBound)
        self.balance = min(max(balance, Self.balanceRange.lowerBound), Self.balanceRange.upperBound)
    }

    public static let identity = ColorGrading()

    public var isIdentity: Bool { self == .identity }

    /// 向恒等收敛（Recipe 强度混合用）：色轮值与 balance 线性收敛；
    /// `blending` 向恒等态的 100 收敛（t=0 时必须整体等于 `.identity`）。
    public func blended(towardsIdentity t: Double) -> ColorGrading {
        let k = min(max(t, 0), 1)
        return ColorGrading(
            shadows: shadows.blended(towardsIdentity: k),
            midtones: midtones.blended(towardsIdentity: k),
            highlights: highlights.blended(towardsIdentity: k),
            blending: 100 + (blending - 100) * k,
            balance: balance * k
        )
    }

    // MARK: - 渲染侧参数契约（RenderKit 消费，保持纯计算无平台依赖）

    /// 三个域的亮度窗中心与半宽（三角窗，保证纯黑/纯白端点权重为 0 —— 无端点污染）。
    public enum LuminanceWindow {
        public static let shadowsCenter: Double = 0.25
        public static let midtonesCenter: Double = 0.50
        public static let highlightsCenter: Double = 0.75
        public static let halfWidth: Double = 0.25

        /// 三角窗权重：中心处 1，窗边缘 0，窗外 0。
        public static func weight(luminance: Double, center: Double) -> Double {
            let d = abs(luminance - center) / halfWidth
            return d >= 1 ? 0 : 1 - d
        }
    }

    /// balance 对阴影轮的权重缩放（-100...100 → 0.5...1.5，即阴影轮 0.75x~1.25x）。
    public var shadowBalanceScale: Double { 1 - balance / 200 }
    /// balance 对高光轮的权重缩放（与阴影互补）。
    public var highlightBalanceScale: Double { 1 + balance / 200 }

    /// 全局混合系数（0...1）。
    public var blendFactor: Double { blending / 100 }
}
