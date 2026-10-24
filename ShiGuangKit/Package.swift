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
        // v1.5.0 Card 1：人脸几何纯逻辑层（Foundation-only，Linux 可测；
        // AICore / RenderKit 与 App 均可依赖；不依赖任何 Apple 框架）
        .library(name: "FaceGeometry", targets: ["FaceGeometry"]),
        .library(name: "BYOKCloud", targets: ["BYOKCloud"]),
        .library(name: "PhotoIO", targets: ["PhotoIO"]),
        .library(name: "SystemKit", targets: ["SystemKit"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
    ],
    targets: [
        // 非破坏编辑内核：纯逻辑，无 UI/平台依赖
        .target(name: "EditKit"),
        // v1.5.0 Card 1：人脸几何模型 / 拓扑 / 槽位映射 / 位姿解算
        // （纯 Foundation + CoreGraphics 通用类型；MediaPipe 官方拓扑表转写）
        .target(name: "FaceGeometry"),
        // 渲染管线：Core Image + Metal（P1.6 交付）
        .target(name: "RenderKit", dependencies: ["EditKit"]),
        // 端侧 AI：Vision + Core ML（Phase 3 交付）
        // R007d：依赖 RenderKit 只为复用进程级性能埋点 `PerfSignpost`（os_signpost），
        // 让 AICore 内的 createCGImage 调用点与全工程同一套证据体系上报
        // （不重复实现第二套埋点）。依赖方向 App → 全部、EditKit 零依赖不变。
        // v1.5.0 Card 1：FaceGeometry 为纯逻辑层，AICore 的 Provider 复用其
        // 槽位映射与位姿解算（RenderKit 禁直连 Vision/MediaPipe 铁律的下层基座）。
        .target(name: "AICore", dependencies: ["RenderKit", "FaceGeometry"]),
        // BYOK 云端直连（Phase 3 交付）
        .target(name: "BYOKCloud"),
        // 照片导入导出（P1.4 交付）
        .target(name: "PhotoIO"),
        // App Intents / Widget / Live Activity（Phase 5 交付）
        .target(name: "SystemKit"),
        // 设计系统 Token（P1.3 交付）
        .target(name: "DesignSystem"),
        .testTarget(name: "EditKitTests", dependencies: ["EditKit"]),
        // v1.5.0 Card 1：人脸几何纯逻辑单测（Linux 可跑，与 EditKit 同纪律）
        .testTarget(name: "FaceGeometryTests", dependencies: ["FaceGeometry"]),
        .testTarget(name: "RenderKitTests", dependencies: ["RenderKit"]),
        .testTarget(name: "PhotoIOTests", dependencies: ["PhotoIO", "EditKit"]),
        // R009：SystemKit 进度框架（ProgressTracker 纯逻辑可跨平台测；
        // LiveActivityProgressCenter 仅在 canImport(ActivityKit) 平台编译）
        .testTarget(name: "SystemKitTests", dependencies: ["SystemKit"]),
        // R007b-1 Stage C：人像分割掩码求交 / 降级 / 肤色判定回归（纯逻辑 + Vision 可用性）
        .testTarget(name: "AICoreTests", dependencies: ["AICore"]),
    ]
)
