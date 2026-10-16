import CoreGraphics
import Foundation
import EditKit
import AICore

/// P1-E：自动选区掩码缓存（主体 / 天空 / 背景）。
///
/// 为什么是一个独立的类型：
/// - 渲染器（`BasicAdjustmentRenderer`）是 **struct 值语义**，每次渲染都做值拷贝；
///   把「大图掩码」放进渲染器会让每次快照都复制一份引用计数并不贵，
///   但**生命周期**必须跟着蒙版走（蒙版删了掩码要一起没），所以集中放在这里。
/// - 渲染在后台线程读、生成在主线程写 → 必须显式同步（`NSLock`）。
///
/// 线程契约：`@unchecked Sendable` —— 所有可变状态都在 `lock` 之内访问，
/// 存进去的 `CGImage` 不可变。渲染线程只做同步读取，不做生成。
final class AutoMaskStore: @unchecked Sendable {

    private let lock = NSLock()
    private var images: [UUID: CGImage] = [:]
    private var failures: [UUID: AutoMaskSourceError] = [:]

    init() {}

    // MARK: - 写入（主线程）

    func store(_ image: CGImage, for id: UUID) {
        lock.lock()
        images[id] = image
        failures[id] = nil
        lock.unlock()
    }

    func recordFailure(_ error: AutoMaskSourceError, for id: UUID) {
        lock.lock()
        failures[id] = error
        lock.unlock()
    }

    func remove(_ id: UUID) {
        lock.lock()
        images[id] = nil
        failures[id] = nil
        lock.unlock()
    }

    /// 清掉所有已删除蒙版的缓存（蒙版被删/文档切换时调用）。
    func retain(only ids: Set<UUID>) {
        lock.lock()
        images = images.filter { ids.contains($0.key) }
        failures = failures.filter { ids.contains($0.key) }
        lock.unlock()
    }

    // MARK: - 读取（任意线程）

    func image(for id: UUID) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return images[id]
    }

    func failure(for id: UUID) -> AutoMaskSourceError? {
        lock.lock()
        defer { lock.unlock() }
        return failures[id]
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return images.count
    }

    // MARK: - 渲染器注入

    /// 供给 `BasicAdjustmentRenderer.maskAlphaProvider`。
    ///
    /// 只认「自动选区」形状：其它形状返回 nil → 渲染器回退到几何渲染，
    /// 因此画笔/线性/径向的行为完全不变（不会被这条新路径影响）。
    ///
    /// 返回的 `CGImage` 尺寸与生成时的分析图一致，通常**不等于**渲染 extent
    /// （预览是降采样档）—— 缩放对齐由 RenderKit `MaskFit.fit` 负责。
    var provider: @Sendable (Mask, CGRect) -> CGImage? {
        { [weak self] mask, _ in
            guard case .auto = mask.shape else { return nil }
            return self?.image(for: mask.id)
        }
    }
}

// MARK: - 场景映射

extension AutoMaskScene {
    /// `MaskKind` → 自动选区场景（只有自动三兄弟有映射）。
    init?(kind: MaskKind) {
        switch kind {
        case .subject: self = .subject
        case .sky: self = .sky
        case .background: self = .background
        case .linear, .radial, .brush: return nil
        }
    }
}
