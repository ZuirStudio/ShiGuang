# AGENTS.md — 拾光项目 AI 协作规范

> 本文件是任何 AI Agent / 协作者在本仓库动手前的**必读纪律**。
> 违反本规范的产出一律不接受，无论 CI 是否绿灯。

## 1. 核心纪律：先看截图，再改代码

本仓库处于「无本地 Mac、无法直接看 UI」的远程开发状态，**CI 截图是唯一的 UI 事实来源**。

1. **CI 成功后，必须先下载 `app-screenshot` artifact 并查看图片**，确认 UI 符合预期，才允许进行下一步改动。
   - 不许在没看图的情况下宣称「已完成」「已验证」。
   - 如果截图与预期不符，按截图暴露的问题修，而不是按自己的想象修。
2. **CI 失败时不许猜**：必须用 `xcrun xcresulttool` 读取 xcresult 中的真实错误（workflow 的 `Extract build errors from xcresult` 步骤会输出摘要），或对包级测试失败直接读对应测试源码定位。
3. **不要向用户索取完整日志**：用 `gh run view <run_id> --log-failed` 自行取失败日志。

## 2. 工程结构约束

1. **绝不手动修改 `project.pbxproj`**：所有 Xcode 工程结构变更必须通过编辑 `project.yml` 后运行 `xcodegen generate` 生成。手工编辑 pbxproj 等于破坏单一真源。
2. **纯逻辑代码必须写在 SwiftPM 模块**（`ShiGuangKit` 下的 EditKit / RenderKit / AICore / PhotoIO / SystemKit / DesignSystem），不允许把可测逻辑直接写进 `App/` 下的 UI 层。UI 层只做组装与渲染。

## 3. R008 实施补充（基础设施事实）

> 以下为 2026-08 R008 基建轮落地时确认的事实，改 workflow / 工程结构前先核对，避免重复踩坑。

### CI 双轨事实

- **两条 workflow 并存**：
  - `ci.yml`（既有）：macOS 三 job —— EditKit+RenderKit 包级测试、App 构建、tag 时未签名 IPA + Release。**保留不动**。
  - `ios.yml`（R008 新增）：`push`/`pull_request` 到 main 触发 —— Linux 纯逻辑单测（零 macOS 分钟成本）+ macOS 构建截图 + 手动 tmate 调试 job。
- 仓库为 **public**，GitHub Actions 分钟免费，双 workflow 并行无成本顾虑。

### 工程真源事实

- **scheme 真名是 `ShiGuang`**（`project.yml` 定义），不是任何模板猜测的 `ShiGuangApp`。
- **bundle id = `com.shiguang.ShiGuang`**（bundleIdPrefix `com.shiguang` + 产品名）。
- **部署目标 iOS 27.0**：runner 必须 `macos-latest` + 选最新 Xcode（ci.yml 的 plutil 逻辑），**Xcode 15.4 / macos-14 无 iOS 27 SDK，不可用**。
- **构建前必须先跑** `swift Scripts/generate_icon.swift --out App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`，否则 AssetCatalog 编译缺图标。
- xcodegen 工作流：改 `project.yml` → `xcodegen generate` → `xcodebuild -project ShiGuang.xcodeproj -scheme ShiGuang ...`。

### EditKit 跨平台事实

- `EditKit` 是**零平台依赖**模块：源码与测试仅 `import Foundation`（`CGFloat`/`CGSize` 在 Darwin 由 Foundation 经 CoreGraphics 再导出、Linux 由 corelibs-foundation 原生提供）。**严禁**给它引入 `UIKit` / `CoreImage` / `Vision` 导入；需要图像能力的逻辑拆去 `RenderKit`。
- Linux 单测采用**隔离 scratch 包**（ios.yml unit-tests job 把 EditKit 源码+测试拷到 `/tmp/editkit-linux` 只含纯逻辑目标）：因为 `swift test` 会构建整个 package graph，而 RenderKit/AICore/PhotoIO/SystemKit/DesignSystem 均为 Apple-only。
- Swift 6 注意 `contains(\.isSkin)` 这类 key path 重载歧义，须写 `contains(where: \.isSkin)`。

### 截图闭环事实

