import Foundation

// MARK: - 内置预设（P2.1 → v2 重调）

/// 内置预设目录 — 可分享、可被 App Intents 复放（Recipe 与 EditGraph 同构序列化）。
/// v2 重调原则：
/// - 每款预设覆盖 5-8 个参数（从光影 → 色彩 → 质感完整链路）
/// - 曲线感的对比与黑白场用组合拳（白点+黑点+对比）模拟
/// - 数值保守，可叠加强度滑杆微调
/// - 用户可通过「导入 LUT」获取更强烈的风格（飓风类 LUT 自行合法获取导入）
public enum BuiltinRecipes {
    public static let all: [Recipe] = [
        Recipe(name: "通透", operations: [
            .exposure(0.15), .contrast(12), .highlights(-15), .shadows(12),
            .whitePoint(8), .blackPoint(5), .vibrance(12), .dehaze(8),
        ]),
        Recipe(name: "胶片", operations: [
            .contrast(14), .saturation(-18), .vibrance(14), .blackPoint(9),
            .highlights(-8), .shadows(14), .vignette(18), .temperature(4),
        ]),
        Recipe(name: "日系写真人像", operations: [
            .exposure(0.3), .contrast(-6), .highlights(-12), .shadows(20),
            .blackPoint(-6), .temperature(7), .saturation(-12), .vibrance(10),
            .skinSmoothing(25), .skinBrightening(15),
        ]),
        Recipe(name: "经典黑白", operations: [
            .saturation(-100), .contrast(22), .highlights(-10), .shadows(10),
            .clarity(18), .vignette(10),
        ]),
        Recipe(name: "暖阳午后", operations: [
            .exposure(0.18), .temperature(24), .tint(5), .highlights(-10),
            .shadows(12), .vibrance(14), .blackPoint(4),
        ]),
        Recipe(name: "北欧冷调", operations: [
            .temperature(-22), .tint(-6), .contrast(10), .highlights(-12),
            .whitePoint(10), .saturation(-8), .vibrance(10),
        ]),
        Recipe(name: "风光大片", operations: [
            .contrast(16), .highlights(-22), .shadows(16), .whitePoint(12),
            .vibrance(28), .dehaze(14), .clarity(18),
        ]),
        Recipe(name: "奶油肌人像", operations: [
            .exposure(0.12), .highlights(-8), .shadows(10), .temperature(5),
            .skinSmoothing(40), .skinBrightening(22), .vibrance(6),
        ]),
        Recipe(name: "暗夜氛围", operations: [
            .exposure(-0.35), .contrast(16), .shadows(-14), .blackPoint(12),
            .vignette(30), .saturation(-10), .temperature(-8),
        ]),
        Recipe(name: "锐利纪实", operations: [
            .contrast(12), .clarity(32), .sharpen(42), .highlights(-8),
            .shadows(8), .vibrance(8),
        ]),
        Recipe(name: "褪色灰调", operations: [
            .contrast(-14), .saturation(-24), .blackPoint(12), .highlights(-12),
            .shadows(8), .temperature(3),
        ]),
        Recipe(name: "赛博霓虹", operations: [
            .contrast(18), .vibrance(35), .temperature(-10), .tint(18),
            .blackPoint(10), .shadows(-8), .vignette(15),
        ]),
    ]

    public static func recipe(named name: String) -> Recipe? {
        all.first { $0.name == name }
    }
}
