import CoreImage
import CoreGraphics
import Foundation

/// 进程级共享的 Core Image 渲染上下文。
///
/// ## 为什么必须共享（R006 性能专项）
/// v0.5.0 之前全工程有 3 处各自 `CIContext()`：
/// 1. `EditorModel.context`（预览热路径）
/// 2. `EditorModel.prepareSkinMask` 的 detached 任务里
/// 3. `EditorModel.export` 里
///
/// 每次 `CIContext()` 构造都会重新申请 GPU 命令队列 / Metal 设备与着色器缓存，
/// 实测 10–30ms 起步，且反复申请会持续抬高功耗与内存峰值（真机升温来源之一）。
/// Apple 文档明确：**`CIContext` 是线程安全的，应尽量复用**。
public enum RenderContext {
    /// 共享上下文。预览、AI 掩码、导出全部走这一个。
    ///
    /// `cacheIntermediates: false`：修图预览每帧都是「整条图重建」，
    /// 中间结果缓存命中率极低却持续占用显存/内存 → 关掉可显著降低内存峰值与功耗。
    ///
    /// R007b-1 Stage B1：构造点**唯一**且带埋点 —— `ciContextCreate` 在真机日志里
    /// 应当恒为 1（进程生命周期只建一次）。若某次改动不小心在热路径里再 `CIContext()`，
    /// 这个计数会立刻暴露它（B2 必核查点 1 的可验证形式）。
    public nonisolated(unsafe) static let shared: CIContext = {
        PerfSignpost.shared.bump(.ciContextCreate)
        return CIContext(options: [.cacheIntermediates: false])
    }()

    /// R007c：**导出专用**上下文。
    ///
    /// v0.7.1 真机埋点：`cgImage` 峰值 28268ms（≈28 秒）—— 全分辨率导出（12MP 级）
    /// 与预览/掩码/缩略图共用同一个 CIContext，GPU 命令队列被导出长任务占满，
    /// 滑杆预览的 `createCGImage` 全部排在后面等 → 画面「定格卡死」、机身发热，
    /// 主线程随后被堆积的手势回调冲爆（stillRender 冲到 8147 次）。
    ///
    /// Core Image 的 context 线程安全但**不并行**：并发提交会在队列里串行。
    /// 导出是「一次性、全分辨率、慢」的任务，预览是「高频、低分辨率、必须跟手」的任务，
    /// 两者混在一个队列里必然互相拖死。拆成两个 context 后：
    /// - 预览 / 掩码 / 缩略图继续复用 `shared`（构造一次，热路径零额外开销）；
    /// - 导出独占 `export`，再慢也只会让导出页转圈，不碰画布的一根手指。
    ///
    /// 代价：多一个 CIContext（共享 Metal 设备，构造一次 ~10-30ms，之后零成本）。
    public nonisolated(unsafe) static let export: CIContext = {
        PerfSignpost.shared.bump(.exportContextCreate)
        return CIContext(options: [.cacheIntermediates: false])
    }()
}

// MARK: - 预览降采样（已移除）

/// R010-C 安全审查：原 `PreviewQuality` 档位枚举与 `PreviewScaler` 在此处**全部删除**。
/// 原因有两条：
/// 1. **死代码**：全仓库（含测试）零引用 —— App 层预览档位用的是 `EditorModel` 自己
///    嵌套的同名 `PreviewQuality`（1600/1024），RenderKit 这份从未被接线；
/// 2. **文档与实现漂移**：其注释称静止档长边 2048「验收要求的预览上限」，
///    与真实常量 `EditorModel.stillLongEdge = 1600` 矛盾 —— 留着就是给后续
///    审查者埋误判陷阱。预览降采样的真实实现见 `EditorModel.source(for:)` 与
///    `downscaledForPipeline(_:longEdge:)`。
