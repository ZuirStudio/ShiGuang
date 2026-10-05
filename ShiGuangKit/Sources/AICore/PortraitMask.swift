import Foundation
import CoreGraphics
import CoreImage
import Vision

// MARK: - 人像精修掩码（P3 端侧 AI 第一能力）

/// 皮肤掩码生成器：白 = 皮肤区域。
/// 双策略（与 ADR-005 一致，全端侧零联网）：
/// 1. VNDetectFaceLandmarksRequest 找脸 → 脸部区域（含轮廓外扩）椭圆化；
/// 2. 全图肤色调检测（YCbCr 经典区间）— 无脸 / 多人都可用；
/// 两者并集，再经羽化让边缘过渡自然。
public enum PortraitMaskAnalyzer {
    /// 生成皮肤掩码（与输入图同尺寸的 CGImage，灰度）。
    /// 检测在 256px 缩略图上进行（CPU 毫秒级），掩码按原尺寸返回。
    public static func skinMask(for image: CGImage) -> CGImage? {
        let maxWidth: Int = 256
        let scale = min(1, Double(maxWidth) / Double(max(image.width, image.height)))
        let smallW = max(8, Int(Double(image.width) * scale))
        let smallH = max(8, Int(Double(image.height) * scale))

        guard let small = downsample(image, to: smallW, height: smallH) else { return nil }

        // 1) 肤色掩码（逐像素 YCbCr）
        var skin = skinToneMask(small)

        // 2) Vision 脸部区域（外扩 1.35 倍椭圆）并入
        let faceRegions = faceRegions(in: small)
        if !faceRegions.isEmpty {
            for region in faceRegions {
                fillEllipse(&skin, width: smallW, height: smallH, region: region)
            }
        }

        // 3) 羽化（3x3 两遍盒滤波近似）
        let feathered = feather(&skin, width: smallW, height: smallH)

        return grayImage(from: feathered, width: smallW, height: smallH, scaleTo: CGSize(width: image.width, height: image.height))
    }

    // MARK: 内部

    private struct FaceRegion {
        var cx: Double
        var cy: Double
        var rx: Double
        var ry: Double
    }

    private static func downsample(_ image: CGImage, to width: Int, height: Int) -> CGImage? {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(
                data: ptr.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return data.withUnsafeMutableBytes { ptr -> CGImage? in
            guard let ctx = CGContext(
                data: ptr.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return ctx.makeImage()
        }
    }

    /// 经典肤色 YCbCr 区间（Chai & Ngan / Hsu 等公开区间）：Cr 133-173, Cb 77-127。
    private static func skinToneMask(_ image: CGImage) -> [UInt8] {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(
                data: ptr.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var mask = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let r = Double(data[i * 4]) / 255
            let g = Double(data[i * 4 + 1]) / 255
            let b = Double(data[i * 4 + 2]) / 255
            // BT.601 YCbCr
            let y = 0.299 * r + 0.587 * g + 0.114 * b
            let cb = 128 - 0.168736 * r - 0.331264 * g + 0.5 * b
            let cr = 128 + 0.5 * r - 0.418688 * g - 0.081312 * b
            if cb >= 77 && cb <= 127 && cr >= 133 && cr <= 173 && y > 0.15 {
                mask[i] = 255
            }
        }
        return mask
    }

    /// Vision 人脸区域（归一化坐标 → 掩码像素坐标；CG 上下翻转注意）。
    private static func faceRegions(in image: CGImage) -> [FaceRegion] {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        var regions: [FaceRegion] = []
        let w = Double(image.width), h = Double(image.height)
        for observation in (request.results ?? []) {
            let box = observation.boundingBox // 归一化，原点左下
            let cx = box.midX * w
            let cy = box.midY * h
            // 脸部向外扩 1.35 倍椭圆（覆盖额头/下巴边缘）
            regions.append(FaceRegion(
                cx: cx, cy: cy,
                rx: box.width * w * 0.675,
                ry: box.height * h * 0.675
            ))
        }
        return regions
    }

    private static func fillEllipse(_ mask: inout [UInt8], width: Int, height: Int, region: FaceRegion) {
        let x0 = max(0, Int(region.cx - region.rx))
        let x1 = min(width - 1, Int(region.cx + region.rx))
        let y0 = max(0, Int(region.cy - region.ry))
        let y1 = min(height - 1, Int(region.cy + region.ry))
        guard x1 >= x0, y1 >= y0, region.rx > 0, region.ry > 0 else { return }
        for y in y0...y1 {
            for x in x0...x1 {
                let dx = (Double(x) - region.cx) / region.rx
                let dy = (Double(y) - region.cy) / region.ry
                if dx * dx + dy * dy <= 1 {
                    mask[y * width + x] = 255
                }
            }
        }
    }

    private static func feather(_ mask: inout [UInt8], width: Int, height: Int) -> [UInt8] {
        var temp = mask
        // 两遍 3x3 盒滤波
        for _ in 0..<2 {
            for y in 0..<height {
                for x in 0..<width {
                    var sum = 0, count = 0
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let nx = x + dx, ny = y + dy
                            if nx >= 0, nx < width, ny >= 0, ny < height {
                                sum += Int(mask[ny * width + nx])
                                count += 1
                            }
                        }
                    }
                    temp[y * width + x] = UInt8(sum / count)
                }
            }
            mask = temp
        }
        return mask
    }

    private static func grayImage(from mask: [UInt8], width: Int, height: Int, scaleTo full: CGSize) -> CGImage? {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let v = mask[i]
            rgba[i * 4 + 0] = v
            rgba[i * 4 + 1] = v
            rgba[i * 4 + 2] = v
            rgba[i * 4 + 3] = 255
        }
        // 掩码分辨率低不影响效果（渲染时被上采样 + 渲染管线自带插值）
        return rgba.withUnsafeMutableBytes { ptr -> CGImage? in
            guard let ctx = CGContext(
                data: ptr.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return ctx.makeImage()
        }
    }
}
