import Foundation

// 拾光 · v1.0.x Hotfix H1 · shared/ServiceInstallGate.swift
// 编译目标：主 App Target + Widget Extension Target + Linux 逻辑测试隔离包
//
// 一次性服务装配门（DispatchOnce 的 Swift 6 形态）。
//
// 背景（H1 根因）：快捷指令 AppIntent 以后台进程执行
// （openAppWhenRun = false），不经过 ShiGuangApp.init()，
// 挂在「App 启动副作用」上的 DI 装配不会发生，PhotoPipeline 闭包
// 保持默认抛错态。修法：装配入口收敛到一个幂等门，任何进程
// （App 启动 / AppIntent perform）在首次使用前 ensureInstalled() 即可。
//
// 设计约束：
// - onInstall 标 @MainActor：真实安装函数（installPhotoPipelineAndDeepLinks）
//   为主线程隔离；门本身不持有隔离，保证 @unchecked Sendable 成立。
// - 安装动作为同步：Swift 6 禁止 async 上下文调用 NSLock（会阻塞协作式
//   线程池），「锁内执行安装」要求安装同步完成 —— 真实安装即纯闭包赋值，
//   天然同步；需要 await 的重活不属于安装阶段，放在闭包被调用时。
// - ensureInstalled() 标 @MainActor 同步：与 onInstall 同隔离；调用方
//   （如 nonisolated 的 AppIntent.perform）经 await 隐式跳主线程。
// - 「恰好一次」语义用 NSLock 保证：先到者执行安装并置位，后到者阻塞等待
//   后直接返回（绝不重入、绝不漏装 —— 锁内执行安装动作，消除
//   「置位-执行」之间的竞态窗口；@MainActor 串行化进一步保证
//   ensureInstalled 之间不并发）。

/// 一次性装配门。线程安全；同一门的所有 ensureInstalled() 合计数恰好触发一次安装。
public final class ServiceInstallGate: @unchecked Sendable {

    private let lock = NSLock()
    private var installed = false
    private let onInstall: @MainActor () -> Void

    /// - Parameter onInstall: 安装动作。在 @MainActor 上同步执行；须为幂等的纯装配
    ///   （闭包赋值级操作，不得做重活 —— 重活留给闭包被调用时按需执行）。
    public init(onInstall: @escaping @MainActor () -> Void) {
        self.onInstall = onInstall
    }

    /// 是否已装配（非隔离可读：内部加锁）。
    public var isInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return installed
    }

    /// 幂等确保已装配。首次调用执行 onInstall，后续调用零成本跳过。
    /// 标 @MainActor 同步：与 onInstall 同隔离，锁内执行安装，无竞态窗口。
    @MainActor
    public func ensureInstalled() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        onInstall()
        installed = true
    }

    /// 测试辅助：恢复未装配态（不影响 onInstall 引用）。
    public func resetForTesting() {
        lock.lock()
        installed = false
        lock.unlock()
    }
}
