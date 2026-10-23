import Foundation

// 拾光 · R010-B 系统集成 · app/AppIntents/PhotoPipeline.swift
// 编译目标：仅主 App Target
//
// PhotoPipeline：App Intents 与主工程业务代码之间的「服务网关」。
//
// 为什么需要它：
//   快捷指令可能由系统在后台拉起执行，不能直接引用主工程的
//   相册 / 编辑器 / 导出器实现。主工程在 App 启动时注入真实
//   闭包实现（见 docs/integration-snippets.md 第 ① 步）：
//
//   PhotoPipeline.applyPreset = { presetID, photoID in
//       try await YourEditorService.shared.apply(presetID: presetID, photoID: photoID)
//   }
//   PhotoPipeline.exportPhoto = { photoID in
//       try await YourExporter.shared.export(photoID: photoID)
//   }
//
// 未注入时调用会抛出 notConfigured，不会崩溃。

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
}

public enum PhotoPipelineError: LocalizedError {
    /// 主工程未注入实现
    case notConfigured
    /// 没有可处理的照片
    case noPhoto
    /// 导出失败
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "快捷指令服务未配置：请在 App 启动时注入 PhotoPipeline 实现"
        case .noPhoto:
            return "没有找到可处理的照片，请先在 App 中编辑一张照片"
        case .exportFailed(let reason):
            return "导出失败：\(reason)"
        }
    }
}
