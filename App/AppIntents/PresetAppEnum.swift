import AppIntents
import Foundation

// 拾光 · R010-B 系统集成 · app/AppIntents/PresetAppEnum.swift
// 编译目标：仅主 App Target
//
// 预设枚举：快捷指令 / Siri 使用。
// AppEnum 是 Apple 官方推荐的「取值集合已知」参数类型，
// 支持 Siri 口述预设名（如“用复古胶片导出照片”）。
//
// ⚠️ 合并时请与会话 1 的预设清单对齐：
//    - case rawValue = 稳定 ID（传给 PhotoPipeline.applyPreset）
//    - caseDisplayRepresentations = 中文显示名（Siri 与 UI 展示）
//    若预设是纯动态数据（用户自建），可改为 AppEntity + EntityQuery，
//    详见报告「扩展方向」。

public enum PresetAppEnum: String, AppEnum, CaseIterable {

    case qingxin  = "preset.qingxin"    // 清新日光
    case fanku    = "preset.fanku"      // 复古胶片
    case heibai   = "preset.heibai"     // 黑白胶片
    case rouguang = "preset.rouguang"   // 人像柔光

    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "预设"

    public static let caseDisplayRepresentations: [PresetAppEnum: DisplayRepresentation] = [
        .qingxin:  DisplayRepresentation(title: "清新日光", subtitle: "明亮 · 通透"),
        .fanku:    DisplayRepresentation(title: "复古胶片", subtitle: "暖调 · 颗粒"),
        .heibai:   DisplayRepresentation(title: "黑白胶片", subtitle: "高对比黑白"),
        .rouguang: DisplayRepresentation(title: "人像柔光", subtitle: "磨皮 · 柔焦"),
    ]

    /// 供 PhotoPipeline.applyPreset 使用的稳定 ID
    public var presetID: String { rawValue }

    /// 中文显示名（取自主显示名，缺失时回退 rawValue）
    public var displayName: String {
        Self.caseDisplayRepresentations[self]?.title ?? rawValue
    }
}
