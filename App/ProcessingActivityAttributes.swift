import ActivityKit
import SystemKit

/// Live Activity 的属性契约。
///
/// **R009 起真源迁入 SystemKit**（`ShiGuangProgressAttributes`）——进度呈现
/// 由 `ProgressManager` 统一掌管（AGENTS.md 第 4 节纪律）。本文件保留
/// typealias 兼容主 App 既有引用；Widget 扩展将随 SystemKit 依赖直接使用真源。
typealias ProcessingActivityAttributes = ShiGuangProgressAttributes
