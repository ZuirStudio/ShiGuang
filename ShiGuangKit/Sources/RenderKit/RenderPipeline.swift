import CoreImage
import EditKit

// MARK: - 渲染协议

/// 渲染器抽象：EditGraph（纯逻辑）→ 平台图像（CIImage）。
/// RenderKit 是唯一知道图像怎么画的地方；EditKit 保持零平台依赖。
public protocol ImageRendering: Sendable {
    func render(source: CIImage, graph: EditGraph) -> CIImage
}

// MARK: - v0.2 渲染器（P1.5）

/// 调整映射（ADR-004：Core Image + 自定义 kernel）：
/// - 色调折叠（10 参数）→ 自定义 `toneAdjust` kernel，单遍完成
/// - sharpen → CISharpenLuminosity
/// - clarity(+) → CIUnsharpMask（近似局部对比；负值 P2 实现软化）
/// - vignette → CIVignette（正值压暗边缘）
/// - straighten → CIStraightenFilter（自动裁掉旋转空角）
/// - crop → CICrop（CropRect 为左上原点归一化坐标，转换到 CI 底部原点）
/// - dehaze / noiseReduction → P2 Metal kernel，暂为恒等
public struct BasicAdjustmentRenderer: ImageRendering {
    private static let kernel: CIKernel? = try? CIKernel(source: ToneKernelSource.source)

    public init() {}

    public func render(source: CIImage, graph: EditGraph) -> CIImage {
        var image = source
        var tone = ToneParams()

        // 折叠完所有连续色调参数后再落专门 filter，避免丢失指令顺序语义
        func flushTone() {
            guard !tone.isIdentity, let kernel = Self.kernel else { return }
            // 逐像素 kernel：源 ROI = 输出矩形（1:1 映射）
            let roi: CIKernelROICallback = { _, rect in rect }
            let arguments: [Any] = [
                image,
                tone.exposureEV, tone.contrast, tone.highlights, tone.shadows,
                tone.whitePoint, tone.blackPoint, tone.temperature, tone.tint,
                tone.saturation, tone.vibrance,
            ]
            if let output = kernel.apply(extent: image.extent, roiCallback: roi, arguments: arguments) {
                image = output
            }
            tone = ToneParams()
        }

        for operation in graph.operations {
            if tone.absorb(operation) { continue }
            flushTone()

            switch operation {
            case .sharpen(let v):
                // 注意：CISharpenLuminosity 在软件渲染器（无 GPU 的 CI 环境）返回 nil
                // （CI 实测捕获）；USM 小半径即为经典锐化，且软件渲染可用
                image = image.applyingFilter(
                    "CIUnsharpMask",
                    parameters: ["inputRadius": 2.0, "inputIntensity": v / 100 * 0.8]
                )
            case .clarity(let v) where v > 0:
                // 近似：大半径 USM 提升局部对比
                image = image.applyingFilter(
                    "CIUnsharpMask",
                    parameters: ["inputRadius": 10.0, "inputIntensity": v / 100 * 0.6]
                )
            case .vignette(let v) where v > 0:
                image = image.applyingFilter(
                    "CIVignette",
                    parameters: ["inputIntensity": v / 100 * 0.8, "inputRadius": 1.8]
                )
            case .straighten(let degrees):
                image = image.applyingFilter(
                    "CIStraightenFilter",
                    parameters: ["inputAngle": degrees * .pi / 180]
                )
            case .crop(let rect):
                image = image.applyingFilter(
                    "CICrop",
                    parameters: ["inputRectangle": CIVector(cgRect: cropCGRect(rect, in: image.extent))]
                )
            case .dehaze, .noiseReduction:
                break // TODO(P2): Metal NLM 去噪 / 去雾 kernel
            default:
                break // 负值 clarity/vignette 等暂为恒等（见 TODO 注释）
            }
        }
        flushTone()
        return image
    }

    /// 归一化左上原点（UIKit 惯例）→ CI 底部原点像素矩形。
    private func cropCGRect(_ rect: CropRect, in extent: CGRect) -> CGRect {
        CGRect(
            x: extent.origin.x + rect.x * extent.width,
            y: extent.origin.y + (1 - rect.y - rect.height) * extent.height,
            width: rect.width * extent.width,
            height: rect.height * extent.height
        ).integral
    }
}
