import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import Vision
import os

// MARK: - 人像分割（R007b-1 Stage C / P0）
//
// 交付口径先说清楚（避免虚报）：
// - **模型来源 = Apple Vision 内置 `VNGeneratePersonSegmentationRequest`**。
//   依据见 docs/R007b1-stageC-report.md 的 C2 调研结论：SINet 与 HumanSeg-lite 都**没有**
//   「现成 Core ML 版 + 权重许可可商用再分发」的产物（只有 MNN / ONNX / PyTorch 形态，
//   ONNX 那份的权重溯源许可不明），按指令 C2 第 4/5 条降级链走到 Vision 保底。
// - 好处是明确的：**App 包体不新增任何权重文件（0 字节）**、零第三方许可、ANE 加速。
// - 已留抽象层 `PersonMaskProviding`：将来换自研 Core ML 模型只需再写一个实现，
//   App 层与 `PortraitMaskBuilder` 零改动。

/// 人像分割的失败原因。
///
/// 语义划分很重要：**「未检出人物」不是错误**，用 `personMask(for:)` 返回 nil 表达，
/// 调用方走优雅降级而不是异常分支（C4 要求无人物时不报错、不黑屏）。
public enum PortraitSegmentationError: Error, Equatable, Sendable {
    /// 输入图无法转成 CGImage（尺寸非法 / CIContext 出图失败）
    case badInput
    /// Vision 推理抛错（带上原始描述，便于真机定位）
    case inferenceFailed(String)
    /// 输出既不是单通道 8bit 也不是可解释为掩码的格式
    case unexpectedOutputFormat
}

/// 人像掩码提供方（抽象层）。
///
/// 刻意**不继承 `Sendable`**：这样测试可以写普通 `struct` 并显式标 `@unchecked Sendable`
/// （若这里已继承 Sendable，同一继承列表再写 `@unchecked Sendable` 会触发「重复遵循」）。
/// 生产实现 `VisionPersonSegmenter` 是 actor，天然 Sendable，由 `PortraitMaskBuilder` 的
/// `P: PersonMaskProviding & Sendable` 约束保证。
/// 跨隔离域传递图像的装箱。
///
/// **为什么必须有它**：Swift 6 严格并发下 `actor` 方法的参数与返回值都必须 `Sendable`，
/// 而本工程此前**从未**让 `CGImage`/`CIImage` 直接穿过 actor 边界 —— R006 走的是
/// **同步静态函数** + 调用方在 `Task.detached` 里用 App 层私有 `SendableCGImage` 装箱，
/// 那两个箱子是 `private` 的，AICore 拿不到。R007b-1 立过铁律：**跨隔离域传值必须显式装箱**。
/// 装箱内容是一张**不可变**图像，装箱后不再被其它持有者改写，故此处断言 `@unchecked` 成立。
public struct SendableSegmentImage: @unchecked Sendable {
    public let image: CIImage
    public init(_ image: CIImage) { self.image = image }
}

public protocol PersonMaskProviding {
    /// 生成人物掩码（白 = 人物，黑 = 背景），尺寸与坐标系与输入一致。
    /// - Parameter image: 待分割图像（须为「上为正」的正立图）。
    /// - Returns: 掩码；**未检出人物返回 nil**（不是错误）。
    func personMask(for image: SendableSegmentImage) async throws -> SendableSegmentImage?
}

