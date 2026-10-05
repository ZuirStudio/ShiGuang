import CoreImage
import EditKit

// MARK: - 折叠色调参数

/// 10 个滑杆型调整折叠为一次 kernel 调用（Lightroom 式"基本面板"合并渲染）。
/// 滑杆语义为绝对值：同参数多次出现取最后值（每参数在管线内有固定处理阶段，
/// 用户操作顺序不影响结果 — 与 Lightroom Basic 面板一致）。
public struct ToneParams: Equatable, Sendable {
    public var exposureEV: Double = 0     // EV，-5...5
    public var contrast: Double = 0      // 归一化 -1...1
    public var highlights: Double = 0    // 归一化 -1...1
    public var shadows: Double = 0
    public var whitePoint: Double = 0
    public var blackPoint: Double = 0
    public var temperature: Double = 0
    public var tint: Double = 0
    public var saturation: Double = 0
    public var vibrance: Double = 0

    public init() {}

    public var isIdentity: Bool { self == ToneParams() }

    /// 吸收一个指令；返回 false 表示该指令不属于色调折叠（由专门 filter 处理）。
    mutating func absorb(_ operation: EditOperation) -> Bool {
        switch operation {
        case .exposure(let v): exposureEV = v
        case .contrast(let v): contrast = v / 100
        case .highlights(let v): highlights = v / 100
        case .shadows(let v): shadows = v / 100
        case .whitePoint(let v): whitePoint = v / 100
        case .blackPoint(let v): blackPoint = v / 100
        case .temperature(let v): temperature = v / 100
        case .tint(let v): tint = v / 100
        case .saturation(let v): saturation = v / 100
        case .vibrance(let v): vibrance = v / 100
        default: return false
        }
        return true
    }
}

// MARK: - Kernel 源码（Core Image Kernel Language）

/// 单遍处理：曝光 → 白点/黑点 → 对比度 → 高光/阴影 → 色温/色调 → 自然饱和度 → 饱和度。
/// 注意：v0 在 premultiplied 像素上直接调色（照片 alpha=1 无影响）；
/// P1.6 接 P3 线性工作色空间与未预乘处理（TODO 见 ADR-004）。
enum ToneKernelSource {
    static let source = """
    kernel vec4 toneAdjust(sampler image,
                           float exposureEV,
                           float contrast,
                           float highlights,
                           float shadows,
                           float whitePoint,
                           float blackPoint,
                           float temperature,
                           float tint,
                           float saturation,
                           float vibrance)
    {
        vec4 c = sample(image, samplerCoord(image));
        vec3 rgb = c.rgb;

        // 1. 曝光：线性乘 2^ev
        rgb *= exp2(exposureEV);

        // 2. 白点（正=提亮，缩放） / 黑点（正=提黑，暗部加权）
        rgb *= (1.0 + whitePoint * 0.25);
        rgb += blackPoint * 0.15 * (1.0 - rgb);

        // 3. 对比度：绕 0.5 中枢
        rgb = (rgb - 0.5) * (1.0 + contrast) + 0.5;

        // 4. 高光 / 阴影：亮度加权
        float luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
        rgb += highlights * 0.35 * smoothstep(0.45, 0.9, luma);
        rgb += shadows   * 0.35 * (1.0 - smoothstep(0.1, 0.55, luma));

        // 5. 色温（暖=红升蓝降）/ 色调（绿-品）
        rgb.r *= (1.0 + temperature * 0.10);
        rgb.b *= (1.0 - temperature * 0.10);
        rgb.g *= (1.0 + tint * 0.10);

        // 6. 自然饱和度：chroma 越低 boost 越大
        luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
        float chroma = max(rgb.r, max(rgb.g, rgb.b)) - min(rgb.r, min(rgb.g, rgb.b));
        rgb = (rgb - luma) * (1.0 + vibrance * (1.0 - chroma)) + luma;

        // 7. 饱和度
        rgb = (rgb - luma) * (1.0 + saturation) + luma;

        return vec4(clamp(rgb, 0.0, 1.0), c.a);
    }
    """
}
