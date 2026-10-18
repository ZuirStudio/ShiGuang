import Testing
import Foundation
@testable import SystemKit

/// R009 任务 3 验收：`ProgressManager` 编排语义（门面 + 节流 + 幂等 + 降级）。
/// Mock 呈现器收集调用序列 —— 不依赖 ActivityKit，跨平台可测。
@MainActor
@Suite struct ProgressManagerTests {

    /// 收集调用的 Mock 呈现器（@MainActor 收集，避免并发写；
    /// `available` 为不可变 let —— nonisolated 读取安全，满足协议 nonisolated 需求）。
    @MainActor
    private final class MockPresenter: ProgressPresenting {
        struct Call: Equatable {
            enum Kind: Equatable { case present, update, dismiss }
            var kind: Kind
            var fraction: Double
            var phase: String
        }

        private let available: Bool
        private(set) var calls: [Call] = []

        init(available: Bool = true) {
            self.available = available
        }

        nonisolated var isAvailable: Bool { available }

        func present(title: String, fraction: Double, phase: String, detail: String) async {
            calls.append(Call(kind: .present, fraction: fraction, phase: phase))
        }

        func update(fraction: Double, phase: String, detail: String) async {
            calls.append(Call(kind: .update, fraction: fraction, phase: phase))
        }

        func dismiss(fraction: Double, phase: String, detail: String) async {
            calls.append(Call(kind: .dismiss, fraction: fraction, phase: phase))
        }

        func reset() { calls.removeAll() }
    }

    private func makeManager() -> (ProgressManager, MockPresenter) {
        let mock = MockPresenter()
        let manager = ProgressManager(presenter: mock, tracker: ProgressTracker())
        return (manager, mock)
    }

    // MARK: 生命周期

    @Test func beginPresentsCardAtZero() async throws {
        let (manager, mock) = makeManager()
        manager.begin(title: "批量导出")
        // begin 内部 Task 是火照忘：等一个调度周期让 Mock 收到
        await settle()
        #expect(manager.isActive)
        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].kind == .present)
        #expect(mock.calls[0].fraction == 0)
        #expect(manager.currentTitle == "批量导出")
        manager.cancel()
    }

    @Test func beginIsIdempotentWhileActive() async throws {
        let (manager, mock) = makeManager()
        manager.begin(title: "AI 消除")
        manager.begin(title: "重复")   // 进行中再 begin：忽略
        await settle()
        #expect(mock.calls.count == 1)
        manager.cancel()
        await settle()
    }

    @Test func reportPushesUpdateAndAdvancesTracker() async throws {
        let (manager, mock) = makeManager()
        manager.begin(title: "AI 消除")
        await settle()
        mock.reset()
        manager.report(fraction: 0.42, phase: "消除中", detail: "第 1 处")
        await settle()
        #expect(abs(manager.fraction - 0.42) < 1e-9)
        #expect(manager.phaseTitle == "消除中")
        #expect(mock.calls.last?.kind == .update)
        #expect(abs((mock.calls.last?.fraction ?? -1) - 0.42) < 1e-9)
        manager.finish()
    }

    @Test func updatesAreThrottledWithinWindow() async throws {
        let (manager, mock) = makeManager()
        manager.begin(title: "节流")
        await settle()
        mock.reset()
        // 300ms 窗口内连报两次：只有第一次送达卡片
        manager.report(fraction: 0.1, phase: "A", detail: "")
        manager.report(fraction: 0.2, phase: "B", detail: "")
        await settle()
        #expect(mock.calls.count == 1)
        #expect(abs(mock.calls[0].fraction - 0.1) < 1e-9)
        // tracker 本体不受节流影响（UI 浮层仍然跟手）
        #expect(abs(manager.fraction - 0.2) < 1e-9)
        manager.cancel()
    }

    @Test func finishDismissesAtFullFraction() async throws {
        let (manager, mock) = makeManager()
        manager.begin(title: "批量导出", steps: [
            ProgressStep(id: "a", title: "A"),
            ProgressStep(id: "b", title: "B"),
        ])
        await settle()
        manager.advance(toStepID: "b")
        await settle()
        mock.reset()
        manager.finish(phase: "已完成", detail: "3 张导出完成")
        await settle()
        #expect(!manager.isActive)
        #expect(mock.calls.last?.kind == .dismiss)
        #expect(mock.calls.last?.fraction == 1)
    }

    @Test func cancelBeforeBeginIsNoOp() async throws {
        let (manager, mock) = makeManager()
        manager.cancel()
        manager.report(fraction: 0.5, phase: "X", detail: "")
        manager.finish()
        await settle()
        #expect(mock.calls.isEmpty)
        #expect(!manager.isActive)
    }

    @Test func unavailablePresenterStillTracksInApp() async throws {
        let mock = MockPresenter(available: false)
        let manager = ProgressManager(presenter: mock, tracker: ProgressTracker())
        manager.begin(title: "降级")
        await settle()
        manager.report(fraction: 0.6, phase: "处理中", detail: "")
        // 呈现器不可用不影响 tracker 与门面状态（App 内浮层照常工作）
        #expect(manager.isActive)
        #expect(abs(manager.fraction - 0.6) < 1e-9)
        manager.cancel()
    }

    // MARK: 工具

    /// 等火照忘 Task 完成（Mock 呈现器的调用发生在 MainActor 上的子任务）。
    private func settle() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
    }
}
