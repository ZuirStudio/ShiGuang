import Testing
import Foundation
import CoreGraphics
import EditKit
import RenderKit

// MARK: - .cube 回环 / 行序锚定（R004 快速加固）

/// 目的：在 CI 内闭环证明「烘焙路径（GradingCube.make）」与「解析路径（LUTParser）」
/// 对条目行序的理解完全一致，零真机成本。
///
/// 背景：v0.3.0 抓到过真实缺陷 —— `GradingCube.make` 曾按 red 最慢 / blue 最快烘焙，
/// 而 `CIColorCube` 契约是 **red 最快 / blue 最慢**，导致拖"红色"滑杆实际作用在蓝色像素上。
/// 本套件是对该契约的三重锚定：① 规范手写锚点 ② 烘焙→序列化→解析回环 ③ 语义开关检测器。
@Suite struct LUTCubeRoundTripTests {

    /// 规范锚定：`.cube` 规范与 `CIColorCube` 契约同为 red 最快 / blue 最慢。
    /// 手工按规范书写一个 2³ cube（每个格点取可辨值），断言解析落位正确。
    @Test func specOrderIsRedFastest() throws {
        let text = """
        # 手写规范锚点
        TITLE "Spec Anchor"
        LUT_3D_SIZE 2

        0.00 0.00 0.00
        1.00 0.00 0.00
        0.00 1.00 0.00
        1.00 1.00 0.00
        0.00 0.00 1.00
        1.00 0.00 1.00
        0.00 1.00 1.00
        1.00 1.00 1.00
        """
        let cube = try LUTParser.parse(text)
        #expect(cube.title == "Spec Anchor")
        #expect(cube.size == 2)
        #expect(cube.rgb.count == 24)
        // 第 2 行 = (ri=1, gi=0, bi=0) → 条目序 1 → flat 偏移 3
        #expect(cube.rgb[3] == 1 && cube.rgb[4] == 0 && cube.rgb[5] == 0)
        // 第 3 行 = (ri=0, gi=1, bi=0) → 条目序 2 → flat 偏移 6
        #expect(cube.rgb[6] == 0 && cube.rgb[7] == 1 && cube.rgb[8] == 0)
        // 第 5 行 = (ri=0, gi=0, bi=1) → 条目序 4 → flat 偏移 12
        #expect(cube.rgb[12] == 0 && cube.rgb[13] == 0 && cube.rgb[14] == 1)
    }

