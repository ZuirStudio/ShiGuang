import Testing
import Foundation
import CoreImage
import CoreGraphics
@testable import EditKit
@testable import RenderKit

// MARK: - P0-B 取证：混合原语 + 位图读法
//
// 这个套件是为了把两件事**分开**：
//   1. 掩码混合原语（maskApply kernel vs CIBlendWithMask）谁对；
//   2. 我读位图的方式对不对。
// 起因：曾经用「线性读取位图缓冲」的统计工具量测，得到「掩码黑区被改色 / 整块压黑」，
// 于是判定 CIBlendWithMask 语义不稳定。后来发现那批数字是**测量工具**的缺陷：
// CI 对 kernel 输出重新栅格化时 `bytesPerRow` 带对齐填充，线性读取把填充字节当成了像素。
// 因此这里同时用两种读法读同一张图并打印差异，结论必须来自按行距读取的数字。

private let diagExtent = CGRect(x: 0, y: 0, width: 180, height: 135)

/// 6px 棋盘源图：整体均值恒定，且像素级高频（磨皮会立刻抹平纹理 → 标准差骤降）。
private func checkerSource(width: Int, height: Int, cell: Int = 6) -> CIImage? {
    guard let ctx = CGContext(data: nil, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(red: 0.99, green: 0.99, blue: 0.99, alpha: 1)
    var y = 0
    var row = 0
    while y < height {
        var x = row % 2 == 0 ? 0 : cell
        while x < width {
            ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
            x += cell * 2
        }
        y += cell
        row += 1
    }
    guard let cg = ctx.makeImage() else { return nil }
    return CIImage(cgImage: cg)
}

/// 右半白、左半黑的不透明 RGBA 掩码（白 = 生效）。
private func rightHalfMask(width: Int, height: Int) -> CIImage? {
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

/// 亮度值（0…255），RGB 三通道加权。
private func luma(_ b: [UInt8], _ i: Int) -> Double {
    Double(b[i]) * 0.299 + Double(b[i + 1]) * 0.587 + Double(b[i + 2]) * 0.114
}

private func meanStd(_ v: [Double]) -> (mean: Double, std: Double) {
    guard !v.isEmpty else { return (0, 0) }
    let m = v.reduce(0, +) / Double(v.count)
    let varSum = v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count)
    return (m, varSum.squareRoot())
}

/// ✅ 正确读法：按 `bytesPerRow` 逐行取值。
private func rowValues(_ cg: CGImage) -> [Double] {
    guard let raw = cg.dataProvider?.data as Data? else { return [] }
    let bpp = cg.bitsPerPixel / 8
    guard bpp >= 3 else { return [] }
    let bytes = [UInt8](raw)
    var out: [Double] = []
    out.reserveCapacity(cg.width * cg.height)
    for y in 0..<cg.height {
        let rowStart = y * cg.bytesPerRow
        guard rowStart + cg.width * bpp <= bytes.count else { break }
        for x in 0..<cg.width { out.append(luma(bytes, rowStart + x * bpp)) }
    }
    return out
}

/// ❌ 错误读法（保留作对照）：把缓冲当连续像素数组，忽略行距填充。
private func linearValues(_ cg: CGImage) -> [Double] {
    guard let raw = cg.dataProvider?.data as Data? else { return [] }
    let bpp = cg.bitsPerPixel / 8
    guard bpp >= 3 else { return [] }
    let bytes = [UInt8](raw)
    var out: [Double] = []
    var i = 0
    while i + bpp <= bytes.count {
        out.append(luma(bytes, i))
        i += bpp
    }
    return out
}

/// 逐格均值网格（按行距读取；行 0 = 画面顶行）。
private func grid(_ cg: CGImage, cols: Int = 18, rows: Int = 9) -> String {
    guard let raw = cg.dataProvider?.data as Data? else { return "(no data)" }
    let bpp = cg.bitsPerPixel / 8
    guard bpp >= 3 else { return "(bpp < 3)" }
    let bytes = [UInt8](raw)
    var lines: [String] = []
    for r in 0..<rows {
        let y0 = r * cg.height / rows
        let y1 = max(y0 + 1, (r + 1) * cg.height / rows)
        var line = ""
        for c in 0..<cols {
            let x0 = c * cg.width / cols
            let x1 = max(x0 + 1, (c + 1) * cg.width / cols)
            var sum = 0.0
            var n = 0
            for y in y0..<y1 {
                let rowStart = y * cg.bytesPerRow
                guard rowStart + cg.width * bpp <= bytes.count else { continue }
                for x in x0..<x1 {
                    sum += luma(bytes, rowStart + x * bpp)
                    n += 1
                }
            }
            line += String(format: "%4.0f", n == 0 ? -1 : sum / Double(n))
        }
        lines.append(line)
    }
    return lines.joined(separator: "\n")
}

/// 左右内部区域（避开掩码边界 30px 过渡带）的统计。
private func innerRegions(_ cg: CGImage) -> (left: (mean: Double, std: Double), right: (mean: Double, std: Double)) {
    guard let raw = cg.dataProvider?.data as Data? else { return ((0, 0), (0, 0)) }
    let bpp = cg.bitsPerPixel / 8
    let bytes = [UInt8](raw)
    var left: [Double] = []
    var right: [Double] = []
    for y in (cg.height / 5)..<(cg.height * 4 / 5) {
        let rowStart = y * cg.bytesPerRow
        guard rowStart + cg.width * bpp <= bytes.count else { continue }
        for x in 0..<cg.width {
            let v = luma(bytes, rowStart + x * bpp)
            if x >= cg.width * 10 / 100 && x < cg.width * 40 / 100 { left.append(v) }
            if x >= cg.width * 60 / 100 && x < cg.width * 90 / 100 { right.append(v) }
        }
    }
    return (meanStd(left), meanStd(right))
}

@Suite("P0-B 取证：混合原语与位图读法")
struct MaskBlendDiagnosticTests {

    @Test("取证：同一张输出的两种读法差异（行距填充是真凶）")
    func readerDiscrepancy() throws {
        let source = try #require(checkerSource(width: 180, height: 135))
        let mask = try #require(rightHalfMask(width: 180, height: 135))
        var graph = EditGraph()
        graph.append(.skinSmoothing(100))
        var renderer = BasicAdjustmentRenderer()
        renderer.skinMask = mask
        let out = renderer.render(source: source, graph: graph)

        let ctx = CIContext(options: [.useSoftwareRenderer: true])
        let cgSource = try #require(ctx.createCGImage(source, from: diagExtent))
        let cgOut = try #require(ctx.createCGImage(out, from: diagExtent))
        let cgMask = try #require(ctx.createCGImage(MaskFit.fit(mask, to: diagExtent), from: diagExtent))

        print("[DIAG] CIClamp 过滤器存在：\(CIFilter(name: "CIClamp") != nil)")
        print("[DIAG] source bpr=\(cgSource.bytesPerRow) w*bpp=\(cgSource.width * cgSource.bitsPerPixel / 8) bpp=\(cgSource.bitsPerPixel)")
        print("[DIAG] out    bpr=\(cgOut.bytesPerRow) w*bpp=\(cgOut.width * cgOut.bitsPerPixel / 8) bpp=\(cgOut.bitsPerPixel)")
        let rowOut = meanStd(rowValues(cgOut))
        let linOut = meanStd(linearValues(cgOut))
        print("[DIAG] out 按行距 mean=\(rowOut.mean) std=\(rowOut.std)")
        print("[DIAG] out 线性  mean=\(linOut.mean) std=\(linOut.std)")
        print("[DIAG] == mask 网格（行0=画面顶）==\n" + grid(cgMask))
        print("[DIAG] == source 网格 ==\n" + grid(cgSource))
        print("[DIAG] == out 网格 ==\n" + grid(cgOut))
        let r = innerRegions(cgOut)
        print("[DIAG] out 内部 左(mean=\(r.left.mean) std=\(r.left.std)) 右(mean=\(r.right.mean) std=\(r.right.std))")
        let rs = innerRegions(cgSource)
        print("[DIAG] src 内部 左(mean=\(rs.left.mean) std=\(rs.left.std)) 右(mean=\(rs.right.mean) std=\(rs.right.std))")

        #expect(cgMask.height == 135)
    }

    @Test("取证：maskApply kernel 与 CIBlendWithMask 对照（掩码尺寸三档）")
    func kernelVersusBlendWithMask() throws {
        let source = try #require(checkerSource(width: 180, height: 135))
        var graph = EditGraph()
        graph.append(.skinSmoothing(60))

        let ctx = CIContext(options: [.useSoftwareRenderer: true])
        let cgBase = try #require(ctx.createCGImage(source, from: diagExtent))
        let base = innerRegions(cgBase)

        let sizes: [(String, Int, Int)] = [
            ("180x135", 180, 135), ("1600x1200", 1600, 1200), ("4032x3024", 4032, 3024),
        ]
        for (label, w, h) in sizes {
            let mask = try #require(rightHalfMask(width: w, height: h))

            var renderer = BasicAdjustmentRenderer()
            renderer.skinMask = mask
            let piped = try #require(ctx.createCGImage(renderer.render(source: source, graph: graph), from: diagExtent))
            let p = innerRegions(piped)

            // 手工复刻同一条链路，但把混合原语换成内建 CIBlendWithMask
            //
            // ⚠️ 以下这段**不是 oracle**（R007b-2 复核结论）。CI 实测（三档掩码尺寸完全一致）：
            //      左(掩码黑) mean=190.255 std=62.0   ← 与源图左区完全一致（背景透出，正确）
            //      右(掩码白) mean=0.0   std=0.0      ← 纯黑
            //    "掩码白区 = 纯黑"**不是原语语义差异**：R007b-2 在 `MaskBlendOracleTests`
            //    里加了探针，把前景换成一张**有效**的模糊图 → CIBlend 白区=前景 198.90、
            //    黑区=背景 189.90，语义完全正确（软件渲染器与默认渲染器一致）。真正的问题是
            //    本段的 foreground 链（`CIClamp` 用默认区间 [0,1] + `CIGaussianBlur`）在该环境
            //    下连位图都出不来（createCGImage → nil），属于**取证工具**问题。
            //    所以这行数字禁止再被引用为语义证据；内建原语的硬断言应在真机上做。
            //    管线自身的混合律已改由 `MaskBlendOracleTests`（自算 oracle，不依赖任何内建 filter）取证。
            let amount = 0.6
            let radius = amount * 10
            let blurred = source.applyingFilter("CIClamp", parameters: [:])
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius])
                .cropped(to: diagExtent)
            let fitted = MaskFit.fit(MaskFit.canonical(mask), to: diagExtent)
            let blended = blurred.applyingFilter(
                "CIBlendWithMask",
                parameters: [
                    kCIInputBackgroundImageKey: source,
                    kCIInputMaskImageKey: fitted,
                ]
            ).cropped(to: diagExtent)
            let withMask = try #require(ctx.createCGImage(blended, from: diagExtent))
            let b = innerRegions(withMask)

            print("[DIAG] \(label) 管线 左(mean=\(p.left.mean) std=\(p.left.std)) 右(mean=\(p.right.mean) std=\(p.right.std))")
            print("[DIAG] \(label) CIBlend 左(mean=\(b.left.mean) std=\(b.left.std)) 右(mean=\(b.right.mean) std=\(b.right.std))")
            print("[DIAG] \(label) 原图 左(mean=\(base.left.mean) std=\(base.left.std)) 右(mean=\(base.right.mean) std=\(base.right.std))")

            // 掩码白区（右半）必须真的被磨平
            #expect(p.right.std < p.left.std * 0.7, "\(label) 管线：右半没被磨平")
            // 掩码黑区（左半）必须原样 —— 两种实现都必须满足
            #expect(abs(p.left.mean - base.left.mean) < 2.0, "\(label) 管线：左半均值被改动")
            #expect(abs(p.left.std - base.left.std) < 2.0, "\(label) 管线：左半纹理被改动")
            #expect(abs(b.left.mean - base.left.mean) < 2.0, "\(label) CIBlend：左半均值被改动")
            #expect(abs(b.left.std - base.left.std) < 2.0, "\(label) CIBlend：左半纹理被改动")
        }
    }
}