- 截图 job 的设备链路：**resolve-or-create iPhone 15（UDID 精确操作）**——按 version 数值序选最新可用 iOS runtime 创建设备（runner 的 Xcode 26.6 只有 iOS 26.5 runtime，`xcodebuild -downloadPlatform iOS` 无效已证伪）；启动流程含：boot → `bootstatus <udid> -b`（`-b` 必须在 device 之后，前置会被当作 device 参数报 `Invalid device: -b`）→ 状态栏打补丁（9:41/满电/满信号）→ install + `privacy grant photos`（必须在 install 之后，未安装时 grant 无效）→ launch `com.shiguang.ShiGuang` → 双 sleep 6 → `simctl io screenshot` + `sips -Z 1800`。
- 构建用 `generic/platform=iOS Simulator`（命名 destination 在该 runner 上解析失败，已取证）；**CI 部署目标覆盖**：runner SDK 为 iPhoneSimulator26.5.sdk，低于 project.yml 真机目标 27.0，故 CI 内 `IPHONEOS_DEPLOYMENT_TARGET=26.5` + CI 工作区临时 sed Package.swift platforms 到 26.0（不提交、真源零改动）——产物 MinimumOSVersion 26.5 才能装进 26.5 模拟器（installd 严格校验 `Have 26.5; need 27.0`）。
- artifact 名固定为 **`app-screenshot`**（保留 2 天），失败时另传 `build-logs`。

## 4. 架构宪法：版本里程碑与防御性设计规范（R008-2，最高优先级）

> 用户已明确设定四个阶段性目标。**所有架构设计必须为这些目标预留扩展空间**；
> 违反下表的「当前差距」栏所列方向、把功能写死在核心路径上的代码，一律不接受。

### 4.1 版本里程碑

| 里程碑 | 目标 | 必备功能 |
|---|---|---|
| **v1.0.0 基本可用** | 当前核心功能绝对稳定、无致命 Bug、交互流畅 | 调色、曲线、HSL、蒙版、基础人像、预设、导出 |
| **v1.5.0 像素蛋糕全量** | 拥有像素蛋糕的一切功能 | 高级人像（**面部液化、五官微调、3D 骨骼**）、**批量修图**、**证件照/商品图模板**、**AI 追色** |
| **v2.0.0 四神合一** | 吞下 LR / PS / Snapseed / 像素蛋糕全部功能 | **图层面板**、**深度 RAW 解拜耳**、**AI 消除/生成式填充**、**AI 扩图**、**高级色彩分级**、**局部 U-Point 技术** |
| **v2.1.0 集大成者** | 网评各家优点完美融合 | LR 的质感、Snapseed 的手势、像素蛋糕的傻瓜化 |

### 4.2 防御性设计规范（编写任何代码时强制遵守）

1. **渲染管线**：`RenderKit` 必须支持**任意节点的链式插入**，不能写死只有当前这几步。后续增加「AI 消除层」或「液化变形节点」时**不得重构核心**。
   - 现状（v0.7.3）：`ImageRendering` 协议已抽象（✓），但 `BasicAdjustmentRenderer` 是单一实现、内部硬编码步骤序列（toneAdjust → sharpen → vignette → straighten → crop → skin → lut → dehaze），**尚非节点链**（差距：新效果类型会持续膨胀这个 struct）。
2. **数据模型**：`EditKit` 的 `EditGraph` 必须考虑**「图层」概念**。当前全局参数 + 局部蒙版只是图层概念的特例，要为后续多图层叠加留出接口。
   - 现状（v0.7.3）：`EditGraph` = 有序 `EditOperation` 数组（ADR-003 非破坏编辑图），结构本身可扩展，但**无图层容器**（差距：v2.0.0 图层面板前需引入分组/层级抽象，且保持 Codable 兼容）。
3. **AI 接入层**：`AICore` 必须**基于协议（Protocol）设计**。端侧 Vision / CoreML、云端 BYOK 接入的 DALL-E / Stable Diffusion，都只需实现协议即可插拔。
   - 现状（v0.7.3）：已有 `OnDeviceAIProviding` / `PersonMaskProviding` 协议 + `UnimplementedAICore` 占位（✓ 方向正确）；**云端 BYOK 侧尚无对应协议**（差距：v1.5.0 AI 追色 / v2.0.0 AI 消除前需补云端 provider 协议）。
4. **UI 扩展**：SwiftUI 组件化程度必须极高，未来增加「液化面板」「图层面板」时能**直接插入现有底部 Tab 栏**。
   - 现状（v0.7.3）：面板按模式分文件（GradingPanels / MaskPanels / AutoMaskPanels），底部 Tab 由 `PanelModeMenu` 驱动（✓ 有模式→面板机制）；新面板须延续此模式注册，不得在 EditorView 里写死分支。

### 4.3 执行纪律

