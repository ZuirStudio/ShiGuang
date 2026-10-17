import Testing
import Foundation
import EditKit

// MARK: - R007d P0-D：门控拒绝时「图谱 + 历史」成对剔除皮肤项

@Suite("皮肤项剔除（图谱 × 历史成对）")
struct SkinPurgeTests {

    /// 图谱剔除：只剔皮肤项，其余指令顺序原样保留；返回值 = 被剔除项。
    @Test func graphRemoveSkinKeepsOthers() {
        var graph = EditGraph(operations: [
            .exposure(0.3), .skinSmoothing(25), .contrast(-6), .skinBrightening(15),
        ])
        let removed = graph.removeSkinOperations()
        #expect(removed.count == 2)
        #expect(removed.contains(.skinSmoothing(25)))
        #expect(removed.contains(.skinBrightening(15)))
        #expect(graph.operations == [.exposure(0.3), .contrast(-6)])
    }

    /// 无残留时剔除是零操作（不误触发重渲路径）。
    @Test func graphRemoveSkinNoopWhenAbsent() {
        var graph = EditGraph(operations: [.exposure(0.3), .contrast(-6)])
        #expect(graph.removeSkinOperations().isEmpty)
        #expect(graph.operations.count == 2)
    }

    /// 核心回归：只剔图谱不剔历史 → undo 会把皮肤项复活回图谱。
    /// 本测试锁定「成对剔除」语义：历史同步剔后，重放序列不再含皮肤项。
    @Test func historyRemoveSkinBlocksResurrection() {
        var history = EditHistory()
        history.commit(label: "预设·人像", operations: [.exposure(0.3), .skinSmoothing(40)])
        history.commit(label: "滑杆", operations: [.contrast(6)])
        // 模拟 EditorModel.purgeSkinEffects：图谱 + 历史成对剔除
        var graph = EditGraph(operations: history.operations)
        _ = graph.removeSkinOperations()
        history.removeSkinOperations()
        // 剔除后历史重放序列无皮肤项
        #expect(history.operations.contains(where: { $0.isSkin }) == false)
        #expect(history.operations == [.exposure(0.3), .contrast(6)])
        // undo/redo 重放也不会把皮肤项带回来（redo 缓冲同样被剔）
        _ = history.undo()
        #expect(history.redoSteps.contains(where: { $0.operations.contains(where: { $0.isSkin }) }) == false)
        _ = history.redo()
        #expect(history.operations.contains(where: { $0.isSkin }) == false)
    }

    /// 纯皮肤步骤被整步移除（不留空步骤污染历史面板）；混合步骤只丢皮肤项。
    @Test func historyRemoveSkinDropsEmptySteps() {
        var history = EditHistory()
        history.commit(label: "磨皮", operations: [.skinSmoothing(40)])
        history.commit(label: "预设·人像", operations: [.skinSmoothing(40), .vibrance(6)])
        history.removeSkinOperations()
        #expect(history.stepCount == 1)
        #expect(history.steps[0].label == "预设·人像")
        #expect(history.steps[0].operations == [.vibrance(6)])
    }
}
