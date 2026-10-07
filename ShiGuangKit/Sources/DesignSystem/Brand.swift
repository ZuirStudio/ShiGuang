import SwiftUI

// MARK: - 品牌色（R006 追加 B：参数列表浮层高亮用暖金橙）

extension DS {
    /// 拾光品牌色板。与 App 图标同源（深空黑底 + 暖金→橙径向）。
    /// 刻意**不用**竞品的黄色（Snapseed 的 #FFCC00 一类），这里是偏暖的琥珀金，色相更靠红。
    public enum Brand {
        /// #FFB347 暖金
        public static let gold = Color(red: 255.0 / 255.0, green: 179.0 / 255.0, blue: 71.0 / 255.0)
        /// #FF7A45 橙
        public static let ember = Color(red: 255.0 / 255.0, green: 122.0 / 255.0, blue: 69.0 / 255.0)
        /// #0A0A0A 深空黑
        public static let void = Color(red: 10.0 / 255.0, green: 10.0 / 255.0, blue: 10.0 / 255.0)

        /// 品牌强调色（替代语义蓝用于「当前项」高亮）
        public static let accent = gold

        /// 暖金 → 橙，与图标同心。
        public static var gradient: LinearGradient {
            LinearGradient(colors: [gold, ember], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
