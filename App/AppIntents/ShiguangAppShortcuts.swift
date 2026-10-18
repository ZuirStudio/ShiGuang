import AppIntents
import Foundation

// 拾光 · R010-B 系统集成 · app/AppIntents/ShiguangAppShortcuts.swift
// 编译目标：仅主 App Target
//
// 预置快捷指令：安装 App 后无需任何配置即可用。
// 系统会自动发现本文件（AppShortcutsProvider），无需手动注册。
//
// Siri 示例：
//   “嘿 Siri，在拾光里用复古胶片导出照片”
//   “嘿 Siri，用拾光的清新日光导出照片”
//   “嘿 Siri，在拾光里一键导出照片”
//
// 注意：
//   1. 每条短语必须包含 \(.applicationName)（Apple 规定）。
//   2. 预设参数使用 AppEnum，可直接在短语中插值。
//   3. 若后续做多语言，短语需放到 AppShortcuts.strings。

public struct ShiguangAppShortcuts: AppShortcutsProvider {

    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ApplyPresetAndExportIntent(),
            phrases: [
                "在\(.applicationName)里用\(\.$preset)导出照片",
                "用\(.applicationName)的\(\.$preset)导出照片",
                "在\(.applicationName)里一键导出照片",
            ],
            shortTitle: "预设导出",
            systemImageName: "wand.and.stars"
        )
    }

    public static let shortcutTileColor: ShortcutTileColor = .orange
}