- 任何**新功能类型**（新效果、新 AI 能力、新面板）落地前，先对照 4.2 检查是否踩「写死核心」；踩了就先做抽象再写功能。
- v1.0.0 冻结前（功能轮），优先偿还 4.2「现状差距」栏标注的三个架构债（节点链 / 图层容器 / 云端 AI 协议）。
- **进度上报（R009 强制）**：后续开发凡涉及耗时任务（批量导出 / AI 消除 / 生成式填充 / 导出队列等），**必须**使用 `SystemKit.ProgressManager`（`begin / advance / report / finish / cancel`）上报进度，由它统一驱动 App 内浮层、灵动岛 / 锁屏卡片与将来的 Widget / 通知。**禁止**任何新代码私接 `Activity.request` 或自建第二套进度源 —— 割裂的进度源会造成「浮层 90% / 卡片 40%」的体验事故（R006 追加 C 实测教训）。
- 本规范是 R008-2 用户指令的持久化；修改需用户明确批准。

### 4.4 R009 落地事实（2026-08）

- **色彩分级（v2.0.0 功能前置到 v1.0.0 拼图）**：`EditKit.ColorGrading`（三色轮 + blending + balance，纯值类型可 Linux 单测）+ `RenderKit.ColorGradingRenderer`（`CIColorKernel` 三角窗，纯黑/纯白端点权重为 0 → 无端点污染）+ App「色轮分级」面板（`ColorGradingPanel`，`EditorPanelMode.grading`）。渲染管线固定为**最后一级调色阶段**（HSL 之后）。
- **批量预留**：`PhotoIO.BatchExportRequest / BatchExporter`（TaskGroup 限流并发 + actor 结果收集 + 单张失败不中断 + 进度回调）；`EditGraph` / `Recipe` 保持纯数据模型（Foundation-only），`SystemKit.ProgressManager` 即为其进度消费方。
- **进度框架**：`ProgressTracker`（纯逻辑步进/自由式进度数学）+ `LiveActivityProgressCenter`（ActivityKit 桥，`ActivityBox` 隔离模式，不可用时静默降级）+ `ProgressManager`（`@MainActor` 门面，300ms 节流）。Live Activity 属性契约真源 = `SystemKit.ShiGuangProgressAttributes`（`Shared/ProcessingActivityAttributes.swift` 降级为 typealias）。
- **App 侧既有桥迁移**：`ProcessingActivityBridge` 已改为 `ProgressManager` 薄封装（EditorModel 五个调用点不变），AI 人像美化链路零改动。

### 4.6 v1.0.x 收尾事实与技术债登记（2026-10）

- **H1 冷场景修复（已随 v1.0.x 批次验收）**：快捷指令 AppIntent 以后台进程执行（`openAppWhenRun = false`），不经过 `ShiGuangApp.init()`，挂在启动副作用上的 DI 装配不会发生。修法为装配入口收敛到 `Shared/ServiceInstallGate` 幂等门：`ApplyPresetAndExportIntent.perform()` 首行即自注册 installer 后接 `await PhotoPipeline.ensureInstalled()`，该调用链**完全不读取、也不依赖 `didFinishLaunching` 或「App 是否启动过」的任何前置状态**（含冷进程从未跑过 App 装配）——语义已写入 `ServiceInstallGate.swift` 文档注释（「冷场景契约」段 + `ensureInstalled()` 冷场景安全注释）。
- **技术债 ①（依赖方向，FaceML → RenderKit）**：`FaceML` target 对 `RenderKit` 的依赖**仅为 `PerfSignpost` 性能打点**（`MediaPipeFaceMeshProvider.swift` 一处使用）。待 `PerfSignpost` 下沉到零平台依赖的共享模块后，解除该依赖，恢复「FaceML 只依赖 AICore」的干净分层。还债时同步删除 `FaceML/Package.swift` 中的 RenderKit 产品依赖与文件头 `import RenderKit`。
- **技术债 ②（架构放弃，x86_64 模拟器）**：`MediaPipeTasksVision` xcframework 仅含 `ios-arm64` + `ios-arm64-simulator` 切片，**无 x86_64 模拟器切片**；`ARCHS_STANDARD`（iOS Simulator）= arm64 + x86_64，x86_64 侧 ld 会忽略全部 MediaPipe 框架导致链接失败。ci.yml / ios.yml 两个 xcodebuild build 命令已强制 `ARCHS=arm64`（macOS runner 为 Apple Silicon，arm64 模拟器原生可跑）。**代价：放弃 x86_64 模拟器支持**；Intel Mac 构建说明已写入 README「自行构建」节。真机（arm64 iPhone）不受影响。若未来 MediaPipe 补 x86_64 切片或换框架，可移除 ARCHS 覆盖恢复全架构。
