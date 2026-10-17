import Testing
import Foundation
import CoreImage
import CoreGraphics
@testable import AICore

// MARK: - 测试夹具

private let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

/// 纯色 CIImage（灰度值 value ∈ 0…1）
private func solid(_ value: CGFloat, w: Int = 32, h: Int = 24,
                   origin: CGPoint = .zero) -> CIImage {
    CIImage(color: CIColor(red: value, green: value, blue: value, alpha: 1))
        .cropped(to: CGRect(x: origin.x, y: origin.y, width: CGFloat(w), height: CGFloat(h)))
}

/// 渲染指定区域为 RGBA8 字节
private func bytes(_ image: CIImage, _ rect: CGRect) -> [UInt8] {
    let w = max(1, Int(rect.width)), h = max(1, Int(rect.height))
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CIContext(options: [.useSoftwareRenderer: true])
    buf.withUnsafeMutableBytes { raw in
        if let base = raw.baseAddress {
            ctx.render(image, toBitmap: base, rowBytes: w * 4, bounds: rect,
                       format: .RGBA8, colorSpace: cs)
        }
    }
    return buf
}

/// 取单点亮度（0…255）
private func luma(_ image: CIImage, x: Int, y: Int) -> Int {
    Int(bytes(image, CGRect(x: x, y: y, width: 1, height: 1))[0])
}

// MARK: - C4 核心：人像 ∩ 肤色 求交

@Suite("人像掩码求交")
struct PortraitRefinementTests {
    private let box = CGRect(x: 0, y: 0, width: 32, height: 24)

    @Test("未检出人物 + strictGate → 零掩码（纯风景不会被误磨皮）")
    func strictGateWhenNoPerson() {
        let out = PortraitRefinement.combine(skin: solid(1), person: nil,
                                            extent: box, fallback: .strictGate)
        #expect(luma(out, x: 0, y: 0) == 0)
        #expect(luma(out, x: 16, y: 12) == 0)
        #expect(luma(out, x: 31, y: 23) == 0)
    }

    @Test("未检出人物 + skinOnly → 原样退回肤色掩码（保留 R006 行为）")
    func skinOnlyWhenNoPerson() {
        let out = PortraitRefinement.combine(skin: solid(1), person: nil,
                                            extent: box, fallback: .skinOnly)
        #expect(abs(luma(out, x: 10, y: 10) - 255) <= 2)
    }

    @Test("人物掩码为背景（黑）→ 全零：人物之外不施效果")
    func personBlackSuppressesAll() {
        let out = PortraitRefinement.combine(skin: solid(1), person: solid(0),
                                            extent: box, fallback: .strictGate)
        #expect(luma(out, x: 16, y: 12) == 0)
    }

    @Test("人物掩码为前景（白）→ 等于肤色掩码：人像内不受损")
    func personWhiteKeepsSkin() {
        let out = PortraitRefinement.combine(skin: solid(1), person: solid(1),
                                            extent: box, fallback: .strictGate)
        #expect(abs(luma(out, x: 16, y: 12) - 255) <= 2)
    }

    @Test("肤色为黑 → 结果黑（人像内但没有皮肤也不施效果）")
    func skinBlackStaysBlack() {
        let out = PortraitRefinement.combine(skin: solid(0), person: solid(1),
                                            extent: box, fallback: .strictGate)
        #expect(luma(out, x: 16, y: 12) == 0)
    }

    @Test("两侧半强度 → 被压制且严格小于单侧（交集语义）")
    func intersectionSuppresses() {
        let out = PortraitRefinement.combine(skin: solid(0.5), person: solid(0.5),
                                            extent: box, fallback: .strictGate)
        let v = luma(out, x: 16, y: 12)
        #expect(v > 0)
        #expect(v < 128)
    }

    @Test("输出范围严格裁到目标 extent（不溢出原图）")
    func croppedToExtent() {
        let out = PortraitRefinement.combine(skin: solid(1, w: 64, h: 64),
                                              person: solid(1, w: 64, h: 64),
                                              extent: box, fallback: .strictGate)
        #expect(out.extent == box)
    }

    @Test("尺寸不一致的人物掩码先重采样再求交（P0-D v0.7.1 对齐修复）")
    func resamplesPersonBeforeIntersect() {
        // 128×128 的左半白人物掩码 vs 64×64 肤色掩码。
        // v0.7.0 直接把全尺寸掩码与缩略肤色相乘（person 只经 cropped(to:) 裁剪不缩放），
        // 取到的是「左上角」错位区域 → 整个 64 盒被判成人像（全选）；
        // 修复后重采样到 64×64，只有左半命中。
        let person = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 128))
            .composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0))
                .cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128)))
        let out = PortraitRefinement.combine(skin: solid(1, w: 64, h: 64),
                                             person: person,
                                             extent: CGRect(x: 0, y: 0, width: 64, height: 64),
                                             fallback: .strictGate)
        #expect(luma(out, x: 8, y: 32) > 150)
        #expect(luma(out, x: 56, y: 32) == 0)
    }
}

