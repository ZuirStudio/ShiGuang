import Foundation

// MARK: - 编辑图

/// 非破坏编辑图（ADR-003）：有序指令数组即完整编辑状态。
/// 序列化后即为 `.recipe` 预设与 App Intents 复放的载体。
public struct EditGraph: Equatable, Codable, Sendable {
    public private(set) var operations: [EditOperation]

    public init(operations: [EditOperation] = []) {
        self.operations = operations
    }

    public var isEmpty: Bool { operations.isEmpty }

    /// 追加一条指令（自动裁剪到合法范围）。
    public mutating func append(_ operation: EditOperation) {
        operations.append(operation.clamped)
    }

    /// 交互式调整（滑杆拖动）：同参数连续调整时替换最后一条而非追加，
    /// 避免拖动一次产生几十条历史。返回 true 表示发生了替换。
    @discardableResult
    public mutating func updateInteractive(_ operation: EditOperation) -> Bool {
        let clamped = operation.clamped
        if let last = operations.last, last.parameter == clamped.parameter {
            operations[operations.count - 1] = clamped
            return true
        }
        operations.append(clamped)
        return false
    }
}

// MARK: - 文档信封

/// 序列化文档（含 schemaVersion，为未来迁移预留）。
public struct EditDocument: Equatable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var graph: EditGraph
    public var history: EditHistory

    public init(
        schemaVersion: Int = EditDocument.currentSchemaVersion,
        graph: EditGraph = EditGraph(),
        history: EditHistory = EditHistory()
    ) {
        self.schemaVersion = schemaVersion
        self.graph = graph
        self.history = history
    }
}
