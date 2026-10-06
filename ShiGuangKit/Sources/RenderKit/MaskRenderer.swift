import CoreImage
import CoreGraphics
import EditKit

// MARK: - 蒙版渲染

/// 蒙版 kernel：把「局部调整后的图像」按蒙版权重混回原图。
/// 权重 = 蒙版亮度 × 不透明度；`sample(s, samplerCoord(s))` 逐 sampler 取源坐标，
/// 三张图同域（都裁到 image.extent），因此 1:1 映射。
enum MaskKernelSource {
    static let source = """
    kernel vec4 maskApply(sampler original, sampler adjusted, sampler maskImage, float amount) {
        vec4 o = sample(original, samplerCoord(original));
        vec4 a = sample(adjusted, samplerCoord(adjusted));
        vec4 m = sample(maskImage, samplerCoord(maskImage));
        float w = clamp(m.r, 0.0, 1.0) * clamp(amount, 0.0, 1.0);
        // 显式 lerp（不依赖 mix 重载）
        return vec4(o.rgb + (a.rgb - o.rgb) * w, o.a);
    }
    """

    /// 蒙版预览叠加色 kernel（单独一份源码：`CIKernel(source:)` 每份源码只允许一个 kernel 函数）。
    static let tintSource = """
    kernel vec4 maskTint(sampler image, sampler maskImage, vec4 tint, float strength) {
        vec4 base = sample(image, samplerCoord(image));
        vec4 m = sample(maskImage, samplerCoord(maskImage));
        float a = clamp(m.r, 0.0, 1.0) * clamp(strength, 0.0, 1.0);
        return vec4(base.rgb + (tint.rgb - base.rgb) * a, base.a);
    }
    """
}

/// 蒙版 → alpha 图（灰度、不透明，白 = 完全生效）。
///
/// 设计要点（合规 + 性能）：
/// - 线性 / 径向：**纯 Core Image 生成器**（CILinearGradient / CIRadialGradient），GPU 路径
/// - 画笔：CoreGraphics 一次性栅格化笔画路径（绘制而非逐像素循环，且在 1024px 内降采样），
///   软化用 CIGaussianBlur（仍走 CI），再缩放回目标 extent
/// - 归一化坐标一律**左上原点**，与 UI 手势、`CropRect` 惯例一致
public enum MaskRenderer {
    /// 画笔栅格化分辨率上限（长边）。笔画只在手指移动时重建，不进入逐帧热路径。
    static let brushRasterMaxDimension: Double = 1024

    /// 生成蒙版 alpha 图；extent 为当前管线图像域（几何指令之后会变化）。
    public static func alphaImage(for mask: Mask, in extent: CGRect) -> CIImage? {
        guard extent.width >= 1, extent.height >= 1 else { return nil }
        let mask = mask.normalized()
        guard !mask.isEmpty else { return nil }

        let soft = min(max(mask.feather / 100, 0), 1)
        var image: CIImage?

        switch mask.shape {
        case .linear(let linear):
            image = linearImage(linear, softness: soft, in: extent)
        case .radial(let radial):
            image = radialImage(radial, softness: soft, in: extent)
        case .brush(let brush):
            image = brushImage(brush, feather: soft, in: extent)
        }

        guard var result = image else { return nil }
        if mask.isInverted {
            result = invert(result)
        }
        result = scale(result, by: mask.opacity / 100)
        return result.cropped(to: extent)
    }

    /// 蒙版预览叠加色（仅预览，不写入导出）：把选区染成暖橙，用自有 kernel 插值
    /// （避免 CIBlendWithMask / CIColorMatrix 在 premultiplied 语义上的不确定性）。
    public static func tint(_ alpha: CIImage, over base: CIImage, extent: CGRect) -> CIImage? {
        guard let kernel = tintKernel else { return nil }
        let roi: CIKernelROICallback = { _, rect in rect }
        let tint = CIVector(x: 0.95, y: 0.30, z: 0.15, w: 1)
        return kernel.apply(
            extent: extent,
            roiCallback: roi,
            arguments: [base, alpha.cropped(to: extent), tint, 0.42]
        )
    }

    private static let tintKernel: CIKernel? = CIKernel(source: MaskKernelSource.tintSource)

    // MARK: 形状