/// Vision 内置人像分割（`VNGeneratePersonSegmentationRequest`，iOS 15+ / macOS 12+）。
///
/// - **actor 隔离**：Vision 请求对象与 `CIContext` 只创建一次并缓存（C3「模型加载一次缓存」）；
///   推理串行执行，避免并发 `perform` 同一请求导致输出缓冲被覆写。
/// - **降采样**：推理前把长边压到 `workingLongEdge`，掩码再按比例放大回原图尺度。
/// - **埋点**：os_signpost（`portraitInfer`）+ 轻量累加器；真机可接 Instruments，
///   CI 可用 `snapshot()` 取真实毫秒数——性能结论不靠代码推断（报告纪律）。
public actor VisionPersonSegmenter: PersonMaskProviding {
    /// 共享实例（模型只在进程内加载一次）。
    public static let shared = VisionPersonSegmenter()

    /// 推理输入的最长边。人像分割对分辨率不敏感，1024 已足够且显著快于全尺寸。
    public static let workingLongEdge: CGFloat = 1024

    /// 运行期统计（`snapshot()` 返回；供报告与诊断引用真实数字）。
    public struct Stats: Sendable, Equatable {
        public var requestCreations = 0
        public var inferences = 0
        public var personFound = 0
        public var noPerson = 0
        public var failures = 0
        /// 首次推理耗时（ms）——C5「首次加载 < 500ms」的取证点
        public var firstLoadMillis = 0.0
        public var lastInferenceMillis = 0.0
        public var maxInferenceMillis = 0.0
        public var totalInferenceMillis = 0.0
        public var meanInferenceMillis: Double {
            inferences > 0 ? totalInferenceMillis / Double(inferences) : 0
        }
    }

    private let quality: VNGeneratePersonSegmentationRequest.QualityLevel
    private var request: VNGeneratePersonSegmentationRequest?
    private var context: CIContext?
    private var stats = Stats()
    private let log = OSLog(subsystem: "studio.zuir.shiguang", category: "portrait")

    public init(quality: VNGeneratePersonSegmentationRequest.QualityLevel = .balanced) {
        self.quality = quality
    }

    /// 运行期可用性。部署目标已保证 iOS 27 / macOS 15（该请求 iOS 15+ / macOS 12+ 即提供），
    /// 故恒为 true；仍保留为方法，方便将来/CI 如实上报「请求真的能创建」。
    public func isAvailable() -> Bool { true }

    /// 读取累计统计。
    public func snapshot() -> Stats { stats }

    /// 只创建请求（不计推理），用于单独测量「首次加载」成本。
    @discardableResult
    public func warmUp() -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        _ = requestIfNeeded()
        _ = contextIfNeeded()
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    }

    /// 生成人像掩码。返回 nil = **未检出人物**（调用方据此降级，不视为错误）。
    public func personMask(for boxed: SendableSegmentImage) async throws -> SendableSegmentImage? {
        let image = boxed.image
        let t0 = DispatchTime.now().uptimeNanoseconds
        let req = requestIfNeeded()
        let ctx = contextIfNeeded()

        let extent = image.extent
        guard extent.width >= 2, extent.height >= 2, extent.isInfinite == false,
              !extent.isEmpty else {
            throw PortraitSegmentationError.badInput
        }

        // 1) 降采样到工作分辨率（掩码随后放大回原尺度）
        let longEdge = max(extent.width, extent.height)
        let scale = min(1, Self.workingLongEdge / longEdge)
        let working = scale < 1
            ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : image

        guard let cg = ctx.createCGImage(working, from: working.extent) else {
            throw PortraitSegmentationError.badInput
        }

        // 2) Vision 推理（同步；actor 保证串行，不会并发覆写同一请求的输出缓冲）
        let signpostID = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "portraitInfer", signpostID: signpostID)
        defer { os_signpost(.end, log: log, name: "portraitInfer", signpostID: signpostID) }

        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        do {
            try handler.perform([req])
        } catch {
            stats.failures += 1
            throw PortraitSegmentationError.inferenceFailed(String(describing: error))
        }

        guard let observation = req.results?.first as? VNPixelBufferObservation else {
            stats.noPerson += 1
            return nil
        }

        // 3) 像素缓冲 → 不透明灰度 CGImage（直接读字节，结果确定，不经色彩管理）
        guard let maskCG = Self.grayscaleMask(from: observation.pixelBuffer, context: ctx) else {
            stats.failures += 1
            throw PortraitSegmentationError.unexpectedOutputFormat
        }

        // 4) 放大回原图尺度并对齐原图原点
        let maskImage = CIImage(cgImage: maskCG)
        let up = extent.width / max(1, maskImage.extent.width)
        let aligned = maskImage
            .transformed(by: CGAffineTransform(scaleX: up, y: up))
            .transformed(by: CGAffineTransform(translationX: extent.origin.x, y: extent.origin.y))
            .cropped(to: extent)

        // 5) 统计
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        stats.inferences += 1
        stats.personFound += 1
        stats.lastInferenceMillis = ms
        stats.maxInferenceMillis = max(stats.maxInferenceMillis, ms)
        stats.totalInferenceMillis += ms
        if stats.firstLoadMillis == 0 { stats.firstLoadMillis = ms }
        return SendableSegmentImage(aligned)
    }

    // MARK: - 私有

    private func requestIfNeeded() -> VNGeneratePersonSegmentationRequest {
        if let request { return request }
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = quality
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        request = r
        stats.requestCreations += 1
        return r
    }

    private func contextIfNeeded() -> CIContext {
        if let context { return context }
        // 复用同一 context：R006 踩过「每次调用新建 CIContext」的坑
        let c = CIContext(options: [.cacheIntermediates: false])
        context = c
        return c
    }

    /// 把 Vision 的单通道掩码像素缓冲转成不透明灰度 CGImage。
    /// 优先直接读字节（快且确定）；格式不是 OneComponent8 时退回 Core Image 解释。
    private static func grayscaleMask(from buffer: CVPixelBuffer, context: CIContext) -> CGImage? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_OneComponent8 else {
            let ci = CIImage(cvPixelBuffer: buffer)
            return context.createCGImage(ci, from: ci.extent)
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        let src = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            let row = src + y * rowBytes
            for x in 0..<w {
                let v = row[x]
                let i = (y * w + x) * 4
                rgba[i] = v
                rgba[i + 1] = v
                rgba[i + 2] = v
                rgba[i + 3] = 255
            }
        }
        return makeOpaqueGray(rgba, width: w, height: h)
    }

    /// [RGBA8] → 不透明灰度 CGImage（与 R006 `PortraitMaskAnalyzer.grayImage` 同构）。
    static func makeOpaqueGray(_ rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        guard let space = CGColorSpace(name: CGColorSpace.deviceRGB),
              let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}

