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
private func rightHalfWhiteMask(width: Int, height: Int) -> CIImage? {
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

    @Test("管线级回归：掩码尺寸不再影响磨皮/美白落点（掩码 1600 档 == 180 档）")
    func skinRenderIsMaskSizeIndependent() throws {
        let source = try #require(checkerSource(width: 180, height: 135))
        let exactMask = try #require(rightHalfWhiteMask(width: 180, height: 135))
        let previewMask = try #require(rightHalfWhiteMask(width: 1600, height: 1200))

        var graph = EditGraph()
        graph.append(.skinSmoothing(60))
        graph.append(.skinBrightening(40))

        func render(_ mask: CIImage?) -> CIImage {
            var renderer = BasicAdjustmentRenderer()
            renderer.skinMask = mask
            return renderer.render(source: source, graph: graph)
        }

        let noMask = render(nil)
        let withExact = render(MaskFit.fit(exactMask, to: source.extent))
        let withBig = render(MaskFit.fit(previewMask, to: source.extent))
        let withRawBig = render(previewMask)   // 不预先 fit：由 blend 内部适配（RenderPipeline 修复点）

        for (label, image) in [("无掩码", noMask), ("180 掩码(预先 fit)", withExact),
                               ("1600 掩码(预先 fit)", withBig), ("1600 掩码(交给管线)", withRawBig)] {
            let means = try #require(halfMeans(image))
            print("[P0B] \(label) extent=\(image.extent) 左=\(means.left) 右=\(means.right)")
            // 掩码白区在右半：美白后右半必须明显亮于左半。
            // 若掩码几何被裁错（旧行为），右半与左半会被抹平 → 这条断言会红。
            #expect(means.right > means.left + 1.0)
            #expect(image.extent.width >= 1 && image.extent.height >= 1)
        }
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
