import SwiftUI

// MARK: - 设计系统 Token（P1.3）

/// 遵循 apple-design skill 的设计基线：
/// - 8pt 网格间距；语义层级用系统字体样式（Dynamic Type 自动缩放）
/// - SF Symbols 优先于位图图标；标准 spring/smooth 曲线，克制使用
/// - Dark Mode：不硬编码颜色，依赖系统语义色与材质（App 层零显式背景色）
public enum DS {
    // MARK: 8pt 间距网格
    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 16
        public static let lg: CGFloat = 24
        public static let xl: CGFloat = 32
        public static let xxl: CGFloat = 48
    }

    // MARK: 圆角
    public enum Radius {
        public static let small: CGFloat = 8
        public static let medium: CGFloat = 14
        public static let large: CGFloat = 22
        public static let pill: CGFloat = 999
    }

    // MARK: 字体（系统样式 = Dynamic Type 免费获得）
    public enum Typography {
        public static let navigation = Font.headline
        public static let panelTitle = Font.subheadline.weight(.semibold)
        public static let sliderLabel = Font.footnote.weight(.medium)
        public static let sliderValue = Font.caption.monospacedDigit()
    }

    // MARK: 图标尺寸（SF Symbols）
    public enum IconSize {
        public static let small: CGFloat = 16
        public static let medium: CGFloat = 20
        public static let large: CGFloat = 28
    }

    // MARK: 强调色（P1.7 换品牌色板；先语义蓝保证对比度）
    public static let accent = Color.blue

    // MARK: 动效（apple-design：动效帮用户理解状态，不炫技）
    public enum Motion {
        /// 标准交互反馈
        public static let standard = SwiftUI.Animation.smooth(duration: 0.25)
        /// Sheet / 大面积过渡
        public static let sheet = SwiftUI.Animation.smooth(duration: 0.35)
        /// 弹性确认（删除、应用预设）
        public static let spring = SwiftUI.Animation.spring(duration: 0.4, bounce: 0.15)
    }
}
