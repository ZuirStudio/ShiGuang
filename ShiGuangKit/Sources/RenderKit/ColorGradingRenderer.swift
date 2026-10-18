import CoreImage
import EditKit

// MARK: - 色彩分级渲染（三色轮 · 亮度三角窗）

/// 色轮偏移 kernel：按亮度三角窗分域染色。
///
/// 设计口径：
/// - **色彩数学全部在 EditKit**（`ColorWheel.tintVector`：色相+饱和度 → RGB
///   偏移量，纯逻辑可 Linux 单测）；本 kernel 只做「域权重 + 加法 + clamp」，
///   极简且行为完全可预测（无采样模糊，纯色输入精确输出）。
/// - **三角窗保证端点无污染**：三窗中心 0.25 / 0.50 / 0.75、半宽 0.25，
///   纯黑（luma=0）与纯白（luma=1）处三窗权重全部为 0 —— 黑场白场不被染色
///   （验收点：对纯黑/纯白像素无污染）。
/// - balance：阴影轮与高光轮的权重再分配（b ∈ -1...1 → 阴影 1.5x~0.5x、
///   高光互补），中间调轮不受影响。
/// - blending：全局混合（0 = 整条指令恒等）。
enum ColorGradingKernelSource {
    static let source = """
    kernel vec4 colorGrading(sampler image,
                             vec3 shadowTint,
                             vec3 midTint,
                             vec3 highTint,
                             float blending,
                             float balance)
    {
        vec4 c = sample(image, samplerCoord(image));
        vec3 rgb = c.rgb;
        float luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));

        // 三角窗：中心权重 1，窗边缘 0，窗外 0（纯黑/纯白端点三窗全 0）
        float wShadow = max(0.0, 1.0 - abs(luma - 0.25) / 0.25);
        float wMid    = max(0.0, 1.0 - abs(luma - 0.50) / 0.25);
        float wHigh   = max(0.0, 1.0 - abs(luma - 0.75) / 0.25);

        // balance：阴影/高光轮权重再分配（与 EditKit.ColorGrading.shadowBalanceScale 同式）
        float b = clamp(balance, -1.0, 1.0);
        wShadow *= (1.0 - b * 0.5);
        wHigh   *= (1.0 + b * 0.5);

        vec3 offset = shadowTint * wShadow + midTint * wMid + highTint * wHigh;
        rgb += offset * clamp(blending, 0.0, 1.0);

        return vec4(clamp(rgb, 0.0, 1.0), c.a);
    }
    """
}

/// 色彩分级渲染入口：EditKit 纯逻辑参数 → kernel 参数 → CIImage。
///
/// 固定阶段纪律（同 toneCurve）：色彩分级是**最后调色阶段**，与指令到达顺序无关；
/// 管线在 tone / curve / HSL 折叠落完之后调用（见 `BasicAdjustmentRenderer.apply`）。
enum ColorGradingRenderer {
    private static let kernel: CIKernel? = CIKernel(source: ColorGradingKernelSource.source)

    /// 应用色彩分级；`isIdentity` 或 kernel 缺失时返回 nil（调用方保持原图）。
    static func apply(_ grading: ColorGrading, on image: CIImage) -> CIImage? {
        guard !grading.isIdentity, let kernel else { return nil }
        let roi: CIKernelROICallback = { _, rect in rect } // 逐像素 1:1 映射
        let arguments: [Any] = [
            image,
            CIVector(x: grading.shadows.tintVector.red,
                     y: grading.shadows.tintVector.green,
                     z: grading.shadows.tintVector.blue),
            CIVector(x: grading.midtones.tintVector.red,
                     y: grading.midtones.tintVector.green,
                     z: grading.midtones.tintVector.blue),
            CIVector(x: grading.highlights.tintVector.red,
                     y: grading.highlights.tintVector.green,
                     z: grading.highlights.tintVector.blue),
            grading.blendFactor,
            grading.balance / 100
        ]
        return kernel.apply(extent: image.extent, roiCallback: roi, arguments: arguments)
    }
}
