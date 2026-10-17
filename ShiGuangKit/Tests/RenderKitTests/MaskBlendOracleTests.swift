import Testing
import Foundation
import CoreImage
import CoreGraphics
@testable import EditKit
@testable import RenderKit

// MARK: - P0-B 取证 v2：**自算 oracle** 验证掩码混合律
//
// 为什么要再来一遍（结论驱动，不是为了多写测试）：
//   上一版 `MaskBlendDiagnosticTests` 的对照是**打印型**的，而且它的 CIBlendWithMask
//   参考实现（receiver = blurred / background = source / mask = 右白掩码）在 CI 的
//   软件渲染器下打印出「掩码白区 = 0.0（纯黑）、掩码黑区 = 源图（190.26）」，
//   即 foreground 在混合里**完全没参与**。
//   → 这种参考**不能当语义 oracle**：它反映的是"某个环境里这个 filter 长这样"，
//     不足以支撑"我们的 kernel 与内建 filter 语义不同"这种产品级结论。
//   → 本套件改用**管线自算**的 oracle，把"混合"这一件事单独隔离出来验证：
//
//         E60 := 用**全白掩码**渲染同一张图、同一个图谱 → "效果侧"（权重 = amount = 0.6）
//         期望 out(x) = src(x) + (E60(x) - src(x)) × 掩码亮度(x)
//
//   oracle 与被测物**共用同一段效果代码**（同一个 `BasicAdjustmentRenderer` + 同一图谱），
//   唯一变量就是掩码 → 失败只可能来自"混合"本身的实现。
//   （maskApply kernel 的混合律在 MaskRenderer.swift 里写的是显式 lerp：
//    `o.rgb + (a.rgb - o.rgb) * clamp(m.r) * clamp(amount)`，本套件把它变成可证伪的断言。）
//
// ⚠️ 关于内建 `CIBlendWithMask` 的所有数字仍然**只打印、不断言**（见文件末尾诊断）：
//    CI 的模拟器/软件渲染器上这类 filter 行为差异是已知现象
//    （R007b-1 Stage B 就记录过 `CISubtractBlendMode` 在 CI 上被跳过、
//     而 `CIMultiplyCompositing` 真跑），对 filter 语义下硬断言必须真机。

// MARK: - 常量与固定装置

private enum Oracle {
    static let width = 180
    static let height = 135
    static let extent = CGRect(x: 0, y: 0, width: 180, height: 135)
    /// 效果权重：`.skinSmoothing(60)` → amount = 0.6（与上一版对照脚本同参数，便于比对数字）
    static let amount = 0.6
    /// 统计时避开边界（掩码拟合/采样边沿）
    static let edgeX = 12
    static let edgeY = 8
}

private func oracleContext() throws -> CGContext {
    try #require(CGContext(
        data: nil,
        width: Oracle.width,
        height: Oracle.height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
}

private func fillColumns(_ ctx: CGContext, gray: (Int) -> CGFloat) {
    for x in 0..<Oracle.width {
        let v = gray(x)
        ctx.setFillColor(red: v, green: v, blue: v, alpha: 1)
        ctx.fill(CGRect(x: x, y: 0, width: 1, height: Oracle.height))
    }
}

/// 掩码左半黑（不生效）/ 右半白（全权重生效）
private func oracleHalfMaskCG() throws -> CGImage {
    let ctx = try oracleContext()
    ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: Oracle.width / 2, height: Oracle.height))
    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    ctx.fill(CGRect(x: Oracle.width / 2, y: 0, width: Oracle.width / 2, height: Oracle.height))
    return try #require(ctx.makeImage())
}

/// 全白掩码：拿到"效果侧" E60
private func oracleWhiteMaskCG() throws -> CGImage {
    let ctx = try oracleContext()
    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: Oracle.width, height: Oracle.height))
    return try #require(ctx.makeImage())
}

/// 水平线性渐变掩码：第 x 列灰度 = x / (width - 1)
private func oracleRampMaskCG() throws -> CGImage {
    let ctx = try oracleContext()
    let denom = CGFloat(Oracle.width - 1)
    fillColumns(ctx) { x in CGFloat(x) / denom }
    return try #require(ctx.makeImage())
}

