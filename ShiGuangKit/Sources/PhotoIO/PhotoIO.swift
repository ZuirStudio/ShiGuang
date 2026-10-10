import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import CoreText

// MARK: - 导入照片模型

/// 已导入的照片（应用沙盒内拷贝；原图不经我们上传 — 合规 A2/C4）。
/// 文件名 = UUID，不保留原文件名（避免隐私泄露）。
public struct ImportedPhoto: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let fileName: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let importedAt: Date

    public init(
        id: UUID = UUID(),
        fileName: String,
        pixelWidth: Int,
        pixelHeight: Int,
        importedAt: Date = Date()
    ) {
        self.id = id
        self.fileName = fileName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.importedAt = importedAt
    }

    public var aspectRatio: CGFloat {
        guard pixelHeight > 0, pixelWidth > 0 else { return 1 }
        return CGFloat(pixelWidth) / CGFloat(pixelHeight)
    }
}

// MARK: - 存储协议

public protocol PhotoStoring: Sendable {
    func save(imageData: Data, preferredExtension: String) async throws -> ImportedPhoto
    func delete(_ photo: ImportedPhoto) async throws
    func allPhotos() async throws -> [ImportedPhoto]
    /// 全尺寸 CIImage（RAW / ProRAW 经 CIImage(contentsOf:) 自动接管）。
    func fullCIImage(for photo: ImportedPhoto) -> CIImage?
    /// 缩略图（ImageIO 降采样，避免全图解码）。
    func thumbnailCGImage(for photo: ImportedPhoto, maxPixel: CGFloat) -> CGImage?
}

// MARK: - 文件存储

