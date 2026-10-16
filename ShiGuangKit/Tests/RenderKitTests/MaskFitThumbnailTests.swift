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
/// 形态与生产链路一致：**不透明 RGBA**（AICore `makeOpaqueGray` / MaskRenderer 的渐变掩码都是这个形态）。
/// ⚠️ CI 取证：单通道灰度（DeviceGray + alphaInfo .none）掩码在 `CIBlendWithMask` 下几何会反常
/// （见 `grayChannelMaskSemantics` 用例），所以生产掩码必须是三通道。
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

/// 单通道灰度掩码（用于取证：这类掩码直接进 CIBlendWithMask 会几何反常）。
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

    @Test("管线级回归：掩码尺寸不再影响美白落点（掩码 1600 档 == 180 档，几何必须对齐）")
    func skinRenderIsMaskSizeIndependent() throws {
        let source = try #require(checkerSource(width: 180, height: 135))
        let exactMask = try #require(rightHalfWhiteMask(width: 180, height: 135))
        let previewMask = try #require(rightHalfWhiteMask(width: 1600, height: 1200))

        // 只用美白（mix = 1.0，不走二次强度混合），信号最强：白区整体抬亮 ~23 级。
        var graph = EditGraph()
        graph.append(.skinBrightening(100))

        func render(_ mask: CIImage?) -> CIImage {
            var renderer = BasicAdjustmentRenderer()
            renderer.skinMask = mask
            return renderer.render(source: source, graph: graph)
        }

        let noMask = render(nil)
        let withExact = render(MaskFit.fit(exactMask, to: source.extent))
        let withBig = render(MaskFit.fit(previewMask, to: source.extent))
        let withRawBig = render(previewMask)   // 不预先 fit：由 blend 内部适配（RenderPipeline 修复点）

        var rightMeans: [Double] = []
        for (label, image) in [("无掩码", noMask), ("180 掩码(预先 fit)", withExact),
                               ("1600 掩码(预先 fit)", withBig), ("1600 掩码(交给管线)", withRawBig)] {
            let means = try #require(halfMeans(image))
            print("[P0B] \(label) extent=\(image.extent) 左=\(means.left) 右=\(means.right)")
            #expect(image.extent.width >= 1 && image.extent.height >= 1)
            if label != "无掩码" {
                // 掩码白区在右半：美白后右半必须明显亮于左半。
                // 旧行为（只裁不缩）会把 180 宽窗口落在 1600 宽掩码的左上角（全黑）→ 左右被抹平 → 这条会红。
                #expect(means.right > means.left + 10.0)
                // 掩码外不得被抹黑（灰阶/错配掩码曾把掩码外的区域整块压成 0）
                #expect(means.left > 50.0)
                rightMeans.append(means.right)
            } else {
                #expect(abs(means.left - means.right) < 1.0)   // 无掩码 = 不出效果，左右一致
            }
        }

        // 尺寸无关性：三种掩码尺寸（含交给管线适配的那一档）结果必须几乎一致
        let spread = (rightMeans.max() ?? 0) - (rightMeans.min() ?? 0)
        print("[P0B] 三种掩码尺寸右半均值极差 = \(spread)")
        #expect(spread < 2.0)
    }

    @Test("取证：单通道灰度掩码的语义（生产掩码必须三通道不透明）")
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

        let grayOut = render(grayMask)
        let rgbaOut = render(rgbaMask)
        let grayMeans = try #require(halfMeans(grayOut))
        let rgbaMeans = try #require(halfMeans(rgbaOut))
        print("[P0B] 灰阶掩码 左=\(grayMeans.left) 右=\(grayMeans.right)；RGBA 掩码 左=\(rgbaMeans.left) 右=\(rgbaMeans.right)")

        // 三通道掩码：掩码外必须保持原图亮度（只多做一次模糊，均值基本不变）
        #expect(rgbaMeans.left > 100.0)
        // 灰阶掩码经 MaskFit.canonical 规整后同样不得把掩码外压黑
        #expect(grayMeans.left > 100.0)
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
