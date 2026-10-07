import ActivityKit
import Foundation

/// Live Activity 的属性契约。
///
/// 这个文件**同时编译进主 App 和 Widget 扩展**（在 `project.yml` 里两个 target 都包含 `Shared/`），
/// 所以它只能依赖 Foundation 与 ActivityKit —— 不要在这里 `import SwiftUI` 或 `import UIKit`。
struct ProcessingActivityAttributes: ActivityAttributes, Sendable {

    /// 可变状态：由主 App 在后台处理期间不断刷新。
    struct ContentState: Codable, Hashable, Sendable {
        /// 0...1
        var fraction: Double
        /// 当前阶段文案，例如「识别人像轮廓」
        var phaseTitle: String
        /// 次要说明，例如「第 2 / 3 步」
        var detail: String

        init(fraction: Double, phaseTitle: String, detail: String) {
            self.fraction = fraction
            self.phaseTitle = phaseTitle
            self.detail = detail
        }
    }

    /// 固定属性：一次处理任务的标题。
    var title: String

    init(title: String = "AI 人像美化") {
        self.title = title
    }
}
