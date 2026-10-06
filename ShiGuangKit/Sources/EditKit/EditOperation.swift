import Foundation

// MARK: - 编辑参数标识

/// 每个可调整参数的稳定标识（用于同参数合并、UI 绑定定位）。
public enum EditParameter: String, Equatable, Sendable, CaseIterable, Codable {
    case exposure, contrast, highlights, shadows, whitePoint, blackPoint
    case temperature, tint, saturation, vibrance
    case clarity, dehaze, sharpen, noiseReduction, vignette
    case crop, straighten
    case skinSmoothing, skinBrightening   // 人像精修
    case lut                              // LUT 引用（结构化）
    case toneCurve                        // 色调曲线（结构化：RGB 主曲线 + R/G/B 分通道）
    // HSL 分通道（8 通道 × 3 分量 = 24 个参数）
    case hslRedHue, hslRedSaturation, hslRedLuminance
    case hslOrangeHue, hslOrangeSaturation, hslOrangeLuminance
    case hslYellowHue, hslYellowSaturation, hslYellowLuminance
    case hslGreenHue, hslGreenSaturation, hslGreenLuminance
    case hslAquaHue, hslAquaSaturation, hslAquaLuminance
    case hslBlueHue, hslBlueSaturation, hslBlueLuminance
    case hslPurpleHue, hslPurpleSaturation, hslPurpleLuminance
    case hslMagentaHue, hslMagentaSaturation, hslMagentaLuminance

    /// 该参数滑杆的默认取值范围（UI 绑定与测试共用）。
    public var defaultRange: ClosedRange<Double> {
        switch self {
        case .exposure: return -5...5
        case .sharpen, .noiseReduction: return 0...100
        case .skinSmoothing, .skinBrightening: return 0...100
        case .straighten: return -45...45
        default: return -100...100
        }
    }

    /// 是否可被 AI 自动调参引擎建议数值。
    public var isAutoTunable: Bool {
        AutoTune.tunableParameters.contains(self)
    }

    /// 是否进入手势调色序列（上下滑切换）。
    public var isGestureAdjustable: Bool {
        switch self {
        case .crop, .straighten, .lut, .toneCurve: return false
        default:
            // HSL 24 参数由专属面板承载（自带通道手势），不进入全局手势序列
            return hslBinding == nil
        }
    }

    /// 参数分组（像素蛋糕式分类标准）。
    public var group: ParameterGroup {
        switch self {
        case .exposure, .contrast, .highlights, .shadows, .whitePoint, .blackPoint:
            return .light
        case .temperature, .tint, .saturation, .vibrance:
            return .color
        case .clarity, .dehaze, .sharpen, .noiseReduction, .vignette:
            return .texture
        case .skinSmoothing, .skinBrightening:
            return .portrait
        case .crop, .straighten:
            return .geometry
        case .lut:
            return .style
        case .toneCurve:
            return .curve
        default:
            // 其余新增参数均为 HSL 分通道
            return hslBinding == nil ? .color : .hsl
        }
    }
}

/// 参数分组（功能分类标准）。
public enum ParameterGroup: String, Equatable, Sendable, CaseIterable, Codable {
    case light      // 光线
    case color      // 色彩
    case texture    // 质感
    case portrait   // 人像
    case geometry   // 构图
    case style      // 风格
    case curve      // 曲线
    case hsl        // 色彩分级（HSL 分通道）

    public var displayName: String {
        switch self {
        case .light: return "光线"
        case .color: return "色彩"
        case .texture: return "质感"
        case .portrait: return "人像"
        case .geometry: return "构图"
        case .style: return "风格"
        case .curve: return "曲线"
        case .hsl: return "色彩分级"
        }
    }

    public var symbol: String {
        switch self {
        case .light: return "sun.max"
        case .color: return "paintpalette"
        case .texture: return "sparkles"
        case .portrait: return "person.crop.circle"
        case .geometry: return "crop.rotate"
        case .style: return "camera.filters"
        case .curve: return "chart.xyaxis.line"
        case .hsl: return "paintpalette.fill"
        }
    }
}

