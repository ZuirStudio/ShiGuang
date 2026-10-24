import Foundation

// MARK: - 历史步骤

/// 历史步骤：一批指令 + 人类可读标签（如「曝光 +0.3」「应用胶片预设」）。
/// 预设应用等多指令操作作为一个原子步骤进入历史。
public struct HistoryStep: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let label: String
    public let operations: [EditOperation]
    /// 步骤提交时间（R010：历史面板按时间倒序展示用；撤销/重放/jump 不依赖它）。
    public let timestamp: Date
    /// H3：节点级开关。默认 true（渲染参与）；false = 该步不参与渲染但参数保留，可重新启用。
    /// 旧档（无此字段）解码默认 true，序列化兼容。
    public let enabled: Bool

    public init(id: UUID = UUID(), label: String, operations: [EditOperation], timestamp: Date = Date(), enabled: Bool = true) {
        self.id = id
        self.label = label
        self.operations = operations
        self.timestamp = timestamp
        self.enabled = enabled
    }

    // H3：自定义解码，旧档缺 enabled 字段时回退 true（序列化兼容旧档）。
    private enum CodingKeys: String, CodingKey {
        case id, label, operations, timestamp, enabled
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        operations = try c.decode([EditOperation].self, forKey: .operations)
        timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

// MARK: - 编辑历史

/// 编辑历史（ADR-003）：
/// - undo = 截断最后一步；redo = 重放缓冲；
/// - jump(to:) = 任意回溯，被移除的步骤按时间顺序进 redo 缓冲；
/// - `operations` 是渲染管线的唯一输入。
public struct EditHistory: Equatable, Codable, Sendable {
    public internal(set) var steps: [HistoryStep] = []
    public internal(set) var redoSteps: [HistoryStep] = []

    public init() {}

    /// 当前完整指令序列（= 渲染输入）。
    /// 折叠语义与 `EditGraph` 一致：**蒙版按 id 去重** —— 保留首次出现的位置
    /// （叠加顺序稳定），取最后一次出现的值（后写覆盖）。这样「蒙版编辑 = 新增一步」
    /// 在 undo/redo 下依然自洽：撤销一步即回到上一版蒙版，而不是同时存在两个同名蒙版。
    /// H3：仅聚合 `enabled` 的步骤；禁用步骤跳过渲染但保留（可重新启用）。
    public var operations: [EditOperation] {
        var out: [EditOperation] = []
        var maskIndex: [UUID: Int] = [:]
        for step in steps where step.enabled {
            for op in step.operations {
                if let mask = op.maskValue {
                    if let index = maskIndex[mask.id] {
                        out[index] = op
                    } else {
                        maskIndex[mask.id] = out.count
                        out.append(op)
                    }
                } else {
                    out.append(op)
                }
            }
        }
        return out
    }

    /// 当前可回溯位置数（历史面板行数）。
    public var stepCount: Int { steps.count }

    /// 提交一个原子步骤（清空 redo 缓冲）。
    public mutating func commit(_ step: HistoryStep) {
        steps.append(step)
        redoSteps.removeAll()
    }

    public mutating func commit(label: String, operations: [EditOperation]) {
        commit(HistoryStep(label: label, operations: operations))
    }

    /// 交互式提交（滑杆拖动）：同标签连续拖动合并为一个历史步骤，
    /// 历史面板不因一次拖动产生几十行。任何提交清空 redo 缓冲。
    public mutating func commitInteractive(label: String, operation: EditOperation) {
        if let last = steps.last, last.label == label {
            steps[steps.count - 1] = HistoryStep(label: label, operations: [operation])
        } else {
            steps.append(HistoryStep(label: label, operations: [operation]))
        }
        redoSteps.removeAll()
    }

    /// 剔除所有历史步骤（含 redo 缓冲）里的皮肤类指令（R007d P0-D）。
    ///
    /// 与 `EditGraph.removeSkinOperations` **必须成对调用**：图谱是渲染输入、
    /// 历史是 undo/redo 的重放源（`resyncFromHistory` 用历史重建图谱）——
    /// 只剔图谱不剔历史，一次 undo 就把皮肤项复活回图谱。
    /// 剔除后变为空步骤的步骤一并移除（它已无可撤销内容，留着只会污染历史面板）。
    public mutating func removeSkinOperations() {
        steps = steps.compactMap { step in
            let kept = step.operations.filter { !$0.isSkin }
            return kept.isEmpty ? nil : HistoryStep(id: step.id, label: step.label, operations: kept, timestamp: step.timestamp)
        }
        redoSteps = redoSteps.compactMap { step in
            let kept = step.operations.filter { !$0.isSkin }
            return kept.isEmpty ? nil : HistoryStep(id: step.id, label: step.label, operations: kept, timestamp: step.timestamp)
        }
    }

    /// 撤销最后一步；无可撤销时返回 nil。
    @discardableResult
    public mutating func undo() -> HistoryStep? {
        guard let last = steps.popLast() else { return nil }
        redoSteps.append(last)
        return last
    }

    /// 重做最后被撤销的步骤。
    @discardableResult
    public mutating func redo() -> HistoryStep? {
        guard let next = redoSteps.popLast() else { return nil }
        steps.append(next)
        return next
    }

    /// 任意回溯：保留前 `index` 个步骤（jump(to: 0) = 回到原图），
    /// 其余按时间顺序压入 redo 栈顶（redo 栈为 LIFO：逆序压入保证重放顺序）。
    public mutating func jump(to index: Int) {
        let idx = max(0, min(index, steps.count))
        guard idx < steps.count else { return }
        let removed = Array(steps[idx...])
        steps.removeSubrange(idx...)
        redoSteps.append(contentsOf: removed.reversed())
    }
}
