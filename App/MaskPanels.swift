import SwiftUI
import EditKit
import DesignSystem

// MARK: - 蒙版形状只读辅助（App 层扩展，不改 ShiGuangKit）

extension Mask {
    var linearShape: LinearMask? {
        if case .linear(let value) = shape { return value }
        return nil
    }

    var radialShape: RadialMask? {
        if case .radial(let value) = shape { return value }
        return nil
    }

    var brushShape: BrushMask? {
        if case .brush(let value) = shape { return value }
        return nil
    }
}

// MARK: - 修复模块（蒙版）面板

/// 修复：蒙版列表 + 选区编辑开关 + 画笔参数 + **局部调整**。
///
/// 全局 / 局部边界（重要）：
/// - 本面板所有滑杆读写 `Mask.adjustments`（经 `setAdjustment` / `value(for:)`），
///   提交走 `EditHistory.commitMask`（同标签连续拖动合并为一步历史）；
/// - 全局参数面板在「色彩」模块，两者互不影响，标题分别为「局部 · 名字」与「全局」。
struct MaskPanel: View {
    let model: EditorModel
    @Binding var isEditing: Bool

    @State private var renameTarget: UUID?
    @State private var renameText = ""

    private var selected: Mask? { model.selectedMask }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                header
                creationRow
                if model.masks.isEmpty {
                    emptyHint
                } else {
                    maskList
                }
                if let mask = selected {
                    toolRow(mask)
                    if let brush = mask.brushShape {
                        brushTools(mask: mask, brush: brush)
                    }
                    localAdjustments(mask)
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
        }
        .frame(maxHeight: 330)
        .background(.regularMaterial)
        .alert("重命名蒙版", isPresented: renameAlertBinding) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("确定") {
                if let id = renameTarget {
                    model.renameMask(id: id, name: renameText)
                }
                renameTarget = nil
            }
        }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { presented in if !presented { renameTarget = nil } }
        )
    }

    // MARK: 上下文标题

    private var header: some View {
        HStack(spacing: DS.Spacing.sm) {
            ContextBadge(
                isLocal: selected != nil,
                title: selected?.name ?? "未选中蒙版",
                note: selected == nil ? nil : "\(model.masks.count) 个选区"
            )

            Button {
                model.setMaskOverlayVisible(!model.showMaskOverlay)
            } label: {
                Label(
                    model.showMaskOverlay ? "叠色" : "正常",
                    systemImage: model.showMaskOverlay ? "eye" : "eye.slash"
                )
                .font(DS.Typography.sliderLabel)
            }
            .buttonStyle(.bordered)
            .disabled(selected == nil)
            .accessibilityLabel(model.showMaskOverlay ? "隐藏选区叠加色，正常显示" : "显示选区叠加色")
            .accessibilityHint("叠加色只影响预览，导出永远不叠加")
        }
    }

    // MARK: 新建

    private var creationRow: some View {
        HStack(spacing: DS.Spacing.sm) {
            Menu {
                ForEach(MaskKind.allCases) { kind in
                    Button {
                        model.addMask(kind: kind)
                        isEditing = true
                    } label: {
                        Label(kind.displayName, systemImage: kind.symbol)
                    }
                }
            } label: {
                Label("新建选区", systemImage: "plus.circle.fill")
                    .font(DS.Typography.sliderLabel)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("新建选区")
            .accessibilityHint("可选择线性、径向或画笔蒙版")

            Spacer(minLength: 0)

            Text(model.masks.isEmpty ? "还没有选区" : "后加的选区在上层")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("用选区圈出要单独处理的区域")
                .font(DS.Typography.sliderLabel)
            Text("线性 = 渐变过渡；径向 = 椭圆区域；画笔 = 手动涂抹。建好后在「编辑选区」里拖手柄或涂抹，再调整下方局部参数。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(DS.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.small).fill(Color.primary.opacity(0.05))
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: 列表

    private var maskList: some View {
        VStack(spacing: DS.Spacing.xs) {
            // 倒序显示：数组末尾 = 最上层，列表最上方同步
            ForEach(model.masks.reversed()) { mask in
                maskRow(mask)
            }
        }
    }

    private func maskRow(_ mask: Mask) -> some View {
        let isSelected = mask.id == selected?.id
        let index = model.masks.firstIndex(where: { $0.id == mask.id }) ?? 0
        let isTop = index >= model.masks.count - 1
        let isBottom = index <= 0

        return HStack(spacing: DS.Spacing.sm) {
            Button {
                model.selectMask(mask.id)
                isEditing = true
            } label: {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: mask.kind.symbol)
                        .font(.system(size: DS.IconSize.small))
                        .frame(width: 22)
                        .foregroundStyle(isSelected ? DS.accent : Color.primary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(mask.name)
                            .font(DS.Typography.sliderLabel)
                            .lineLimit(1)
                        HStack(spacing: DS.Spacing.xs) {
                            Text(mask.kind.displayName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if mask.isInverted { badge("已反选") }
                            if mask.hasAdjustments { badge("已有局部调整") }
                            if mask.isEmpty { badge("未涂抹") }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(mask.kind.displayName)蒙版 \(mask.name)")
            .accessibilityValue(
                mask.hasAdjustments ? "已有局部调整" : "无局部调整"
            )
            .accessibilityHint("选中它进入局部调整与图上编辑")
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])

            Menu {
                Button {
                    renameText = mask.name
                    renameTarget = mask.id
                } label: {
                    Label("重命名", systemImage: "pencil")
                }

                Button {
                    model.duplicateMask(id: mask.id)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }

                Button {
                    model.setMaskInverted(id: mask.id, inverted: !mask.isInverted)
                } label: {
                    Label(mask.isInverted ? "取消反选" : "反选", systemImage: "arrow.triangle.2.circlepath")
                }

                Divider()

                Button {
                    model.moveMask(id: mask.id, by: 1)
                } label: {
                    Label("上移一层", systemImage: "arrow.up")
                }
                .disabled(isTop)

                Button {
                    model.moveMask(id: mask.id, by: -1)
                } label: {
                    Label("下移一层", systemImage: "arrow.down")
                }
                .disabled(isBottom)

                Divider()

                Button(role: .destructive) {
                    model.removeMask(id: mask.id)
                } label: {
                    Label("删除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: DS.IconSize.medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, DS.Spacing.xs)
            }
            .accessibilityLabel("\(mask.name) 的更多操作")
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.small)
                .fill(isSelected ? DS.accent.opacity(0.14) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.small)
                .stroke(isSelected ? DS.accent.opacity(0.5) : Color.clear, lineWidth: 1)
        )
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(DS.accent)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(DS.accent.opacity(0.12)))
    }

    // MARK: 选区操作

    private func toolRow(_ mask: Mask) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Button {
                isEditing.toggle()
            } label: {
                Label(
                    isEditing ? "结束编辑" : "编辑选区",
                    systemImage: isEditing ? "checkmark.circle.fill" : "hand.draw"
                )
                .font(DS.Typography.sliderLabel)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(isEditing ? "结束选区编辑" : "开始选区编辑")
            .accessibilityHint(editingHint(mask))

            Button {
                model.setMaskInverted(id: mask.id, inverted: !mask.isInverted)
            } label: {
                Label(mask.isInverted ? "取消反选" : "反选", systemImage: "arrow.triangle.2.circlepath")
                    .font(DS.Typography.sliderLabel)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(mask.isInverted ? "取消反选" : "反选选区")

            Button {
                model.duplicateMask(id: mask.id)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
                    .font(DS.Typography.sliderLabel)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("复制选区")

            Button(role: .destructive) {
                model.removeMask(id: mask.id)
            } label: {
                Label("删除", systemImage: "trash")
                    .font(DS.Typography.sliderLabel)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("删除选区")

            Spacer(minLength: 0)
        }
        .font(DS.Typography.sliderLabel)
    }

    private func editingHint(_ mask: Mask) -> String {
        switch mask.kind {
        case .linear: return "拖两端点改变过渡方向与范围，拖中点整体平移，拖侧方手柄旋转并改变长度"
        case .radial: return "拖中心移动，拖边缘手柄改半径，拖侧方手柄改长宽比与旋转"
        case .brush: return "在图像上按住涂抹，松开结束一笔"
        }
    }

    // MARK: 画笔参数

    private func brushTools(mask: Mask, brush: BrushMask) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                Label("画笔", systemImage: MaskKind.brush.symbol)
                    .font(DS.Typography.panelTitle)
                Spacer(minLength: 0)
                Text("\(brush.strokes.count) 笔")
                    .font(DS.Typography.sliderValue)
                    .foregroundStyle(.secondary)
                Button {
                    model.undoLastBrushStroke(id: mask.id)
                } label: {
                    Label("撤销笔画", systemImage: "arrow.uturn.backward")
                        .font(DS.Typography.sliderLabel)
                }
                .buttonStyle(.bordered)
                .disabled(brush.isEmpty)
                .accessibilityLabel("撤销最后一笔涂抹")
            }

            brushSlider(
                "大小",
                icon: "circle.dashed",
                range: 0.01...0.30,
                read: { model.selectedMask?.brushShape?.radius ?? brush.radius },
                write: { model.setBrushSettings(id: mask.id, radius: $0) },
                display: { "\(Int(($0 * 100).rounded()))%" }
            )

            brushSlider(
                "硬度",
                icon: "circle.lefthalf.filled",
                range: 0...100,
                read: { model.selectedMask?.brushShape?.hardness ?? brush.hardness },
                write: { model.setBrushSettings(id: mask.id, hardness: $0) },
                display: { "\(Int($0.rounded()))" }
            )

            brushSlider(
                "流量",
                icon: "drop",
                range: 0...100,
                read: { model.selectedMask?.brushShape?.flow ?? brush.flow },
                write: { model.setBrushSettings(id: mask.id, flow: $0) },
                display: { "\(Int($0.rounded()))" }
            )

            Text("在图像上按住涂抹；松开即结束一笔。涂抹过程走 80ms 防抖渲染，不会阻塞手势。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func brushSlider(
        _ title: String,
        icon: String,
        range: ClosedRange<Double>,
        read: @escaping () -> Double,
        write: @escaping (Double) -> Void,
        display: @escaping (Double) -> String
    ) -> some View {
        VStack(spacing: DS.Spacing.xs) {
            HStack {
                Label(title, systemImage: icon)
                    .font(DS.Typography.sliderLabel)
                Spacer()
                Text(display(read()))
                    .font(DS.Typography.sliderValue)
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: read, set: write), in: range)
                .accessibilityLabel("画笔\(title)")
                .accessibilityValue(display(read()))
        }
    }

    // MARK: 局部调整

    /// 局部参数分组：与全局滑杆面板同源（可手势调整的参数），只是读写对象换成蒙版。
    private var localGroups: [(ParameterGroup, [EditParameter])] {
        let adjustable = EditParameter.allCases.filter { $0.isGestureAdjustable }
        return ParameterGroup.allCases.map { group in
            (group, adjustable.filter { $0.group == group })
        }.filter { !$0.1.isEmpty }
    }

    private func localAdjustments(_ mask: Mask) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack(spacing: DS.Spacing.sm) {
                Text("局部调整")
                    .font(DS.Typography.panelTitle)
                Spacer(minLength: 0)
                if mask.hasAdjustments {
                    Button("全部重置") {
                        model.resetMaskAdjustments(id: mask.id)
                    }
                    .font(DS.Typography.sliderLabel)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("重置该选区的全部局部调整")
                }
            }

            Text("只作用于「\(mask.name)」选区；全局参数在「色彩」模块。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(localGroups.indices, id: \.self) { index in
                let group = localGroups[index].0
                let parameters = localGroups[index].1
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Label(group.displayName, systemImage: group.symbol)
                        .font(DS.Typography.panelTitle)
                        .foregroundStyle(.secondary)

                    ForEach(parameters, id: \.self) { parameter in
                        AdjustmentSliderRow(
                            parameter: parameter,
                            value: Binding(
                                get: { model.selectedMask?.value(for: parameter) ?? 0 },
                                set: { model.setMaskAdjustment(parameter, value: $0, in: mask.id) }
                            ),
                            onAuto: nil
                        )
                    }
                }
            }
        }
    }

    private func isLocallyAdjusted(_ parameter: EditParameter) -> Bool {
        model.selectedMask?.adjustedParameters.contains(parameter) ?? false
    }
}