// MARK: - LUT 引用

/// 已导入 LUT 的引用（LUT 数据本体存于 LUTStore，指令只存引用——非破坏且轻量）。
public struct LUTReference: Identifiable, Equatable, Codable, Hashable, Sendable {
    public let id: UUID
    public let name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

// MARK: - 裁剪矩形

/// 归一化裁剪区域（0...1，相对原图，左上原点）。
public struct CropRect: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

// MARK: - 编辑指令

/// 非破坏编辑指令（ADR-003）：
/// 编辑状态 = `[EditOperation]` 有序数组；渲染 = 折叠为滤镜链。
/// - 数值调整参与预设强度混合与 AI 自动调参；
/// - 结构化指令（crop / lut）不参与混合，原样保留。
public enum EditOperation: Equatable, Codable, Sendable {
    // MARK: 光线
    case exposure(Double)        // -5.0 ... 5.0（EV）
    case contrast(Double)        // -100 ... 100
    case highlights(Double)      // -100 ... 100
    case shadows(Double)         // -100 ... 100
    case whitePoint(Double)      // -100 ... 100
    case blackPoint(Double)      // -100 ... 100
    // MARK: 色彩
    case temperature(Double)     // -100 ... 100
    case tint(Double)            // -100 ... 100
    case saturation(Double)      // -100 ... 100
    case vibrance(Double)        // -100 ... 100
    // MARK: 质感
    case clarity(Double)         // -100 ... 100
    case dehaze(Double)          // -100 ... 100
    case sharpen(Double)         // 0 ... 100
    case noiseReduction(Double)  // 0 ... 100
    case vignette(Double)        // -100 ... 100
    // MARK: 构图（结构化）
    case crop(CropRect)
    case straighten(Double)      // -45.0 ... 45.0（度）
    // MARK: 人像精修（掩码内处理）
    case skinSmoothing(Double)   // 0 ... 100
    case skinBrightening(Double) // 0 ... 100
    // MARK: 风格（结构化）
    case lut(LUTReference)
    // MARK: 曲线（结构化：RGB 主曲线 + R/G/B 分通道曲线）
    case toneCurve(ToneCurveSet)
    // MARK: HSL 分通道（-100 ... 100；色相 ±100 对应 ±180°）
    case hsl(HSLChannel, HSLComponent, Double)

    /// 该指令对应的参数标识。
    public var parameter: EditParameter {
        switch self {
        case .exposure: .exposure
        case .contrast: .contrast
        case .highlights: .highlights
        case .shadows: .shadows
        case .whitePoint: .whitePoint
        case .blackPoint: .blackPoint
        case .temperature: .temperature
        case .tint: .tint
        case .saturation: .saturation
        case .vibrance: .vibrance
        case .clarity: .clarity
        case .dehaze: .dehaze
        case .sharpen: .sharpen
        case .noiseReduction: .noiseReduction
        case .vignette: .vignette
        case .crop: .crop
        case .straighten: .straighten
        case .skinSmoothing: .skinSmoothing
        case .skinBrightening: .skinBrightening
        case .lut: .lut
        case .toneCurve: .toneCurve
        case .hsl(let channel, let component, _): EditParameter.hsl(channel, component)
        }
    }

    /// 数值负载（结构化指令为 nil）。
    public var numericValue: Double? {
        switch self {
        case .exposure(let v), .contrast(let v), .highlights(let v), .shadows(let v),
             .whitePoint(let v), .blackPoint(let v), .temperature(let v), .tint(let v),
             .saturation(let v), .vibrance(let v), .clarity(let v), .dehaze(let v),
             .sharpen(let v), .noiseReduction(let v), .vignette(let v), .straighten(let v),
             .skinSmoothing(let v), .skinBrightening(let v):
            return v
        case .hsl(_, _, let v):
            return v
        case .crop, .lut, .toneCurve:
            return nil
        }
    }