/// 8×8 棋盘（0.5 / 0.99 灰）：有高频细节，模糊后才会明显变化
private func oracleCheckerSourceCG() throws -> CGImage {
    let ctx = try oracleContext()
    for y in stride(from: 0, to: Oracle.height, by: 8) {
        for x in stride(from: 0, to: Oracle.width, by: 8) {
            let dark = ((x / 8) + (y / 8)) % 2 == 0
            let v: CGFloat = dark ? 0.5 : 0.99
            ctx.setFillColor(red: v, green: v, blue: v, alpha: 1)
            ctx.fill(CGRect(x: x, y: y, width: 8, height: 8))
        }
    }
    return try #require(ctx.makeImage())
}

// MARK: - 读回（**按行距逐行读**，这一条是上一轮的缺陷来源，不可再犯）

private struct OraclePlane {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixels: [UInt8]

    /// 线性亮度（0…255）。按 `bytesPerRow` 逐行定位，绝不用 `width * 4` 充当行距。
    func luma(_ x: Int, _ y: Int) -> Double {
        let i = y * bytesPerRow + x * 4
        let r = Double(pixels[i]) / 255.0
        let g = Double(pixels[i + 1]) / 255.0
        let b = Double(pixels[i + 2]) / 255.0
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) * 255.0
    }

    /// 某一列在有效行范围内的平均亮度
    func columnMean(_ x: Int) -> Double {
        var sum = 0.0
        for y in Oracle.edgeY..<(height - Oracle.edgeY) { sum += luma(x, y) }
        return sum / Double(height - 2 * Oracle.edgeY)
    }

    func regionMeanStd(xRange: Range<Int>) -> (mean: Double, std: Double) {
        var sum = 0.0
        var sumSq = 0.0
        var n = 0.0
        for y in Oracle.edgeY..<(height - Oracle.edgeY) {
            for x in xRange {
                let v = luma(x, y)
                sum += v
                sumSq += v * v
                n += 1
            }
        }
        let mean = sum / n
        let variance = max(0, sumSq / n - mean * mean)
        return (mean, variance.squareRoot())
    }
}

private func oraclePlane(_ image: CGImage) throws -> OraclePlane {
    let data = try #require(image.dataProvider?.data as Data?)
    return OraclePlane(
        width: image.width,
        height: image.height,
        bytesPerRow: image.bytesPerRow,
        pixels: [UInt8](data)
    )
}

/// ⚠️ 刻意做成**函数**而不是文件级 `let`：Swift 6 里全局 `let` 持有非 Sendable 的
/// `CIContext` 会被判为非并发安全（"not concurrency-safe ... may have shared mutable
/// state"），每个用例各取一个，代价可忽略。
private func oracleSoftwareContext() -> CIContext {
    CIContext(options: [.useSoftwareRenderer: true])
}

private func oracleRender(_ source: CIImage, mask: CIImage?, graph: EditGraph) -> CIImage {
    var renderer = BasicAdjustmentRenderer()
    renderer.skinMask = mask
    return renderer.render(source: source, graph: graph)
}

private func oracleRenderCG(_ source: CIImage, mask: CIImage?, graph: EditGraph) throws -> CGImage {
    let context = oracleSoftwareContext()
    return try #require(context.createCGImage(
        oracleRender(source, mask: mask, graph: graph),
        from: Oracle.extent
    ))
}

/// 规范 + 对齐到 oracle 画布（与管线对掩码做的事完全一致）
private func oracleFittedMask(_ mask: CGImage) -> CIImage {
    MaskFit.fit(MaskFit.canonical(CIImage(cgImage: mask)), to: Oracle.extent)
}

/// sRGB 传输函数的逆（仅用于**打印**"两种候选约定"的偏差，不参与任何断言）
private func oracleSRGBToLinear(_ v: Double) -> Double {
    v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
}

private func oracleEditGraph() -> EditGraph {
    var graph = EditGraph()
    graph.append(.skinSmoothing(60))
    return graph
}

// MARK: - 断言 1/2：极性 + 排他性（掩码黑区不动、白区等于全权重效果）

@Suite("P0-B 取证 v2：掩码混合的自算 oracle")
struct MaskBlendOracleTests {

