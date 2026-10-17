import Foundation

// MARK: - P0-D（R007c）：皮肤类效果的门控策略（纯逻辑，可 CI 单测）

/// 人像皮肤类效果（磨皮 / 美白）的**应用层门控**。
///
/// v0.7.1 把门控做在了 `PortraitMaskBuilder`（掩码生成）侧：覆盖率不过关就不装掩码，
/// 渲染层 `skinMask == nil` 时皮肤操作自然恒等 —— 这保证了「无人物照片绝不被全图磨皮」。
///
/// R007c 真机反馈暴露了剩下的两个缺口：
/// 1. **套用预设**（`Recipe` 含 `.skinSmoothing` / `.skinBrightening`）时，UI 层不查门控状态，
///    皮肤项被静默丢弃、其余项照常全图生效，用户看到的就是「预设效果作用到了全图」且没有任何解释；
/// 2. **手动拖滑杆**时同样静默无响应，且「未识别到可用人像区域」的提示只挂在掩码生成
///    结束的那一瞬（HUD / Live Activity），用户后来拖动滑杆时看不到任何说明。
///
/// 本类型把「该不该应用皮肤项」的裁决做成**纯函数**，App 层（`EditorModel`）调用，
/// 单元测试直接覆盖全部裁决分支（App target 不在 CI 单测范围里，策略必须落在 ShiGuangKit）。
public enum PortraitEffectGate {
    /// 门控裁决输入。
    public struct Input: Sendable, Equatable {
        /// 本次应用是否包含皮肤类参数（磨皮 / 美白）。
        public var usesSkin: Bool
        /// 人像掩码门控是否已通过（掩码已安装、可施效）。
        public var maskReady: Bool
        /// 掩码是否仍在后台生成中。
        public var isPreparing: Bool

        public init(usesSkin: Bool, maskReady: Bool, isPreparing: Bool) {
            self.usesSkin = usesSkin
            self.maskReady = maskReady
            self.isPreparing = isPreparing
        }
    }

    /// 裁决结果。
    public enum Decision: Sendable, Equatable {
        /// 全部放行（无皮肤项，或门控已通过）。
        case allowAll
        /// 识别中：非皮肤项立即应用，皮肤项挂起等门控结果。
        case deferSkin
        /// 门控拒绝 / 不可用：剔除皮肤项，其余照常应用。
        case dropSkin
    }

    /// 裁决：一次「应用操作序列」该如何对待其中的皮肤项。
    ///
    /// - 无皮肤项 → `allowAll`（与既有行为完全一致，零回归面）。
    /// - 有皮肤项且门控通过 → `allowAll`（掩码在渲染层注入，效果落在人像区域内）。
    /// - 有皮肤项但仍在识别 → `deferSkin`：先应用色彩/光影项（用户立刻看到效果），
    ///   皮肤项挂起，掩码就绪后补应用；门控拒绝则挂起项作废并提示。
    /// - 有皮肤项且门控拒绝 → `dropSkin`：绝不把无掩码的磨皮/美白留给渲染层。
    public static func decide(_ input: Input) -> Decision {
        guard input.usesSkin else { return .allowAll }
        if input.maskReady { return .allowAll }
        if input.isPreparing { return .deferSkin }
        return .dropSkin
    }

    /// 从操作序列中判断是否包含皮肤类参数。
    ///
    /// R007d：递归进蒙版的局部调整集合 —— 用户自存预设（`saveCurrentAsPreset`）
    /// 会连蒙版一起保存，蒙版 adjustments 里的磨皮/美白同样是皮肤项，
    /// 只扫顶层会漏掉它们（门控形同虚设）。
    public static func usesSkin(_ operations: [EditOperation]) -> Bool {
        operations.contains { operation in
            if operation.isSkin { return true }
            if case .mask(let mask) = operation {
                return mask.adjustments.contains(where: \.isSkin)
            }
            return false
        }
    }

    /// 剔除皮肤类参数（保留其余全部顺序语义）。
    ///
    /// R007d：蒙版指令只剔其 adjustments 里的皮肤项、蒙版本体保留
    /// （其余局部调整与选区形状不受影响）。
    public static func strippingSkin(_ operations: [EditOperation]) -> [EditOperation] {
        operations.compactMap { operation in
            if operation.isSkin { return nil }
            if case .mask(var mask) = operation {
                guard mask.adjustments.contains(where: \.isSkin) else { return operation }
                mask.adjustments.removeAll { $0.isSkin }
                return .mask(mask)
            }
            return operation
        }
    }
}
