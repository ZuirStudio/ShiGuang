import CoreImage
import CoreGraphics
import Vision

/// P1-E：自动选区掩码生成（选择主体 / 选择天空 / 选择背景）。
///
/// - **主体**：Vision `VNGenerateForegroundInstanceMaskRequest`（端侧、离线，iOS 17+）
/// - **天空**：色域规则（上半部垂直权重 × 蓝性/白性），纯像素运算，瞬时完成，无模型
/// - **背景**：主体掩码反选
///
/// 输出的掩码契约（**必须遵守**，RenderPipeline 的 `blend` 依赖它）：
/// **与输入同尺寸的不透明三通道图，白 = 生效，黑 = 不生效。**
/// （CI 取证：单通道灰度图当 `inputMaskImage` 时几何会反常 —— 见 `MaskFit.canonical` 注释。）
public enum AutoMaskScene: String, Sendable, CaseIterable, Equatable {
    case subject
    case sky
    case background

    public var displayName: String {
        switch self {
        case .subject: return "主体"
        case .sky: return "天空"
        case .background: return "背景"
        }
    }
}

public enum AutoMaskSourceError: Error, Sendable, Equatable {
    /// 输入图不可用（0 尺寸等）
    case invalidInput
    /// 没识别到目标（画面里没有人物/前景实例，或没有天空色域）
    case sceneNotFound
    /// 生成过程失败
    case generationFailed
}

public enum AutoMaskSource {

    /// 生成自动选区掩码。同步阻塞（Vision `perform` 是同步 API），调用方负责放到后台任务。
    public static func mask(for scene: AutoMaskScene, from image: CGImage) throws -> CGImage {
        guard image.width > 0, image.height > 0 else { throw AutoMaskSourceError.invalidInput }
        switch scene {
        case .subject:
            return try subjectMask(from: image)
        case .sky:
            return try skyMask(from: image)
        case .background:
            return try invert(try subjectMask(from: image))
        }
    }
}

// MARK: - 主体（Vision 前景实例掩码）

extension AutoMaskSource {

    /// 端侧前景实例掩码。一次 `perform` 拿到画面里所有前景实例并取并集。
    static func subjectMask(from image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw AutoMaskSourceError.generationFailed
        }
        guard let observation = request.results?.first else {
            throw AutoMaskSourceError.sceneNotFound
        }
        guard !observation.allInstances.isEmpty else {
            throw AutoMaskSourceError.sceneNotFound
        }
        do {
            let buffer = try observation.generateScaledMaskForImage(
                forInstances: observation.allInstances,
                from: handler
            )
            let mask = CIImage(cvPixelBuffer: buffer)
            guard let cg = sharedContext.createCGImage(mask, from: mask.extent) else {
                throw AutoMaskSourceError.generationFailed
            }
            return try opaqueRGBA(cg)
        } catch let error as AutoMaskSourceError {
            throw error
        } catch {
            throw AutoMaskSourceError.generationFailed
        }
    }

    /// R007c：原来这是个**计算属性** —— 每访问一次就新建一个 CIContext
    /// （一次自动选区生成要访问 3 次 = 3 次 GPU 资源申请，正是 R006 踩过的坑）。
    /// 改懒加载静态常量：进程内只建一次。
    nonisolated(unsafe) private static let sharedContext: CIContext =
        CIContext(options: [.useSoftwareRenderer: false])
}

// MARK: - 天空（色域规则）

extension AutoMaskSource {

    /// 分析用降采样尺寸：色域规则不需要细节，512 长边足够且快（毫秒级）。
    static let skyAnalysisLongEdge: CGFloat = 512
    /// 天空覆盖率低于该值视为"没有天空"
    static let skyMinimumCoverage: Double = 0.015

