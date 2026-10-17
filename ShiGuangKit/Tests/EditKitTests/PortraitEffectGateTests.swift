import Testing
import EditKit

// MARK: - P0-D（R007c）：皮肤类效果门控策略

@Suite struct PortraitEffectGateTests {
    /// 无皮肤项：任何门控状态下都全量放行（与 v0.7.1 行为一致，零回归面）。
    @Test func noSkinOpsAlwaysAllowAll() {
        let ops: [EditOperation] = [.exposure(0.3), .contrast(-6), .temperature(7)]
        #expect(PortraitEffectGate.usesSkin(ops) == false)
        for ready in [true, false] {
            for preparing in [true, false] {
                let input = PortraitEffectGate.Input(usesSkin: false, maskReady: ready, isPreparing: preparing)
                #expect(PortraitEffectGate.decide(input) == .allowAll)
            }
        }
    }

    /// 门控通过：皮肤项全量放行（掩码由渲染层注入）。
    @Test func maskReadyAllowsSkin() {
        let input = PortraitEffectGate.Input(usesSkin: true, maskReady: true, isPreparing: false)
        #expect(PortraitEffectGate.decide(input) == .allowAll)
    }

    /// 识别中：非皮肤项先应用、皮肤项挂起（用户立刻看到色彩效果，不等掩码）。
    @Test func preparingDefersSkin() {
        let input = PortraitEffectGate.Input(usesSkin: true, maskReady: false, isPreparing: true)
        #expect(PortraitEffectGate.decide(input) == .deferSkin)
    }

    /// 门控拒绝（红车街景：无可用人像）：剔除皮肤项，其余照常。
    @Test func gateRefusedDropsSkin() {
        let input = PortraitEffectGate.Input(usesSkin: true, maskReady: false, isPreparing: false)
        #expect(PortraitEffectGate.decide(input) == .dropSkin)
    }

    /// usesSkin 识别磨皮/美白，且不误伤其它参数。
    @Test func usesSkinDetection() {
        #expect(PortraitEffectGate.usesSkin([.skinSmoothing(25)]) )
        #expect(PortraitEffectGate.usesSkin([.exposure(0.1), .skinBrightening(15)]) )
        #expect(PortraitEffectGate.usesSkin([.exposure(0.1), .contrast(5)]) == false)
        #expect(PortraitEffectGate.usesSkin([]) == false)
    }

    /// 剔除皮肤项保留其余指令的顺序语义（预设的其它效果不能丢）。
    @Test func strippingSkinKeepsOrder() {
        let ops: [EditOperation] = [
            .exposure(0.3), .skinSmoothing(25), .contrast(-6), .skinBrightening(15), .temperature(7),
        ]
        let stripped = PortraitEffectGate.strippingSkin(ops)
        #expect(stripped.count == 3)
        #expect(stripped[0] == .exposure(0.3))
        #expect(stripped[1] == .contrast(-6))
        #expect(stripped[2] == .temperature(7))
        #expect(PortraitEffectGate.usesSkin(stripped) == false)
    }

    /// 恒等性：对无皮肤项的序列调用剔除 = 原序列（不多不少不改序）。
    @Test func strippingSkinIdentityOnNonSkin() {
        let ops: [EditOperation] = [.exposure(0.3), .contrast(-6), .vibrance(10)]
        #expect(PortraitEffectGate.strippingSkin(ops) == ops)
    }

    // MARK: - R007d：蒙版内嵌皮肤项（用户自存预设的整图保存路径）

    /// 自存预设会把蒙版一起保存 —— 蒙版 adjustments 里的磨皮/美白同样是皮肤项。
    /// 只扫顶层会漏掉它们（门控形同虚设），usesSkin 必须递归。
    @Test func usesSkinDetectsMaskNestedSkin() {
        var mask = Mask(name: "脸部", shape: .radial(RadialMask()))
        mask.setAdjustment(.skinSmoothing(30))
        let ops: [EditOperation] = [.exposure(0.2), .mask(mask)]
        #expect(PortraitEffectGate.usesSkin(ops))
    }

    /// 蒙版里只有非皮肤调整 → 不算皮肤项（不能误伤局部调整）。
    @Test func usesSkinIgnoresNonSkinMaskAdjustments() {
        var mask = Mask(name: "背景", shape: .radial(RadialMask()))
        mask.setAdjustment(.exposure(0.4))
        let ops: [EditOperation] = [.mask(mask)]
        #expect(PortraitEffectGate.usesSkin(ops) == false)
    }

    /// 剔除蒙版内嵌皮肤项：蒙版本体与其余局部调整保留，只丢皮肤项。
    @Test func strippingSkinKeepsMaskButDropsNestedSkin() {
        var mask = Mask(name: "脸部", shape: .radial(RadialMask()))
        mask.setAdjustment(.skinSmoothing(30))
        mask.setAdjustment(.exposure(0.4))
        let ops: [EditOperation] = [.mask(mask), .skinBrightening(10)]
        let stripped = PortraitEffectGate.strippingSkin(ops)
        #expect(stripped.count == 1)
        guard case .mask(let out) = stripped[0] else {
            Issue.record("蒙版指令应保留"); return
        }
        #expect(out.adjustments.count == 1)
        #expect(out.adjustments[0] == .exposure(0.4))
        #expect(PortraitEffectGate.usesSkin(stripped) == false)
    }
}
