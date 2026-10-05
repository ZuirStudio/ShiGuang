import CoreImage
import CoreGraphics
import EditKit

// MARK: - 图像分析（AutoTune 的数据源）

/// 从 CIImage 提取统计快照：64px 缩略 + CPU 逐像素统计（几毫秒级，主线程可用）。
public enum ImageAnalyzer {
    public static func analyze(_ image: CIImage, context: CIContext) -> ImageStats? {
        // 1) 长边缩到 64px
        let maxDim = max(image.extent.width, image.extent.height)
        guard maxDim > 0 else { return nil }
        let scale = min(1, 64 / maxDim)
        let thumb = scale < 1
            ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : image

        guard let cg = context.createCGImage(thumb, from: thumb.extent) else { return nil }

        // 2) 读像素
        let width = cg.width, height = cg.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var stats: ImageStats?
        pixels.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        // 3) 统计
        var lumas: [Double] = []
        lumas.reserveCapacity(width * height)
        var sumR: Double = 0, sumG: Double = 0, sumB: Double = 0
        var sumChroma: Double = 0
        let count = width * height
        for i in 0..<count {
            let r = Double(pixels[i * 4]) / 255
            let g = Double(pixels[i * 4 + 1]) / 255
            let b = Double(pixels[i * 4 + 2]) / 255
            sumR += r; sumG += g; sumB += b
            lumas.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
            sumChroma += max(r, g, b) - min(r, g, b)
        }
        let sorted = lumas.sorted()
        func percentile(_ p: Double) -> Double {
            let idx = min(max(Int(p * Double(count - 1)), 0), count - 1)
            return sorted[idx]
        }
        stats = ImageStats(
            medianLuma: percentile(0.5),
            p05Luma: percentile(0.05),
            p95Luma: percentile(0.95),
            meanR: sumR / Double(count),
            meanG: sumG / Double(count),
            meanB: sumB / Double(count),
            meanChroma: sumChroma / Double(count)
        )
        return stats
    }
}