    /// 线性渐变：start 侧无效果 → end 侧完全生效。
    /// 羽化 = 端点间过渡带占整条线的比例（0 → 近似硬边）。
    static func linearImage(_ linear: LinearMask, softness: Double, in extent: CGRect) -> CIImage? {
        let a = ciPoint(linear.start, in: extent)
        let b = ciPoint(linear.end, in: extent)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let band = min(max(softness, 0.01), 1)
        let p0 = CGPoint(x: mid.x - (mid.x - a.x) * band, y: mid.y - (mid.y - a.y) * band)
        let p1 = CGPoint(x: mid.x + (b.x - mid.x) * band, y: mid.y + (b.y - mid.y) * band)
        guard let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(cgPoint: p0),
            "inputPoint1": CIVector(cgPoint: p1),
            "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 1),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
        ])?.outputImage else { return nil }
        return gradient.cropped(to: extent)
    }

    /// 径向渐变：**椭圆内完全生效、椭圆外无效果**（与 Lightroom 径向滤镜的心智一致），
    /// aspectRatio = 横轴/纵轴，rotationDegrees 顺时针。
    static func radialImage(_ radial: RadialMask, softness: Double, in extent: CGRect) -> CIImage? {
        let minDim = min(extent.width, extent.height)
        let outer = max(radial.radius * minDim, 1)
        let inner = outer * (1 - min(max(softness, 0), 0.98))
        guard let gradient = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 0, y: 0),
            "inputRadius0": inner,
            "inputRadius1": outer,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])?.outputImage else { return nil }

        let center = ciPoint(radial.center, in: extent)
        var transform = CGAffineTransform(translationX: center.x, y: center.y)
        transform = transform.rotated(by: radial.rotationDegrees * .pi / 180)
        transform = transform.scaledBy(x: max(radial.aspectRatio, 0.05), y: 1)
        return gradient.transformed(by: transform).cropped(to: extent)
    }

    /// 画笔：笔画路径栅格化 → 高斯软化（硬度）→ 羽化 → 缩放回 extent。
    static func brushImage(_ brush: BrushMask, feather: Double, in extent: CGRect) -> CIImage? {
        let strokes = brush.strokes.filter { !$0.points.isEmpty }
        guard !strokes.isEmpty else { return nil }

        let scale = min(1, brushRasterMaxDimension / max(extent.width, extent.height))
        let w = max(Int((extent.width * scale).rounded()), 8)
        let h = max(Int((extent.height * scale).rounded()), 8)
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setStrokeColor(gray: 1, alpha: 1)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let minDim = min(extent.width, extent.height) * scale
        var maxRadiusPx = 1.0
        for stroke in strokes {
            let rPx = max(stroke.radius * minDim, 1)
            maxRadiusPx = max(maxRadiusPx, rPx)
            ctx.setLineWidth(rPx * 2)
            let pts = stroke.points.map { point in
                CGPoint(x: point.x * Double(w), y: (1 - point.y) * Double(h))
            }
            if pts.count == 1 {
                let p = pts[0]
                ctx.fillEllipse(in: CGRect(x: p.x - rPx, y: p.y - rPx, width: rPx * 2, height: rPx * 2))
            } else {
                ctx.beginPath()
                ctx.move(to: pts[0])
                for p in pts.dropFirst() { ctx.addLine(to: p) }
                ctx.strokePath()
            }
        }
        guard let cgImage = ctx.makeImage() else { return nil }

        var image = CIImage(cgImage: cgImage)
        // 硬度 → 边缘软化半径；羽化再叠加一层（两者都映射到栅格空间）
        let hardnessSoft = (1 - min(max(brush.hardness / 100, 0), 1)) * 0.5
        let blurRadius = (hardnessSoft + feather * 0.4) * maxRadiusPx
        if blurRadius > 0.3 {
            image = image
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": blurRadius])
                .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // 栅格 → extent
        let sx = extent.width / Double(w)
        let sy = extent.height / Double(h)
        let transform = CGAffineTransform(translationX: extent.minX, y: extent.minY).scaledBy(x: sx, y: sy)
        var out = image.transformed(by: transform).cropped(to: extent)
        // 流量 = 画笔浓度：v1 以整体 alpha 缩放近似（逐点盖章累积留待 v2）。
        // 与 mask.opacity 是两级独立系数：flow 属笔刷本体，opacity 属蒙版整体。
        let flow = min(max(brush.flow / 100, 0), 1)
        if flow < 0.999 { out = Self.scale(out, by: flow).cropped(to: extent) }
        return out
    }

    // MARK: 后处理

    /// 反选（负向量 + 偏移，显式保留 alpha；CIColorInvert 会把 alpha 一起翻掉，不用）
    static func invert(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: -1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: -1, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: -1, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
        ])
    }

    /// 不透明度：缩放亮度，保留 alpha。
    static func scale(_ image: CIImage, by factor: Double) -> CIImage {
        let k = min(max(factor, 0), 1)
        guard k < 0.999 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    /// 归一化左上原点 → CI 底部原点像素坐标。
    static func ciPoint(_ point: MaskPoint, in extent: CGRect) -> CGPoint {
        CGPoint(
            x: extent.minX + point.x * extent.width,
            y: extent.minY + (1 - point.y) * extent.height
        )
    }
}
