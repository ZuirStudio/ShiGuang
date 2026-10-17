import Testing
import Foundation
import CoreImage
import CoreGraphics
@testable import EditKit
@testable import RenderKit

// MARK: - R007d P0-D：渲染层掩码有效性门（skinSmoothed / skinBrightening）

private let skinTestSize = 96

/// 硬边二分位图生成器：`leftValue` 铺左半、`rightValue` 铺右半（0…255）。
/// 源图用「左黑右白」—— 磨皮（高斯模糊）只有在掩码白区内、且靠近黑白边界时
/// 才会改变像素，于是「效果只在掩码内生效」与「掩码无效时原图返回」都可像素级断言。
private func makeHalfSplitImage(size: Int, left: UInt8, right: UInt8) -> CGImage? {
    var bytes = [UInt8](repeating: 0, count: size * size * 4)
    for row in 0..<size {
        for col in 0..<size {
            let i = (row * size + col) * 4
            let v: UInt8 = col < size / 2 ? left : right
            bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v; bytes[i + 3] = 255
        }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
        width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )
}

/// 全黑不透明掩码（另一种「无效掩码」形态：非空 extent 但无任何生效区域）。
private func makeAllBlackImage(size: Int) -> CGImage? {
    makeHalfSplitImage(size: size, left: 0, right: 0)
}

/// 软件渲染器出图（CI 无 GPU 环境下确定可用）。
private func skinTestBytes(_ image: CIImage, size: Int) -> [UInt8]? {
    var bytes = [UInt8](repeating: 0, count: size * size * 4)
    let ctx = CIContext(options: [.useSoftwareRenderer: true])
    let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return false }
        ctx.render(image, toBitmap: base, rowBytes: size * 4,
                   bounds: CGRect(x: 0, y: 0, width: size, height: size),
                   format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return true
    }
    return ok ? bytes : nil
}

/// 归一化坐标采样（左上原点）→ 灰度 0…255。
private func skinTestGray(_ image: CIImage, size: Int, nx: Double, ny: Double = 0.5) -> Int? {
    guard let bytes = skinTestBytes(image, size: size) else { return nil }
    let col = min(max(Int(nx * Double(size)), 0), size - 1)
    let row = min(max(Int(ny * Double(size)), 0), size - 1)
    return Int(bytes[(row * size + col) * 4])
}

@Suite("R007d P0-D：皮肤掩码有效性门")
struct SkinMaskValidityTests {

    /// 有效掩码：白区内靠近边界处被模糊（效果确实落在掩码内），
    /// 掩码外原样不动（效果不外溢），白区内远离边界处黑侧模糊恒等。
    @Test func validMaskAppliesInsideOnly() throws {
        let source = try #require(makeHalfSplitImage(size: skinTestSize, left: 0, right: 255))
        let mask = try #require(makeHalfSplitImage(size: skinTestSize, left: 255, right: 0))
        var graph = EditGraph()
        graph.append(.skinSmoothing(100))
        let renderer = BasicAdjustmentRenderer(skinMask: CIImage(cgImage: mask))
        let output = renderer.render(source: CIImage(cgImage: source), graph: graph)
        // 掩码内、距黑白边界 4.8px：模糊把白侧拉进来 → 明显高于源图的 0
        #expect(try #require(skinTestGray(output, size: skinTestSize, nx: 0.45)) > 20)
        // 掩码外：仍为纯白（不外溢）
        #expect(try #require(skinTestGray(output, size: skinTestSize, nx: 0.75)) == 255)
        // 掩码内远离边界：黑侧模糊恒等，仍为 0
        #expect(try #require(skinTestGray(output, size: skinTestSize, nx: 0.06)) == 0)
    }

    /// 用户原话落地：「没有传入有效（非空、非全黑）的 mask，直接 return image 原图」。
    /// 全黑掩码 → 输出与源图逐点一致（连边界处也不许被模糊）。
    @Test func allBlackMaskReturnsOriginal() throws {
        let source = try #require(makeHalfSplitImage(size: skinTestSize, left: 0, right: 255))
        let black = try #require(makeAllBlackImage(size: skinTestSize))
        var graph = EditGraph()
        graph.append(.skinSmoothing(100))
        let renderer = BasicAdjustmentRenderer(skinMask: CIImage(cgImage: black))
        let output = renderer.render(source: CIImage(cgImage: source), graph: graph)
        #expect(try #require(skinTestGray(output, size: skinTestSize, nx: 0.45)) == 0)
        #expect(try #require(skinTestGray(output, size: skinTestSize, nx: 0.75)) == 255)
    }

    /// 空 extent 掩码（掩码腐化的另一形态）→ 同样原图返回，不崩不花。
    @Test func emptyExtentMaskReturnsOriginal() throws {
        let source = try #require(makeHalfSplitImage(size: skinTestSize, left: 0, right: 255))
        let empty = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 0, height: 0))
        var graph = EditGraph()
        graph.append(.skinSmoothing(100))
        let renderer = BasicAdjustmentRenderer(skinMask: empty)
        let output = renderer.render(source: CIImage(cgImage: source), graph: graph)
        #expect(try #require(skinTestGray(output, size: skinTestSize, nx: 0.45)) == 0)
        #expect(try #require(skinTestGray(output, size: skinTestSize, nx: 0.75)) == 255)
    }

    /// 美白链路同一道门（skinBrightened 与 skinSmoothed 对称）。
    @Test func allBlackMaskBlocksBrighteningToo() throws {
        let source = try #require(makeHalfSplitImage(size: skinTestSize, left: 0, right: 255))
        let black = try #require(makeAllBlackImage(size: skinTestSize))
        var graph = EditGraph()
        graph.append(.skinBrightening(100))
        let renderer = BasicAdjustmentRenderer(skinMask: CIImage(cgImage: black))
        let output = renderer.render(source: CIImage(cgImage: source), graph: graph)
        #expect(try #require(skinTestGray(output, size: skinTestSize, nx: 0.75)) == 255)
        #expect(try #require(skinTestGray(output, size: skinTestSize, nx: 0.45)) == 0)
    }

    /// 既有语义回归：skinMask = nil 时皮肤项恒等（v0.7.0 以来的硬保证不破）。
    @Test func nilMaskStaysIdentity() throws {
        let source = try #require(makeHalfSplitImage(size: skinTestSize, left: 0, right: 255))
        var graph = EditGraph()
        graph.append(.skinSmoothing(80))
        graph.append(.skinBrightening(60))
        let renderer = BasicAdjustmentRenderer(skinMask: nil)
        let output = renderer.render(source: CIImage(cgImage: source), graph: graph)
        #expect(try #require(skinTestGray(output, size: skinTestSize, nx: 0.45)) == 0)
        #expect(try #require(skinTestGray(output, size: skinTestSize, nx: 0.75)) == 255)
    }
}
