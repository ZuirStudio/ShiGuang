import Foundation

// 拾光 · v1.0.x Hotfix H2 · EditKit/RenderNodeCache.swift
// 编译目标：EditKit（纯逻辑，零平台依赖，Linux 可单测）
//
// DAG 中间节点输出哈希缓存（H2 三件套之③）。
//
// 渲染器对「相同 DAG 前缀」的输出做哈希键缓存：相邻两帧（如只微调色轮分级）
// 只有图谱末级（grading）变化，前面 tone/curve/hsl 折叠段完全相同 ——
// 命中前缀缓存则复用前面相同前缀的栅格化结果，只对变化后缀重渲，避免整帧重渲。
//
// 职责边界（与 RenderDeduper 互补）：
// - RenderDeduper：整帧去重（图谱+档位+源/掩码/叠加完全相同 → 跳过整帧）。
// - RenderNodeCache：本结构只负责**命中判定 + LRU 容量淘汰**，是可单测的纯逻辑。
//   真正跨帧持有的输出位图（CIImage / UIImage）由平台侧渲染器 / EditorModel 持有，
//   不进纯逻辑包（避免把 Core Image 带进 Linux 隔离包）。
//
// 为什么是纯逻辑 + Sendable：高频渲染路径上的缓存查询必须能在并发任务中安全调用；
// 内部仅用 `Array` + `Set`（Key: Hashable & Sendable），结构本身满足 Sendable。

/// 节点输出缓存（纯逻辑）：以「DAG 前缀哈希 / 整帧图谱哈希」为键，记录命中并做 LRU 淘汰。
public struct RenderNodeCache<Key: Hashable & Sendable>: Sendable {

    /// 查询结局：命中（已在缓存内，复用既有输出）或未命中（需计算）。
    public enum Outcome: Equatable, Sendable {
        case hit
        case miss
    }

    private var order: [Key] = []
    private var seen: Set<Key> = []
    public private(set) var capacity: Int
    public private(set) var hitCount = 0
    public private(set) var missCount = 0

    public init(capacity: Int = 32) {
        self.capacity = max(1, capacity)
    }

    /// 查询键：
    /// - 已在缓存内 → `.hit`，并把该键提到「最近使用」（LRU 命中更新）。
    /// - 不在缓存内 → `.miss`，记入 LRU；若超过容量则淘汰最久未用的一项。
    public mutating func consider(_ key: Key) -> Outcome {
        if seen.contains(key) {
            if let idx = order.firstIndex(of: key) { order.remove(at: idx) }
            order.append(key)
            hitCount += 1
            return .hit
        }
        missCount += 1
        seen.insert(key)
        order.append(key)
        if order.count > capacity, let oldest = order.first {
            order.removeFirst()
            seen.remove(oldest)
        }
        return .miss
    }

    /// 是否含某键（不更新 LRU）。
    public func contains(_ key: Key) -> Bool { seen.contains(key) }

    /// 当前缓存项数。
    public var count: Int { order.count }

    /// 命中率（0...1）。
    public var hitRatio: Double {
        let total = hitCount + missCount
        return total > 0 ? Double(hitCount) / Double(total) : 0
    }

    /// 清空（不影响容量配置）。
    public mutating func reset() {
        order.removeAll()
        seen.removeAll()
        hitCount = 0
        missCount = 0
    }
}