/// 照片存储（actor 隔离）：Application Support/ShiGuang/Photos/ + index.json 清单。
/// - P2 迁移到 SwiftData 时保持此协议不变
public actor FilePhotoStore: PhotoStoring {
    private let directory: URL
    private let indexURL: URL
    private var index: [ImportedPhoto] = []

    public init(directory: URL? = nil) throws {
        // 注意：不存储 FileManager 属性 —— actor 属性无法从 `??` 的
        // nonisolated autoclosure 引用（Swift 6 严格隔离）；FileManager.default
        // 是全局静态，随处可用
        let dir = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ShiGuang/Photos", isDirectory: true)
        self.directory = dir
        self.indexURL = dir.appendingPathComponent("index.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([ImportedPhoto].self, from: data) {
            index = decoded
        }
    }

    // MARK: 协议实现

    public func save(imageData: Data, preferredExtension: String = "jpg") throws -> ImportedPhoto {
        let id = UUID()
        let ext = preferredExtension.isEmpty ? "jpg" : preferredExtension
        let fileName = "\(id.uuidString).\(ext)"
        try imageData.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        let size = Self.pixelSize(of: imageData)
        let photo = ImportedPhoto(
            id: id,
            fileName: fileName,
            pixelWidth: size?.width ?? 0,
            pixelHeight: size?.height ?? 0
        )
        index.insert(photo, at: 0)
        try persistIndex()
        return photo
    }

    public func delete(_ photo: ImportedPhoto) throws {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(photo.fileName))
        index.removeAll { $0.id == photo.id }
        try persistIndex()
    }

    public func allPhotos() throws -> [ImportedPhoto] { index }

    /// 原文件 URL（nonisolated：可在后台导出任务里读取，用于按策略搬运 EXIF/IPTC/GPS）。
    public nonisolated func sourceURL(of photo: ImportedPhoto) -> URL? {
        let url = fileURL(of: photo)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public nonisolated func fullCIImage(for photo: ImportedPhoto) -> CIImage? {
        CIImage(contentsOf: fileURL(of: photo))
    }

    public nonisolated func thumbnailCGImage(for photo: ImportedPhoto, maxPixel: CGFloat = 512) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(fileURL(of: photo) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - 私有

    /// directory 为 let（Sendable）→ nonisolated 可访问。
    private nonisolated func fileURL(of photo: ImportedPhoto) -> URL {
        directory.appendingPathComponent(photo.fileName)
    }

    private nonisolated static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    private func persistIndex() throws {
        let data = try JSONEncoder().encode(index)
        try data.write(to: indexURL, options: .atomic)
    }
}

// MARK: - 导出（P2.2）

/// 导出格式。ICC Profile 随 CGImage 的色彩空间由 ImageIO 自动嵌入。
public enum ExportFormat: String, CaseIterable, Sendable, Identifiable {
    case jpeg, heif, png, tiff

    public var id: String { rawValue }

    /// ImageIO 目的地类型标识
    public var typeIdentifier: CFString {
        switch self {
        case .jpeg: return "public.jpeg" as CFString
        case .heif: return "public.heic" as CFString
        case .png: return "public.png" as CFString
        case .tiff: return "public.tiff" as CFString
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .heif: return "heic"
        case .png: return "png"
        case .tiff: return "tiff"
        }
    }

    public var isLossy: Bool { self == .jpeg || self == .heif }

    public var displayName: String {
        switch self {
        case .jpeg: return "JPEG"
        case .heif: return "HEIF"
        case .png: return "PNG"
        case .tiff: return "TIFF"
        }
    }
}

// MARK: - 导出选项（P1-5 完整版：尺寸 / 元数据 / 色彩空间 / ICC / 水印）

/// 导出尺寸策略。
public enum ExportResize: Sendable, Equatable {
    case original
    /// 长边像素（clamp 64...12000）
    case longEdge(Int)
    /// 缩放百分比（clamp 0.1...1.0）
    case percentage(Double)

    public static let longEdgePresets: [Int] = [1024, 2048, 3072, 4096]

    public var displayName: String {
        switch self {
        case .original: return "原始尺寸"
        case .longEdge(let px): return "长边 \(px) px"
        case .percentage(let p): return "\(Int((p * 100).rounded()))%"
        }
    }
}

/// 元数据保留策略（默认剔除位置：合规 C4）。
public struct ExportMetadataPolicy: Sendable, Equatable {
    /// 拍摄参数（机型 / 曝光 / 镜头等 EXIF）
    public var exif: Bool
    /// 位置信息（GPS）
    public var gps: Bool
    /// 版权 / 作者 / 关键词（IPTC）
    public var iptc: Bool

    public init(exif: Bool = true, gps: Bool = false, iptc: Bool = true) {
        self.exif = exif
        self.gps = gps
        self.iptc = iptc
    }

    public static let all = ExportMetadataPolicy(exif: true, gps: true, iptc: true)
    public static let none = ExportMetadataPolicy(exif: false, gps: false, iptc: false)
}

/// 导出色彩空间。
public enum ExportColorSpace: String, CaseIterable, Sendable {
    case sRGB
    case displayP3
    case adobeRGB1998

    public var displayName: String {
        switch self {
        case .sRGB: return "sRGB"
        case .displayP3: return "Display P3"
        case .adobeRGB1998: return "Adobe RGB"
        }
    }

    /// ICC 描述名（写入 `kCGImagePropertyProfileName`）
    public var iccName: String {
        switch self {
        case .sRGB: return "sRGB IEC61966-2.1"
        case .displayP3: return "Display P3"
        case .adobeRGB1998: return "Adobe RGB (1998)"
        }
    }

    public var cgColorSpace: CGColorSpace? {
        switch self {
        case .sRGB: return CGColorSpace(name: CGColorSpace.sRGB)
        case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)
        case .adobeRGB1998: return CGColorSpace(name: CGColorSpace.adobeRGB1998)
        }
    }
}

/// 导出水印。
public struct ExportWatermark: Sendable, Equatable {
    public enum Position: String, CaseIterable, Sendable {
        case bottomRight, bottomLeft, topRight, topLeft, center

        public var displayName: String {
            switch self {
            case .bottomRight: return "右下"
            case .bottomLeft: return "左下"
            case .topRight: return "右上"
            case .topLeft: return "左上"
            case .center: return "居中"
            }
        }
    }

    public var text: String
    public var position: Position
    /// 0.05...1
    public var opacity: Double
    /// 字号相对短边比例 0.01...0.2
    public var scale: Double

