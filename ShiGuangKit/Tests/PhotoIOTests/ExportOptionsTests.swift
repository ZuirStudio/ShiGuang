import Testing
import Foundation
import CoreGraphics
import ImageIO
import PhotoIO

/// P1-5 导出面板内核：每一项用户可见选项至少一条用例。
/// 全部只走公开 API；夹具在文件末尾的 `extension ExportOptionsTests` 里。
@Suite(.serialized)
struct ExportOptionsTests {

    // MARK: - 尺寸

    @Test func longEdgeResizesProportionally() {
        let size = ExportOptions(resize: .longEdge(320)).targetPixelSize(width: 640, height: 320)
        #expect(size.width == 320)
        #expect(size.height == 160)
    }

    @Test func longEdgeNeverUpscales() {
        let size = ExportOptions(resize: .longEdge(4096)).targetPixelSize(width: 64, height: 32)
        #expect(size.width == 64)
        #expect(size.height == 32)
    }

    @Test func longEdgeIsClampedAt64() {
        let size = ExportOptions(resize: .longEdge(1)).targetPixelSize(width: 1000, height: 500)
        #expect(size.width == 64)
        #expect(size.height == 32)
    }

    @Test func percentageResizes() {
        let size = ExportOptions(resize: .percentage(0.5)).targetPixelSize(width: 64, height: 32)
        #expect(size.width == 32)
        #expect(size.height == 16)
    }

    @Test func percentageIsClampedAt10Percent() {
        let size = ExportOptions(resize: .percentage(0.01)).targetPixelSize(width: 1000, height: 500)
        #expect(size.width == 100)
        #expect(size.height == 50)
    }

    @Test func originalKeepsPixels() {
        let size = ExportOptions(resize: .original).targetPixelSize(width: 64, height: 32)
        #expect(size.width == 64)
        #expect(size.height == 32)
    }

