import Foundation
import os

/// R007b-1 Stage B1：渲染管线性能埋点。
///
/// 设计要点：
/// 1. **os_signpost**：每个阶段都有静态名称的区间/事件，真机接 Instruments（Time Profiler / os_signpost）
///    即可看到时间线上的真实耗时——这是 B1「必须埋点证明，不能凭代码看起来对」的落点。
/// 2. **轻量累加器**：除 signpost 外同时累计「次数 / 均值 / 峰值 / 最近一次」，成本 ~ns 级，
///    便于在真机不接 Instruments 时用 `report()` 打印一份摘要（例如日志或诊断面板）。
/// 3. **可实例化**：`shared` 是进程级单例，但 `init()` 公开——单测用独立实例，
///    避免 R006 踩过的「进程级单例 + Swift Testing 并行 → 互相污染」问题。
/// 4. 线程安全：`NSLock` 保护累加器（渲染在后台线程，手势/主线程也会读最近耗时）。
public enum PerfStage: String, Sendable, CaseIterable, Hashable {
    /// 预览渲染整条管线（RenderPipeline.render）
    case previewRender
    /// 仍量（全质量）渲染
    case stillRender
    /// 蒙版 alpha 生成
    case maskAlpha
    /// 蒙版 alpha 命中缓存（只计数）
    case maskAlphaCacheHit
    /// createCGImage 出图
    case cgImage
    /// 主线程回转/赋值阻塞
    case mainThreadHop
    /// CIContext 构造（进程内应恒为 1 次）
    case ciContextCreate
    /// 缩略图生成
    case thumbnail
    /// 被去重跳过的预览请求（R007b-1 Stage B3）
    case renderSkipped
    /// 人像/肤色掩码生成（Vision 分析，Stage B/C 都要盯的冷路径）
    case aiMaskPrepare

    /// 供 os_signpost 使用的静态名称（signpost 要求 StaticString）。
    var signpostName: StaticString {
        switch self {
        case .previewRender: return "previewRender"
        case .stillRender: return "stillRender"
        case .maskAlpha: return "maskAlpha"
        case .maskAlphaCacheHit: return "maskAlphaCacheHit"
        case .cgImage: return "cgImage"
        case .mainThreadHop: return "mainThreadHop"
        case .ciContextCreate: return "ciContextCreate"
        case .thumbnail: return "thumbnail"
        case .renderSkipped: return "renderSkipped"
        case .aiMaskPrepare: return "aiMaskPrepare"
        }
    }
}

/// 单阶段统计。
public struct PerfSample: Sendable, Equatable {
    public var count: Int = 0
    public var totalMS: Double = 0
    public var maxMS: Double = 0

    public init(count: Int = 0, totalMS: Double = 0, maxMS: Double = 0) {
        self.count = count
        self.totalMS = totalMS
        self.maxMS = maxMS
    }

    public var meanMS: Double { count > 0 ? totalMS / Double(count) : 0 }
}

/// 进程级性能埋点收集器。
public final class PerfSignpost: @unchecked Sendable {
    public static let shared = PerfSignpost()

    private let log: OSLog
    private let lock = NSLock()
    private var samples: [PerfStage: PerfSample] = [:]
    private var last: [PerfStage: Double] = [:]

    public init(subsystem: String = "studio.zuir.shiguang", category: String = "perf") {
        self.log = OSLog(subsystem: subsystem, category: category)
    }

    /// 记一次事件（只计数，不算耗时）。
    public func bump(_ stage: PerfStage) {
        os_signpost(.event, log: log, name: stage.signpostName)
        record(stage, ms: 0)
    }

    /// 记录一次耗时。
    public func record(_ stage: PerfStage, ms: Double) {
        let value = ms.isFinite ? Swift.max(0, ms) : 0
        lock.lock()
        var s = samples[stage] ?? PerfSample()
        s.count += 1
        s.totalMS += value
        s.maxMS = Swift.max(s.maxMS, value)
        samples[stage] = s
        last[stage] = value
        lock.unlock()
    }

    /// 测量一个**同步**区间并累加统计。用 `defer` 实现，天然覆盖多 return 路径。
    @discardableResult
    public func measure<T>(_ stage: PerfStage, _ body: () throws -> T) rethrows -> T {
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer { record(stage, ms: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000) }
        return try body()
    }

    /// 开始一个 signpost 区间（跨线程/跨函数时用 begin/end 配对）。
    public func begin(_ stage: PerfStage, detail: String = "") -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: stage.signpostName, signpostID: id, "%{public}@", detail)
        return id
    }

    /// 结束 signpost 区间。
    public func end(_ stage: PerfStage, _ id: OSSignpostID, detail: String = "") {
        os_signpost(.end, log: log, name: stage.signpostName, signpostID: id, "%{public}@", detail)
    }

    public func count(_ stage: PerfStage) -> Int {
        lock.lock(); defer { lock.unlock() }
        return samples[stage]?.count ?? 0
    }

    /// 最近一次该阶段耗时（毫秒）；没有样本返回 0。供 FramePacer 自适应节流使用。
    public func lastMS(_ stage: PerfStage) -> Double {
        lock.lock(); defer { lock.unlock() }
        return last[stage] ?? 0
    }

    public func sample(_ stage: PerfStage) -> PerfSample {
        lock.lock(); defer { lock.unlock() }
        return samples[stage] ?? PerfSample()
    }

    public func reset() {
        lock.lock(); samples.removeAll(); last.removeAll(); lock.unlock()
    }

    /// 生成一份可读摘要（真机不接 Instruments 时的证据来源）。
    public func report() -> String {
        lock.lock()
        let snapshot = samples
        lock.unlock()
        var lines = ["# 拾光 性能埋点摘要（R007b-1 Stage B1）"]
        for stage in PerfStage.allCases {
            guard let s = snapshot[stage], s.count > 0 else { continue }
            lines.append(String(format: "%-22@ 次数 %4d  均值 %7.2fms  峰值 %7.2fms",
                                stage.rawValue as NSString, s.count, s.meanMS, s.maxMS))
        }
        if lines.count == 1 { lines.append("（尚无样本）") }
        return lines.joined(separator: "\n")
    }
}
