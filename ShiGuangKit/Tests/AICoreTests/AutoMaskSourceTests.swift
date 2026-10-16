import Testing
import CoreGraphics
import Foundation
@testable import AICore
import EditKit

// MARK: - P1-E 自动选区：规则层与产物层测试

@Suite("自动选区 · 规则层")
struct AutoMaskRuleTests {

    @Test("垂直权重：顶部满权重，0.62 处衰减到 0")
    func verticalWeightProfile() {
        #expect(AutoMaskSource.verticalWeight(fromTop: 0.0) > 0.99)
        #expect(AutoMaskSource.verticalWeight(fromTop: 0.3) > 0.9)
        #expect(AutoMaskSource.verticalWeight(fromTop: 0.62) == 0)
        #expect(AutoMaskSource.verticalWeight(fromTop: 0.9) == 0)
        #expect(AutoMaskSource.verticalWeight(fromTop: 0.2)
                > AutoMaskSource.verticalWeight(fromTop: 0.5))
    }

    @Test("蓝性：深蓝最高，暖色/中性灰为 0")
    func skynessBlue() {
        let blue = AutoMaskSource.skyness(r: 0.35, g: 0.55, b: 0.85)
        #expect(blue > 0.5)
        #expect(AutoMaskSource.skyness(r: 0.85, g: 0.5, b: 0.25) == 0)  // 暖橙
        #expect(AutoMaskSource.skyness(r: 0.5, g: 0.5, b: 0.5) == 0)     // 中性灰
        #expect(blue > AutoMaskSource.skyness(r: 0.55, g: 0.6, b: 0.62) + 0.4)
    }

    @Test("白性：明亮低饱和为高，暗部/纯色为 0")
    func skynessWhite() {
        #expect(AutoMaskSource.skyness(r: 0.93, g: 0.95, b: 0.97) > 0.5)
        #expect(AutoMaskSource.skyness(r: 0.2, g: 0.2, b: 0.2) == 0)
        #expect(AutoMaskSource.skyness(r: 0.97, g: 0.55, b: 0.3) < 0.2)
    }
}

// MARK: - 产物层（真跑 Core Image / Vision）

/// 造一张「上半蓝天、下半暖地」的图：天空识别必须只圈上半部。
private func makeSkyScene(width: Int = 96, height: Int = 96) -> CGImage? {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: width * 4,
                              space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }
    // CG 坐标原点在左下：先画"下半"= 暖色地面，再画"上半"= 蓝天。
    ctx.setFillColor(red: 0.72, green: 0.52, blue: 0.34, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
    ctx.setFillColor(red: 0.30, green: 0.55, blue: 0.92, alpha: 1)
    ctx.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
    return ctx.makeImage()
}

/// 造一张纯暖色图（无天空）。
private func makeNoSkyImage(width: Int = 64, height: Int = 64) -> CGImage? {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: width * 4,
                              space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }
    ctx.setFillColor(red: 0.86, green: 0.44, blue: 0.16, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()
}

/// 读某一行（0 = 顶部）的掩码均值（0…1）。
private func rowCoverage(_ image: CGImage, fromTop: Double) -> Double? {
    guard let data = image.dataProvider?.data as Data? else { return nil }
    let row = min(image.height - 1, max(0, Int(Double(image.height - 1) * fromTop)))
    let bpr = image.bytesPerRow
    let bpp = max(1, image.bitsPerPixel / 8)
    var sum = 0
    for x in 0..<image.width {
        sum += Int(data[row * bpr + x * bpp])
    }
    return Double(sum) / Double(image.width) / 255.0
}

@Suite("自动选区 · 天空 / 反选")
struct AutoMaskSkyTests {

    @Test("天空掩码：上半部有值，下半部为 0，且是不透明三通道")
    func skyMaskIsUpperHalfOnly() throws {
        let source = try #require(makeSkyScene())
        let mask = try AutoMaskSource.mask(for: .sky, from: source)

        #expect(mask.width == source.width)
        #expect(mask.height == source.height)

        let top = try #require(rowCoverage(mask, fromTop: 0.1))
        let bottom = try #require(rowCoverage(mask, fromTop: 0.9))
        #expect(top > 0.6, "蓝天区域应被选中（实测 \\(top)）")
        #expect(bottom < 0.05, "下半暖色地面不应被选中（实测 \\(bottom)）")
        #expect(top > bottom + 0.5)
    }

    @Test("整幅暖色图：天空识别应报 sceneNotFound 而不是给空掩码")
    func noSkyReportsSceneNotFound() throws {
        let source = try #require(makeNoSkyImage())
        #expect(throws: AutoMaskSourceError.self) {
            _ = try AutoMaskSource.mask(for: .sky, from: source)
        }
    }

    @Test("反选：out = 255 − in，尺寸不变")
    func invertFlipsCoverage() throws {
        let source = try #require(makeSkyScene())
        let mask = try AutoMaskSource.mask(for: .sky, from: source)
        let inverted = try AutoMaskSource.invert(mask)

        #expect(inverted.width == mask.width)
        let topBefore = try #require(rowCoverage(mask, fromTop: 0.1))
        let topAfter = try #require(rowCoverage(inverted, fromTop: 0.1))
        let bottomAfter = try #require(rowCoverage(inverted, fromTop: 0.9))
        #expect(abs((topBefore + topAfter) - 1.0) < 0.02, "上下应互补（\\(topBefore) + \\(topAfter)）")
        #expect(bottomAfter > 0.9)
    }
}