    public init(
        text: String = "拾光",
        position: Position = .bottomRight,
        opacity: Double = 0.65,
        scale: Double = 0.045
    ) {
        self.text = text
        self.position = position
        self.opacity = min(max(opacity, 0.05), 1)
        self.scale = min(max(scale, 0.01), 0.2)
    }
}

public struct ExportOptions: Sendable, Equatable {
    public var format: ExportFormat = .jpeg
    /// 0.05...1（仅对 JPEG/HEIC 有效）
    public var quality: Double = 0.9
    public var resize: ExportResize = .original
    public var colorSpace: ExportColorSpace = .sRGB
    public var metadata: ExportMetadataPolicy = ExportMetadataPolicy()
    /// true：附带具名 ICC 描述；false：按设备 RGB 输出，不写 ICC 描述（交阅读器按 sRGB 默认解释）
    public var embedICCProfile: Bool = true
    public var watermark: ExportWatermark?

    public init(
        format: ExportFormat = .jpeg,
        quality: Double = 0.9,
        resize: ExportResize = .original,
        colorSpace: ExportColorSpace = .sRGB,
        metadata: ExportMetadataPolicy = ExportMetadataPolicy(),
        embedICCProfile: Bool = true,
        watermark: ExportWatermark? = nil
    ) {
        self.format = format
        self.quality = min(max(quality, 0.05), 1)
        self.resize = resize
        self.colorSpace = colorSpace
        self.metadata = metadata
        self.embedICCProfile = embedICCProfile
        self.watermark = watermark
    }

    /// 目标像素尺寸（纯计算，可单测）：`original` 或无效输入回落到原尺寸。
    public func targetPixelSize(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (width, height) }
        switch resize {
        case .original:
            return (width, height)
        case .longEdge(let px):
            let target = min(max(px, 64), 12000)
            let maxDim = max(width, height)
            guard maxDim != target else { return (width, height) }
            // 只降不升：目标长边大于原图时保持原尺寸（放大不会带来细节，只会白白变大）
            let scale = min(Double(target) / Double(maxDim), 1)
            return (
                max(1, Int((Double(width) * scale).rounded())),
                max(1, Int((Double(height) * scale).rounded()))
            )
        case .percentage(let p):
            let clamped = min(max(p, 0.1), 1.0)  // 10%...100%，超过 100% 视为原尺寸
            guard clamped < 0.999 else { return (width, height) }
            return (
                max(1, Int((Double(width) * clamped).rounded())),
                max(1, Int((Double(height) * clamped).rounded()))
            )
        }
    }

    /// 无尺寸 / 无色彩转换、无水印时可直接直通原图（避免无谓重采样）。
    public func needsPixelPass(currentColorSpaceName: String) -> Bool {
        if resize != .original { return true }
        if watermark != nil { return true }
        guard embedICCProfile else { return true }
        return colorSpace.iccName != currentColorSpaceName
    }
}

