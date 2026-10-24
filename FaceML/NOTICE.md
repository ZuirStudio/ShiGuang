# NOTICE — 第三方资产与许可核查（v1.5.0 Card 1）

本包（FaceML）分发两类第三方资产，均按全局合规红线入仓并附许可：

## 1. `face_landmarker.task`（端侧模型，随 App 打包）

| 项 | 值 |
|---|---|
| 来源 | Google 官方 MediaPipe 模型分发：<https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task> |
| 大小 | 3,758,596 字节（3.6 MB） |
| SHA-256 | `64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff` |
| 许可 | **Apache-2.0**（模型卡随包内含；`LICENSE` 为本仓逐字收录的许可全文） |
| 模型构成 | BlazeFace Short Range（人脸检测，~190KB tflite）+ Face Mesh V2（468+10 关键点，~3.5MB tflite），共 4 个 tflite 文件（float16 量化） |
| 产出契约 | 478 点 = 468 面部网格槽位（0..<468）+ 10 虹膜点（468..<478） |

**核查方式**：官方 URL 下载 → `sha256sum` 与上表逐位比对 → 模型卡许可字段为
Apache-2.0 → 收录 `LICENSE`（sha256 `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30`，
与 apache.org 官方文本一致）。模型卡明示可再分发（Apache-2.0 §4），无额外
专利/商标限制条款；不含任何版权 LUT 或受限素材（红线：禁版权 LUT —— 本包零 LUT）。

## 2. `MediaPipeTasksVision` 1.1.1（推理框架，SPM 二进制依赖）

| 项 | 值 |
|---|---|
| 分发 | Google 官方 SPM：`https://github.com/google-ai-edge/mediapipe`（branch `master`） |
| 二进制 | `https://dl.google.com/cpdc/20261013-213039/MediaPipeTasksVision-1.1.1.xcframework.zip` |
| SHA-256 | `755390ce853b062536899f0729321156d4cdceb263aa92c4bf3b2dd05fe640e0` |
| 切片 | `ios-arm64`（真机）+ `ios-arm64-simulator`（模拟器，CI 截图链路依赖） |
| 许可 | **Apache-2.0**（框架每个头文件顶部均有 "Copyright 2023 The MediaPipe Authors. Licensed under the Apache License, Version 2.0"） |

**上游约束（AD-2 已核查）**：mediapipe 根 `Package.swift` 的二进制 target 带
checksum 且随 master 滚动更新、无版本 tag，下游只能 branch/revision 引用。
本包按 `branch: "master"` 引用；框架 zip 的 sha256 与二进制 checksum 均已记录在案，
若上游滚动导致构建漂移，以本表为比对基线定位。

## 3. 本包自研代码

`MediaPipeFaceMeshProvider.swift` 为本工程原创，随主仓许可（见根目录 `LICENSE`）分发。
