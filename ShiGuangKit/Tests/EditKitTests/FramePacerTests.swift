import Testing
import Foundation
@testable import EditKit

@Suite("FramePacer 自适应帧预算")
struct FramePacerTests {

    @Test("渲染很快时保持 floor 节奏（跟手）")
    func fastRenderUsesFloor() {
        let pacer = FramePacer()
        #expect(pacer.intervalMS(lastRenderMS: 12) == 24)
        #expect(pacer.isThrottled(lastRenderMS: 12) == false)
    }

    @Test("渲染中等时按 headroom 错开，避免堆积")
    func mediumRenderScales() {
        let pacer = FramePacer()
        // 40 × 1.25 = 50
        #expect(pacer.intervalMS(lastRenderMS: 40) == 50)
        #expect(pacer.isThrottled(lastRenderMS: 40))
    }

    @Test("渲染很慢时被 ceiling 封顶")
    func slowRenderCapped() {
        let pacer = FramePacer()
        #expect(pacer.intervalMS(lastRenderMS: 400) == 150)
        #expect(pacer.intervalMS(lastRenderMS: 120) == 150)
    }

    @Test("无样本/非法耗时时退回 floor")
    func invalidInputFallsBackToFloor() {
        let pacer = FramePacer()
        #expect(pacer.intervalMS(lastRenderMS: 0) == 24)
        #expect(pacer.intervalMS(lastRenderMS: -5) == 24)
        #expect(pacer.intervalMS(lastRenderMS: .nan) == 24)
        #expect(pacer.intervalMS(lastRenderMS: .infinity) == 24)
    }

    @Test("interval 返回可直接用于 sleep 的 Duration")
    func intervalDuration() {
        let pacer = FramePacer()
        #expect(pacer.interval(lastRenderMS: 40) == .milliseconds(50))
        #expect(pacer.interval(lastRenderMS: 1000) == .milliseconds(150))
    }

    @Test("throttleRatio 量化省下的开销")
    func ratio() {
        let pacer = FramePacer()
        #expect(pacer.throttleRatio(lastRenderMS: 400) == 150.0 / 24.0)
        #expect(pacer.throttleRatio(lastRenderMS: 10) == 1.0)
    }

    @Test("退化配置被钳制，不会产生 0 间隔或倒挂")
    func degenerateConfiguration() {
        let bad = FramePacer.Configuration(floorMS: 0, ceilingMS: 5, headroom: 0.1, slowThresholdMS: -3)
        #expect(bad.floorMS == 1)
        #expect(bad.ceilingMS == 1)
        #expect(bad.headroom == 1)
    }

    @Test("节奏随耗时单调不减")
    func monotonic() {
        let pacer = FramePacer()
        let values = [1.0, 10, 20, 30, 60, 120, 500].map { pacer.intervalMS(lastRenderMS: $0) }
        for i in 1..<values.count {
            #expect(values[i] >= values[i - 1])
        }
    }
}