public enum PhotoExporter {
    /// 写盘（P1-5：尺寸 / 色彩空间 / 元数据 / ICC / 水印 全部落地）。
    /// - Parameter originalURL: 原始文件 URL，用于按策略搬运 EXIF/IPTC/GPS（可选）。
    public static func write(
        _ image: CGImage,
        options: ExportOptions,
        to url: URL,
        originalURL: URL? = nil
    ) throws {
        let composed = compose(image, options: options)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, options.format.typeIdentifier, 1, nil
        ) else {
            throw PhotoExportError.cannotCreateDestination
        }
        let properties = outputProperties(options: options, originalURL: originalURL)
        CGImageDestinationAddImage(destination, composed, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoExportError.cannotFinalize
        }
    }

    /// 导出到临时目录（分享 / 存储到"文件"用），返回文件 URL。
    /// 文件名带 UUID：并行导出/测试互不覆盖。
    public static func exportToTemporary(
        _ image: CGImage,
        options: ExportOptions,
        fileName: String = "ShiGuang",
        originalURL: URL? = nil
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(fileName)-\(UUID().uuidString)")
            .appendingPathExtension(options.format.fileExtension)
        try write(image, options: options, to: url, originalURL: originalURL)
        return url
    }

    /// 本次导出实际写入的 ImageIO 属性字典（纯函数，供单测与 UI 说明）。
    /// - 元数据策略决定 EXIF / IPTC / GPS 三个字典的取舍；
    /// - 无论策略如何，都会写入 Software 标识（合规：导出件可溯源）；
    /// - 方向恒为 1（像素已摆正，避免阅读器二次旋转）；
    /// - `embedICCProfile` 为真时写入具名 ICC 描述。
    public static func outputProperties(
        options: ExportOptions,
        originalURL: URL? = nil
    ) -> [CFString: Any] {
        var properties: [CFString: Any] = [:]
        if options.format.isLossy {
            properties[kCGImageDestinationLossyCompressionQuality] = options.quality
        }
        properties[kCGImagePropertyOrientation] = 1
        if options.embedICCProfile {
            properties[kCGImagePropertyProfileName] = options.colorSpace.iccName
        }

        var exif: [CFString: Any] = [kCGImagePropertyExifSoftware: softwareTag]
        var iptc: [CFString: Any] = [:]
        var gps: [CFString: Any] = [:]

        if let originalURL,
           let source = CGImageSourceCreateWithURL(originalURL as CFURL, nil),
           let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            if options.metadata.exif,
               let sourceExif = sourceProperties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                for (key, value) in sourceExif where key != kCGImagePropertyExifSoftware {
                    exif[key] = value
                }
            }
            if options.metadata.iptc,
               let sourceIPTC = sourceProperties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
                iptc = sourceIPTC
            }
            if options.metadata.gps,
               let sourceGPS = sourceProperties[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
                gps = sourceGPS
            }
        }

        properties[kCGImagePropertyExifDictionary] = exif
        if !iptc.isEmpty { properties[kCGImagePropertyIPTCDictionary] = iptc }
        if !gps.isEmpty { properties[kCGImagePropertyGPSDictionary] = gps }
        return properties
    }

    /// 导出件溯源标识。
    static let softwareTag = "拾光 ShiGuang"
}

extension PhotoExporter {
    /// 尺寸 / 色彩空间 / 水印 合成；无需处理时直通原图（零重采样）。
    static func compose(_ image: CGImage, options: ExportOptions) -> CGImage {
        let target = options.targetPixelSize(width: image.width, height: image.height)
        guard options.needsPixelPass(currentColorSpaceName: colorSpaceName(image.colorSpace)) else {
            return image
        }
        let space: CGColorSpace? = options.embedICCProfile
            ? (options.colorSpace.cgColorSpace ?? image.colorSpace)
            : CGColorSpaceCreateDeviceRGB()
        guard let space,
              let context = CGContext(
                data: nil,
                width: target.width,
                height: target.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        if let watermark = options.watermark, !watermark.text.isEmpty {
            draw(watermark, in: context)
        }
        return context.makeImage() ?? image
    }

    /// 水印绘制：白色文字 + 指定不透明度，边距取短边 3%。
    static func draw(_ watermark: ExportWatermark, in context: CGContext) {
        let width = Double(context.width)
        let height = Double(context.height)
        let shortSide = min(width, height)
        let fontSize = max(shortSide * watermark.scale, 8)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: watermark.text, attributes: attributes)
        )
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let margin = shortSide * 0.03
        var x = margin - Double(bounds.minX)
        var y = margin - Double(bounds.minY)
        switch watermark.position {
        case .bottomRight:
            x = width - margin - Double(bounds.maxX)
        case .bottomLeft:
            break
        case .topRight:
            x = width - margin - Double(bounds.maxX)
            y = height - margin - Double(bounds.maxY)
        case .topLeft:
            y = height - margin - Double(bounds.maxY)
        case .center:
            x = (width - Double(bounds.width)) / 2 - Double(bounds.minX)
            y = (height - Double(bounds.height)) / 2 - Double(bounds.minY)
        }
        context.saveGState()
        context.setAlpha(watermark.opacity)
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// CGColorSpace 名称；无颜色空间返回空串。
    static func colorSpaceName(_ space: CGColorSpace?) -> String {
        guard let space, let name = space.name else { return "" }
        return name as String
    }
}
