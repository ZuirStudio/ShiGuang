import Foundation

// MARK: - 编辑参数标识

/// 每个可调整参数的稳定标识（用于同参数合并、UI 绑定定位）。
public enum EditParameter: String, Equatable, Sendable, CaseIterable, Codable {
    case exposure, contrast, highlights, shadows, whitePoint, blackPoint
    case temperature, tint, saturation, vibrance
    case clarity, dehaze, sharpen, noiseReduction, vignette
    case crop, straighten

    /// 该参数滑杆的默认取值范围（UI 绑定与测试共用）。
    public var defaultRange: ClosedRange<Double> {
        switch self {
        case .exposure: return -5...5
        case .sharpen, .noiseReduction: return 0...100
        case .straighten: return -45...45
        default: return -100...100
        }
    }
}

// MARK: - 裁剪矩形

/// 归一化裁剪区域（0...1，相对原图）。
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
/// - 数值调整参与预设强度混合；
/// - 结构化指令（crop / straighten）不参与混合，原样保留。
public enum EditOperation: Equatable, Codable, Sendable {
    // MARK: 光学与影调
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
    // MARK: 几何（结构化）
    case crop(CropRect)
    case straighten(Double)      // -45.0 ... 45.0（度）

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
        }
    }

    /// 数值负载（crop 为 nil）。
    public var numericValue: Double? {
        switch self {
        case .exposure(let v), .contrast(let v), .highlights(let v), .shadows(let v),
             .whitePoint(let v), .blackPoint(let v), .temperature(let v), .tint(let v),
             .saturation(let v), .vibrance(let v), .clarity(let v), .dehaze(let v),
             .sharpen(let v), .noiseReduction(let v), .vignette(let v), .straighten(let v):
            return v
        case .crop:
            return nil
        }
    }

    /// 替换数值（crop 原样返回）。
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
        case .crop(let rect): return .crop(rect)
        case .straighten: return .straighten(newValue)
        }
    }

    /// 该参数的合法范围。
    public var validRange: ClosedRange<Double> {
        switch self {
        case .exposure: return -5...5
        case .sharpen, .noiseReduction: return 0...100
        case .straighten: return -45...45
        default: return -100...100
        }
    }

    /// 是否可按预设强度线性混合（结构化指令返回 false）。
    public var isBlendable: Bool {
        switch self {
        case .crop, .straighten: return false
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
        guard isBlendable, let value = numericValue else { return self }
        let t = min(max(amount, 0), 1)
        return withValue(value * t)
    }

    /// UI 显示名（P1.3 接 String Catalog 做本地化）。
    public var displayName: String { parameter.rawValue }

    /// 参数 → 指令工厂（滑杆绑定用；crop 不适用，返回全幅占位）。
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
        case .crop: return .crop(CropRect(x: 0, y: 0, width: 1, height: 1))
        case .straighten: return .straighten(value)
        }
    }
}