// MARK: - 注入用 stub（CI 上不需要真实推理就能验降级路径）

private struct StubProvider: PersonMaskProviding, Sendable {
    var mask: SendableSegmentImage? = nil
    var fail: PortraitSegmentationError? = nil

    func personMask(for image: SendableSegmentImage) async throws -> SendableSegmentImage? {
        if let fail { throw fail }
        return mask
    }
}

/// 造纯色 CGImage。
///
/// 刻意用 **deviceRGB**（与 `PortraitMaskAnalyzer.downsample` 的 context 同空间）：
/// 同空间绘制是恒等变换，字节不会被色彩管理改写，判定结果才可复现 —— 若这里用 sRGB
/// 而下游用 deviceRGB，在 CI runner 的 display profile 上可能整体漂移，导致测试偶发。
private func solidImage(_ r: UInt8, _ g: UInt8, _ b: UInt8, n: Int = 64) -> CGImage? {
    var buf = [UInt8](repeating: 255, count: n * n * 4)
    for i in 0..<(n * n) {
        buf[i * 4] = r; buf[i * 4 + 1] = g; buf[i * 4 + 2] = b
    }
    guard let provider = CGDataProvider(data: Data(buf) as CFData) else { return nil }
    return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)
}

/// 肤色像素 (220,170,140)：修复后的 BT.601 判定得 Cb≈104.6 / Cr≈155.4，
/// 距区间边界（Cb 77…127、Cr 133…173）各有 17 以上余量，不吃色彩管理的小漂移。
private func skinTone() -> CGImage? { solidImage(220, 170, 140) }

private func meanLuma(_ image: CIImage, n: Int = 64) -> Double {
    let b = bytes(image, CGRect(x: 0, y: 0, width: n, height: n))
    var sum = 0
    for i in stride(from: 0, to: b.count, by: 4) { sum += Int(b[i]) }
    return Double(sum) / Double(n * n)
}

// MARK: - R006 遗留缺陷回归：肤色判定尺度（0…255 vs 归一化）

@Suite("肤色判定回归（R007b-1 修复）")
struct SkinToneMaskTests {

    @Test("已知肤色像素 → 掩码大面积命中（修复前恒为全黑）")
    func skinToneIsDetected() throws {
        let src = try #require(skinTone())
        let mask = try #require(PortraitMaskAnalyzer.skinMask(for: src))
        #expect(mask.width == 64 && mask.height == 64)
        let mean = meanLuma(CIImage(cgImage: mask))
        #expect(mean > 150, "修复前该均值恒为 0：Cb 恒在 127.5…128.5，`cb <= 127` 永不成立")
    }

    @Test("中性灰 → 不判为肤色（证明判定不是「恒真」）")
    func neutralGrayIsNotSkin() throws {
        let src = try #require(solidImage(128, 128, 128))
        let mask = try #require(PortraitMaskAnalyzer.skinMask(for: src))
        #expect(meanLuma(CIImage(cgImage: mask)) < 8)
    }

    @Test("纯蓝 → 不判为肤色")
    func blueIsNotSkin() throws {
        let src = try #require(solidImage(0, 0, 255))
        let mask = try #require(PortraitMaskAnalyzer.skinMask(for: src))
        #expect(meanLuma(CIImage(cgImage: mask)) < 8)
    }
}

// MARK: - C4 门控与降级（stub 注入，CI 无需真实推理）

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var raw: [(Int, Int)] = []
    func append(_ d: Int, _ t: Int) { lock.lock(); raw.append((d, t)); lock.unlock() }
    var values: [(Int, Int)] { lock.lock(); defer { lock.unlock() }; return raw }
}

/// 人像掩码夹具：左半白（人像）、右半黑（背景）
private func leftHalfPersonMask(n: Int = 64) -> CIImage {
    let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
        .cropped(to: CGRect(x: 0, y: 0, width: n / 2, height: n))
    let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
        .cropped(to: CGRect(x: 0, y: 0, width: n, height: n))
    return white.composited(over: black)
}

@Suite("合成掩码流水线（门控 + 降级 + 进度）")
struct PortraitMaskBuilderTests {