    /// 天空掩码：`skyness = max(蓝性, 白性) × 上半部垂直权重`，再轻微羽化。
    static func skyMask(from image: CGImage) throws -> CGImage {
        let longEdge = max(image.width, image.height)
        let scale = longEdge > Int(skyAnalysisLongEdge)
            ? skyAnalysisLongEdge / CGFloat(longEdge)
            : 1
        let width = max(4, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(4, Int((CGFloat(image.height) * scale).rounded()))

        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw AutoMaskSourceError.generationFailed }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { throw AutoMaskSourceError.generationFailed }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        var coverageSum = 0.0
        for row in 0..<height {
            // CGBitmapContext 的位图缓冲**第 0 行 = 画面顶行**（CGImage 自顶向下存储；
            // 反证：ctx.draw(image) + ctx.makeImage() 的往返不翻转，见 MaskRenderTests
            // 的 samplePixel 约定）。所以 row→fromTop 是**正序**，不要取 1 - x。
            let fromTop = (Double(row) + 0.5) / Double(height)
            let vertical = verticalWeight(fromTop: fromTop)
            for column in 0..<width {
                let offset = (row * width + column) * 4
                let r = Double(pixels[offset]) / 255
                let g = Double(pixels[offset + 1]) / 255
                let b = Double(pixels[offset + 2]) / 255
                let value = vertical * skyness(r: r, g: g, b: b)
                coverageSum += value
                let byte = UInt8((value * 255).rounded())
                pixels[offset] = byte
                pixels[offset + 1] = byte
                pixels[offset + 2] = byte
                pixels[offset + 3] = 255
            }
        }
        let coverage = coverageSum / Double(width * height)
        guard coverage >= skyMinimumCoverage else { throw AutoMaskSourceError.sceneNotFound }
        guard let rough = ctx.makeImage() else { throw AutoMaskSourceError.generationFailed }

        // 羽化 + 升采样回原尺寸（模糊半径按分析图长边取 1.2%）
        let ci = CIImage(cgImage: rough)
        let radius = max(1.5, max(CGFloat(width), CGFloat(height)) * 0.012)
        let blurred = ci
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: ci.extent)
            .transformed(by: CGAffineTransform(scaleX: CGFloat(image.width) / CGFloat(width),
                                               y: CGFloat(image.height) / CGFloat(height)))
        guard let out = sharedContext.createCGImage(blurred, from: blurred.extent) else {
            throw AutoMaskSourceError.generationFailed
        }
        return try opaqueRGBA(out)
    }

    /// 从顶部数的归一化高度 → 垂直权重：上半部满权重，0.62 处衰减到 0。
    static func verticalWeight(fromTop: Double) -> Double {
        let lower = 0.45, upper = 0.62
        if fromTop <= lower { return 1 }
        if fromTop >= upper { return 0 }
        return (upper - fromTop) / (upper - lower)
    }

    /// 单像素"天空感"：蓝性或白性，取较大者。
    static func skyness(r: Double, g: Double, b: Double) -> Double {
        // 蓝性：蓝色通道明显高于红/绿
        let blueness = max(0, min(1, (b - max(r, g)) / 0.25)) * (b > 0.25 ? 1 : 0)
        // 白性（阴天/过曝的天空）：整体亮且低饱和
        let luminance = min(r, min(g, b))
        let brightness = max(0, min(1, (luminance - 0.62) / 0.25))
        let saturation = max(r, max(g, b)) - luminance
        let lowSaturation = max(0, min(1, 1 - saturation / 0.12))
        let whiteness = min(brightness, lowSaturation)
        return max(blueness, whiteness * 0.9)
    }
}

// MARK: - 背景（主体反选）与公共工具

extension AutoMaskSource {

    /// 反选：背景掩码 = 主体掩码反相（out = 1 − in，保持不透明）。
    static func invert(_ mask: CGImage) throws -> CGImage {
        let ci = CIImage(cgImage: mask)
        // 亮度反相：out = 1 - in（保持 alpha）
        let inverted = ci.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: -1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: -1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: -1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
        ])
        guard let out = sharedContext.createCGImage(inverted, from: inverted.extent) else {
            throw AutoMaskSourceError.generationFailed
        }
        return try opaqueRGBA(out)
    }
}

// MARK: - 测试可用的取证工具

extension AutoMaskSource {

    /// 掩码覆盖率（0…1）：白 = 生效区域的占比。用于测试与"是否识别到"的门控。
    public static func coverage(of image: CGImage) -> Double {
        let width = max(1, min(image.width, 64))
        let height = max(1, min(image.height, 64))
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return 0 }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var sum = 0.0
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            sum += Double(pixels[index]) / 255
        }
        return sum / Double(width * height)
    }

    /// 指定归一化区域的覆盖率（y 从**顶部**数，用于"上半部/下半部"断言）。
    public static func coverage(of image: CGImage, top: Double, bottom: Double) -> Double {
        let width = max(1, min(image.width, 64))
        let height = max(1, min(image.height, 64))
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return 0 }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var sum = 0.0
        var count = 0
        for row in 0..<height {
            // 位图第 0 行 = 画面顶行（同 skyMask 的说明）
            let fromTop = (Double(row) + 0.5) / Double(height)
            guard fromTop >= top, fromTop <= bottom else { continue }
            for column in 0..<width {
                sum += Double(pixels[(row * width + column) * 4]) / 255
                count += 1
            }
        }
        return count == 0 ? 0 : sum / Double(count)
    }

    /// 把任意 CGImage 规整成**不透明三通道**（白 = 生效）。
    /// 与 RenderKit `MaskFit.canonical` 保持同一契约：单通道/带 alpha 的掩码源
    /// 直接送进 `CIBlendWithMask` 会出现几何反常（详见 MaskFitThumbnailTests 取证）。
    static func opaqueRGBA(_ image: CGImage) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw AutoMaskSourceError.generationFailed }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let out = ctx.makeImage() else { throw AutoMaskSourceError.generationFailed }
        return out
    }
}
