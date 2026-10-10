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
    ///
    /// R006 性能专项：加了一层**记忆化**。同一帧内 `applyMask` 与「蒙版叠加色」会各取一次 alpha，
    /// 滑杆拖动时每帧都取两次；笔刷蒙版的 `brushImage` 每次都要 `CGBitmapContext` 栅格化整条笔画
    /// （1024px 路径），是全链路最贵的单点。形状不变时直接复用同一个 `CIImage`，
    /// 顺带让 Core Image 自身的中间结果也按同一节点复用。
    public static func alphaImage(for mask: Mask, in extent: CGRect) -> CIImage? {
        guard extent.width >= 1, extent.height >= 1 else { return nil }
        if let hit = AlphaMemo.shared.cached(mask, extent) {
            // R007b-1 Stage B1：命中率是可验证指标（真机 `PerfSignpost.shared.report()` 可读）。
            PerfSignpost.shared.bump(.maskAlphaCacheHit)
            return hit
        }
        // R007b-1 Stage B1/B3：未命中才真正栅格化 —— 这里是最贵的单点（画笔 1024px 路径重建）。
        return PerfSignpost.shared.measure(.maskAlpha) {
            guard let fresh = makeAlphaImage(for: mask, in: extent) else { return nil }
            AlphaMemo.shared.store(mask, extent, fresh)
            return fresh
        }
    }

    /// 未缓存的真实生成路径。
    static func makeAlphaImage(for mask: Mask, in extent: CGRect) -> CIImage? {
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

// MARK: - alpha 记忆化

/// 蒙版 alpha 记忆缓存的键（R007b-1 Stage B3：由「线性扫描 + 逐字段比较」改为「哈希键」）。
///
/// 由 `mask.id` + `mask.cacheDigest`（内容摘要）+ extent 的四个分量组成。
/// **命中后仍做全量 `==` 校验**，所以摘要碰撞只会退化成一次重算，不会产生错误画面。
struct MaskCacheKey: Hashable {
    let id: UUID
    let digest: UInt64
    let originX: Double
    let originY: Double
    let width: Double
    let height: Double

    init(mask: Mask, extent: CGRect) {
        self.id = mask.id
        self.digest = mask.cacheDigest
        self.originX = extent.origin.x
        self.originY = extent.origin.y
        self.width = extent.width
        self.height = extent.height
    }
}

/// 蒙版 alpha 图的极小容量记忆缓存（4 条，够覆盖「选区列表 + 叠加色」的并发取用）。
///
/// - 键 = `MaskCacheKey`（id + 内容摘要 + extent）；命中后**再**做一次 `extent ==` / `mask ==`
///   全量校验 —— 缓存语义与「按 `Mask` 相等」完全一致，只是把 miss 路径从 O(点数) 降到 O(1) 查找。
/// - 用 `NSLock` 而非 `actor`：取值必须在**渲染线程同步返回**，async 会让热路径退化成串行等待。
/// - 自带命中/未命中计数（供 Stage B 的「命中率」证据与单测断言；不用进程级 `PerfSignpost`，
///   避免 R006 踩过的「单例 + 并行测试互相污染」）。
private final class AlphaMemo: @unchecked Sendable {
    static let shared = AlphaMemo()

    private let lock = NSLock()
    private var entries: [MaskCacheKey: (mask: Mask, extent: CGRect, image: CIImage)] = [:]
    private var order: [MaskCacheKey] = []
    private let capacity = 4
    private var hits = 0
    private var misses = 0

    func cached(_ mask: Mask, _ extent: CGRect) -> CIImage? {
        let key = MaskCacheKey(mask: mask, extent: extent)
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key], entry.extent == extent, entry.mask == mask else {
            misses += 1
            // 摘要碰撞 / 条目过期：顺手清掉脏记录，别让它继续占容量。
            if entries[key] != nil { removeLocked(key) }
            return nil
        }
        hits += 1
        return entry.image
    }

    func store(_ mask: Mask, _ extent: CGRect, _ image: CIImage) {
        let key = MaskCacheKey(mask: mask, extent: extent)
        lock.lock()
        defer { lock.unlock() }
        // 同一蒙版旧版本先淘汰（拖动中持续产生新形状，否则会把容量全占满）
        for stale in order where entries[stale]?.mask.id == mask.id {
            removeLocked(stale)
        }
        removeLocked(key)
        entries[key] = (mask, extent, image)
        order.append(key)
        while order.count > capacity {
            let oldest = order.removeFirst()
            entries[oldest] = nil
        }
    }

    func stats() -> (hits: Int, misses: Int, count: Int, capacity: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (hits, misses, entries.count, capacity)
    }

    private func removeLocked(_ key: MaskCacheKey) {
        entries[key] = nil
        order.removeAll { $0 == key }
    }

    /// 仅供测试：清空缓存与计数。
    func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        order.removeAll()
        hits = 0
        misses = 0
    }
}

/// 测试入口（`private` 类型不能在测试里直接触达，这里给一个 internal 包装）。
enum AlphaMemoTestHooks {
    static func reset() { AlphaMemo.shared.resetForTesting() }

    /// Stage B：命中 / 未命中 / 当前条目数 / 容量。
    static func stats() -> (hits: Int, misses: Int, count: Int, capacity: Int) {
        AlphaMemo.shared.stats()
    }
}
