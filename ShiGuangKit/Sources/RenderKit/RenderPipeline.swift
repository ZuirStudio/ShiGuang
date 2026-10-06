import CoreImage
import EditKit

// MARK: - 渲染协议

/// 渲染器抽象：EditGraph（纯逻辑）→ 平台图像（CIImage）。
/// RenderKit 是唯一知道图像怎么画的地方；EditKit 保持零平台依赖。
public protocol ImageRendering: Sendable {
    func render(source: CIImage, graph: EditGraph) -> CIImage
}

// MARK: - v0.3 渲染器

/// 调整映射（ADR-004：Core Image + 自定义 kernel）：
/// - 色调折叠（10 参数）→ 自定义 `toneAdjust` kernel，单遍完成
/// - sharpen / clarity → CIUnsharpMask（CISharpenLuminosity 在软件渲染器返回 nil，实测）
/// - vignette → CIVignette（正值压暗边缘）
/// - straighten → CIStraightenFilter；crop → CICrop（左上原点归一化转换）
/// - skinSmoothing / skinBrightening → 皮肤掩码内处理（掩码由 AICore 生成，无掩码时跳过）
/// - lut → CIColorCubeWithColorSpace（3D LUT，引用注入）
/// - dehaze / noiseReduction → P2 Metal kernel，暂为恒等
public struct BasicAdjustmentRenderer: ImageRendering {
    /// 运行时编译的自定义 kernel（Core Image Kernel Language，deprecated 但可用；
    /// P2 迁移到 .metal + CIKernel(functionName:fromMetalLibraryData:)）
    private static let kernel: CIKernel? = CIKernel(source: ToneKernelSource.source)

    /// 蒙版局部混合 kernel（v0.4 Phase 4.3）。
    private static let maskKernel: CIKernel? = CIKernel(source: MaskKernelSource.source)

    /// 皮肤掩码（与原图同域；预览需按预览 scale 同步缩放）。
    /// CIImage 不可变且线程安全 → @unchecked 合规。
    public var skinMask: CIImage?

    /// LUT 数据提供方（App 层 LUTStore 注入；缺省跳过 lut 指令）。
    public var lutProvider: (@Sendable (UUID) -> LUTCube?)?

    /// 蒙版预览模式：非 nil 时在成片上叠加该蒙版的选区色（仅预览，不写入导出）。
    public var maskOverlayID: UUID?

    public init(
        skinMask: CIImage? = nil,
        lutProvider: (@Sendable (UUID) -> LUTCube?)? = nil,
        maskOverlayID: UUID? = nil
    ) {
        self.skinMask = skinMask
        self.lutProvider = lutProvider
        self.maskOverlayID = maskOverlayID
    }

    public func render(source: CIImage, graph: EditGraph) -> CIImage {
        let base = apply(graph.operations, to: source)
        guard let overlayID = maskOverlayID,
              let mask = graph.masks.first(where: { $0.id == overlayID }),
              let alpha = MaskRenderer.alphaImage(for: mask, in: base.extent),
              let tinted = MaskRenderer.tint(alpha, over: base, extent: base.extent) else { return base }
        return tinted
    }

