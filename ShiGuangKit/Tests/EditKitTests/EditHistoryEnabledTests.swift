import Testing
import Foundation
@testable import EditKit

// MARK: - H3：历史面板节点级开关

/// 覆盖 H3 验收「Linux 单测验证禁用节点不影响图谱序列化往返」：
/// - 禁用步骤不进入渲染输入（`EditHistory.operations`），但保留于 `steps`（参数不丢、可重新启用）；
/// - 旧档（无 `enabled` 字段）解码默认 `true`，序列化兼容；
/// - `EditDocument`（含 schemaVersion + graph + history）往返后禁用态与 operations 过滤一致。
@Suite struct EditHistoryEnabledTests {

    private func exposure(_ v: Double) -> EditOperation { .exposure(v) }

    // MARK: - 渲染输入过滤

    /// 禁用中间一步：该步指令不出现在 operations，但仍留在 steps（参数保留）。
    @Test func disabledStepExcludedFromOperationsButKeptInSteps() {
        var history = EditHistory()
        history.commit(label: "曝光", operations: [exposure(0.3)])
        history.commit(label: "对比度", operations: [.contrast(0.5)])

        let disabledID = history.steps[0].id
        history.steps[0] = HistoryStep(
            id: history.steps[0].id, label: history.steps[0].label,
            operations: history.steps[0].operations,
            timestamp: history.steps[0].timestamp, enabled: false
        )

        #expect(history.steps.count == 2)
        #expect(history.operations.count == 1)
        #expect(history.operations.contains(.contrast(0.5)))
        #expect(!history.operations.contains(exposure(0.3)))
        // 参数仍在 steps 里，只是被跳过
        #expect(history.steps.first(where: { $0.id == disabledID })?.enabled == false)
        #expect(history.steps.first(where: { $0.id == disabledID })?.operations == [exposure(0.3)])
    }

    /// 重新启用被禁用步骤：指令重新进入 operations。
    @Test func reEnablingStepRestoresOperations() {
        var history = EditHistory()
        history.commit(label: "曝光", operations: [exposure(0.3)])
        history.commit(label: "对比度", operations: [.contrast(0.5)])
        history.steps[0] = HistoryStep(
            id: history.steps[0].id, label: history.steps[0].label,
            operations: history.steps[0].operations,
            timestamp: history.steps[0].timestamp, enabled: false
        )
        #expect(history.operations.count == 1)

        history.steps[0] = HistoryStep(
            id: history.steps[0].id, label: history.steps[0].label,
            operations: history.steps[0].operations,
            timestamp: history.steps[0].timestamp, enabled: true
        )
        #expect(history.operations.count == 2)
    }

    // MARK: - 序列化兼容（旧档无 enabled 字段 → 默认 true）

    /// 旧版 `.recipe` / 文档缺 `enabled` 字段时解码默认 `true`，不破坏既有字段。
    /// 做法：编码一个真实步骤后手动剔除 `enabled` 键，模拟旧档（避免依赖具体 payload 编码格式）。
    @Test func legacyStepWithoutEnabledDecodesToTrue() throws {
        let step = HistoryStep(label: "曝光", operations: [exposure(0.3)])
        let raw = try JSONEncoder().encode(step)
        let dict = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        var legacy = dict
        legacy.removeValue(forKey: "enabled")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)

        let decoded = try JSONDecoder().decode(HistoryStep.self, from: legacyData)
        #expect(decoded.enabled == true)
        #expect(decoded.label == "曝光")
        #expect(decoded.operations == [exposure(0.3)])
    }

    /// 新档 `enabled: false` 编码后往返保持 false。
    @Test func disabledStepRoundTripsFalse() throws {
        let step = HistoryStep(label: "对比度", operations: [.contrast(0.5)], enabled: false)
        let data = try JSONEncoder().encode(step)
        let decoded = try JSONDecoder().decode(HistoryStep.self, from: data)
        #expect(decoded.enabled == false)
        #expect(decoded.label == "对比度")
        #expect(decoded.operations == [.contrast(0.5)])
    }

    // MARK: - 图谱（EditDocument）序列化往返

    /// H3 验收核心：禁用步在 EditDocument 往返后仍 disabled，且 operations 过滤在往返后保持一致。
    @Test func documentRoundTripPreservesDisabledAndOperations() throws {
        var history = EditHistory()
        history.commit(label: "曝光", operations: [exposure(0.3)])
        history.commit(label: "对比度", operations: [.contrast(0.5)])
        history.steps[1] = HistoryStep(
            id: history.steps[1].id, label: history.steps[1].label,
            operations: history.steps[1].operations,
            timestamp: history.steps[1].timestamp, enabled: false
        )
        let doc = EditDocument(graph: EditGraph(operations: history.operations), history: history)

        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(EditDocument.self, from: data)

        #expect(decoded.schemaVersion == EditDocument.currentSchemaVersion)
        #expect(decoded.history.steps.count == 2)
        #expect(decoded.history.steps[0].enabled == true)
        #expect(decoded.history.steps[1].enabled == false)
        // 往返后渲染输入仍只含启用步
        #expect(decoded.history.operations == [exposure(0.3)])
        // 图谱与历史渲染输入同源一致
        #expect(decoded.graph.operations == decoded.history.operations)
    }

    /// 蒙版去重与禁用交互：被禁用的是蒙版步时，不应干扰同 id 蒙版的去重（后写覆盖）语义。
    @Test func disabledMaskStepDoesNotAffectDedup() {
        let maskID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let maskV1 = Mask(id: maskID, name: "m", shape: .radial(RadialMask()), opacity: 100, adjustments: [exposure(0.3)])
        let maskV2 = Mask(id: maskID, name: "m", shape: .radial(RadialMask()), opacity: 80, adjustments: [exposure(0.9)])

        var history = EditHistory()
        history.commit(label: "蒙版v1", operations: [.mask(maskV1)])
        history.commit(label: "对比度", operations: [.contrast(0.5)])
        history.commit(label: "蒙版v2", operations: [.mask(maskV2)])

        // 禁用中间的对比度步
        history.steps[1] = HistoryStep(
            id: history.steps[1].id, label: history.steps[1].label,
            operations: history.steps[1].operations,
            timestamp: history.steps[1].timestamp, enabled: false
        )

        // 启用步：蒙版去重保留 v2（后写覆盖），对比度被跳过
        let ops = history.operations
        #expect(ops.count == 1)
        if case let .mask(m) = ops[0] {
            #expect(m.id == maskID)
            #expect(m.adjustments == [exposure(0.9)]) // v2 胜出
        } else {
            Issue.record("期望去重后仅剩蒙版 v2")
        }
    }
}
