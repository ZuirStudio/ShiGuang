import AppIntents
import Foundation

// 拾光 · R010-B 系统集成 · app/AppIntents/ApplyPresetAndExportIntent.swift
// 编译目标：仅主 App Target
//
// 「一键套用指定预设并导出」快捷指令。
//
// 运行方式：Siri / 快捷指令 App / 聚焦 / 操作按钮。
// 后台执行（openAppWhenRun = false）：套用预设 → 导出 → 语音反馈，
// 全程不打开 App、不触碰 UI 主面板。
//
// 照片选择逻辑：photoID 参数留空时，取最近编辑的一张
// （PhotoPipeline.recentPhotoIDs().first）。
//
// ── H1 修复 ────────────────────────────────────────────────────────
// 旧现象：快捷指令报「快捷指令服务未配置：请在 App 启动时注入
// PhotoPipeline 实现」。
// 根因：DI 装配只挂在 ShiGuangApp.init() 启动副作用上；本 intent 以后台
// 进程执行（openAppWhenRun = false），不经过 App 启动，闭包保持默认抛错态。
// 修法：perform() 首行在本进程内注册 installer 并 ensureInstalled()
//（幂等门；与 App 启动路径共用同一门，重复调用零成本）。

public struct ApplyPresetAndExportIntent: AppIntent {

    public static let title: LocalizedStringResource = "套用预设并导出"

    public static let description = IntentDescription("对照片套用指定预设并导出到相册")

    /// false = 后台运行，不打开 App
    public static let openAppWhenRun = false

    /// 要套用的预设（Siri 可直接口述，如“用复古胶片导出照片”）
    @Parameter(title: "预设")
    public var preset: PresetAppEnum

    /// 目标照片；留空则处理最近编辑的一张。
    @Parameter(title: "照片 ID", description: "留空则处理最近编辑的照片")
    public var photoID: String?

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        // H1：本进程（快捷指令后台执行，不经 App 启动）注册装配函数并惰性装配。
        // installer 引用本 target 内的 installPhotoPipelineAndDeepLinks()；
        // 门保证与 App 启动路径合计恰好装配一次。
        PhotoPipeline.installer = installPhotoPipelineAndDeepLinks
        await PhotoPipeline.ensureInstalled()

        // 1. 确定照片：显式指定 > 最近编辑
        // （await 不能置于 ?? 右侧——那会落入非并发 autoclosure；改为显式先求值）
        var resolvedPhotoID: String? = photoID
        if resolvedPhotoID == nil {
            resolvedPhotoID = await PhotoPipeline.recentPhotoIDs().first
        }
        guard let photoID = resolvedPhotoID else {
            throw PhotoPipelineError.noPhoto
        }

        // 2. 套用预设
        try await PhotoPipeline.applyPreset(preset.presetID, photoID)

        // 3. 导出
        let url = try await PhotoPipeline.exportPhoto(photoID)

        // 4. 反馈（Siri 朗读 / 快捷指令结果）
        return .result(
            value: url.lastPathComponent,
            dialog: "已用「\(preset.displayName)」处理并导出"
        )
    }

    /// 快捷指令编辑器里的参数摘要
    public static var parameterSummary: some ParameterSummary {
        Summary("用 \(\.$preset) 处理并导出照片")
    }
}
