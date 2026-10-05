import Foundation

// MARK: - 历史步骤

/// 历史步骤：一批指令 + 人类可读标签（如「曝光 +0.3」「应用胶片预设」）。
/// 预设应用等多指令操作作为一个原子步骤进入历史。
public struct HistoryStep: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let label: String
    public let operations: [EditOperation]

    public init(id: UUID = UUID(), label: String, operations: [EditOperation]) {
        self.id = id
        self.label = label
        self.operations = operations
    }
}

// MARK: - 编辑历史

/// 编辑历史（ADR-003）：
/// - undo = 截断最后一步；redo = 重放缓冲；
/// - jump(to:) = 任意回溯，被移除的步骤按时间顺序进 redo 缓冲；
/// - `operations` 是渲染管线的唯一输入。
public struct EditHistory: Equatable, Codable, Sendable {
    public private(set) var steps: [HistoryStep] = []
    public private(set) var redoSteps: [HistoryStep] = []

    public init() {}

    /// 当前完整指令序列（= 渲染输入）。
    public var operations: [EditOperation] { steps.flatMap(\.operations) }

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
    /// 其余按时间顺序放入 redo 缓冲头部。
    public mutating func jump(to index: Int) {
        let idx = max(0, min(index, steps.count))
        guard idx < steps.count else { return }
        let removed = Array(steps[idx...])
        steps.removeSubrange(idx...)
        redoSteps.insert(contentsOf: removed, at: 0)
    }
}