    @Test func resizeReachesTheFile() throws {
        let image = try Self.makeImage(width: 256, height: 128, gray: 0.5)
        let options = ExportOptions(format: .png, resize: .longEdge(128))
        let url = try PhotoExporter.exportToTemporary(image, options: options, fileName: "resize-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let size = try Self.decode(url)
        #expect(size.width == 128)
        #expect(size.height == 64)
    }

    // MARK: - 元数据

    @Test func metadataCarriesExifAndIPTCButNotGPS() throws {
        let source = try Self.makeSourceJPEG(withGPS: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let properties = PhotoExporter.outputProperties(
            options: ExportOptions(metadata: ExportMetadataPolicy()),
            originalURL: source
        )
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect((exif?[kCGImagePropertyExifLensModel] as? String) == "TestLens 50mm")
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        #expect((iptc?[kCGImagePropertyIPTCCopyrightNotice] as? String) == "拾光测试")
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test func gpsIsCarriedWhenOptedIn() throws {
        let source = try Self.makeSourceJPEG(withGPS: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let policy = ExportMetadataPolicy(exif: true, gps: true, iptc: true)
        let properties = PhotoExporter.outputProperties(
            options: ExportOptions(metadata: policy),
            originalURL: source
        )
        #expect(properties[kCGImagePropertyGPSDictionary] != nil)
    }

    @Test func exifStrippedWhenDisabled() throws {
        let source = try Self.makeSourceJPEG(withGPS: false)
        defer { try? FileManager.default.removeItem(at: source) }
        let policy = ExportMetadataPolicy(exif: false, gps: false, iptc: false)
        let properties = PhotoExporter.outputProperties(
            options: ExportOptions(metadata: policy),
            originalURL: source
        )
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifLensModel] == nil)
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect((tiff?[kCGImagePropertyTIFFSoftware] as? String) == "拾光 ShiGuang")
    }

    @Test func orientationIsNormalizedToUpright() {
        let properties = PhotoExporter.outputProperties(options: ExportOptions())
        #expect((properties[kCGImagePropertyOrientation] as? Int) == 1)
    }

    // MARK: - 色彩空间 / ICC

    @Test func iccNameWrittenForDisplayP3() {
        let options = ExportOptions(colorSpace: .displayP3, embedICCProfile: true)
        let properties = PhotoExporter.outputProperties(options: options)
        #expect((properties[kCGImagePropertyProfileName] as? String) == "Display P3")
    }

    @Test func iccIgnoredWhenEmbeddingDisabled() {
        let options = ExportOptions(colorSpace: .displayP3, embedICCProfile: false)
        let properties = PhotoExporter.outputProperties(options: options)
        #expect(properties[kCGImagePropertyProfileName] == nil)
    }

    @Test func displayP3ExportProducesReadableFile() throws {
        let image = try Self.makeImage(width: 48, height: 32, gray: 0.35)
        let options = ExportOptions(format: .png, colorSpace: .displayP3, embedICCProfile: true)
        let url = try PhotoExporter.exportToTemporary(image, options: options, fileName: "p3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let size = try Self.decode(url)
        #expect(size.width == 48)
        #expect(size.height == 32)
    }

    // MARK: - 水印

    @Test func watermarkBurnsWhitePixelsIntoBottomRight() throws {
        let image = try Self.makeImage(width: 240, height: 240, gray: 0.2)
        let mark = ExportWatermark(text: "SG", position: .bottomRight, opacity: 1, scale: 0.15)
        let options = ExportOptions(format: .png, watermark: mark)
        let url = try PhotoExporter.exportToTemporary(image, options: options, fileName: "wm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let pixels = try Self.pixels(of: url)
        #expect(Self.countWhite(pixels, width: 240, height: 240, quadrant: .bottomRight) > 0)
        #expect(Self.countWhite(pixels, width: 240, height: 240, quadrant: .topLeft) == 0)
    }

    @Test func watermarkClampsOpacityAndScale() {
        let mark = ExportWatermark(text: "x", position: .center, opacity: 9, scale: 9)
        #expect(mark.opacity == 1)
        #expect(mark.scale == 0.2)
    }

    @Test func withoutWatermarkNoWhitePixels() throws {
        let image = try Self.makeImage(width: 240, height: 240, gray: 0.2)
        let url = try PhotoExporter.exportToTemporary(image, options: ExportOptions(format: .png), fileName: "nowm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let pixels = try Self.pixels(of: url)
        #expect(Self.countWhite(pixels, width: 240, height: 240, quadrant: .bottomRight) == 0)
        #expect(Self.countWhite(pixels, width: 240, height: 240, quadrant: .topLeft) == 0)
    }

    // MARK: - 选项透传

    @Test func everyOptionSurvivesInitializer() {
        let mark = ExportWatermark(text: "拾光", position: .topLeft, opacity: 0.5, scale: 0.06)
        let policy = ExportMetadataPolicy(exif: false, gps: true, iptc: false)
        let options = ExportOptions(
            format: .tiff,
            quality: 0.42,
            resize: .percentage(0.75),
            colorSpace: .adobeRGB1998,
            metadata: policy,
            embedICCProfile: false,
            watermark: mark
        )
        #expect(options.format == .tiff)
        #expect(options.quality == 0.42)
        #expect(options.resize == .percentage(0.75))
        #expect(options.colorSpace == .adobeRGB1998)
        #expect(options.metadata == policy)
        #expect(options.embedICCProfile == false)
        #expect(options.watermark == mark)
    }
}

// MARK: - 夹具（全部自建，不依赖真机资源）

extension ExportOptionsTests {

    enum FixtureError: Error {
        case contextUnavailable
        case decodeFailed
    }

    enum Quadrant {
        case topLeft
        case bottomRight
    }

    /// 纯灰测试图（sRGB，8bpc RGBA，行序自上而下）。
    static func makeImage(width: Int, height: Int, gray: Double) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw FixtureError.contextUnavailable }
        let value = min(max(gray, 0), 1)
        context.setFillColor(CGColor(red: value, green: value, blue: value, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw FixtureError.contextUnavailable }
        return image
    }

    /// 回读导出文件的像素尺寸（走 Data，避开文件句柄竞态）。
    static func decode(_ url: URL) throws -> (width: Int, height: Int) {
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw FixtureError.decodeFailed
        }
        return (image.width, image.height)
    }

    /// 把导出文件解码成 8bpc RGBA 像素缓冲（缓冲区首行 = 图像顶行）。
    static func pixels(of url: URL) throws -> [UInt8] {
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw FixtureError.decodeFailed
        }
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw FixtureError.contextUnavailable }
        return buffer
    }

    /// 统计指定象限内接近纯白的像素数（水印是白色文字）。
    static func countWhite(_ pixels: [UInt8], width: Int, height: Int, quadrant: Quadrant) -> Int {
        var count = 0
        for y in 0..<height {
            let rowMatches = quadrant == .topLeft ? y < height / 2 : y >= height / 2
            guard rowMatches else { continue }
            for x in 0..<width {
                let columnMatches = quadrant == .topLeft ? x < width / 2 : x >= width / 2
                guard columnMatches else { continue }
                let index = (y * width + x) * 4
                if pixels[index] > 240, pixels[index + 1] > 240, pixels[index + 2] > 240 {
                    count += 1
                }
            }
        }
        return count
    }

    /// 造一张带 EXIF / IPTC（可选 GPS）的 JPEG，作为「原图」供元数据搬运测试。
    static func makeSourceJPEG(withGPS: Bool) throws -> URL {
        let image = try makeImage(width: 40, height: 40, gray: 0.4)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-\(UUID().uuidString)")
            .appendingPathExtension("jpg")
        let exif: [CFString: Any] = [
            kCGImagePropertyExifLensModel: "TestLens 50mm",
            kCGImagePropertyExifFNumber: 4.0,
            kCGImagePropertyExifDateTimeOriginal: "2026:10:10 20:00:00"
        ]
        var properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCopyrightNotice: "拾光测试"],
            kCGImagePropertyOrientation: 1
        ]
        if withGPS {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 39.9042,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 116.4074,
                kCGImagePropertyGPSLongitudeRef: "E"
            ]
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.jpeg" as CFString, 1, nil
        ) else { throw FixtureError.contextUnavailable }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.decodeFailed }
        return url
    }
}
