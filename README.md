# 拾光 ShiGuang

**全功能免费的开源 iOS AI 修图 App**
Free & open-source AI photo editor for iOS — [GPL-3.0](LICENSE)

> 在全员订阅制、全员云端 AI 的修图市场里，拾光反其道而行：**全部功能免费、AI 全部在设备本地运行、代码完全开源**。
> 没有会员墙、没有水印、没有上传、没有追踪。

## 特性（开发中）

| 能力 | 状态 |
|------|------|
| 非破坏编辑（指令图 + 无限历史 + 任意回溯） | ✅ |
| 基础调色 15 参数（曝光/对比/高光/阴影/白点/黑点/色温/色调/饱和/自然饱和/清晰度/去雾/锐化/降噪/暗角） | ✅ |
| RAW / ProRAW 导入（DNG 经 Core Image 接管） | ✅ |
| 自定义 CIKernel 单遍色调渲染 | ✅ |
| 裁剪 / 拉直 | ✅ |
| 预设系统 + 强度滑杆 | ✅ |
| 导出（JPEG/HEIF/PNG/TIFF + 质量滑块 + ICC） | ✅ |
| 曲线（RGB/分通道）+ HSL 分级调色 | ✅ |
| 蒙版系统（线性 / 径向 / 画笔 + 局部调整 + 叠加预览 + 反选/羽化/不透明度/排序/复制） | ✅ |
| 编辑入口按七大模块组织（预设 / 构图 / 色彩 / 人像 / 衣物 / 液化 / 修复） | ✅ |
| 批量处理 + App Intents 快捷指令自动化 | 📋 |
| 端侧 AI（抠图 / 磨皮 / 消除 / 超分，无需联网） | 📋 |
| 衣物 / 液化模块 | 📋 |

## 安装（未签名 IPA）

从 [Releases](../../releases) 下载 `ShiGuang-unsigned.ipa`，然后用任一方式侧载：

| 方式 | 说明 |
|------|------|
| **TrollStore** | 直接安装（若你的系统版本支持） |
| **AltStore / SideStore** | 免费 Apple ID 签名，7 天续签 |
| **Sideloadly / eSign** | 用自己的 Apple ID 或证书签名 |
| **自编译** | 见下方，Xcode 27 直接跑 |

> 未签名 IPA 需要你用自己的 Apple ID 签名后才能安装——这是 iOS 的机制，与拾光无关，我们也不会（也不能）替你签名。

## 自行构建

```bash
# 需要：Mac + Xcode 27（或直接 fork 后让 GitHub Actions 替你构建）
git clone https://github.com/ZuirStudio/ShiGuang.git
cd ShiGuang
brew install xcodegen
xcodegen generate          # 生成 ShiGuang.xcodeproj（工程文件不入库）
open ShiGuang.xcodeproj     # Cmd+R 运行
```

纯逻辑单元测试（无需模拟器）：

```bash
cd ShiGuangKit && swift test
```

或者 fork 本仓库——**每次 push 自动触发 CI，Releases 页自动产出未签名 IPA**（workflow 见 `.github/workflows/ci.yml`）。

## 架构

```
ShiGuangKit（本地 SPM 包，7 模块）
├── EditKit        非破坏编辑内核：指令图/历史/预设（纯逻辑，零平台依赖，100% 可单测）
├── RenderKit      Core Image + 自定义 CIKernel 渲染管线
├── AICore         端侧 AI（Vision + Core ML，规划中）
├── BYOKCloud      云端 BYOK 直连（规划中，可选）
├── PhotoIO        照片导入导出（PhotosPicker / ImageIO）
├── SystemKit      App Intents / Widget / Live Activity（规划中）
└── DesignSystem   设计 Token（8pt 网格 / SF Symbols / 系统动效）
```

- **非破坏编辑**：编辑状态 = 有序指令数组（Codable），渲染 = 折叠为 Core Image 滤镜链；历史 = 指令步骤栈，任意回溯
- **单遍渲染**：10 个色调参数折叠进一个自定义 `toneAdjust` kernel，GPU 单遍完成
- **隐私**：照片仅本地处理；无账号、无追踪、无遥测、无第三方 SDK

## 参与

- Issue / PR 欢迎；`project.yml` 是工程唯一真源（改完跑 `xcodegen generate`）
- 设计遵循 [Apple HIG]；动效克制（帮助理解状态，不炫技）

## 许可

[GPL-3.0](LICENSE) — 衍生作品必须同样开源免费。这正是拾光的宣言：**修图不该被订阅墙锁住**。

第三方组件许可：内置 AI 模型将采用 Apache-2.0 / BSD 等商用友好许可（接入时逐项列明于 `docs/00_compliance_risk.md`）。

[Apple HIG]: https://developer.apple.com/design/human-interface-guidelines/