    @Test("掩码黑区必须逐像素等于源图（极性正确、无泄漏）")
    func blackRegionIsUntouched() throws {
        let sourceCG = try oracleCheckerSourceCG()
        let source = CIImage(cgImage: sourceCG)
        let fitted = MaskFit.fit(MaskFit.canonical(CIImage(cgImage: try oracleHalfMaskCG())), to: Oracle.extent)

        let outCG = try oracleRenderCG(source, mask: fitted, graph: oracleEditGraph())
        let s = try oraclePlane(sourceCG)
        let o = try oraclePlane(outCG)

        var maxDiff = 0.0
        var diffCount = 0
        for y in Oracle.edgeY..<(Oracle.height - Oracle.edgeY) {
            for x in Oracle.edgeX..<(Oracle.width / 2 - Oracle.edgeX) {
                let d = abs(s.luma(x, y) - o.luma(x, y))
                if d > maxDiff { maxDiff = d }
                if d > 0.5 { diffCount += 1 }
            }
        }
        print("[Oracle] 黑区：逐像素最大差 = \(maxDiff)，超过 0.5 的像素数 = \(diffCount)")
        #expect(maxDiff <= 2.0)
    }

    @Test("掩码白区必须等于「全白掩码」渲染（效果权重一致，不吞不溢）")
    func whiteRegionMatchesFullWeightEffect() throws {
        let sourceCG = try oracleCheckerSourceCG()
        let source = CIImage(cgImage: sourceCG)
        let graph = oracleEditGraph()
        let whiteFitted = MaskFit.fit(
            MaskFit.canonical(CIImage(cgImage: try oracleWhiteMaskCG())),
            to: Oracle.extent
        )
        let halfFitted = MaskFit.fit(
            MaskFit.canonical(CIImage(cgImage: try oracleHalfMaskCG())),
            to: Oracle.extent
        )

        let effectCG = try oracleRenderCG(source, mask: whiteFitted, graph: graph)
        let outCG = try oracleRenderCG(source, mask: halfFitted, graph: graph)
        let e = try oraclePlane(effectCG)
        let o = try oraclePlane(outCG)

        let right = (Oracle.width / 2 + Oracle.edgeX)..<(Oracle.width - Oracle.edgeX)
        var maxDiff = 0.0
        for y in Oracle.edgeY..<(Oracle.height - Oracle.edgeY) {
            for x in right {
                let d = abs(e.luma(x, y) - o.luma(x, y))
                if d > maxDiff { maxDiff = d }
            }
        }
        let eRegion = e.regionMeanStd(xRange: right)
        let oRegion = o.regionMeanStd(xRange: right)
        print("[Oracle] 白区：E60 mean=\(eRegion.mean) std=\(eRegion.std) / out mean=\(oRegion.mean) std=\(oRegion.std) / 逐像素最大差=\(maxDiff)")
        #expect(maxDiff <= 3.0)
    }

    /// 混合律（水平线性渐变掩码）：把每列的有效权重**反解**出来，验证它单调、端点正确、无过冲。
    ///
    /// 反解式：w(x) = (out − src) / (E60 − src)（同列均值，避开边缘）。
    /// 为什么要反解：直接断言"权重 == 掩码灰度"会夹带**色彩管理约定**（CI 工作空间是线性，
    /// sampler 拿到的灰度可能是线性化后的值），那不是产品逻辑、会误伤；所以绝对约定只**打印**，
    /// 断言只保留在**任何单调传输函数下都成立**的性质。
    @Test("取证 v2：渐变掩码下有效权重单调、端点正确、无过冲")
    func rampWeightIsMonotoneAndClamped() throws {
        let sourceCG = try oracleCheckerSourceCG()
        let source = CIImage(cgImage: sourceCG)
        let rampCG = try oracleRampMaskCG()
        let graph = oracleEditGraph()

        let referenceCG = try oracleRenderCG(
            source, mask: oracleFittedMask(try oracleWhiteMaskCG()), graph: graph
        )
        let outCG = try oracleRenderCG(source, mask: oracleFittedMask(rampCG), graph: graph)

        let s = try oraclePlane(sourceCG)
        let e = try oraclePlane(referenceCG)
        let o = try oraclePlane(outCG)
        let m = try oraclePlane(rampCG)

        var weights: [Double] = []
        var maskCols: [Double] = []
        for x in Oracle.edgeX..<(Oracle.width - Oracle.edgeX) {
            var sCol = 0.0, eCol = 0.0, oCol = 0.0, mCol = 0.0
            var n = 0.0
            for y in Oracle.edgeY..<(Oracle.height - Oracle.edgeY) {
                sCol += s.luma(x, y)
                eCol += e.luma(x, y)
                oCol += o.luma(x, y)
                mCol += m.luma(x, y)
                n += 1
            }
            sCol /= n; eCol /= n; oCol /= n; mCol /= n
            let denom = eCol - sCol
            guard abs(denom) > 8 else { continue }
            weights.append((oCol - sCol) / denom)
            maskCols.append(mCol / 255.0)
        }

        let first = try #require(weights.first)
        let last = try #require(weights.last)

        var dips = 0
        var outOfRange = 0
        for (i, w) in weights.enumerated() {
            if i > 0, w < weights[i - 1] - 0.01 { dips += 1 }
            if w < -0.02 || w > 1.03 { outOfRange += 1 }
        }

        var maxErrRaw = 0.0
        var maxErrLinear = 0.0
        for i in 0..<weights.count {
            maxErrRaw = max(maxErrRaw, abs(weights[i] - maskCols[i]))
            maxErrLinear = max(maxErrLinear, abs(weights[i] - oracleSRGBToLinear(maskCols[i])))
        }

        print("[Oracle] 渐变反解权重：列数=\(weights.count) 首=\(first) 末=\(last) 非单调点=\(dips) 越界点=\(outOfRange)")
        print("[Oracle] 与两类约定的最大偏差：原样灰度=\(maxErrRaw) ／ 线性化灰度=\(maxErrLinear)（打印值，不参与断言）")

        #expect(weights.count >= 120, "可用列太少（\(weights.count)）")
        #expect(first <= 0.06, "最暗端权重应≈0，实测 \(first)")
        #expect(last >= 0.94, "最亮端权重应≈1，实测 \(last)")
        #expect(dips == 0, "权重必须单调不减，非单调点 \(dips)")
        #expect(outOfRange == 0, "权重越界点 \(outOfRange)")
    }

