import Testing
import Foundation
import CoreGraphics
import ImageIO
import PhotoIO

// MARK: - 导出器测试（真写盘）

@Suite struct PhotoExporterTests {
    /// 造一张 8x8 纯色图（与 RenderKitTests 同款工具，避免跨 target 依赖）
    private func makeImage(width: Int = 8, height: Int = 8) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4] = 200
            pixels[i * 4 + 1] = 120
            pixels[i * 4 + 2] = 60
            pixels[i * 4 + 3] = 255
        }
        let image = pixels.withUnsafeMutableBytes { ptr -> CGImage? in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return ctx.makeImage()
        }
        guard let image else {
            Issue.record("无法创建测试图")
            return CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!.makeImage()!
        }
        return image
    }

    @Test func jpegExportRoundTrip() throws {
        let options = ExportOptions(format: .jpeg, quality: 0.9)
        let url = try PhotoExporter.exportToTemporary(makeImage(), options: options)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.pathExtension == "jpg")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.size] as? Int ?? 0) > 0)

        // 解码回读：尺寸一致（用 Data 读回避免文件句柄竞态）
        let data = try Data(contentsOf: url)
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        #expect(source != nil)
        if let source,
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            #expect(props[kCGImagePropertyPixelWidth] as? Int == 8)
            #expect(props[kCGImagePropertyPixelHeight] as? Int == 8)
        }
    }

    @Test func allFormatsWriteSuccessfully() throws {
        for format in ExportFormat.allCases {
            let options = ExportOptions(format: format, quality: 0.8)
            let url = try PhotoExporter.exportToTemporary(makeImage(), options: options)
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(url.pathExtension == format.fileExtension)
        }
    }

    @Test func qualityClamped() {
        #expect(ExportOptions(format: .jpeg, quality: 5).quality == 1)
        #expect(ExportOptions(format: .jpeg, quality: -1).quality == 0.05)
    }

    @Test func highQualityLargerThanLow() throws {
        let high = try PhotoExporter.exportToTemporary(
            makeImage(width: 64, height: 64),
            options: ExportOptions(format: .jpeg, quality: 1))
        let low = try PhotoExporter.exportToTemporary(
            makeImage(width: 64, height: 64),
            options: ExportOptions(format: .jpeg, quality: 0.05))
        defer {
            try? FileManager.default.removeItem(at: high)
            try? FileManager.default.removeItem(at: low)
        }
        let highSize = try FileManager.default.attributesOfItem(atPath: high.path)[.size] as? Int ?? 0
        let lowSize = try FileManager.default.attributesOfItem(atPath: low.path)[.size] as? Int ?? 0
        #expect(highSize >= lowSize)
    }
}
