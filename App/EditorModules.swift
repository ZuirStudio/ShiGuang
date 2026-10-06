import SwiftUI
import EditKit
import DesignSystem

// MARK: - 七大编辑模块（入口重组）

/// 编辑模块：面向**用户任务**的入口分类。
/// 注意与 `EditKit.ParameterGroup` 的区别：后者是**参数**分类（光线/色彩/质感…），
/// 这里是 App 层的导航单元；两者刻意解耦，未来新增模块不必改 ShiGuangKit。
enum EditorModule: String, CaseIterable, Identifiable {
    case presets
    case composition
    case color
    case portrait
    case clothing
    case liquify
    case retouch

    var id: String { rawValue }

    var label: String {
        switch self {
        case .presets: return "预设"
        case .composition: return "构图"
        case .color: return "色彩"
        case .portrait: return "人像"
        case .clothing: return "衣物"
        case .liquify: return "液化"
        case .retouch: return "修复"
        }
    }

    var symbol: String {
        switch self {
        case .presets: return "wand.and.rays"
        case .composition: return "crop.rotate"
        case .color: return "paintpalette.fill"
        case .portrait: return "person.crop.circle"
        case .clothing: return "tshirt"
        case .liquify: return "drop.triangle"
        case .retouch: return "bandage"
        }
    }

    /// 一句话说明「这个模块能做什么 / 不能做什么」（占位页与无障碍共用）。
    var summary: String {
        switch self {
        case .presets: return "一键套用内置风格，或保存自己的配方。"
        case .composition: return "裁剪比例与拉直地平线。"
        case .color: return "光线、色彩、质感与曲线的全局调整。"
        case .portrait: return "端侧人像识别后的肤色平滑与提亮。"
        case .clothing: return "衣物区域识别与处理。"
        case .liquify: return "推拉式局部变形。"
        case .retouch: return "用蒙版圈出区域做局部修复调整。"
        }
    }

    /// v1 范围内是否已有真实能力（未实现的模块走「即将上线」占位页，不留空白入口）。
    var isAvailable: Bool {
        switch self {
        case .clothing, .liquify: return false
        default: return true
        }
    }

    /// 占位页正文：只说明现状，不假装可用。
    var comingSoonNote: String {
        switch self {
        case .clothing: return "衣物区域识别与换色、去褶皱尚未实现，当前版本无法使用。"
        case .liquify: return "液化（局部推拉变形）尚未实现，当前版本无法使用。"
        default: return ""
        }
    }
}

// MARK: - 色彩子面板紧凑标签

extension EditorPanelMode {
    /// 横滑子工具条用的短标签（完整标签见 `label`）。
    var compactLabel: String {
        switch self {
        case .gesture: return "手势"
        case .sliders: return "调色"
        case .curve: return "曲线"
        case .hsl: return "分级"
        }
    }

    /// 是否需要显示在色彩子工具条里（当前全部需要）。
    var isColorSubPanel: Bool { true }
}

// MARK: - 模块横滑条

