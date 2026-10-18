import Testing
import Foundation
@testable import SystemKit

/// R009 任务 3 验收：`ProgressTracker` 进度数学（纯逻辑，跨平台可测）。
///
/// 覆盖：步进式与自由式两种用法、权重归一、钳制、终态、空表退化。
@Suite struct ProgressTrackerTests {

    private func batchSteps() -> [ProgressStep] {
        [
            ProgressStep(id: "prepare", title: "准备图像", weight: 1),
            ProgressStep(id: "render", title: "批量处理", weight: 3),
            ProgressStep(id: "save", title: "写盘收尾", weight: 1),
        ]
    }

    // MARK: 初始态

    @Test func initialStateIsNotRunningAtZero() {
        let tracker = ProgressTracker(steps: batchSteps())
        #expect(!tracker.isRunning)
        #expect(tracker.currentIndex == -1)
        #expect(tracker.fraction == 0)
        #expect(tracker.currentStep.id == "prepare")
    }

    @Test func emptyStepsDegradeToSingle() {
        let tracker = ProgressTracker(steps: [])
        #expect(tracker.steps.count == 1)
        #expect(tracker.steps[0].id == "single")
        #expect(tracker.fraction == 0)
    }

    // MARK: 自由式（单步直接给分）

    @Test func freeFormSingleStepFraction() {
        var tracker = ProgressTracker()
        tracker.begin()
        #expect(tracker.fraction == 0)
        tracker.setProgress(0.5)
        #expect(abs(tracker.fraction - 0.5) < 1e-9)
        tracker.setProgress(2)   // 钳制
        #expect(tracker.fraction == 1)
        tracker.setProgress(-1)  // 钳制
        #expect(tracker.fraction == 0)
        tracker.complete()
        #expect(tracker.fraction == 1)
        #expect(tracker.isRunning)   // complete 不改变运行态（由 Manager 收尾）
    }

    // MARK: 步进式（权重归一）

    @Test func stepAdvanceFractionsFollowWeights() {
        var tracker = ProgressTracker(steps: batchSteps())
        tracker.begin()
        #expect(tracker.fraction == 0)
        #expect(tracker.phaseTitle == "准备图像")

        // 第一步走一半：1/5 × 0.5 = 0.1
        tracker.setProgress(0.5)
        #expect(abs(tracker.fraction - 0.1) < 1e-9)

        // 进到第二步（权重 3）：已完成 1/5 = 0.2
        let movedToRender = tracker.advance(toStepID: "render")
        #expect(movedToRender)
        #expect(abs(tracker.fraction - 0.2) < 1e-9)
        #expect(tracker.phaseTitle == "批量处理")

        // 第二步走一半：(1 + 3×0.5)/5 = 0.5
        tracker.setProgress(0.5)
        #expect(abs(tracker.fraction - 0.5) < 1e-9)

        // 末步开始：已完成 4/5 = 0.8
        let movedToSave = tracker.advance(toStepID: "save")
        #expect(movedToSave)
        #expect(abs(tracker.fraction - 0.8) < 1e-9)
        tracker.complete()
        #expect(tracker.fraction == 1)
    }

    @Test func advanceToUnknownStepIsNoOp() {
        var tracker = ProgressTracker(steps: batchSteps())
        tracker.begin()
        tracker.setProgress(0.4)
        let movedToUnknown = tracker.advance(toStepID: "不存在")
        #expect(!movedToUnknown)
        #expect(tracker.currentIndex == 0)
        #expect(abs(tracker.fraction - 0.08) < 1e-9)
    }

    @Test func resetReturnsToInitial() {
        var tracker = ProgressTracker(steps: batchSteps())
        tracker.begin()
        tracker.advance(toStepID: "render")
        tracker.setProgress(0.7)
        tracker.reset()
        #expect(!tracker.isRunning)
        #expect(tracker.currentIndex == -1)
        #expect(tracker.fraction == 0)
    }

    // MARK: 退化路径

    @Test func zeroWeightsFallBackToWithinStep() {
        var tracker = ProgressTracker(steps: [
            ProgressStep(id: "a", title: "A", weight: 0),
            ProgressStep(id: "b", title: "B", weight: 0),
        ])
        tracker.begin()
        tracker.setProgress(0.25)
        #expect(tracker.totalWeight == 0)
        #expect(abs(tracker.fraction - 0.25) < 1e-9)
        tracker.complete()
        #expect(tracker.fraction == 1)
    }

    // MARK: 值语义（并发共享安全）

    @Test func trackerIsValueType() {
        var a = ProgressTracker(steps: batchSteps())
        let b = a
        a.begin()
        a.advance(toStepID: "render")
        #expect(!b.isRunning)
        #expect(b.fraction == 0)
    }
}
