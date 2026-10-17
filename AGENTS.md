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

- 截图 job 用**命名模拟器**（`iPhone 15`，不存在则按最新 iOS runtime 创建）而非 generic destination；启动流程含：boot → `bootstatus -b` → 状态栏打补丁（9:41/满电/满信号）→ `privacy grant photos`（防权限弹窗污染）→ install + launch `com.shiguang.ShiGuang` → 双 sleep 6 → `simctl io screenshot` + `sips -Z 1800`。
- artifact 名固定为 **`app-screenshot`**（保留 2 天），失败时另传 `build-logs`。
