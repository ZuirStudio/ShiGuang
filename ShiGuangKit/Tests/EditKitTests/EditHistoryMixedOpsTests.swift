import Testing
import Foundation
@testable import EditKit

/// R011 历史面板链路补强：混合 `CropRect` / `ColorGrading` / `Mask` 的
/// 提交折叠、蒙版按 id 去重、Undo/Redo 与 jump 回溯、蒙版提交/删除、
/// 皮肤指令剔除、Codable 往返。
///
/// 背景：`EditHistoryTests`（EditKitTests.swift）只覆盖简单数值参数；
/// 而历史是 undo/redo 的重放源（`resyncFromHistory` 用历史重建图谱），
/// 结构化指令的折叠语义必须与 `EditGraph` 逐条对齐 —— 这些用例即契约。
@Suite struct EditHistoryMixedOpsTests {

    // MARK: - 夹具

    /// 构造带固定 id 的蒙版（同 id 不同值 = 后写覆盖场景）。
    private func makeMask(id: String, exposure: Double, opacity: Double = 100) -> Mask {
        Mask(
            id: UUID(uuidString: id)!,
            name: "蒙版-\(id)",
            shape: .radial(RadialMask()),
            opacity: opacity,
            adjustments: [.exposure(exposure)]
        )
    }

    // 计算属性（每次访问生成等值实例；同 id 不同值 = 后写覆盖场景）
    private var maskA: Mask { makeMask(id: "00000000-0000-0000-0000-00000000000A", exposure: 0.3) }
    private var maskAEdited: Mask { makeMask(id: "00000000-0000-0000-0000-00000000000A", exposure: 0.9, opacity: 80) }
    private var maskB: Mask { makeMask(id: "00000000-0000-0000-0000-00000000000B", exposure: -0.2) }

    // MARK: - 混合提交与折叠顺序

    /// crop / colorGrading / mask 混合提交：operations 顺序 = 提交顺序
    /// （渲染管线输入的有序性是预设复现的前提）。
    @Test func mixedCommitFoldsInOrder() {
        var history = EditHistory()
        history.commit(label: "裁剪", operations: [.crop(CropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))])
        history.commit(label: "色彩分级", operations: [.colorGrading(
            ColorGrading(shadows: ColorWheel(hue: 210, saturation: 60), blending: 80)
        )])
        history.commit(label: "蒙版", operations: [.mask(maskA)])

