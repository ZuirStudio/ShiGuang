# 第三方组件与模型许可清单

> 原则：**只引入允许商用 + 允许再分发的资产**；不允许的宁可不上，改用系统能力或自研。

## 1. 当前内置的 AI 能力

### 1.1 人像分割（R007b-1 Stage C，v0.7.0）

| 项 | 值 |
|---|---|
| 实现 | `AICore/PortraitSegmentation.swift` |
| 来源 | **Apple Vision `VNGeneratePersonSegmentationRequest`**（系统框架，随 iOS 下发） |
| 许可 | Apple SDK 条款；**不随 App 分发任何模型文件**，故无第三方再分发义务 |
| 体积 | **0 字节**（无模型资源进包） |
| 备注 | AICore ADR-005 原本已把 `subjectMask` 定为 Vision；Stage C 与该 ADR 一致 |

结论：**当前无任何第三方模型许可风险。**

### 1.2 肤色检测（R006）

纯代码实现（BT.601 YCbCr 阈值 + Vision 人脸椭圆兜底），无外部资产。
⚠️ R007b-1 修复了一个真实缺陷：阈值定义在 0…255 尺度，R006 却先归一化再比较，
导致 `cb <= 127` 恒不成立、**肤色掩码恒为全黑**。详见 `AICoreTests/SkinToneMaskTests`。

## 2. 已评估但**本轮未采用**的专用模型（备选，留档）

| 模型 | 体积 | 来源 / 许可 | 未采用原因 |
|---|---|---|---|
| **SINet**（`YexingWan/Fast-Portrait-Segmentation`） | ONNX **421 KB** | GitHub，**MIT** ✅ | 仓库无 Core ML 产物，只有 ONNX；iSH 无 `coremltools`/`onnx` 可用 wheel（musllinux-aarch64 无二进制），**本机无法转换**，且无法真机验证精度 |
| **HumanSeg-lite**（`PaddlePaddle/PaddleSeg`） | 量化约 187 KB | GitHub 9.4k★，**Apache-2.0** ✅ | 同上：需 Paddle→ONNX→Core ML 转换，本机不具备工具链 |

两者许可都**允许商用与再分发**，是后续「换更准模型」的合规候选。

**若将来换用**：必须同时更新本文件（模型名 / 版本 / 来源 URL / 许可 / 体积 / SHA256），
并把 `.mlpackage` 放进仓库走 Code Review；任何 **非商用 / 禁止再分发** 的权重一律拒收。

## 3. 已知风险

1. **精度未真机验证**：Vision 人像分割的抠图质量**只能在真机验证**，CI 只能证明「能加载 /
   能跑 / 形状对 / 不崩」。CI 绿 ≠ 抠得准，不得据此宣称效果达标。
2. **设备差异**：Vision 的可用性与质量随机型/系统版本变化，退出到「未识别到人像」降级路径
   属于预期行为，非崩溃。
