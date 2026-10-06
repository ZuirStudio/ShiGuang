import Testing
import Foundation
import CoreImage
import CoreGraphics
@testable import EditKit
@testable import RenderKit

// MARK: - 测试夹具

private let maskTestSize = 96
private let maskTestGray: UInt8 = 128

/// 直接用字节构造「上半白、下半黑」位图（CGImage 第 0 行 = 图像顶行，无歧义ground truth）。
private func makeTopHalfWhiteImage(size: Int) -> CGImage? {
    var bytes = [UInt8](repeating: 0, count: size * size * 4)
    for row in 0..<size {
        for col in 0..<size {
            let i = (row * size + col) * 4
            let v: UInt8 = row < size / 2 ? 255 : 0
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

private struct RGB: Equatable {
    let r: Int, g: Int, b: Int
    var gray: Int { (r + g + b) / 3 }
}

/// 归一化坐标采样（nx/ny 均为**左上原点**，与蒙版坐标约定一致）。
private func samplePixel(of image: CGImage, nx: Double, ny: Double) -> RGB? {
    let w = image.width, h = image.height
    guard w > 0, h > 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    let drawn: Bool = bytes.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(
            data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        return true
    }
    guard drawn else { return nil }
    let col = min(max(Int(nx * Double(w)), 0), w - 1)
    let row = min(max(Int(ny * Double(h)), 0), h - 1)
    let i = (row * w + col) * 4
    return RGB(r: Int(bytes[i]), g: Int(bytes[i + 1]), b: Int(bytes[i + 2]))
}

private func renderMasked(
    _ operations: [EditOperation],
    overlay: UUID? = nil,
    r: UInt8 = maskTestGray, g: UInt8 = maskTestGray, b: UInt8 = maskTestGray
) -> CGImage? {
    guard let source = makeColorImage(r: r, g: g, b: b, size: maskTestSize) else { return nil }
    let renderer = BasicAdjustmentRenderer(maskOverlayID: overlay)
    let output = renderer.render(source: CIImage(cgImage: source), graph: EditGraph(operations: operations))
    return CIContext().createCGImage(output, from: output.extent)
}

private func linearMask(
    start: MaskPoint, end: MaskPoint, feather: Double = 0, opacity: Double = 100,
    inverted: Bool = false, adjustments: [EditOperation]
) -> Mask {
    var mask = Mask(
        name: "线性", shape: .linear(LinearMask(start: start, end: end)),
        isInverted: inverted, feather: feather, opacity: opacity
    )
    mask.adjustments = adjustments
    return mask
}

private func radialMask(
    center: MaskPoint = MaskPoint(x: 0.5, y: 0.5), radius: Double = 0.25,
    aspectRatio: Double = 1, feather: Double = 0, opacity: Double = 100,
    inverted: Bool = false, adjustments: [EditOperation]
) -> Mask {
    var mask = Mask(
        name: "径向",
        shape: .radial(RadialMask(center: center, radius: radius, aspectRatio: aspectRatio, rotationDegrees: 0)),
        isInverted: inverted, feather: feather, opacity: opacity
    )
    mask.adjustments = adjustments
    return mask
}

private func brushMask(
    strokes: [BrushStroke], radius: Double = 0.1, hardness: Double = 100, flow: Double = 100,
    feather: Double = 0, opacity: Double = 100, adjustments: [EditOperation]
) -> Mask {
    var mask = Mask(
        name: "画笔",
        shape: .brush(BrushMask(strokes: strokes, radius: radius, hardness: hardness, flow: flow)),
        feather: feather, opacity: opacity
    )
    mask.adjustments = adjustments
    return mask
}

// MARK: - 采样前提校验

@Suite struct MaskTestHarnessTests {
    /// 采样器方向前提：ny = 0 必须落在图像**顶行**（否则所有蒙版方向断言都失去意义）。
    @Test func samplerTreatsNyZeroAsImageTop() throws {
        let cg = try #require(makeTopHalfWhiteImage(size: 64))
        let top = try #require(samplePixel(of: cg, nx: 0.5, ny: 0.2))
        let bottom = try #require(samplePixel(of: cg, nx: 0.5, ny: 0.8))
        #expect(top.r > 200)
        #expect(bottom.r < 55)
    }
}

// MARK: - 线性蒙版

@Suite struct LinearMaskRenderTests {
    /// 起点侧无效果、终点侧完全生效；羽化 0 = 硬边落在两端点中点。
    @Test func linearMaskAffectsOnlyFarSide() throws {
        let mask = linearMask(
            start: MaskPoint(x: 0.5, y: 0.05), end: MaskPoint(x: 0.5, y: 0.95),
            adjustments: [.exposure(2)]
        )
        let out = try #require(renderMasked([.mask(mask)]))
        let near = try #require(samplePixel(of: out, nx: 0.5, ny: 0.02))
        let far = try #require(samplePixel(of: out, nx: 0.5, ny: 0.98))
        #expect(abs(near.gray - Int(maskTestGray)) <= 4, "起点侧不应被调整：\(near)")
        #expect(far.gray > 200, "终点侧应完全生效：\(far)")
    }

    /// 羽化拉满 → 过渡带铺满起点到终点，中点只吃一半强度。
    @Test func featherWidensTransitionBand() throws {
        let mask = linearMask(
            start: MaskPoint(x: 0.5, y: 0.05), end: MaskPoint(x: 0.5, y: 0.95),
            feather: 100, adjustments: [.exposure(2)]
        )
        let out = try #require(renderMasked([.mask(mask)]))
        let near = try #require(samplePixel(of: out, nx: 0.5, ny: 0.02)).gray
        let mid = try #require(samplePixel(of: out, nx: 0.5, ny: 0.5)).gray
        let far = try #require(samplePixel(of: out, nx: 0.5, ny: 0.98)).gray
        #expect(mid > near + 25 && mid < far - 25, "中点应为半强：near=\(near) mid=\(mid) far=\(far)")
    }

    /// 方向由端点决定（横向渐变时左右分区，上下不受影响）。
    @Test func linearMaskDirectionFollowsEndpoints() throws {
        let mask = linearMask(
            start: MaskPoint(x: 0.05, y: 0.5), end: MaskPoint(x: 0.95, y: 0.5),
            adjustments: [.exposure(2)]
        )
        let out = try #require(renderMasked([.mask(mask)]))
        let left = try #require(samplePixel(of: out, nx: 0.02, ny: 0.5)).gray
        let right = try #require(samplePixel(of: out, nx: 0.98, ny: 0.5)).gray
        let topEdge = try #require(samplePixel(of: out, nx: 0.98, ny: 0.02)).gray
        #expect(abs(left - Int(maskTestGray)) <= 4)
        #expect(right > 200)
        #expect(topEdge > 200, "终点侧整列都应生效（含角落）")
    }

    /// 反选：效果相反。
    @Test func invertedLinearMaskSwapsSides() throws {
        let base = linearMask(
            start: MaskPoint(x: 0.5, y: 0.05), end: MaskPoint(x: 0.5, y: 0.95),
            adjustments: [.exposure(2)]
        )
        let out = try #require(renderMasked([.mask(base)]))
        let normalNear = try #require(samplePixel(of: out, nx: 0.5, ny: 0.02)).gray
        let normalFar = try #require(samplePixel(of: out, nx: 0.5, ny: 0.98)).gray

        var inverted = base
        inverted.isInverted = true
        let invOut = try #require(renderMasked([.mask(inverted)]))
        let invNear = try #require(samplePixel(of: invOut, nx: 0.5, ny: 0.02)).gray
        let invFar = try #require(samplePixel(of: invOut, nx: 0.5, ny: 0.98)).gray

        #expect(invNear > 200, "反选后起点侧生效：\(invNear)")
        #expect(abs(invFar - Int(maskTestGray)) <= 4, "反选后终点侧失效：\(invFar)")
        #expect(abs(invNear - normalFar) <= 8)
        #expect(abs(invFar - normalNear) <= 8)
    }

    /// 不透明度 0 = 完全无效；50 = 半强度。
    @Test func opacityScalesEffect() throws {
        let shape = (MaskPoint(x: 0.5, y: 0.05), MaskPoint(x: 0.5, y: 0.95))
        let full = try #require(renderMasked([.mask(linearMask(start: shape.0, end: shape.1, adjustments: [.exposure(2)]))]))
        let none = try #require(renderMasked([.mask(linearMask(start: shape.0, end: shape.1, opacity: 0, adjustments: [.exposure(2)]))]))
        let half = try #require(renderMasked([.mask(linearMask(start: shape.0, end: shape.1, opacity: 50, adjustments: [.exposure(2)]))]))

        let fullFar = try #require(samplePixel(of: full, nx: 0.5, ny: 0.98)).gray
        let noneFar = try #require(samplePixel(of: none, nx: 0.5, ny: 0.98)).gray
        let halfFar = try #require(samplePixel(of: half, nx: 0.5, ny: 0.98)).gray

        #expect(abs(noneFar - Int(maskTestGray)) <= 4, "不透明度 0 应完全无效")
        #expect(fullFar > 200)
        #expect(halfFar > noneFar + 25 && halfFar < fullFar - 25, "50% 应半强：\(halfFar)")
    }
}

// MARK: - 径向蒙版

@Suite struct RadialMaskRenderTests {
    /// 椭圆内生效、椭圆外无效。
    @Test func radialMaskAffectsOnlyInsideEllipse() throws {
        let mask = radialMask(radius: 0.25, adjustments: [.exposure(2)])
        let out = try #require(renderMasked([.mask(mask)]))
        let inside = try #require(samplePixel(of: out, nx: 0.5, ny: 0.5)).gray
        let corner = try #require(samplePixel(of: out, nx: 0.02, ny: 0.02)).gray
        let outsideX = try #require(samplePixel(of: out, nx: 0.95, ny: 0.5)).gray
        #expect(inside > 200, "圆心应完全生效：\(inside)")
        #expect(abs(corner - Int(maskTestGray)) <= 4)
        #expect(abs(outsideX - Int(maskTestGray)) <= 4)
    }

    /// 长宽比把圆拉成椭圆：横向变长、纵向不变。
    @Test func aspectRatioStretchesHorizontallyOnly() throws {
        let mask = radialMask(radius: 0.2, aspectRatio: 2, adjustments: [.exposure(2)])
        let out = try #require(renderMasked([.mask(mask)]))
        // 横向 dx = 0.35*96 = 33.6px < rx = 0.2*96*2 = 38.4px → 在椭圆内（未拉伸时 0.2*96=19.2px，会落在外面）
        let wide = try #require(samplePixel(of: out, nx: 0.85, ny: 0.5)).gray
        // 纵向 dy = 0.32*96 = 30.7px > ry = 19.2px → 在椭圆外
        let tall = try #require(samplePixel(of: out, nx: 0.5, ny: 0.82)).gray
        #expect(wide > 200, "横轴被拉伸后应仍在椭圆内：\(wide)")
        #expect(abs(tall - Int(maskTestGray)) <= 4, "纵轴不应被拉伸：\(tall)")
    }

    /// 反选：椭圆外生效。
    @Test func invertedRadialMaskAffectsOutside() throws {
        let mask = radialMask(radius: 0.25, inverted: true, adjustments: [.exposure(2)])
        let out = try #require(renderMasked([.mask(mask)]))
        let inside = try #require(samplePixel(of: out, nx: 0.5, ny: 0.5)).gray
        let corner = try #require(samplePixel(of: out, nx: 0.02, ny: 0.02)).gray
        #expect(abs(inside - Int(maskTestGray)) <= 4)
        #expect(corner > 200, "反选后椭圆外生效：\(corner)")
    }
}

// MARK: - 画笔蒙版

@Suite struct BrushMaskRenderTests {
    /// 笔画走廊内生效、走廊外无效。
    @Test func brushMaskAffectsStrokeCorridorOnly() throws {
        let stroke = BrushStroke(points: [
            MaskPoint(x: 0.2, y: 0.5), MaskPoint(x: 0.5, y: 0.5), MaskPoint(x: 0.8, y: 0.5),
        ], radius: 0.1)
        let mask = brushMask(strokes: [stroke], adjustments: [.exposure(2)])
        let out = try #require(renderMasked([.mask(mask)]))
        let onStroke = try #require(samplePixel(of: out, nx: 0.5, ny: 0.5)).gray
        let offStroke = try #require(samplePixel(of: out, nx: 0.5, ny: 0.05)).gray
        let organic = try #require(samplePixel(of: out, nx: 0.02, ny: 0.5)).gray
        #expect(onStroke > 200, "笔画中心应完全生效：\(onStroke)")
        #expect(abs(offStroke - Int(maskTestGray)) <= 4, "远离笔画处不应变化：\(offStroke)")
        #expect(abs(organic - Int(maskTestGray)) <= 4, "笔画起止点之外不应变化：\(organic)")
    }

    /// 单笔画撤销：撤销后不再有任何效果。
    @Test func undoingLastStrokeRemovesEffect() throws {
        var brush = BrushMask(radius: 0.1, hardness: 100, flow: 100)
        brush.beginStroke(at: MaskPoint(x: 0.2, y: 0.5))
        brush.appendPoint(MaskPoint(x: 0.8, y: 0.5))
        brush.endStroke()
        var mask = brushMask(strokes: brush.strokes, adjustments: [.exposure(2)])
        let painted = try #require(renderMasked([.mask(mask)]))
        #expect(try #require(samplePixel(of: painted, nx: 0.5, ny: 0.5)).gray > 200)

        _ = brush.undoLastStroke()
        mask.shape = .brush(brush)
        #expect(mask.isEmpty)
        let cleared = try #require(renderMasked([.mask(mask)]))
        let center = try #require(samplePixel(of: cleared, nx: 0.5, ny: 0.5)).gray
        #expect(abs(center - Int(maskTestGray)) <= 4, "撤销后应回到原图：\(center)")
    }

    /// 流量减半 → 强度减半（区域仍生效）。
    @Test func flowScalesBrushStrength() throws {
        let stroke = BrushStroke(points: [MaskPoint(x: 0.2, y: 0.5), MaskPoint(x: 0.8, y: 0.5)], radius: 0.1)
        let full = try #require(renderMasked([.mask(brushMask(strokes: [stroke], flow: 100, adjustments: [.exposure(2)]))]))
        let half = try #require(renderMasked([.mask(brushMask(strokes: [stroke], flow: 50, adjustments: [.exposure(2)]))]))
        let fullGray = try #require(samplePixel(of: full, nx: 0.5, ny: 0.5)).gray
        let halfGray = try #require(samplePixel(of: half, nx: 0.5, ny: 0.5)).gray
        #expect(halfGray > Int(maskTestGray) + 20, "50% 流量仍应生效：\(halfGray)")
        #expect(halfGray < fullGray - 20, "50% 流量应弱于满流量：half=\(halfGray) full=\(fullGray)")
    }
}

// MARK: - 局部调整 / 叠加 / 预览

@Suite struct MaskCompositeTests {
    /// 局部调整只作用于蒙版区域；蒙版外的全局调整照常生效。
    @Test func localAdjustmentStaysInsideMask() throws {
        let mask = radialMask(radius: 0.2, adjustments: [.exposure(2), .saturation(-60)])
        let out = try #require(renderMasked([.mask(mask), .contrast(10)]))
        let inside = try #require(samplePixel(of: out, nx: 0.5, ny: 0.5))
        let outside = try #require(samplePixel(of: out, nx: 0.02, ny: 0.02))
        #expect(inside.gray > 200)
        #expect(abs(outside.gray - Int(maskTestGray)) <= 8, "蒙版外只应有全局对比度：\(outside)")
    }

    /// 两个蒙版各自作用于自己的区域（叠加共存，互不吞并）。
    @Test func twoMasksCoverDisjointRegions() throws {
        let top = linearMask(start: MaskPoint(x: 0.5, y: 0.95), end: MaskPoint(x: 0.5, y: 0.05), adjustments: [.exposure(2)])
        let bottom = linearMask(start: MaskPoint(x: 0.5, y: 0.05), end: MaskPoint(x: 0.5, y: 0.95), adjustments: [.exposure(2)])
        let out = try #require(renderMasked([.mask(top), .mask(bottom)]))
        let upper = try #require(samplePixel(of: out, nx: 0.5, ny: 0.05)).gray
        let lower = try #require(samplePixel(of: out, nx: 0.5, ny: 0.95)).gray
        #expect(upper > 200 && lower > 200, "两个蒙版都应生效：upper=\(upper) lower=\(lower)")
    }

    /// 同一区域的多个蒙版按序列依次作用（而非后者覆盖前者）：
    /// 两次 +2EV 串联 ≈ +4EV 过曝到纯白，单次只到 ~240。
    @Test func stackedMasksApplySequentially() throws {
        let one = radialMask(radius: 0.6, adjustments: [.exposure(2)])
        let single = try #require(renderMasked([.mask(one)]))
        let doubled = try #require(renderMasked([.mask(one), .mask(one.duplicated())]))
        let singleGray = try #require(samplePixel(of: single, nx: 0.5, ny: 0.5)).gray
        let doubledGray = try #require(samplePixel(of: doubled, nx: 0.5, ny: 0.5)).gray
        #expect(singleGray > 200 && singleGray < 250, "单层 +2EV：\(singleGray)")
        #expect(doubledGray == 255, "两层 +2EV 串联应过曝到纯白：\(doubledGray)")
    }

    /// 蒙版预览叠加色：区域被染色，区域外保持原样。
    @Test func overlayTintsMaskedRegionOnly() throws {
        var mask = radialMask(radius: 0.25, adjustments: [])
        mask.name = "预览"
        let out = try #require(renderMasked([.mask(mask)], overlay: mask.id))
        let inside = try #require(samplePixel(of: out, nx: 0.5, ny: 0.5))
        let outside = try #require(samplePixel(of: out, nx: 0.02, ny: 0.02))
        #expect(inside.r > inside.g + 20 && inside.r > inside.b + 20, "区域内应偏红：\(inside)")
        #expect(abs(inside.r - inside.g) > abs(outside.r - outside.g))
        #expect(outside.r < 140 && outside.g > 118, "区域外应接近原灰：\(outside)")
    }

    /// 没有局部调整的蒙版 = 恒等（不改变画面，只做选区）。
    @Test func maskWithoutAdjustmentsIsIdentity() throws {
        let mask = radialMask(radius: 0.4, adjustments: [])
        let out = try #require(renderMasked([.mask(mask)]))
        let center = try #require(samplePixel(of: out, nx: 0.5, ny: 0.5)).gray
        #expect(abs(center - Int(maskTestGray)) <= 2)
    }
}
