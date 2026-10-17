import Testing
import Foundation
import CoreImage
import CoreGraphics
@testable import EditKit
@testable import RenderKit

// MARK: - R007d P0-D：渲染层掩码有效性门（skinSmoothed / skinBrightening）

private let skinTestSize = 96

/// 硬边二分位图生成器：`leftValue` 铺左半、`rightValue` 铺右半（0…255）。
/// 源图用「左 128 右 255」—— 左半非纯黑，使「掩码被接受」与「掩码被忽略」
/// 两种分支在任何渲染环境下都产出不同像素（CI 软件渲染器下 CIClamp +
/// CIGaussianBlur 链出不了位图，见 MaskBlendDiagnosticTests 取证注释，
/// 因此断言**不依赖模糊的绝对数值**，只做自 oracle 对照）。
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

    /// 有效掩码：白区权重 1.0（与全白掩码渲染逐像素一致）、黑区原样不动。
    ///
    /// 为什么用自 oracle 对照而不是绝对数值：CI 软件渲染环境下
    /// `CIClamp + CIGaussianBlur` 链出不了位图（MaskBlendDiagnosticTests
    /// 已取证），模糊的具体数值随环境而变；但「同一张源图、同一个 graph、
    /// 只换掩码」的两次渲染在白区必须逐像素一致（权重都是 1.0），
    /// 这个性质与环境无关。它同时能抓住「门控把有效掩码误判为无效」
    /// （那样输出会等于源图，与全白掩码渲染在左半 128 vs 模糊值不等）。
    @Test func validMaskAppliesInsideOnly() throws {
        let source = try #require(makeHalfSplitImage(size: skinTestSize, left: 128, right: 255))
        let half = try #require(makeHalfSplitImage(size: skinTestSize, left: 255, right: 0))
        let white = try #require(makeHalfSplitImage(size: skinTestSize, left: 255, right: 255))
        var graph = EditGraph()
        graph.append(.skinSmoothing(100))
        let src = CIImage(cgImage: source)
        let outValid = BasicAdjustmentRenderer(skinMask: CIImage(cgImage: half))
            .render(source: src, graph: graph)
        let outFull = BasicAdjustmentRenderer(skinMask: CIImage(cgImage: white))
            .render(source: src, graph: graph)
        // ① 掩码白区（左半，含边界附近）== 全白掩码渲染：门控接受了掩码且权重拉满
        for nx in [0.06, 0.25, 0.45] {
            let a = try #require(skinTestGray(outValid, size: skinTestSize, nx: nx))
            let b = try #require(skinTestGray(outFull, size: skinTestSize, nx: nx))
            #expect(abs(a - b) <= 1, "nx=\(nx)：掩码白区应与全权重效果一致（\(a) vs \(b)）")
        }
        // ② 掩码黑区（右半）== 源图：效果不外溢
        for nx in [0.55, 0.75, 0.95] {
            let a = try #require(skinTestGray(outValid, size: skinTestSize, nx: nx))
            let s = try #require(skinTestGray(src, size: skinTestSize, nx: nx))
            #expect(abs(a - s) <= 2, "nx=\(nx)：掩码黑区必须原样（\(a) vs \(s)）")
        }
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
