import Foundation

// MARK: - 内置预设（P2.1）

/// 内置预设目录 — 可分享、可被 App Intents 复放（Recipe 与 EditGraph 同构序列化）。
/// 调色取向参考主流审美风格命名；全部数值已落在 EditOperation 合法范围内。
public enum BuiltinRecipes {
    public static let all: [Recipe] = [
        Recipe(name: "清透", operations: [
            .exposure(0.25), .contrast(8), .highlights(-12), .shadows(18), .vibrance(15),
        ]),
        Recipe(name: "胶片", operations: [
            .contrast(12), .saturation(-15), .vibrance(10), .blackPoint(6), .vignette(20),
        ]),
        Recipe(name: "日系", operations: [
            .exposure(0.35), .contrast(-8), .highlights(-8), .shadows(22),
            .temperature(8), .saturation(-10),
        ]),
        Recipe(name: "黑白", operations: [
            .saturation(-100), .contrast(18), .clarity(20),
        ]),
        Recipe(name: "暖阳", operations: [
            .exposure(0.2), .temperature(22), .vibrance(12), .shadows(10),
        ]),
        Recipe(name: "冷调", operations: [
            .temperature(-25), .tint(-4), .contrast(6), .vibrance(8),
        ]),
        Recipe(name: "风光", operations: [
            .contrast(15), .highlights(-20), .shadows(15), .vibrance(25), .dehaze(15),
        ]),
        Recipe(name: "人像", operations: [
            .exposure(0.15), .highlights(-10), .shadows(12), .temperature(6), .vibrance(8),
        ]),
        Recipe(name: "暗调", operations: [
            .exposure(-0.4), .contrast(14), .shadows(-18), .vignette(28),
        ]),
        Recipe(name: "锐利", operations: [
            .contrast(10), .clarity(35), .sharpen(45),
        ]),
        Recipe(name: "褪色", operations: [
            .contrast(-15), .saturation(-20), .blackPoint(10), .highlights(-10),
        ]),
        Recipe(name: "通透蓝", operations: [
            .temperature(-10), .tint(6), .vibrance(18), .contrast(8), .dehaze(10),
        ]),
    ]

    public static func recipe(named name: String) -> Recipe? {
        all.first { $0.name == name }
    }
}