// MARK: - 掩码求交：「人像 ∩ 肤色」

/// 把人像掩码与肤色掩码合成单张掩码，使磨皮/美白**只落在人物皮肤上**。
public enum PortraitRefinement {
    /// 未检出人物（或人像分割不可用）时的降级策略。
    public enum Fallback: String, Sendable, CaseIterable {
        /// 严格门控：效果不生效（零掩码）。纯风景照片不会被误磨皮 —— v0.7.0 默认值。
        case strictGate
        /// 退回肤色掩码：保留 R006 的旧行为，对「人像识别失败的近距离特写」更友好。
        case skinOnly
    }

    /// 求交 = 逐像素相乘（两张都是黑底白前景的灰度掩码）。
    ///
    /// 两个输入先各自归一化成「不透明灰度」，因此无论上游给的是 RGB 灰度、单通道灰度
    /// 还是带 alpha 的图，结果都稳定可预测；再用 `CIMultiplyBlendMode`（逐通道乘积）
    /// 完成交集，最后裁到目标范围。
    ///
    /// 门控性质（不依赖色彩空间，任何情况下都成立）：**任一侧为 0 则结果为 0** ——
    /// 这正是「人物之外不施效果」的硬保证。软边（羽化值）在两端之间单调过渡。
    public static func combine(skin: CIImage,
                              person: CIImage?,
                              extent: CGRect,
                              fallback: Fallback) -> CIImage {
        let bounds = extent.isEmpty ? skin.extent : extent
        guard let person else {
            switch fallback {
            case .strictGate:
                return CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: bounds)
            case .skinOnly:
                return luminance(skin).cropped(to: bounds)
            }
        }
        return luminance(skin)
            .applyingFilter("CIMultiplyBlendMode",
                            parameters: [kCIInputBackgroundImageKey: luminance(person)])
            .cropped(to: bounds)
    }

    /// 取亮度并强制不透明（alpha = 1），把任意掩码输入规整成同一形态。
    public static func luminance(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.2126, z: 0.2126, w: 0),
            "inputGVector": CIVector(x: 0.7152, y: 0.7152, z: 0.7152, w: 0),
            "inputBVector": CIVector(x: 0.0722, y: 0.0722, z: 0.0722, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }
}

// MARK: - 一站式构建：肤色 + 人像 → 合成掩码

/// 肤色掩码 + 人像掩码 → 合成掩码，带**真实分阶段进度**与**优雅降级**。
///
/// 阶段划分（`stageCount = 7`，每一步都是真发生的事，不是凑数）：
/// `0` 准备/降采样 → `1...3` 肤色掩码（3 个子阶段）→ `4` 人像分割开始
/// → `5` 人像分割完成 → `6` 求交合成完成 → `7` 全部完成。
public enum PortraitMaskBuilder {
    /// 阶段总数，与内部真实步骤一一对应（供 UI 显示真实进度条）。
    public static let stageCount = 7

