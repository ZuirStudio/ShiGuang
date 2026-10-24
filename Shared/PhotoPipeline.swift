import Foundation

// 拾光 · v1.0.x Hotfix H1 · shared/PhotoPipeline.swift
// 编译目标：主 App Target + Widget Extension Target + Linux 逻辑测试隔离包
//
// PhotoPipeline：App Intents 与主工程业务代码之间的「服务网关」。
//
// 为什么需要它：
//   快捷指令可能由系统在后台拉起执行，不能直接引用主工程的
//   相册 / 编辑器 / 导出器实现。主工程注入真实闭包实现
//   （见 App/AppIntents/PhotoPipelineInjection.swift）：
//
//   PhotoPipeline.applyPreset = { presetID, photoID in
//       try await YourEditorService.shared.apply(presetID: presetID, photoID: photoID)
//   }
//   PhotoPipeline.exportPhoto = { photoID in
//       try await YourExporter.shared.export(photoID: photoID)
//   }
//
// 未注入时调用会抛出 notConfigured，不会崩溃。
//
// ── H1 修复（快捷指令「用预设处理并导出照片」报未配置）──────────────
// 根因：装配（installPhotoPipelineAndDeepLinks）只挂在 ShiGuangApp.init()
// 启动副作用上；AppIntent 以后台进程执行，不经过 App 启动，DI 未装配。
//
// 修法（惰性装配）：
//   1. 装配动作经 ServiceInstallGate 收敛为幂等门；
//   2. 每个「不经过 App 启动」的入口（AppIntent.perform 首行）先
//      ensureInstalled()，再调用闭包；
//   3. installer 由 App 侧注册（AppIntent 文件在 App target，可引用
//      import UIKit 的装配函数；Widget / Linux 无宿主，installer 为 nil，
//      门保持未装配态 —— 不会误装、不会崩）。
//   4. notConfigured 降级为内部信号：面向用户文案改为通用说法，
//      内部细节只进 NSLog（App 侧文件，见 PhotoPipelineInjection.swift）。
//
// 本文件保持纯 Foundation（不 import UIKit / AppIntents），
// 因此可被 Linux 隔离包复制、由单测直接驱动（H1 验收）。

@MainActor
public enum PhotoPipeline {

    /// 套用预设（实现内应顺手写入 RecentEditsStore 以刷新 Widget）
    public static var applyPreset: @Sendable (_ presetID: String, _ photoID: String) async throws -> Void = { _, _ in
        throw PhotoPipelineError.notConfigured
    }

    /// 导出照片，返回导出文件 URL
    public static var exportPhoto: @Sendable (_ photoID: String) async throws -> URL = { _ in
        throw PhotoPipelineError.notConfigured
    }

    /// 最近照片 ID 列表（快捷指令默认取第一张）
    public static var recentPhotoIDs: @Sendable () async -> [String] = { [] }

    /// 打开编辑器（带回预设；用于「继续编辑」路径）
    public static var openEditor: @Sendable (_ photoID: String, _ presetID: String?) -> Void = { _, _ in }

    // ── H1：惰性装配 ────────────────────────────────────────────────

    /// DI 装配动作（真实装配函数引用）。
    ///
    /// 注册点（均在 App target，可引用 import UIKit 的装配函数）：
    ///   - ShiGuangApp.init()：App 正常启动路径；
    ///   - ApplyPresetAndExportIntent.perform()：快捷指令后台进程入口。
    ///
    /// 非 App 宿主（Widget Extension / Linux 测试隔离包）保持 nil：
    /// ensureInstalled() 直接跳过，闭包维持默认态。
    public static var installer: (@MainActor () -> Void)?

    /// 一次性装配门（幂等）。installer 为 nil 时安装动作为空操作。
    private static let installGate = ServiceInstallGate {
        installer?()
    }

    /// 在「不经过 App 启动」的入口首行调用：确保 DI 已装配。
    ///
    /// App 启动路径（ShiGuangApp.init 已立即装配）下为零成本跳过；
    /// AppIntent 后台进程下完成装配，随后 handler 闭包可正常解析。
    public static func ensureInstalled() async {
        guard installer != nil else { return }
        installGate.ensureInstalled()
    }

    /// 测试辅助：恢复出厂态（闭包默认值 + installer 置空 + 门复位）。
    /// Linux 隔离包单测在 setUp 调用；App target 无测试引用。
    public static func resetForTesting() {
        applyPreset = { _, _ in throw PhotoPipelineError.notConfigured }
        exportPhoto = { _ in throw PhotoPipelineError.notConfigured }
        recentPhotoIDs = { [] }
        openEditor = { _, _ in }
        installer = nil
        installGate.resetForTesting()
    }

    // ── 测试辅助（@MainActor 隔离，供 nonisolated 测试经 await 驱动） ──

    /// 注册 installer（测试用；nil = 注销）。
    static func setInstallerForTesting(_ installer: (@MainActor () -> Void)?) {
        self.installer = installer
    }

    /// 替换 applyPreset 实现（测试装配用）。
    static func applyPresetForTesting(_ impl: @escaping @Sendable (String, String) async throws -> Void) {
        applyPreset = impl
    }

    /// 替换 exportPhoto 实现（测试装配用）。
    static func exportPhotoForTesting(_ impl: @escaping @Sendable (String) async throws -> URL) {
        exportPhoto = impl
    }

    /// 替换 recentPhotoIDs 实现（测试装配用）。
    static func recentPhotoIDsForTesting(_ impl: @escaping @Sendable () async -> [String]) {
        recentPhotoIDs = impl
    }
}

public enum PhotoPipelineError: LocalizedError, Equatable {
    /// 内部信号：DI 未装配（装配后不应到达用户）。
    /// H1：面向用户文案已降级为通用说法；内部细节只进 NSLog。
    case notConfigured
    /// H1：无匹配预设（原误用 notConfigured 表达，内部文案泄漏给用户）
    case presetNotFound(String)
    /// 没有可处理的照片
    case noPhoto
    /// 导出失败
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            // H1：降级文案 —— 不再暴露「注入实现」等内部术语
            return "快捷指令暂时不可用，请打开拾光后重试"
        case .presetNotFound(let presetID):
            return "找不到预设「\(presetID)」，请先在 App 中确认该预设"
        case .noPhoto:
            return "没有找到可处理的照片，请先在 App 中编辑一张照片"
        case .exportFailed(let reason):
            return "导出失败：\(reason)"
        }
    }
}
