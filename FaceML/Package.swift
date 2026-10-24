// swift-tools-version: 6.0
import PackageDescription

// FaceML — MediaPipe Face Landmarker 主路径 Provider（v1.5.0 Card 1 / P0）
//
// 为什么是独立本地包而不是 ShiGuangKit 内的 target：
// MediaPipeTasksVision 是 **iOS-only 二进制框架**（xcframework 双切片：
// ios-arm64 + ios-arm64-simulator）。若进 ShiGuangKit 包图，macOS 宿主上的
// `swift test`（ci.yml Job 1：构建整个包图跑纯逻辑单测）会在包解析阶段
// 失败 —— 二进制 target 的平台约束与 macOS 宿主冲突。隔离到本包后：
// - ShiGuangKit 保持「macOS 可完整构建测试」不变（ADR-007）；
// - 本包只被 iOS App 依赖（project.yml 显式引入），macOS CI 从不解析它。
// 详见 docs/v1.5.0-card1-architecture.md ADR-1。
let package = Package(
    name: "FaceML",
    // 与 MediaPipeTasksVision 上游一致：仅 iOS（含模拟器切片）
    platforms: [.iOS("27.0")],
    products: [
        .library(name: "FaceML", targets: ["FaceML"]),
    ],
    dependencies: [
        // MediaPipe Tasks Vision（Google 官方 SPM 分发）。
        // 按 branch 引用是上游约束：mediapipe 根 Package.swift 的二进制
        // target 带 checksum 且随 master 滚动更新（无版本 tag），
        // 下游只能 branch/revision 引用（AD-2 已核查）。
        .package(url: "https://github.com/google-ai-edge/mediapipe", branch: "master"),
        // 主工程：协议层（AICore）+ 纯逻辑模型层（FaceGeometry），路径依赖同仓库
        .package(path: "../ShiGuangKit"),
    ],
    targets: [
        .target(
            name: "FaceML",
            dependencies: [
                .product(name: "MediaPipeTasksVision", package: "mediapipe"),
                .product(name: "AICore", package: "ShiGuangKit"),
                .product(name: "FaceGeometry", package: "ShiGuangKit"),
            ],
            resources: [
                // Apache-2.0 许可的 Google 官方模型（3.6MB；sha256 见 NOTICE.md）
                .copy("Resources/face_landmarker.task")
            ]
        ),
    ]
)
