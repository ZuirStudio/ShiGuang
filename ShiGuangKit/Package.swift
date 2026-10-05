// swift-tools-version: 6.0
import PackageDescription

// 拾光 ShiGuang — 核心模块包（ADR-008 依赖方向：App → 全部；EditKit 零依赖可独立测试）
// 注：声明 .macOS 仅为了 CI 在 macOS runner 上直接 `swift test` 跑纯逻辑单测（ADR-007）
let package = Package(
    name: "ShiGuangKit",
    platforms: [
        .iOS("27.0"),
        .macOS("15.0"),
    ],
    products: [
        .library(name: "EditKit", targets: ["EditKit"]),
        .library(name: "RenderKit", targets: ["RenderKit"]),
        .library(name: "AICore", targets: ["AICore"]),
        .library(name: "BYOKCloud", targets: ["BYOKCloud"]),
        .library(name: "PhotoIO", targets: ["PhotoIO"]),
        .library(name: "SystemKit", targets: ["SystemKit"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
    ],
    targets: [
        // 非破坏编辑内核：纯逻辑，无 UI/平台依赖
        .target(name: "EditKit"),
        // 渲染管线：Core Image + Metal（P1.6 交付）
        .target(name: "RenderKit", dependencies: ["EditKit"]),
        // 端侧 AI：Vision + Core ML（Phase 3 交付）
        .target(name: "AICore"),
        // BYOK 云端直连（Phase 3 交付）
        .target(name: "BYOKCloud"),
        // 照片导入导出（P1.4 交付）
        .target(name: "PhotoIO"),
        // App Intents / Widget / Live Activity（Phase 5 交付）
        .target(name: "SystemKit"),
        // 设计系统 Token（P1.3 交付）
        .target(name: "DesignSystem"),
        .testTarget(name: "EditKitTests", dependencies: ["EditKit"]),
        .testTarget(name: "RenderKitTests", dependencies: ["RenderKit"]),
        .testTarget(name: "PhotoIOTests", dependencies: ["PhotoIO", "EditKit"]),
    ]
)