        #expect(history.stepCount == 3)
        #expect(history.operations.count == 3)
        if case .crop(let rect) = history.operations[0] {
            #expect(abs(rect.width - 0.8) < 1e-9)
        } else { Issue.record("operations[0] 应为 crop") }
        if case .colorGrading(let g) = history.operations[1] {
            #expect(abs(g.shadows.saturation - 60) < 1e-9)
        } else { Issue.record("operations[1] 应为 colorGrading") }
        if case .mask(let m) = history.operations[2] {
            #expect(m.id == maskA.id)
        } else { Issue.record("operations[2] 应为 mask") }
    }

    /// 蒙版折叠语义：**按 id 去重** —— 保留首次出现的位置（叠加顺序稳定），
    /// 取最后一次出现的值（后写覆盖）。「蒙版编辑 = 新增一步」在 undo 下自洽。
    @Test func maskDedupKeepsFirstPositionLastValue() {
        var history = EditHistory()
        // 第一步：蒙版 + 曝光（mask 在前，验证位置保持）
        history.commit(label: "新建蒙版", operations: [.mask(maskA), .exposure(0.2)])
        history.commit(label: "色彩分级", operations: [.colorGrading(ColorGrading(shadows: ColorWheel(hue: 30, saturation: 50)))])
        // 第三步：同 id 蒙版的后写覆盖（用户又调了该蒙版）
        history.commit(label: "改蒙版", operations: [.mask(maskAEdited)])

        let ops = history.operations
        #expect(ops.count == 3)                       // mask + exposure + colorGrading，不产生第二个蒙版
        let masks = ops.compactMap(\.maskValue)
        #expect(masks.count == 1)
        #expect(masks[0].id == maskA.id)
        #expect(masks[0].adjustments == [.exposure(0.9)])   // 后写覆盖
        #expect(masks[0].opacity == 80)
        // 蒙版保持在首次出现的位置（index 0），后续指令顺次前移
        if case .mask = ops[0] {} else { Issue.record("蒙版应保持在首次出现位置") }
        if case .exposure(let v) = ops[1] { #expect(abs(v - 0.2) < 1e-9) } else { Issue.record("ops[1] 应为 exposure") }
        if case .colorGrading = ops[2] {} else { Issue.record("ops[2] 应为 colorGrading") }
    }

    /// 不同 id 的蒙版各自保留，顺序稳定（叠加顺序 = 层级）。
    @Test func distinctMaskIdsBothKeptInOrder() {
        var history = EditHistory()
        history.commit(label: "蒙版A", operations: [.mask(maskA)])
        history.commit(label: "曝光", operations: [.exposure(0.2)])
        history.commit(label: "蒙版B", operations: [.mask(maskB)])
        #expect(history.operations.compactMap(\.maskValue).map(\.id) == [maskA.id, maskB.id])
        #expect(history.operations.count == 3)
    }

    // MARK: - Undo/Redo 回溯（混合操作）

    /// 混合 crop / colorGrading / mask 的完整撤销/重做往返：
    /// 返回值匹配、空栈边界、operations 逐步收敛与复原。
    @Test func undoRedoRoundTripWithMixedOps() {
        var history = EditHistory()
        let s1 = HistoryStep(label: "裁剪", operations: [.crop(CropRect(x: 0, y: 0, width: 0.5, height: 0.5))])
        let s2 = HistoryStep(label: "色彩分级", operations: [.colorGrading(ColorGrading(shadows: ColorWheel(hue: 90, saturation: 70)))])
        let s3 = HistoryStep(label: "蒙版", operations: [.mask(maskA)])
        history.commit(s1)
        history.commit(s2)
        history.commit(s3)
        #expect(history.operations.count == 3)

        // 撤销：返回值 = 被移除的步骤；operations 从尾部收敛
        #expect(history.undo() == s3)
        #expect(history.operations.count == 2)
        #expect(history.operations.compactMap(\.maskValue).isEmpty)
        #expect(history.undo() == s2)
        #expect(history.operations.count == 1)
        #expect(history.undo() == s1)
        #expect(history.operations.isEmpty)
        #expect(history.undo() == nil)                 // 空栈撤销返回 nil
        #expect(history.redoSteps.count == 3)

        // 重做：逆序重放，operations 逐步复原
        #expect(history.redo() == s1)
        #expect(history.redo() == s2)
        #expect(history.redo() == s3)
        #expect(history.operations.count == 3)
        #expect(history.redo() == nil)                 // 空缓冲重做返回 nil
        // 复原后的完整序列与提交序列逐一相等
        #expect(history.operations[0] == EditOperation.crop(CropRect(x: 0, y: 0, width: 0.5, height: 0.5)))
        #expect(history.operations[2] == EditOperation.mask(maskA))
    }

    /// undo 后再 jump：redo 栈混合「undo 推入」与「jump 逆序压入」，
    /// 重放必须按原时间顺序（LIFO + 逆序压栈 = 顺序重放）。
    @Test func jumpAfterUndoKeepsRedoConsistent() {
        var history = EditHistory()
        history.commit(label: "A", operations: [.exposure(0.1)])
        history.commit(label: "B", operations: [.mask(maskA)])
        history.undo()                                  // steps=[A]，redo=[B]
        history.jump(to: 0)                             // 移除 A → redo=[B, A]
        #expect(history.steps.isEmpty)
        #expect(history.redoSteps.map(\.label) == ["B", "A"])
        #expect(history.redo()?.label == "A")           // 时间顺序重放：先 A
        #expect(history.redo()?.label == "B")           // 后 B
        #expect(history.steps.map(\.label) == ["A", "B"])
        #expect(history.operations == [.exposure(0.1), .mask(maskA)])
    }

    // MARK: - 蒙版提交 / 删除（Mask.swift 扩展）

    /// commitMask：同蒙版同标签连续拖动合并；换标签 / 换蒙版 → 新步。
    @Test func commitMaskMergesSameMaskSameLabel() {
        var history = EditHistory()
        history.commitMask(maskA, label: "蒙版不透明度")
        history.commitMask(maskAEdited, label: "蒙版不透明度")     // 同 id 同标签 → 合并为一步
        #expect(history.stepCount == 1)
        let masks = history.operations.compactMap(\.maskValue)
        #expect(masks.count == 1)
        #expect(masks[0].opacity == 80)                 // 取最后一次拖动值

        history.commitMask(maskA, label: "蒙版羽化")                // 换标签 → 新步
        #expect(history.stepCount == 2)
        history.commitMask(maskB, label: "蒙版不透明度")            // 换蒙版（同标签）→ 新步
        #expect(history.stepCount == 3)
        #expect(history.steps.map(\.label) == ["蒙版不透明度", "蒙版羽化", "蒙版不透明度"])
        #expect(history.operations.compactMap(\.maskValue).map(\.id) == [maskA.id, maskB.id])
    }

    @Test func commitMaskClearsRedo() {
        var history = EditHistory()
        history.commitMask(maskA, label: "蒙版不透明度")
        history.undo()
        #expect(history.redoSteps.count == 1)
        history.commitMask(maskB, label: "蒙版不透明度")
        #expect(history.redoSteps.isEmpty)
        #expect(history.stepCount == 1)
    }

    /// commitMaskRemoval：从所有历史步骤剥离该蒙版；被清空的步骤整体移除；
    /// redo 缓冲同步清空（删除不可撤销，v1 语义）。
    @Test func commitMaskRemovalStripsMaskEverywhere() {
        var history = EditHistory()
        history.commit(label: "蒙版A", operations: [.mask(maskA)])
        history.commit(label: "曝光", operations: [.exposure(0.2)])
        history.commit(label: "混合", operations: [.mask(maskB), .mask(maskA), .contrast(5)])
        history.commitMaskRemoval(id: maskA.id, label: "删除蒙版")

        #expect(history.operations.compactMap(\.maskValue).map(\.id) == [maskB.id])
        #expect(history.stepCount == 2)                 // 「蒙版A」步被清空后移除
        #expect(history.steps.map(\.label) == ["曝光", "混合"])
        #expect(history.operations == [.exposure(0.2), .mask(maskB), .contrast(5)])
        #expect(history.redoSteps.isEmpty)

        // 只含被删蒙版的步骤整体移除
        var h2 = EditHistory()
        h2.commit(label: "蒙版B", operations: [.mask(maskB)])
        h2.commitMaskRemoval(id: maskB.id, label: "删除蒙版")
        #expect(h2.stepCount == 0)
        #expect(h2.operations.isEmpty)
    }

    // MARK: - 皮肤指令剔除（R007d P0-D 契约）

    /// removeSkinOperations：只剔皮肤指令、混合步保留其余、纯皮肤步整体移除、
    /// 保留步的 id/timestamp 不漂移（历史面板行身份稳定）。
    @Test func removeSkinOperationsPurgesStepsPreservingIdentity() {
        var history = EditHistory()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let s1 = HistoryStep(label: "磨皮+曝光", operations: [.skinSmoothing(50), .exposure(0.3)], timestamp: t)
        let s2 = HistoryStep(label: "纯磨皮", operations: [.skinBrightening(20)], timestamp: t)
        let s3 = HistoryStep(label: "裁剪", operations: [.crop(CropRect(x: 0, y: 0, width: 1, height: 1))], timestamp: t)
        history.commit(s1)
        history.commit(s2)
        history.commit(s3)
        history.undo()                                  // 制造非空 redo（含 s3）

        history.removeSkinOperations()

        #expect(history.steps.count == 1)               // s2（纯皮肤）移除；s3 已被 undo 进 redo
        #expect(history.steps[0].id == s1.id)           // 保留步 id 不漂移
        #expect(history.steps[0].timestamp == t)
        #expect(history.steps[0].operations == [.exposure(0.3)])   // 只剔皮肤指令
        #expect(history.redoSteps.count == 1)           // redo 无皮肤 → 不变
        #expect(history.redoSteps[0].id == s3.id)
    }

    /// redo 缓冲里的皮肤指令同样必须剔除 —— 否则一次 redo 就把皮肤项复活。
    @Test func removeSkinOperationsPurgesRedoSkin() {
        var history = EditHistory()
        history.commit(label: "磨皮", operations: [.skinSmoothing(50)])
        history.commit(label: "曝光", operations: [.exposure(0.2)])
        history.undo()                                  // redo=[曝光]
        history.undo()                                  // redo=[曝光, 磨皮]
        #expect(history.steps.isEmpty)
        #expect(history.redoSteps.count == 2)

        history.removeSkinOperations()
        #expect(history.redoSteps.map(\.label) == ["曝光"])   // 磨皮从 redo 剔除
    }

    // MARK: - Codable 往返

    /// 混合结构化指令 + 非空 redo 的完整序列化往返（固定时间戳保证精确相等）。
    @Test func codableRoundTripWithMixedOps() throws {
        var history = EditHistory()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        history.commit(HistoryStep(label: "裁剪", operations: [
            .crop(CropRect(x: 0.1, y: 0.2, width: 0.7, height: 0.6))
        ], timestamp: t))
        history.commit(HistoryStep(label: "色彩分级", operations: [
            .colorGrading(ColorGrading(
                shadows: ColorWheel(hue: 210, saturation: 55),
                midtones: ColorWheel(hue: 40, saturation: 20),
                highlights: ColorWheel(hue: 300, saturation: 60),
                blending: 80, balance: -20
            ))
        ], timestamp: t))
        history.commit(HistoryStep(label: "蒙版", operations: [.mask(maskAEdited)], timestamp: t))
        history.undo()                                  // 制造非空 redo

        let data = try JSONEncoder().encode(history)
        let decoded = try JSONDecoder().decode(EditHistory.self, from: data)

        #expect(decoded == history)
        #expect(decoded.stepCount == 2)
        #expect(decoded.redoSteps.count == 1)
        #expect(decoded.operations == history.operations)
        // 解码后折叠语义不变：steps 折叠出 crop + colorGrading（蒙版步已被 undo 进 redo）
        #expect(decoded.operations.count == 2)
        if case .crop = decoded.operations[0] {} else { Issue.record("ops[0] 应为 crop") }
        if case .colorGrading = decoded.operations[1] {} else { Issue.record("ops[1] 应为 colorGrading") }
        // redo 缓冲中的蒙版完整保留（opacity 80 = maskAEdited）
        #expect(decoded.redoSteps[0].operations.compactMap(\.maskValue).count == 1)
        #expect(decoded.redoSteps[0].operations.compactMap(\.maskValue)[0].opacity == 80)
        // 解码后 redo 重放：蒙版回到渲染输入（往返闭环）
        var replayed = decoded
        #expect(replayed.redo()?.label == "蒙版")
        #expect(replayed.operations.compactMap(\.maskValue).count == 1)
        #expect(replayed.operations.compactMap(\.maskValue)[0].opacity == 80)
        #expect(replayed.operations.count == 3)
    }
}