    @Test("分割不可用 + strictGate → 仍出图（全零），不报错不崩")
    func unavailableStrictGate() async throws {
        let tone = try #require(skinTone())
        let out = try #require(await PortraitMaskBuilder.build(
            for: tone, provider: StubProvider(fail: .badInput),
            fallback: .strictGate))
        #expect(out.personFound == false)
        #expect(out.personSegmentationAvailable == false)
        #expect(out.appliedFallback == .strictGate)
        #expect(luma(CIImage(cgImage: out.mask), x: 32, y: 32) == 0)
    }

    @Test("分割不可用 + skinOnly → 退回肤色掩码（不黑屏，效果仍可用）")
    func unavailableSkinOnly() async throws {
        let tone = try #require(skinTone())
        let out = try #require(await PortraitMaskBuilder.build(
            for: tone, provider: StubProvider(fail: .badInput),
            fallback: .skinOnly))
        #expect(out.personSegmentationAvailable == false)
        #expect(out.appliedFallback == .skinOnly)
        #expect(meanLuma(CIImage(cgImage: out.mask)) > 150)
    }

    @Test("检出人物 → 只保留人像侧的肤色（人像 ∩ 肤色）")
    func personFoundGates() async throws {
        let tone = try #require(skinTone())
        let out = try #require(await PortraitMaskBuilder.build(
            for: tone,
            provider: StubProvider(mask: SendableSegmentImage(leftHalfPersonMask())),
            fallback: .strictGate))
        #expect(out.personFound)
        #expect(out.appliedFallback == nil)
        let m = CIImage(cgImage: out.mask)
        #expect(luma(m, x: 8, y: 32) > 150)
        #expect(luma(m, x: 56, y: 32) == 0)
    }

    @Test("检出人物（实测覆盖率 50%）→ 生效且覆盖率如实上报")
    func measuredCoveragePersonApplies() async throws {
        let tone = try #require(skinTone())
        let out = try #require(await PortraitMaskBuilder.build(
            for: tone,
            provider: StubProvider(mask: SendableSegmentImage(
                leftHalfPersonMask(), personCoverage: 0.5)),
            fallback: .strictGate))
        #expect(out.personFound)
        #expect(out.appliedFallback == nil)
        #expect(out.willApplyEffect)
        #expect(abs(out.personCoverage - 0.5) < 1e-9)
        #expect(out.combinedCoverage > 0.4)
    }

    // MARK: - P0-D（v0.7.1）：按真实覆盖率门控，不信「返回非 nil」

    @Test("全覆盖人物掩码 + 检不出人脸 → 判定误检，零掩码不生效（红车街景场景）")
    func allWhitePersonWithoutFaceIsRejected() async throws {
        // skinTone() 是纯色图，VNDetectFaceLandmarksRequest 检不出人脸。
        // v0.7.0 在此场景把全白掩码当「检出人物」→ 肤色掩码整图生效。
        let tone = try #require(skinTone())
        let allWhite = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let out = try #require(await PortraitMaskBuilder.build(
            for: tone,
            provider: StubProvider(mask: SendableSegmentImage(allWhite, personCoverage: 1.0)),
            fallback: .strictGate))
        #expect(out.personFound == false)
        #expect(out.willApplyEffect == false)
        #expect(out.appliedFallback == .strictGate)
        #expect(luma(CIImage(cgImage: out.mask), x: 32, y: 32) == 0)
        #expect(out.personCoverage == 1.0)
        #expect(out.combinedCoverage == 0)
    }

    @Test("零覆盖率人物掩码（全黑）→ 未检出人物，效果不生效")
    func zeroCoveragePersonIsRejected() async throws {
        let tone = try #require(skinTone())
        let allBlack = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let out = try #require(await PortraitMaskBuilder.build(
            for: tone,
            provider: StubProvider(mask: SendableSegmentImage(allBlack, personCoverage: 0)),
            fallback: .strictGate))
        #expect(out.personFound == false)
        #expect(out.willApplyEffect == false)
        #expect(meanLuma(CIImage(cgImage: out.mask)) == 0)
    }

    @Test("进度回调覆盖 0…stageCount 且单调不减")
    func progressIsMonotonic() async throws {
        let box = ProgressBox()
        let tone = try #require(skinTone())
        let out = await PortraitMaskBuilder.build(
            for: tone, provider: StubProvider(mask: nil),
            fallback: .strictGate, progress: { d, t in box.append(d, t) })
        #expect(out != nil)
        let seen = box.values
        #expect(seen.first?.0 == 0)
        #expect(seen.last?.0 == PortraitMaskBuilder.stageCount)
        #expect(seen.allSatisfy { $0.1 == PortraitMaskBuilder.stageCount })
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0.0.0 <= $0.1.0 })
    }
}