    /// 构建结果。
    ///
    /// `@unchecked Sendable`：内含 `CGImage`（本 SDK 下未标注 Sendable）。该掩码由本函数
    /// **新建**、构造后不再被其它持有者引用或改写，跨到主 actor 使用是安全的 —— 与
    /// `SendableSegmentImage` 同一套论证。
    public struct Result: @unchecked Sendable {
        /// 合成掩码（人像 ∩ 肤色；未检出人物时内容由 `fallback` 决定）
        public let mask: CGImage
        /// 是否检出人物
        public let personFound: Bool
        /// 人像分割能力是否可用（false = 走了降级路径）
        public let personSegmentationAvailable: Bool
        /// 实际生效的降级策略（nil = 正常走「人像 ∩ 肤色」）
        public let appliedFallback: PortraitRefinement.Fallback?

        /// 本次是否**真的会**施加效果。
        ///
        /// `false` 时 UI 必须走「未识别到可用人像区域」分支，不要假装成功 —— App 固定用
        /// `.strictGate`，未检出人物 ⇒ 掩码全零 ⇒ 磨皮/美白输出与输入逐像素相同。
        public var willApplyEffect: Bool { personFound }

        public init(mask: CGImage, personFound: Bool,
                    personSegmentationAvailable: Bool,
                    appliedFallback: PortraitRefinement.Fallback?) {
            self.mask = mask
            self.personFound = personFound
            self.personSegmentationAvailable = personSegmentationAvailable
            self.appliedFallback = appliedFallback
        }
    }

    /// 生产入口：Vision 内置人像分割。
    public static func build(for image: CGImage,
                             fallback: PortraitRefinement.Fallback = .strictGate,
                             progress: (@Sendable (Int, Int) -> Void)? = nil) async -> Result? {
        await build(for: image, provider: VisionPersonSegmenter.shared,
                    fallback: fallback, progress: progress)
    }

    /// 可注入入口：测试用 stub 在 CI 上验证「求交 / 降级」行为，无需真实推理。
    public static func build<P: PersonMaskProviding & Sendable>(
        for image: CGImage,
        provider: P,
        fallback: PortraitRefinement.Fallback = .strictGate,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> Result? {
        let total = stageCount
        progress?(0, total)

        // 阶段 1-3：肤色掩码（复用 R006 的分阶段实现，保留其真实子进度）
        guard let skin = PortraitMaskAnalyzer.skinMask(for: image, progress: { done, _ in
            progress?(min(done, 3), total)
        }) else {
            progress?(total, total)
            return nil
        }

        // 阶段 4-5：人像分割（失败/未检出人物都不抛错，走降级）
        progress?(4, total)
        var person: CIImage?
        var segmenterOK = true
        do {
            let boxed = try await provider.personMask(
                for: SendableSegmentImage(CIImage(cgImage: image)))
            person = boxed?.image
        } catch {
            segmenterOK = false
        }
        let personFound = person != nil
        progress?(5, total)

        // 阶段 6：求交合成
        let extent = CGRect(x: 0, y: 0, width: skin.width, height: skin.height)
        let combined = PortraitRefinement.combine(skin: CIImage(cgImage: skin),
                                                  person: person,
                                                  extent: extent,
                                                  fallback: fallback)
        guard let out = renderGrayscale(combined, extent: extent) else {
            progress?(total, total)
            return nil
        }
        progress?(6, total)
        progress?(total, total)
        return Result(mask: out,
                      personFound: personFound,
                      personSegmentationAvailable: segmenterOK,
                      appliedFallback: personFound ? nil : fallback)
    }

    /// 把合成结果落成不透明灰度 CGImage（每张照片只调一次，context 建一次可接受）。
    private static func renderGrayscale(_ image: CIImage, extent: CGRect) -> CGImage? {
        let width = Int(extent.width.rounded())
        let height = Int(extent.height.rounded())
        guard width > 0, height > 0 else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CIContext(options: [.cacheIntermediates: false])
        let space = CGColorSpace(name: CGColorSpace.deviceRGB) ?? CGColorSpaceCreateDeviceRGB()
        rgba.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            ctx.render(image, toBitmap: base, rowBytes: width * 4, bounds: extent,
                       format: .RGBA8, colorSpace: space)
        }
        return VisionPersonSegmenter.makeOpaqueGray(rgba, width: width, height: height)
    }
}
