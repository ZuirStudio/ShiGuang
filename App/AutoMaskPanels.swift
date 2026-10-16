
import SwiftUI
import EditKit
import DesignSystem

extension MaskKind {
    /// P1-E：面板上的能力说明（小白可读，不出现术语堆砌）。
    var selectionHint: String {
        switch self {
        case .linear: return "拖出一条线，线的两侧做渐变过渡"
        case .radial: return "拖出一个椭圆，中心到边缘渐变过渡"
        case .brush: return "手指涂抹的区域生效，适合精细局部"
        case .subject: return "端侧识别画面主体并生成选区（无需联网）"
        case .sky: return "按色域规则识别上半部的蓝天/白云区域"
        case .background: return "主体之外的部分作为选区"
        }
    }
}

// MARK: - 自动选区卡片（P1-E）

/// 自动选区的状态卡：告诉用户「成了没有、要不要重来」，而不是让他面对一个空选区。
struct AutoMaskCard: View {
    let mask: Mask
    let status: String?
    let onRegenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: mask.kind.symbol)
                    .font(.system(size: DS.IconSize.small))
                    .foregroundStyle(DS.accent)
                Text("自动选区 · \(mask.kind.displayName)")
                    .font(DS.Typography.panelTitle)
                Spacer(minLength: 0)
                Button("重新生成") { onRegenerate() }
                    .font(DS.Typography.sliderLabel)
                    .buttonStyle(.bordered)
                    .accessibilityHint("按当前照片重新识别一次该选区")
            }
            if let status {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("已生成。可叠加曝光/对比/色彩等调整，只影响选区范围。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("全部在设备端完成，照片不出本机。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(DS.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
    }
}
