import Testing
import Foundation
@testable import RenderKit

/// R007b-1 Stage B1：性能埋点内核的自证测试。
///
/// 这些用例证明「埋点本身可信」——真机上 `PerfSignpost.shared.report()` 打印出的数字
/// 与 signpost 时间线才有意义。全部用**独立实例**，不碰进程级 `shared`（避免并行污染）。
@Suite("PerfSignpost 性能埋点内核")
struct PerfSignpostTests {

    @Test("measure 累加次数 / 总耗时 / 峰值，并写入最近一次")
    func measureAccumulates() {
        let p = PerfSignpost()
        p.measure(.previewRender) { _ = (0..<1000).reduce(0, +) }
        p.measure(.previewRender) { _ = (0..<1000).reduce(0, +) }

        let s = p.sample(.previewRender)
        #expect(s.count == 2)
        #expect(s.totalMS >= 0)
        #expect(s.maxMS >= 0)
        #expect(s.meanMS == s.totalMS / 2)
        #expect(p.lastMS(.previewRender) >= 0)
    }

    @Test("measure 会传播返回值与抛错（rethrows 语义不被埋点破坏）")
    func measureIsTransparent() throws {
        let p = PerfSignpost()
        let value = p.measure(.cgImage) { 42 }
        #expect(value == 42)

        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try p.measure(.cgImage) { throw Boom() }
        }
        // 抛错路径也必须计数（defer 生效）
        #expect(p.count(.cgImage) == 2)
    }

    @Test("bump 只计数、不计耗时")
    func bumpCountsWithoutTiming() {
        let p = PerfSignpost()
        p.bump(.maskAlphaCacheHit)
        p.bump(.maskAlphaCacheHit)
        p.bump(.maskAlphaCacheHit)
        #expect(p.count(.maskAlphaCacheHit) == 3)
        #expect(p.sample(.maskAlphaCacheHit).totalMS == 0)
        #expect(p.sample(.maskAlphaCacheHit).meanMS == 0)
    }

    @Test("非法耗时被夹到 0，不污染统计（NaN / 负数 / 无穷）")
    func invalidDurationsAreSanitized() {
        let p = PerfSignpost()
        p.record(.thumbnail, ms: -5)
        p.record(.thumbnail, ms: .nan)
        p.record(.thumbnail, ms: .infinity)
        let s = p.sample(.thumbnail)
        #expect(s.count == 3)
        #expect(s.totalMS == 0)
        #expect(s.maxMS == 0)
    }

    @Test("report 在无样本时给出占位行，有样本时逐阶段列出")
    func reportContent() {
        let p = PerfSignpost()
        #expect(p.report().contains("尚无样本"))

        p.measure(.stillRender) { _ = 1 }
        p.bump(.ciContextCreate)
        let text = p.report()
        #expect(text.contains("stillRender"))
        #expect(text.contains("ciContextCreate"))
        #expect(text.contains("次数"))
    }

    @Test("独立实例互不干扰（并行测试安全的根据）")
    func instancesAreIsolated() {
        let a = PerfSignpost()
        let b = PerfSignpost()
        a.bump(.previewRender)
        a.bump(.previewRender)
        b.bump(.previewRender)
        #expect(a.count(.previewRender) == 2)
        #expect(b.count(.previewRender) == 1)
    }

    @Test("reset 清空样本与最近值")
    func resetClears() {
        let p = PerfSignpost()
        p.measure(.maskAlpha) { _ = 1 }
        p.reset()
        #expect(p.count(.maskAlpha) == 0)
        #expect(p.lastMS(.maskAlpha) == 0)
        #expect(p.report().contains("尚无样本"))
    }

    @Test("begin/end 区间返回可配对的 id（跨线程/跨函数埋点用）")
    func beginEndPairing() {
        let p = PerfSignpost()
        let id = p.begin(.mainThreadHop, detail: "requestPreview")
        p.end(.mainThreadHop, id, detail: "requestPreview")
        // signpost 区间本身不写累加器（只进 Instruments 时间线），这里只验证调用不崩
        #expect(p.count(.mainThreadHop) == 0)
    }

    @Test("全部阶段都有静态 signpost 名称（CaseIterable 全覆盖，无遗漏）")
    func everyStageHasSignpostName() {
        for stage in PerfStage.allCases {
            #expect(stage.signpostName.description.isEmpty == false)
            #expect(stage.rawValue.isEmpty == false)
        }
        #expect(PerfStage.allCases.count == 10)
    }
}