// MARK: - R007d：收紧后的门控（纯函数全覆盖 + 红车案场景回归）

@Suite("R007d 门控收紧：isCrediblePerson 纯函数裁决")
struct CrediblePersonGateTests {

    @Test("未返回观测 → 一律不可信")
    func noObservationNeverCredible() {
        #expect(PortraitMaskBuilder.isCrediblePerson(personFound: false, personCoverage: 0.5, faceCount: 3) == false)
    }

    @Test("覆盖率未测量（<0）→ 退回旧语义：返回观测即可信")
    func unmeasuredCoverageFallsBackToLegacy() {
        #expect(PortraitMaskBuilder.isCrediblePerson(personFound: true, personCoverage: -1, faceCount: 0))
    }

    /// 红车案主凶：0.5%…2% 的散粒「人物」检出 —— 旧规则（0.5% 下限）放行，
    /// 新规则（2% 下限）拒绝。
    @Test func specklePersonBelowFloorIsRejected() {
        #expect(PortraitMaskBuilder.isCrediblePerson(personFound: true, personCoverage: 0.005, faceCount: 0) == false)
        #expect(PortraitMaskBuilder.isCrediblePerson(personFound: true, personCoverage: 0.019, faceCount: 0) == false)
        #expect(PortraitMaskBuilder.isCrediblePerson(personFound: true, personCoverage: 0.02, faceCount: 1))
    }

    /// 红车案真正缺口：2%…5% 的灰色地带，无人脸佐证 → 拒；有脸 → 放。
    @Test func smallPersonRequiresFaceEvidence() {
        #expect(PortraitMaskBuilder.isCrediblePerson(personFound: true, personCoverage: 0.03, faceCount: 0) == false)
        #expect(PortraitMaskBuilder.isCrediblePerson(personFound: true, personCoverage: 0.03, faceCount: 1))
    }

    /// 5%…98% 的正常占比：不强制要脸（背影 / 侧身人像不受误伤）。
    @Test func normalCoverageDoesNotRequireFace() {
        #expect(PortraitMaskBuilder.isCrediblePerson(personFound: true, personCoverage: 0.06, faceCount: 0))
        #expect(PortraitMaskBuilder.isCrediblePerson(personFound: true, personCoverage: 0.5, faceCount: 0))
        #expect(PortraitMaskBuilder.isCrediblePerson(personFound: true, personCoverage: 0.9, faceCount: 0))
    }

    /// 近全覆盖 + 无脸 → 分割器误检（v0.7.0「全图生效」根因，规则保留）。
    @Test func nearFullCoverageWithoutFaceIsRejected() {
        #expect(PortraitMaskBuilder.isCrediblePerson(personFound: true, personCoverage: 0.99, faceCount: 0) == false)
        #expect(PortraitMaskBuilder.isCrediblePerson(personFound: true, personCoverage: 0.99, faceCount: 1))
    }
}

@Suite("R007d 门控收紧：红车案端到端回归（stub 注入）")
struct RedCarGateRegressionTests {

    /// 红车案复刻：车身上一块 3% 的误检人物 ∩ 红色肤色域。
    /// 旧规则：3% ≥ 0.5% 下限 → 放行 → 磨皮落在车身上。
    /// 新规则：3% < 5% 且纯色图检不出人脸 → 拒绝 → 零掩码不生效。
    @Test func carBodySpeckleIsRejectedEndToEnd() async throws {
        let tone = try #require(skinTone())
        // 64×64 里一块 ~3% 的「人物」误检（左上一小块）
        let speckle = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 64 * 0.17, height: 64 * 0.17))
            .composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0))
                .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)))
        let out = try #require(await PortraitMaskBuilder.build(
            for: tone,
            provider: StubProvider(mask: SendableSegmentImage(speckle, personCoverage: 0.03)),
            fallback: .strictGate))
        #expect(out.personFound == false)
        #expect(out.willApplyEffect == false)
        #expect(out.appliedFallback == .strictGate)
        #expect(meanLuma(CIImage(cgImage: out.mask)) == 0)
    }

    /// 对照：真正的大面积人像（50% 占比）照常生效 —— 证明门控不是「恒拒」。
    @Test func realPortraitStillApplies() async throws {
        let tone = try #require(skinTone())
        let out = try #require(await PortraitMaskBuilder.build(
            for: tone,
            provider: StubProvider(mask: SendableSegmentImage(leftHalfPersonMask(), personCoverage: 0.5)),
            fallback: .strictGate))
        #expect(out.personFound)
        #expect(out.willApplyEffect)
        #expect(out.combinedCoverage > 0.4)
    }
}