    /// 诊断（**打印型，不写断言**）：上一版「CIBlendWithMask 语义不同」的取证为何不可信。
    ///
    /// 同一个 `CIBlendWithMask` 调用分别在**软件渲染器**与**默认渲染器**下跑，并打印
    /// 前景图（blurred）自身的统计。判定逻辑写在报告里：若前景本身不是黑、而掩码白区输出恒为 0，
    /// 则问题在**渲染环境/调用形态**，不是"两种实现的混合语义不同"——
    /// 这种数字绝不能当 oracle 用（真机复核才作数）。
    @Test("诊断：CIBlendWithMask 在软件 vs 默认渲染器下的分区统计（仅打印）")
    func probeBlendWithMaskEnvironments() throws {
        let sourceCG = try oracleCheckerSourceCG()
        let source = CIImage(cgImage: sourceCG)
        let mask = oracleFittedMask(try oracleHalfMaskCG())

        // 两种前景形态：① 只模糊（预期非黑）② 复刻上一版诊断里的 CIClamp+模糊
        // 若 ② 的掩码白区也变成 0，就证明那是**调用链路**问题（CIClamp 默认区间 [0,1]
        // 在 8-bit 工作格式下把像素压到 1），与本原语语义无关。
        let plainBlur = source
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 6.0])
            .cropped(to: Oracle.extent)
        let clampedBlur = source
            .applyingFilter("CIClamp", parameters: [:])
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 6.0])
            .cropped(to: Oracle.extent)

        let cases: [(String, CIContext)] = [
            ("软件渲染器", CIContext(options: [.useSoftwareRenderer: true])),
            ("默认渲染器", CIContext()),
        ]
        let foregrounds: [(String, CIImage)] = [
            ("仅模糊", plainBlur),
            ("CIClamp+模糊", clampedBlur),
        ]
        let left = 4..<78
        let right = 102..<176

        for (contextName, ctx) in cases {
            for (foregroundName, foreground) in foregrounds {
                let blended = foreground.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: source,
                    kCIInputMaskImageKey: mask,
                ])
                let blendedCG = try #require(ctx.createCGImage(blended, from: Oracle.extent))
                let fgCG = try #require(ctx.createCGImage(foreground, from: Oracle.extent))
                let blendedPlane = try oraclePlane(blendedCG)
                let fgPlane = try oraclePlane(fgCG)

                let bl = blendedPlane.regionMeanStd(xRange: left)
                let br = blendedPlane.regionMeanStd(xRange: right)
                let fl = fgPlane.regionMeanStd(xRange: left)
                let fr = fgPlane.regionMeanStd(xRange: right)
                print("[Probe] \(contextName)／\(foregroundName)：前景 左=\(fl.mean)/\(fl.std) 右=\(fr.mean)/\(fr.std) "
                    + "｜ CIBlend 左=\(bl.mean)/\(bl.std) 右=\(br.mean)/\(br.std)")
            }
        }
    }
}