/// 底部模块横滑条：七模块一眼可辨，选中态用填充胶囊 + 强调色描边。
/// 视觉为项目原创（胶囊 + 徽标数字），交互范式为业界通用做法。
struct ModuleStrip: View {
    let selected: EditorModule
    /// 「修复」模块的蒙版数量徽标。
    let maskCount: Int
    let onSelect: (EditorModule) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.sm) {
                ForEach(EditorModule.allCases) { module in
                    moduleButton(module)
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            // 上下 12pt：模块条与导航栏、与下方预览各留呼吸，不再贴边
            .padding(.vertical, 12)
        }
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("编辑模块")
    }

    private func moduleButton(_ module: EditorModule) -> some View {
        let isSelected = module == selected
        return Button {
            onSelect(module)
        } label: {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: module.symbol)
                    .font(.system(size: DS.IconSize.small, weight: isSelected ? .semibold : .regular))
                Text(module.label)
                    .font(DS.Typography.sliderLabel)
                if module == .retouch, maskCount > 0 {
                    Text("\(maskCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(DS.accent))
                }
                if !module.isAvailable {
                    Circle()
                        .stroke(Color.secondary, lineWidth: 1)
                        .frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(isSelected ? DS.accent : Color.primary)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(isSelected ? DS.accent.opacity(0.16) : Color.primary.opacity(0.06))
            )
            .overlay(
                Capsule().stroke(isSelected ? DS.accent.opacity(0.55) : Color.clear, lineWidth: 1)
            )
            .opacity(module.isAvailable ? 1 : 0.62)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(module.label)
        .accessibilityHint(module.isAvailable ? module.summary : "尚未上线")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - 色彩子工具条

/// 色彩模块的子面板切换（手势 / 调色 / 曲线 / 分级）+ LUT 入口。
struct ColorSubStrip: View {
    @Binding var mode: EditorPanelMode
    let onOpenLUT: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            ForEach(EditorPanelMode.allCases) { item in
                let isSelected = item == mode
                Button {
                    withAnimation(DS.Motion.standard) { mode = item }
                } label: {
                    Label(item.compactLabel, systemImage: item.icon)
                        .font(DS.Typography.sliderLabel)
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(isSelected ? DS.accent.opacity(0.16) : Color.primary.opacity(0.06))
                        )
                        .foregroundStyle(isSelected ? DS.accent : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }

            Spacer(minLength: DS.Spacing.xs)

            Button(action: onOpenLUT) {
                Label("LUT", systemImage: "camera.filters")
                    .font(DS.Typography.sliderLabel)
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("LUT 风格")
            .accessibilityHint("打开预设与 LUT 面板")
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
    }
}

// MARK: - 全局 / 局部上下文标题

/// 上下文标题：全局调整与蒙版局部调整在视觉上明确区分（避免串味）。
struct ContextBadge: View {
    let isLocal: Bool
    let title: String
    /// 有界面的补充说明（可选）。
    var note: String?

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            HStack(spacing: 6) {
                Text(isLocal ? "局部" : "全局")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(isLocal ? DS.accent : Color.secondary))
                Text(title)
                    .font(DS.Typography.panelTitle)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(isLocal ? "局部" : "全局")调整，\(title)")

            Spacer(minLength: 0)

            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - 预设快捷面板

/// 预设模块：内置风格快捷胶囊 + 完整预设库 / LUT 入口。
/// 完整面板（含强度滑杆、自定义预设、LUT 导入）仍由 `PresetPanel` 承载。
struct PresetsQuickPanel: View {
    let recipes: [Recipe]
    let luts: [LUTReference]
    let onApply: (Recipe, Double) -> Void
    let onApplyLUT: (LUTReference) -> Void
    let onOpenLibrary: () -> Void
    /// 预设缩略图提供者（用当前照片实时渲染；nil → 显示占位图标）。带默认值，旧调用点不受影响。
    var thumbnail: PresetThumbnailProvider? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                ContextBadge(isLocal: false, title: "预设风格")
                Button {
                    onOpenLibrary()
                } label: {
                    Label("预设库", systemImage: "square.grid.2x2")
                        .font(DS.Typography.sliderLabel)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("打开完整预设库")
                .accessibilityHint("含强度滑杆、自定义预设与 LUT 导入")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: DS.Spacing.md) {
                    ForEach(groupedRecipes.indices, id: \.self) { index in
                        let category = groupedRecipes[index].0
                        let items = groupedRecipes[index].1
                        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                            Text(category.displayName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            HStack(spacing: DS.Spacing.sm) {
                                ForEach(items) { recipe in
                                    presetChip(recipe)
                                }
                            }
                        }
                    }

                    if !luts.isEmpty {
                        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                            Text("LUT")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            HStack(spacing: DS.Spacing.sm) {
                                ForEach(luts) { lut in
                                    lutChip(lut)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            Text("每张照片的调整独立保存；套用预设后再去「色彩」微调即可。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .background(.regularMaterial)
    }

    /// 按分类分组（空组不显示；顺序与 `PresetCategory.allCases` 声明一致：人像→风光→电影→创意→我的）。
    private var groupedRecipes: [(PresetCategory, [Recipe])] {
        PresetCategory.allCases
            .map { category in (category, recipes.filter { $0.presetCategory == category }) }
            .filter { !$0.1.isEmpty }
    }

    /// 预设胶囊：真实照片缩略图 + 名称（缩略图由 `EditorModel` 惰性渲染并按 `Recipe.id` 缓存）。
    private func presetChip(_ recipe: Recipe) -> some View {
        Button {
            onApply(recipe, 1)
        } label: {
            VStack(spacing: 3) {
                PresetThumbnail(side: 60, load: { thumbnail.flatMap { $0(recipe) } })
                Text(recipe.name)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(width: 72)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("套用预设 \(recipe.name)")
    }

    /// LUT 胶囊：本地没有可渲染的预览图，保持图标形式（配色与尺寸对齐预设胶囊）。
    private func lutChip(_ lut: LUTReference) -> some View {
        Button {
            onApplyLUT(lut)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "camera.filters")
                    .font(.system(size: DS.IconSize.medium))
                    .foregroundStyle(DS.accent)
                    .frame(width: 60, height: 60)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                            .fill(DS.accent.opacity(0.10))
                    )
                Text(lut.name)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(width: 72)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("套用 LUT \(lut.name)")
    }
}

// MARK: - 构图面板（裁剪比例 + 拉直）

/// 构图：比例裁剪 + 拉直。
/// 说明（诚实告知）：裁剪指令在管线上顺序叠加，因此每次「应用比例」是**在上一刀之内**再裁一刀；
/// 需要退回时用顶部「撤销」（裁剪是原子历史步骤）。「原图」= 满画幅，即不裁。
struct CompositionPanel: View {
    /// 当前渲染画幅的宽高比（取自预览图；裁剪后会随之变化）。
    let imageAspect: Double
    let straighten: Double
    let onChangeStraighten: (Double) -> Void
    let onApplyCrop: (CropRect) -> Void

    private struct Ratio: Identifiable {
        let id: String
        let title: String
        /// 目标宽高比；0 = 原图（不裁剪）
        let value: Double
    }

    private let ratios: [Ratio] = [
        Ratio(id: "orig", title: "原图", value: 0),
        Ratio(id: "1-1", title: "1:1", value: 1),
        Ratio(id: "4-5", title: "4:5", value: 0.8),
        Ratio(id: "3-4", title: "3:4", value: 0.75),
        Ratio(id: "2-3", title: "2:3", value: 2.0 / 3),
        Ratio(id: "16-9", title: "16:9", value: 16.0 / 9),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            ContextBadge(isLocal: false, title: "构图")

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("比例")
                    .font(DS.Typography.sliderLabel)
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Spacing.sm) {
                        ForEach(ratios) { ratio in
                            Button {
                                onApplyCrop(cropRect(aspect: ratio.value))
                            } label: {
                                Text(ratio.title)
                                    .font(DS.Typography.sliderLabel)
                                    .padding(.horizontal, DS.Spacing.md)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule().fill(Color.primary.opacity(0.06))
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("裁剪为 \(ratio.title)")
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            VStack(spacing: DS.Spacing.xs) {
                HStack {
                    Label("拉直", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(DS.Typography.sliderLabel)
                    Spacer()
                    Text(String(format: "%.0f°", straighten))
                        .font(DS.Typography.sliderValue)
                        .foregroundStyle(straighten == 0 ? Color.secondary : Color.primary)
                    Button("归零") { onChangeStraighten(0) }
                        .font(DS.Typography.sliderLabel)
                        .buttonStyle(.borderless)
                        .disabled(straighten == 0)
                        .accessibilityLabel("拉直归零")
                }
                Slider(
                    value: Binding(get: { straighten }, set: { onChangeStraighten($0) }),
                    in: -45...45,
                    step: 0.5
                )
                .accessibilityLabel("拉直角度")
                .accessibilityValue(String(format: "%.1f 度", straighten))
            }

            Text("裁剪以当前画幅为基准叠加；用顶部「撤销」可退回上一步裁剪。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .background(.regularMaterial)
    }

    /// 目标比例 → 画幅内的居中裁剪矩形（归一化，左上原点）。
    private func cropRect(aspect: Double) -> CropRect {
        guard aspect > 0, imageAspect > 0 else {
            return CropRect(x: 0, y: 0, width: 1, height: 1)
        }
        let k = aspect / imageAspect
        let width = k >= 1 ? 1.0 : k
        let height = k >= 1 ? 1.0 / k : 1.0
        return CropRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }
}

// MARK: - 人像面板（肤色平滑 / 提亮）

/// 人像：复用全局滑杆组件的行样式，但读写的是人像两个参数（与色彩模块同一套 EditGraph 指令）。
struct PortraitPanel: View {
    let smoothing: Double
    let brightening: Double
    let isPreparingMask: Bool
    let onChange: (EditParameter, Double) -> Void
    let onAuto: (EditParameter) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            ContextBadge(isLocal: false, title: "人像", note: isPreparingMask ? "正在识别人像…" : nil)

            VStack(spacing: DS.Spacing.md) {
                AdjustmentSliderRow(
                    parameter: .skinSmoothing,
                    value: Binding(get: { smoothing }, set: { onChange(.skinSmoothing, $0) }),
                    onAuto: { onAuto(.skinSmoothing) }
                )
                AdjustmentSliderRow(
                    parameter: .skinBrightening,
                    value: Binding(get: { brightening }, set: { onChange(.skinBrightening, $0) }),
                    onAuto: { onAuto(.skinBrightening) }
                )
            }

            if isPreparingMask {
                HStack(spacing: DS.Spacing.sm) {
                    ProgressView()
                    Text("正在生成皮肤区域掩码（端侧 Vision，照片不离开设备）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text("仅作用于识别到的肤色区域；未检测到人像时这两项不产生变化。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .background(.regularMaterial)
    }
}

// MARK: - 即将上线占位页

/// 未实现模块的占位页：可点、一句话说明现状，不假装能用。
struct ComingSoonPanel: View {
    let module: EditorModule

    @State private var showDetail = false

    var body: some View {
        VStack(spacing: DS.Spacing.sm) {
            Image(systemName: module.symbol)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text("\(module.label) · 即将上线")
                .font(DS.Typography.panelTitle)

            Text(module.comingSoonNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                withAnimation(DS.Motion.standard) { showDetail.toggle() }
            } label: {
                Text(showDetail ? "收起" : "了解计划")
                    .font(DS.Typography.sliderLabel)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(showDetail ? "收起说明" : "了解\(module.label)模块的计划")

            if showDetail {
                Text("该模块尚未开发，因此不提供入口占位交互（没有可用滑杆或按钮）。上线前可先这样做：\(alternative(for: module))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.lg)
        .background(.regularMaterial)
        .onTapGesture {
            withAnimation(DS.Motion.standard) { showDetail.toggle() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(module.label)模块，即将上线")
    }

    private func alternative(for module: EditorModule) -> String {
        switch module {
        case .clothing: return "用「修复」蒙版圈出衣物区域，再用局部调整里的曝光/饱和度/色温做等效处理。"
        case .liquify: return "用「构图」的比例裁剪改变画面重心的观感。"
        default: return "使用其他已上线模块。"
        }
    }
}
