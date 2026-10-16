import Testing
import Foundation
import CoreImage
import CoreGraphics
@testable import EditKit
@testable import RenderKit

// MARK: - P0-B 取证与回归：人像掩码与背景尺寸不匹配

/// 缩略图尺度（App 层 presetThumbnail side 60 → 60*3 = 180 长边）
private let thumbExtent = CGRect(x: 0, y: 0, width: 180, height: 135)

/// 「右半白、左半黑」掩码：用来判断掩码**几何**是否被正确搬运。
/// 只裁不缩的做法会取到左上角（全黑），正确缩放则右半为白。
///
/// 掩码形态说明：**不透明 RGBA**（AICore `makeOpaqueGray` / MaskRenderer 的渐变掩码都是这个形态）。
/// `grayChannelMaskSemantics` 用例证明单通道灰度源经 `MaskFit.canonical` 规整后结果等价。
private func rightHalfWhiteMask(width: Int, height: Int) -> CIImage? {
    guard let ctx = CGContext(data: nil, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
    guard let cg = ctx.makeImage() else { return nil }
    return CIImage(cgImage: cg)
}

/// 单通道灰度掩码（取证用：进 kernel 前会被 `MaskFit.canonical` 规整成三通道）。
private func grayChannelMask(width: Int, height: Int) -> CIImage? {
    guard let ctx = CGContext(data: nil, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.setFillColor(gray: 0, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
    guard let cg = ctx.makeImage() else { return nil }
    return CIImage(cgImage: cg)
}

/// 棋盘纹理源图：磨皮需要高频细节才看得到差异
private func checkerSource(width: Int, height: Int) -> CIImage? {
    guard let ctx = CGContext(data: nil, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    for y in 0..<height {
        for x in 0..<width {
            let on = ((x / 3) + (y / 3)) % 2 == 0
            ctx.setFillColor(red: on ? 0.85 : 0.25, green: on ? 0.7 : 0.3,
                             blue: on ? 0.6 : 0.35, alpha: 1)
            ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    guard let cg = ctx.makeImage() else { return nil }
    return CIImage(cgImage: cg)
}

/// 采样单点灰度（0…1）
private func graySample(_ image: CIImage, at point: CGPoint) -> Double? {
    guard let cg = RenderContext.shared.createCGImage(image, from: CGRect(x: point.x, y: point.y, width: 1, height: 1))
    else { return nil }
    guard let data = cg.dataProvider?.data as Data?, data.count >= 1 else { return nil }
    return Double(data[0]) / 255.0
}

/// 全图均值（0…255，按亮度近似）
private func meanLuma(_ image: CIImage) -> Double? {
    let extent = image.extent
    guard extent.width >= 1, extent.height >= 1,
          let cg = RenderContext.shared.createCGImage(image, from: extent),
          let data = cg.dataProvider?.data as Data? else { return nil }
    let bpp = cg.bitsPerPixel / 8
    guard bpp >= 1, cg.width * cg.height > 0 else { return nil }
    var sum = 0.0
    var count = 0
    var i = 0
    while i + bpp <= data.count {
        sum += Double(data[i]) * 0.299 + Double(data[i + 1]) * 0.587 + Double(data[i + 2]) * 0.114
        count += 1
        i += bpp
    }
    return count > 0 ? sum / Double(count) : nil
}

/// 左右半区均值（几何敏感指标：掩码错位时左右会被抹平）
private func halfMeans(_ image: CIImage) -> (left: Double, right: Double)? {
    let e = image.extent
    guard e.width >= 4, e.height >= 2 else { return nil }
    let half = (e.width / 2).rounded(.down)
    guard let l = meanLuma(image.cropped(to: CGRect(x: e.origin.x, y: e.origin.y, width: half, height: e.height))),
          let r = meanLuma(image.cropped(to: CGRect(x: e.origin.x + half, y: e.origin.y,
                                                    width: e.width - half, height: e.height))) else { return nil }
    return (l, r)
}

/// 半区内部的均值与标准差（避开掩码边界的模糊过渡带）。
/// 标准差是**极性无关**的效果指标：掩码白区内做磨皮 → 高频被抹平 → 标准差骤降。
private func innerStats(_ image: CIImage) -> (leftMean: Double, leftStd: Double, rightMean: Double, rightStd: Double)? {
    let e = image.extent
    guard e.width >= 20, e.height >= 6 else { return nil }
    let l = CGRect(x: e.origin.x + e.width * 0.10, y: e.origin.y + e.height * 0.20,
                   width: e.width * 0.30, height: e.height * 0.60).integral
    let r = CGRect(x: e.origin.x + e.width * 0.60, y: e.origin.y + e.height * 0.20,
                   width: e.width * 0.30, height: e.height * 0.60).integral
    guard let ls = lumaStats(image.cropped(to: l)), let rs = lumaStats(image.cropped(to: r)) else { return nil }
    return (ls.mean, ls.std, rs.mean, rs.std)
}

/// 某区域内的亮度均值与标准差（0…255）。
private func lumaStats(_ image: CIImage) -> (mean: Double, std: Double)? {
    let extent = image.extent
    guard extent.width >= 1, extent.height >= 1,
          let cg = RenderContext.shared.createCGImage(image, from: extent),
          let data = cg.dataProvider?.data as Data? else { return nil }
    let bpp = cg.bitsPerPixel / 8
    guard bpp >= 3 else { return nil }
    var values: [Double] = []
    values.reserveCapacity(cg.width * cg.height)
    var i = 0
    while i + bpp <= data.count {
        values.append(Double(data[i]) * 0.299 + Double(data[i + 1]) * 0.587 + Double(data[i + 2]) * 0.114)
        i += bpp
    }
    guard !values.isEmpty else { return nil }
    let mean = values.reduce(0, +) / Double(values.count)
    let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    return (mean, variance.squareRoot())
}

@Suite("P0-B 人像掩码尺寸适配")
struct MaskFitThumbnailTests {

    @Test("fit 后 extent 恒等于目标 extent（大掩码 / 小掩码 / 带原点偏移）")
    func fitAlwaysMatchesTargetExtent() throws {
        let big = try #require(rightHalfWhiteMask(width: 1600, height: 1200))
        let small = try #require(rightHalfWhiteMask(width: 90, height: 68))
        let offset = try #require(rightHalfWhiteMask(width: 1600, height: 1200))
            .transformed(by: CGAffineTransform(translationX: 40, y: 30))

        for (label, mask) in [("1600x1200", big), ("90x68", small), ("offset+40+30", offset)] {
            let fitted = MaskFit.fit(mask, to: thumbExtent)
            print("[P0B] fit(\(label)) → extent \(fitted.extent)")
            #expect(abs(fitted.extent.width - thumbExtent.width) < 0.5)
            #expect(abs(fitted.extent.height - thumbExtent.height) < 0.5)
            #expect(fitted.extent.width >= 1 && fitted.extent.height >= 1)
        }
    }

    @Test("根因取证：只裁不缩会取错区域（右半白被裁成整块黑）")
    func cropOnlyLosesGeometry() throws {
        let mask = try #require(rightHalfWhiteMask(width: 1600, height: 1200))
        let cropped = mask.cropped(to: thumbExtent)
        let fitted = MaskFit.fit(mask, to: thumbExtent)

        let croppedRight = try #require(graySample(cropped, at: CGPoint(x: 135, y: 67)))
        let fittedRight = try #require(graySample(fitted, at: CGPoint(x: 135, y: 67)))
        let fittedLeft = try #require(graySample(fitted, at: CGPoint(x: 45, y: 67)))
        print("[P0B] 同一采样点(x=135) cropped=\(croppedRight) fitted=\(fittedRight)；fitted 左半=\(fittedLeft)")

        #expect(croppedRight < 0.1)   // 旧做法：180 宽的裁剪窗口落在 1600 宽掩码的左上角 → 全黑
        #expect(fittedRight > 0.9)    // 新做法：右半白被等比搬进 180 宽窗口
        #expect(fittedLeft < 0.1)
    }

    @Test("管线级回归：掩码尺寸不再影响效果落点（180 / 1600 / 4032 三档必须一致且几何对齐）")
    func skinRenderIsMaskSizeIndependent() throws {
        let source = try #require(checkerSource(width: 180, height: 135))

        // 用**磨皮**而不是美白作为信号：判据是「标准差骤降」——高频被抹平，
        // 与亮度方向无关，断言不依赖任何亮度/极性假设，只依赖
        // 「掩码白区生效、黑区原样」这条已由 MaskRenderTests 绿灯验证过的契约。
        var graph = EditGraph()
        graph.append(.skinSmoothing(100))

        func render(_ mask: CIImage?) -> CIImage {
            var renderer = BasicAdjustmentRenderer()
            renderer.skinMask = mask
            return renderer.render(source: source, graph: graph)
        }

        let base = try #require(innerStats(source))
        let noMask = try #require(innerStats(render(nil)))
        print("[P0B] 无掩码 左(mean=\(noMask.leftMean),std=\(noMask.leftStd)) 右(mean=\(noMask.rightMean),std=\(noMask.rightStd))；原图 std=\(base.leftStd)")
        #expect(abs(noMask.leftStd - base.leftStd) < 1.0)    // 无掩码 = 恒等
        #expect(abs(noMask.rightStd - base.rightStd) < 1.0)

        let cases: [(String, CIImage)] = [
            ("180x135 掩码（缩略图档）", try #require(rightHalfWhiteMask(width: 180, height: 135))),
            ("1600x1200 掩码（预览档）", try #require(rightHalfWhiteMask(width: 1600, height: 1200))),
            ("4032x3024 掩码（全分辨率档）", try #require(rightHalfWhiteMask(width: 4032, height: 3024))),
        ]

        var rightStds: [Double] = []
        var rightMeans: [Double] = []
        for (label, mask) in cases {
            let out = render(mask)
            let s = try #require(innerStats(out))
            print("[P0B] \(label) extent=\(out.extent) 左(mean=\(s.leftMean),std=\(s.leftStd)) 右(mean=\(s.rightMean),std=\(s.rightStd))")
            // 只裁不缩的旧实现会把 180 宽窗口落在 4032 宽掩码的左上角 → 空图/全黑
            #expect(out.extent.width >= 1 && out.extent.height >= 1)
            // 掩码白区（右半）必须真的被磨平
            #expect(s.rightStd < s.leftStd * 0.6)
            // 掩码黑区（左半）必须原样：亮度与纹理都不能被改动
            #expect(abs(s.leftMean - base.leftMean) < 3.0)
            #expect(abs(s.leftStd - base.leftStd) < 2.0)
            rightStds.append(s.rightStd)
            rightMeans.append(s.rightMean)
        }

        // 尺寸无关性 —— P0-B 的核心主张
        let stdSpread = (rightStds.max() ?? 0) - (rightStds.min() ?? 0)
        let meanSpread = (rightMeans.max() ?? 0) - (rightMeans.min() ?? 0)
        print("[P0B] 三档右半：std 极差=\(stdSpread) mean 极差=\(meanSpread)")
        #expect(stdSpread < 1.0)
        #expect(meanSpread < 1.0)
    }

    @Test("取证：单通道灰度掩码经 canonical 规整后与三通道掩码等价")
    func grayChannelMaskSemantics() throws {
        let source = try #require(checkerSource(width: 180, height: 135))
        let grayMask = try #require(grayChannelMask(width: 1600, height: 1200))
        let rgbaMask = try #require(rightHalfWhiteMask(width: 1600, height: 1200))

        var graph = EditGraph()
        graph.append(.skinSmoothing(60))

        func render(_ mask: CIImage) -> CIImage {
            var renderer = BasicAdjustmentRenderer()
            renderer.skinMask = mask
            return renderer.render(source: source, graph: graph)
        }

        let base = try #require(innerStats(source))
        let gray = try #require(innerStats(render(grayMask)))
        let rgba = try #require(innerStats(render(rgbaMask)))
        print("[P0B] 灰阶掩码 左(mean=\(gray.leftMean),std=\(gray.leftStd)) 右(mean=\(gray.rightMean),std=\(gray.rightStd))")
        print("[P0B] RGBA 掩码 左(mean=\(rgba.leftMean),std=\(rgba.leftStd)) 右(mean=\(rgba.rightMean),std=\(rgba.rightStd))")

        // 掩码外必须原样（历史 bug：错配/单通道掩码把掩码外整块压成 0）
        #expect(abs(gray.leftMean - base.leftMean) < 3.0)
        #expect(abs(rgba.leftMean - base.leftMean) < 3.0)
        // 两种通道形态必须等价（canonical 规整的职责）
        #expect(abs(gray.leftMean - rgba.leftMean) < 1.0)
        #expect(abs(gray.rightMean - rgba.rightMean) < 1.0)
        #expect(abs(gray.leftStd - rgba.leftStd) < 1.0)
        #expect(abs(gray.rightStd - rgba.rightStd) < 1.0)
    }

    @Test("尺寸诊断取证：多种掩码尺寸均不得产出空图")
    func maskSizeDiagnostics() throws {
        let source = try #require(checkerSource(width: 180, height: 135))
        var graph = EditGraph()
        graph.append(.skinSmoothing(25))
        graph.append(.skinBrightening(15))

        for size in [(180, 135), (360, 270), (900, 675), (1600, 1200), (4032, 3024)] {
            let mask = try #require(rightHalfWhiteMask(width: size.0, height: size.1))
            var renderer = BasicAdjustmentRenderer()
            renderer.skinMask = mask
            let out = renderer.render(source: source, graph: graph)
            print("[P0B] 源 180x135 + 掩码 \(size.0)x\(size.1) → 输出 extent \(out.extent)")
            #expect(out.extent.width >= 1 && out.extent.height >= 1)
        }
    }
}
