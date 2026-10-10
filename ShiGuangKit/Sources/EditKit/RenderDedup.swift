import Foundation

/// R007b-1 Stage B3：**预览渲染去重**（纯逻辑，可单测）。
///
/// 真机「滑杆一松手就发热」的根因之一不是渲染慢，而是**同一状态被渲染了不止一次**：
/// `endInteractiveEditing()` 会补一帧静止档，而 900ms 后的 `scheduleAutoStillPreview`
/// 兜底还会再调一次 `endInteractiveEditing()` —— 图谱、档位、源、掩码全都一模一样，
/// 第二帧纯属白烧 GPU。
///
/// 判据是「**输出相关的全部输入**」构成的键：
/// - `graph`：指令数组（值类型，比较代价与指令条数同阶，通常 < 100 条）
/// - `quality`：`interactive` / `still` 两档（分辨率不同 → 输出不同，绝不能互相去重）
/// - `sourceToken`：预览源换代号（重新 load / 换图时自增）
/// - `maskToken`：人像掩码换代号（掩码就绪后必须重渲，不能被去重吃掉）
/// - `overlayMaskID`：当前叠加选区的 id（切换选区/开关叠加会改输出）
///
/// 与 `PreviewQuality` 的关系：档位是键的一部分，所以「拖动中 1024 → 松手 1600」
/// 这一对请求**不会被误判为重复**，A3「抬手升完整预览」保得住。
public struct RenderKey: Equatable, Sendable {
    public var graph: EditGraph
    public var quality: String
    public var sourceToken: Int
    public var maskToken: Int
    public var overlayMaskID: UUID?

    public init(
        graph: EditGraph,
        quality: String,
        sourceToken: Int,
        maskToken: Int,
        overlayMaskID: UUID?
    ) {
        self.graph = graph
        self.quality = quality
        self.sourceToken = sourceToken
        self.maskToken = maskToken
        self.overlayMaskID = overlayMaskID
    }
}

/// 渲染去重器。语义：**只按「已接受的那一帧」的键去重**，不感知渲染是否完成
/// （飞行中的合并由调用方的 `pendingRender` 负责，两者职责不重叠）。
public struct RenderDeduper: Sendable {
    /// 最近一次被接受的渲染键（nil = 无记录，任何请求都放行）。
    public private(set) var lastAccepted: RenderKey?
    /// 被去重跳过的请求数（报告用的实测量，不是估算）。
    public private(set) var skippedCount = 0
    /// 被接受的请求数。
    public private(set) var acceptedCount = 0

    public init() {}

    /// 是否应该真的发起渲染。`force` 用于「必须重渲」的少数路径（例如内存压力后重建）。
    public mutating func shouldRender(_ key: RenderKey, force: Bool = false) -> Bool {
        if force { return true }
        if let last = lastAccepted, last == key {
            skippedCount += 1
            return false
        }
        return true
    }

    /// 记录一次被接受的渲染请求（**发起时**记录，不是完成时——避免飞行中重复排队）。
    public mutating func recordAccepted(_ key: RenderKey) {
        lastAccepted = key
        acceptedCount += 1
    }

    /// 使去重记录失效（下一次请求必然放行）。
    public mutating func invalidate() {
        lastAccepted = nil
    }

    public mutating func reset() {
        lastAccepted = nil
        skippedCount = 0
        acceptedCount = 0
    }

    /// 跳过率（0...1）。真机报告的量化指标。
    public var skipRatio: Double {
        let total = skippedCount + acceptedCount
        return total > 0 ? Double(skippedCount) / Double(total) : 0
    }
}