    /// 行序公式锚定：flat 索引 = ((bi * N) + gi) * N + ri。
    @Test func flatIndexFormulaMatchesContract() throws {
        let n = 4
        var text = "LUT_3D_SIZE \(n)\n"
        // 第 i 行写成一个可反解的三元组：r = i%n, g = (i/n)%n, b = i/(n*n)
        for i in 0..<(n * n * n) {
            let r = Double(i % n) / Double(n)
            let g = Double((i / n) % n) / Double(n)
            let b = Double(i / (n * n)) / Double(n)
            text += String(format: "%.6f %.6f %.6f\n", r, g, b)
        }
        let cube = try LUTParser.parse(text)
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let entry = ((bi * n) + gi) * n + ri
                    #expect(cube.rgb[entry * 3 + 0] == Float(ri) / Float(n))
                    #expect(cube.rgb[entry * 3 + 1] == Float(gi) / Float(n))
                    #expect(cube.rgb[entry * 3 + 2] == Float(bi) / Float(n))
                }
            }
        }
    }

    /// 语义开关检测器：只给红通道加一条抬升曲线。
    /// 若烘焙行序写反，"红轴"上的条目会落到蓝轴上 —— 本断言立刻失败。
    @Test func bakedCubeKeepsRedOnRedAxis() throws {
        let n = GradingCube.dimension
        var curves = ToneCurveSet()
        curves.red = ToneCurve(points: [CurvePoint(0, 0), CurvePoint(0.5, 1.0), CurvePoint(1, 1)])
        let cube = try #require(GradingCube.make(curves: curves, hsl: HSLAdjustment()))

        // (ri = 16, gi = 0, bi = 0) → 条目序 16 → flat 偏移 48
        let entry = 0 * n * n + 0 * n + 16
        #expect(cube.rgb[entry * 3 + 0] > 0.9)   // 红通道被曲线抬到 ~1
        #expect(cube.rgb[entry * 3 + 1] == 0)    // 绿不受影响
        #expect(cube.rgb[entry * 3 + 2] == 0)    // 蓝不受影响（行序写反时这里会是抬升值）
    }

    /// 回环主测：烘焙 → `.cube` 文本 → 解析 → 逐条目相等（容差 = 文本 6 位小数舍入）。
    @Test func bakedCubeSurvivesTextRoundTrip() throws {
        let n = GradingCube.dimension
        var curves = ToneCurveSet()
        curves.rgb = ToneCurve(points: [CurvePoint(0, 0), CurvePoint(0.25, 0.18), CurvePoint(1, 1)])
        curves.red = ToneCurve(points: [CurvePoint(0, 0), CurvePoint(0.5, 0.72), CurvePoint(1, 1)])
        curves.green = ToneCurve(points: [CurvePoint(0, 0.04), CurvePoint(1, 0.96)])
        curves.blue = ToneCurve(points: [CurvePoint(0, 0), CurvePoint(0.4, 0.22), CurvePoint(1, 1)])
        var hsl = HSLAdjustment()
        hsl[.orange, .saturation] = 35
        hsl[.blue, .luminance] = -20

        let baked = try #require(GradingCube.make(curves: curves, hsl: hsl))
        #expect(baked.size == n)
        #expect(baked.rgb.count == n * n * n * 3)

        let text = LUTParser.serialize(baked)
        #expect(text.contains("LUT_3D_SIZE \(n)"))
        let parsed = try LUTParser.parse(text)

        #expect(parsed.size == baked.size)
        #expect(parsed.rgb.count == baked.rgb.count)
        var maxDelta: Float = 0
        for i in 0..<baked.rgb.count {
            maxDelta = max(maxDelta, abs(parsed.rgb[i] - baked.rgb[i]))
        }
        #expect(maxDelta < 1e-5, "回环最大偏差 \(maxDelta) 超出文本舍入容差")
    }

    /// 回环后进入 `CIColorCubeWithColorSpace` 的 RGBA 数据也必须逐条目一致
    /// （把「解析路径 → 实际喂给 Core Image 的数据」这一段也纳入闭环）。
    @Test func roundTripPreservesColorCubeData() throws {
        var curves = ToneCurveSet()
        curves.rgb = ToneCurve(points: [CurvePoint(0, 0), CurvePoint(0.6, 0.35), CurvePoint(1, 1)])
        let baked = try #require(GradingCube.make(curves: curves, hsl: HSLAdjustment()))
        let parsed = try LUTParser.parse(LUTParser.serialize(baked))

        let a = LUTParser.colorCubeData(baked)
        let b = LUTParser.colorCubeData(parsed)
        #expect(a.count == b.count)
        a.withUnsafeBytes { (ra: UnsafeRawBufferPointer) in
            b.withUnsafeBytes { (rb: UnsafeRawBufferPointer) in
                let fa = ra.bindMemory(to: Float.self)
                let fb = rb.bindMemory(to: Float.self)
                var maxDelta: Float = 0
                for i in 0..<min(fa.count, fb.count) where i % 4 != 3 {
                    maxDelta = max(maxDelta, abs(fa[i] - fb[i]))
                }
                #expect(maxDelta < 1e-5)
                // alpha 恒为 1（premultiplied 不透明）
                for i in stride(from: 3, to: fb.count, by: 4) {
                    #expect(fb[i] == 1)
                }
            }
        }
    }

    /// 恒等曲线 + 恒等 HSL → 不烘焙（调用方零开销跳过）。
    @Test func identityGradingBakesNothing() {
        #expect(GradingCube.make(curves: ToneCurveSet(), hsl: HSLAdjustment()) == nil)
    }

    /// 序列化写出可被自身解析的文本（含标题引号清洗）。
    @Test func serializeIsSelfParsable() throws {
        let cube = LUTCube(title: "拾光\"测试", size: 2, rgb: [
            0, 0, 0,  1, 0, 0,  0, 1, 0,  1, 1, 0,
            0, 0, 1,  1, 0, 1,  0, 1, 1,  1, 1, 1,
        ])
        let text = LUTParser.serialize(cube)
        let parsed = try LUTParser.parse(text)
        #expect(parsed.title == "拾光测试")
        #expect(parsed.size == 2)
        #expect(parsed.rgb == cube.rgb)
    }
}