    /// 管线主体（不含蒙版叠加色预览）——蒙版局部调整复用同一管线。
    func apply(_ operations: [EditOperation], to source: CIImage) -> CIImage {
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

        // 曲线（固定阶段：基础色调之后）与 HSL 分通道（最后）：与指令到达顺序无关
        var curves = ToneCurveSet()
        var hsl = HSLAdjustment()

        /// 曲线 + HSL 合并烘焙为一次立方 LUT 应用（全恒等时零开销跳过）。
        func flushGrading() {
            guard !curves.isIdentity || !hsl.isIdentity else { return }
            if let cube = GradingCube.make(curves: curves, hsl: hsl),
               let applied = applyLUT(cube, on: image) {
                image = applied
            }
            curves = ToneCurveSet()
            hsl = HSLAdjustment()
        }

        for operation in operations {
            if tone.absorb(operation) { continue }
            if case .toneCurve(let set) = operation {
                curves = set
                continue
            }
            if case .mask = operation {
                flushTone()
                flushGrading()
                image = applyMask(operation, on: image)
                continue
            }
            if hsl.absorb(operation) { continue }
            flushTone()
            flushGrading()

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
            case .skinSmoothing(let v) where v > 0:
                if let mask = skinMask, let smoothed = self.skinSmoothed(image, mask: mask, amount: v) {
                    image = smoothed
                }
            case .skinBrightening(let v) where v > 0:
                if let mask = skinMask, let brightened = self.skinBrightened(image, mask: mask, amount: v) {
                    image = brightened
                }
            case .lut(let ref):
                if let cube = lutProvider?(ref.id),
                   let applied = applyLUT(cube, on: image) {
                    image = applied
                }
            case .dehaze, .noiseReduction:
                break // TODO(P2): Metal NLM 去噪 / 去雾 kernel
            case .mask:
                break // 已在上面提前处理（此处仅为穷举完整）
            default:
                break // 负值 clarity/vignette 等暂为恒等
            }
        }
        flushTone()
        flushGrading()
        return image
    }

    // MARK: 人像精修

    /// 磨皮：掩码内混合高斯模糊（v0 掩码混合；P3 引导滤波保边缘）。
    private func skinSmoothed(_ image: CIImage, mask: CIImage, amount: Double) -> CIImage? {
        let radius = amount / 100 * 10
        let clamped = image.applyingFilter("CIClamp", parameters: [:])
        let blurred = clamped
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius])
            .cropped(to: image.extent)
        return blend(background: blurred, foreground: image, mask: mask, mix: amount / 100)
    }

    /// 美白：掩码内亮度提升。
    private func skinBrightened(_ image: CIImage, mask: CIImage, amount: Double) -> CIImage? {
        let brightened = image.applyingFilter(
            "CIColorControls",
            parameters: ["inputBrightness": amount / 100 * 0.09, "inputSaturation": 1 - amount / 100 * 0.08]
        )
        return blend(background: brightened, foreground: image, mask: mask, mix: amount / 100)
    }

    /// 掩码混合：background 在掩码白区生效，mix 控制整体强度。
    private func blend(background: CIImage, foreground: CIImage, mask: CIImage, mix: Double) -> CIImage? {
        guard mix > 0.001 else { return foreground }
        let scaledMask = mask.cropped(to: background.extent)
        // CIBlendWithMask：掩码白区显示 background，黑区显示 foreground
        let masked = background
            .applyingFilter("CIBlendWithMask", parameters: [
                "inputBackgroundImage": background,
                "inputImage": foreground,
                "inputMaskImage": scaledMask,
            ])
        guard mix < 0.999 else { return masked }
        // 全局强度：灰度 = mix（白=完全生效，黑=原图）
        let g = CGFloat(mix)
        let strengthMask = CIImage(color: CIColor(red: g, green: g, blue: g, alpha: 1)).cropped(to: background.extent)
        return masked.applyingFilter("CIBlendWithMask", parameters: [
            "inputBackgroundImage": masked,
            "inputImage": foreground,
            "inputMaskImage": strengthMask,
        ])
    }

    // MARK: 蒙版（Phase 4.3）

    /// 局部调整：在整图上跑一遍同一管线，再按蒙版权重混回原图。
    /// - 局部调整自身不含蒙版指令（Mask.setAdjustment 已拒绝），故无无限递归
    /// - 无调整 / 空笔画的蒙版 = 恒等（选区色只由预览叠加层负责）
    private func applyMask(_ operation: EditOperation, on image: CIImage) -> CIImage {
        guard case .mask(let mask) = operation else { return image }
        let localOps = mask.adjustments.filter { !$0.isMask }
        guard !mask.isEmpty, !localOps.isEmpty,
              let kernel = Self.maskKernel,
              let alpha = MaskRenderer.alphaImage(for: mask, in: image.extent) else { return image }

        let adjusted = apply(localOps, to: image)
        let roi: CIKernelROICallback = { _, rect in rect }
        let arguments: [Any] = [image, adjusted, alpha, mask.opacity / 100]
        return kernel.apply(extent: image.extent, roiCallback: roi, arguments: arguments) ?? image
    }

    // MARK: LUT

    /// 应用立方 LUT。
    /// ⚠️ `CIColorCubeWithColorSpace` 的 `inputColorSpace` 参数类型是 **CGColorSpace**
    /// （Apple 文档核实：Swift 属性 `colorSpace: CGColorSpace?`）。传入 CIColor 时
    /// CIFilter 判为非法值并抛 NSException（进程崩溃，无法用 Swift do/catch 兜住），
    /// 故此处必须传颜色空间本体。
    private func applyLUT(_ cube: LUTCube, on image: CIImage) -> CIImage? {
        guard cube.size >= 2, !cube.rgb.isEmpty else { return nil }
        let data = LUTParser.colorCubeData(cube)
        // 指定 sRGB：曲线与 HSL 的换算在 sRGB 编码域进行（与调色工具直觉一致），
        // 与 GradingCube 的烘焙前提严格对应。
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeData": data,
            "inputCubeDimension": Float(cube.size),
            "inputColorSpace": sRGB,
        ])
    }

    // MARK: 几何

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

// MARK: - Sendable

/// CIImage / Data 缓存均不可变且线程安全 → unchecked 合规。
extension BasicAdjustmentRenderer: @unchecked Sendable {}