    /// 替换数值（结构化指令原样返回）。
    public func withValue(_ newValue: Double) -> EditOperation {
        switch self {
        case .exposure: return .exposure(newValue)
        case .contrast: return .contrast(newValue)
        case .highlights: return .highlights(newValue)
        case .shadows: return .shadows(newValue)
        case .whitePoint: return .whitePoint(newValue)
        case .blackPoint: return .blackPoint(newValue)
        case .temperature: return .temperature(newValue)
        case .tint: return .tint(newValue)
        case .saturation: return .saturation(newValue)
        case .vibrance: return .vibrance(newValue)
        case .clarity: return .clarity(newValue)
        case .dehaze: return .dehaze(newValue)
        case .sharpen: return .sharpen(newValue)
        case .noiseReduction: return .noiseReduction(newValue)
        case .vignette: return .vignette(newValue)
        case .skinSmoothing: return .skinSmoothing(newValue)
        case .skinBrightening: return .skinBrightening(newValue)
        case .crop(let rect): return .crop(rect)
        case .lut(let ref): return .lut(ref)
        case .toneCurve(let set): return .toneCurve(set)
        case .hsl(let channel, let component, _): return .hsl(channel, component, newValue)
        case .straighten: return .straighten(newValue)
        }
    }

    /// 该参数的合法范围。
    public var validRange: ClosedRange<Double> {
        switch self {
        case .exposure: return -5...5
        case .sharpen, .noiseReduction: return 0...100
        case .skinSmoothing, .skinBrightening: return 0...100
        case .straighten: return -45...45
        default: return -100...100
        }
    }

    /// 是否可按预设强度线性混合（结构化指令返回 false）。
    public var isBlendable: Bool {
        switch self {
        case .crop, .straighten, .lut: return false
        default: return true
        }
    }

    /// 裁剪到合法范围。
    public var clamped: EditOperation {
        guard let value = numericValue else { return self }
        return withValue(min(max(value, validRange.lowerBound), validRange.upperBound))
    }

    /// 按强度 t ∈ 0...1 与原点（零调整）线性插值 — 预设强度滑杆的实现基础。
    public func blended(amount: Double) -> EditOperation {
        // 曲线虽为结构化指令但可混合：控制点 y 向对角线（恒等）收敛，x 不变 → 单调性保持。
        if case .toneCurve(let set) = self {
            return .toneCurve(set.blended(towardsIdentity: amount))
        }
        guard isBlendable, let value = numericValue else { return self }
        let t = min(max(amount, 0), 1)
        return withValue(value * t)
    }

    /// UI 显示名（P1.7 接 String Catalog 做本地化）。
    public var displayName: String { parameter.rawValue }

    /// 参数 → 指令工厂（滑杆绑定用；结构化参数返回占位，UI 不应对其使用）。
    public static func make(parameter: EditParameter, value: Double) -> EditOperation {
        switch parameter {
        case .exposure: return .exposure(value)
        case .contrast: return .contrast(value)
        case .highlights: return .highlights(value)
        case .shadows: return .shadows(value)
        case .whitePoint: return .whitePoint(value)
        case .blackPoint: return .blackPoint(value)
        case .temperature: return .temperature(value)
        case .tint: return .tint(value)
        case .saturation: return .saturation(value)
        case .vibrance: return .vibrance(value)
        case .clarity: return .clarity(value)
        case .dehaze: return .dehaze(value)
        case .sharpen: return .sharpen(value)
        case .noiseReduction: return .noiseReduction(value)
        case .vignette: return .vignette(value)
        case .skinSmoothing: return .skinSmoothing(value)
        case .skinBrightening: return .skinBrightening(value)
        case .crop: return .crop(CropRect(x: 0, y: 0, width: 1, height: 1))
        case .straighten: return .straighten(value)
        case .lut: return .lut(LUTReference(name: ""))
        case .toneCurve: return .toneCurve(ToneCurveSet())
        default:
            // HSL 24 参数：由单一真源 hslBinding 反查，避免 24 路重复分支
            if let binding = parameter.hslBinding {
                return .hsl(binding.channel, binding.component, value)
            }
            return .exposure(value)
        }
    }
}
