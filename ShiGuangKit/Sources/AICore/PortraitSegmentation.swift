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
    /// P0-D（v0.7.1）：人物掩码的真实前景覆盖率（0...1）。
    ///
    /// v0.7.0 的门控只信「`personMask` 返回了非 nil」——而 Vision 在无人物照片上
    /// 也可能返回观测（全黑或误检的全白掩码），调用方无法区分「检出人物」与
    /// 「分割器给出了退化输出」。覆盖率就是区分二者的事实来源：由
    /// `VisionPersonSegmenter` 实测写入，stub 可不提供（nil = 未知，调用方
    /// 退回旧语义）。
    public var personCoverage: Double?
    public init(_ image: CIImage, personCoverage: Double? = nil) {
        self.image = image
        self.personCoverage = personCoverage
    }
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
        /// P0-D（v0.7.1）：最近一次人物掩码的前景覆盖率（0...1；未测量 = -1）。
        /// 无人物照片若返回全黑掩码 → 0；误检的全白掩码 → ≈1。门控与真机排查都看它。
        public var lastPersonCoverage: Double = -1
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

        // P0-D（v0.7.1）：先量覆盖率再出掩码。「返回了观测」≠「检出了人物」——
        // 无人物照片上 Vision 同样可能给出观测（全黑 = 没有人物；全白 = 误检）。
        // os_signpost 事件把每次推理的人物占比打到 Instruments / 日志，真机排查不靠猜。
        let coverage = Self.maskCoverage(of: observation.pixelBuffer)
        stats.lastPersonCoverage = coverage ?? -1
        if let coverage {
            os_signpost(.event, log: log, name: "personCoverage",
                        "%{public}d-permille", Int((coverage * 1000).rounded()))
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
        return SendableSegmentImage(aligned, personCoverage: coverage)
    }

    // MARK: - 私有

    /// P0-D（v0.7.1）：人物掩码前景覆盖率（0...1）。
    /// OneComponent8 直接读字节统计（≥128 记前景）；其它格式返回 nil（未知，不猜）。
    private static func maskCoverage(of buffer: CVPixelBuffer) -> Double? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let src = base.assumingMemoryBound(to: UInt8.self)
        var foreground = 0
        for y in 0..<h {
            let row = src + y * rowBytes
            for x in 0..<w where row[x] >= 128 { foreground += 1 }
        }
        return Double(foreground) / Double(w * h)
    }

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
        let space = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
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
    ///
    /// P0-D（v0.7.1）：**两侧尺寸不一致时先把人物掩码重采样到肤色掩码尺寸**再相乘。
    /// v0.7.0 的缺陷：肤色掩码是 256px 缩略图尺度，人物掩码是全图尺度，直接相乘等于
    /// 用「全图左上角 1/12 区域」当人物信号与全图缩略肤色求交 —— 交集既错位又稀疏。
    /// `cropped(to:)` 只裁不缩放，救不了这个错位，必须显式重采样。
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
        let personAligned = resample(person, to: skin.extent.size)
        return luminance(skin)
            .applyingFilter("CIMultiplyBlendMode",
                            parameters: [kCIInputBackgroundImageKey: luminance(personAligned)])
            .cropped(to: bounds)
    }

    /// 把掩码重采样到目标尺寸（Lanczos 高质量重采样），原点归零、尺寸对齐。
    /// 尺寸已一致（0.5pt 容差）时只做原点归零，不多余重采样。
    static func resample(_ image: CIImage, to size: CGSize) -> CIImage {
        let from = image.extent
        guard from.width > 0, from.height > 0, size.width >= 1, size.height >= 1 else {
            return image
        }
        let originZero = image.transformed(
            by: CGAffineTransform(translationX: -from.origin.x, y: -from.origin.y)
        )
        guard abs(from.width - size.width) >= 0.5 || abs(from.height - size.height) >= 0.5 else {
            return originZero
        }
        let sx = size.width / from.width
        let sy = size.height / from.height
        // 标准 Core Image 重采样惯用法：先仿射变换（惰性），再用 Lanczos
        // （scale=1 / aspect=1）在当前 extent 上强制真正重采样。
        let scaled = originZero
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .applyingFilter("CILanczosScaleTransform",
                            parameters: ["inputScale": 1.0, "inputAspectRatio": 1.0])
        return scaled.cropped(to: CGRect(origin: .zero, size: size))
    }

    /// 取亮度并强制不透明（alpha = 1），把任意掩码输入规整成同一形态。
    ///
    /// ⚠️ `CIColorMatrix` 的语义是**逐列**的：`inputRVector = (x,y,z,w)` 表示
    /// `R_out = x·R + y·G + z·B + w·A`。要让**三个输出通道都等于同一个亮度**
    /// `0.2126R + 0.7152G + 0.0722B`，必须给 R/G/B 三个 vector 填**同一组**权重
    /// （即每行都是 0.2126/0.7152/0.0722）。早期版本把单个权重沿三通道重复
    /// （`(0.2126,0.2126,0.2126)`），得到的是 `0.2126·(R+G+B)`，白掩码被压到
    /// 0.638×，求交后只剩 0.407× —— 磨皮/美白实际只以约 41% 强度生效。
    public static func luminance(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
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

    /// P0-D（v0.7.1）门控阈值：人物掩码前景覆盖率下限。
    /// 低于此值视为「未检出人物」——挡住全黑掩码与散粒噪点掩码击穿门控。
    /// 0.5% 的画面 ≈ 245×245px（以 12MP 照片计）：比这还小的人像不是有意义的磨皮目标。
    public static let minPersonCoverage: Double = 0.005
    /// P0-D（v0.7.1）门控阈值：人物掩码覆盖率「疑似误检」上限。
    /// 大于此值且**检不出人脸**时，判定为分割器误检（典型：无人物照片被整图判为人像，
    /// 即 v0.7.0「效果作用到全图」的直接机制）。贴脸特写有脸，不受此规则影响。
    public static let maxSuspectCoverage: Double = 0.98
    /// P0-D（v0.7.1）门控阈值：合成掩码（人像 ∩ 肤色）覆盖率下限。
    /// 低于此值视为「没有可施效的肤色区域」——效果不生效。
    public static let minCombinedCoverage: Double = 0.002

    /// 构建结果。
    ///
    /// `@unchecked Sendable`：内含 `CGImage`（本 SDK 下未标注 Sendable）。该掩码由本函数
    /// **新建**、构造后不再被其它持有者引用或改写，跨到主 actor 使用是安全的 —— 与
    /// `SendableSegmentImage` 同一套论证。
    public struct Result: @unchecked Sendable {
        /// 合成掩码（人像 ∩ 肤色；未检出人物时内容由 `fallback` 决定）
        public let mask: CGImage
        /// 是否检出**可信的**人物（P0-D 后：非 nil 且覆盖率过门槛，且非「无脸全覆盖」误检）
        public let personFound: Bool
        /// 人像分割能力是否可用（false = 走了降级路径）
        public let personSegmentationAvailable: Bool
        /// 实际生效的降级策略（nil = 正常走「人像 ∩ 肤色」）
        public let appliedFallback: PortraitRefinement.Fallback?
        /// P0-D（v0.7.1）：Vision 人物掩码的实测覆盖率（0...1；未测量/不可用 = -1）
        public let personCoverage: Double
        /// P0-D（v0.7.1）：合成掩码的实测覆盖率（0...1）——「效果会落在百分之几的画面上」
        public let combinedCoverage: Double
        /// P0-D（v0.7.1）：最终门控结果。v0.7.0 的 `willApplyEffect` 只看「人物非 nil」，
        /// 现在以合成掩码的真实覆盖率为准：真有可施效的肤色区域才生效。
        public let willApply: Bool

        /// 本次是否**真的会**施加效果。
        ///
        /// `false` 时 UI 必须走「未识别到可用人像区域」分支，不要假装成功 —— App 固定用
        /// `.strictGate`，未检出人物 ⇒ 掩码全零 ⇒ 磨皮/美白输出与输入逐像素相同。
        public var willApplyEffect: Bool { willApply }

        public init(mask: CGImage, personFound: Bool,
                    personSegmentationAvailable: Bool,
                    appliedFallback: PortraitRefinement.Fallback?,
                    personCoverage: Double = -1,
                    combinedCoverage: Double = 0,
                    willApply: Bool = false) {
            self.mask = mask
            self.personFound = personFound
            self.personSegmentationAvailable = personSegmentationAvailable
            self.appliedFallback = appliedFallback
            self.personCoverage = personCoverage
            self.combinedCoverage = combinedCoverage
            self.willApply = willApply
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
        var personCoverage: Double = -1
        do {
            let boxed = try await provider.personMask(
                for: SendableSegmentImage(CIImage(cgImage: image)))
            person = boxed?.image
            personCoverage = boxed?.personCoverage ?? -1
        } catch {
            segmenterOK = false
        }

        // P0-D（v0.7.1）门控：「personMask 返回非 nil」≠「检出了可用的人物」。
        // 按实测覆盖率逐条裁决：
        // ① 覆盖率 < 下限（含未测量时退回旧语义：非 nil 即可信）→ 未检出人物；
        // ② 覆盖率 > 疑似误检上限 且 检不出人脸 → 分割器误检（无人物照片被整图
        //    判为人像的直接机制，v0.7.0「全图生效」的根因）→ 同样按未检出处理。
        //    贴脸特写能检出人脸，不受影响；人脸识别失败的极端仰拍/大侧脸属安全侧失败
        //    （效果不生效，而非误伤全图）。
        var crediblePerson = person != nil
            && (personCoverage < 0 || personCoverage >= Self.minPersonCoverage)
        if crediblePerson, personCoverage > Self.maxSuspectCoverage {
            if PortraitMaskAnalyzer.faceCount(in: image) == 0 {
                crediblePerson = false
            }
        }
        let personFound = crediblePerson
        // 门控未过 → 当作没有人物（strictGate 出零掩码 / skinOnly 按旧策略降级）
        let effectivePerson = crediblePerson ? person : nil
        progress?(5, total)

        // 阶段 6：求交合成
        let extent = CGRect(x: 0, y: 0, width: skin.width, height: skin.height)
        let combined = PortraitRefinement.combine(skin: CIImage(cgImage: skin),
                                                  person: effectivePerson,
                                                  extent: extent,
                                                  fallback: fallback)
        guard let out = renderGrayscale(combined, extent: extent) else {
            progress?(total, total)
            return nil
        }
        // 终门控：合成掩码的真实覆盖率决定效果是否落地（防散粒交集制造花斑效果）
        let combinedCoverage = coverage(of: out)
        let willApply = combinedCoverage >= Self.minCombinedCoverage
        progress?(6, total)
        progress?(total, total)
        return Result(mask: out,
                      personFound: personFound,
                      personSegmentationAvailable: segmenterOK,
                      appliedFallback: personFound ? nil : fallback,
                      personCoverage: personCoverage,
                      combinedCoverage: combinedCoverage,
                      willApply: willApply)
    }

    /// P0-D（v0.7.1）：灰度掩码覆盖率（前景像素占比，阈值 ≥ 8/255，羽化边缘不计入）。
    /// 掩码固定为 RGBA8 灰度（`makeOpaqueGray` 产物），三通道同值，读 R 通道即可。
    private static func coverage(of mask: CGImage) -> Double {
        let total = mask.width * mask.height
        guard total > 0, let data = mask.dataProvider?.data else { return 0 }
        guard let ptr = CFDataGetBytePtr(data) else { return 0 }
        var hit = 0
        for i in 0..<total where ptr[i * 4] >= 8 { hit += 1 }
        return Double(hit) / Double(total)
    }

    /// 把合成结果落成不透明灰度 CGImage（每张照片只调一次，context 建一次可接受）。
    private static func renderGrayscale(_ image: CIImage, extent: CGRect) -> CGImage? {
        let width = Int(extent.width.rounded())
        let height = Int(extent.height.rounded())
        guard width > 0, height > 0 else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CIContext(options: [.cacheIntermediates: false])
        let space = CGColorSpaceCreateDeviceRGB()
        rgba.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            ctx.render(image, toBitmap: base, rowBytes: width * 4, bounds: extent,
                       format: .RGBA8, colorSpace: space)
        }
        return VisionPersonSegmenter.makeOpaqueGray(rgba, width: width, height: height)
    }
}
