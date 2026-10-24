import Foundation
import SwiftUI
import UIKit
import CoreImage
import DesignSystem
import AICore
import FaceGeometry
import FaceML

// MARK: - 人脸几何调试视图（v1.5.0 Card 1 / P0）

/// 演示图（`Assets.xcassets/DemoFace`，512×512 NASA 公有领域照片）→ 人脸几何
/// 检测 → 468 槽位 + 区域折线 + 虹膜叠加 + Provider 切换 + 状态/耗时。
///
/// 取证背景：该图经**同一个 `face_landmarker.task` 模型**本地验证可检出
/// 478 点、锚点 sane（x 0.3530..0.5277 / y 0.1403..0.3465，槽位 33/133/362/263/
/// 1/152/10 位置合理）——不是随手找的图，是能稳定出结果的验收样本。
/// sha256 与许可见文件末注释。
///
/// 入口（两处，均不打扰普通用户）：
/// - 生产调试：设置页连点版本号 7 次解锁「开发者」分区 → 本视图；
/// - CI 截图验收：`-ShiGuangScreenshotFaceGeometry[:mediapipe|vision]` 深链
///   （见 `ScreenshotLaunch`），图库页以 sheet 直接弹出本视图。
///
/// Provider 切换语义（与注册表不变量配合）：
/// - 「自动」= 注册表主路径（启动期 MediaPipe 注册成功即主路径）；
/// - 显式选 MediaPipe 时若启动注册未完成，**主动 warmUp**（幂等）后检测 ——
///   深链验收不依赖启动时序；
/// - 「Vision」= 兜底轨直调（恒可用，152 外壳槽位，虹膜为空）。
/// 人脸几何 Provider 选择（调试面板 + CI 深链共用）。
///
/// 为什么放文件作用域而不嵌套在 `FaceGeometryDebugModel` 里：嵌套类型的
/// 静态成员（`allCases` / `rawValue` 初始化器）在隔离推断上存在歧义风险，
/// 而调用点里有非隔离上下文（View 辅助属性 `faceGeometryInitialChoice`）——
/// 文件作用域枚举天然非隔离，两种上下文都够得着。
enum FaceGeometryChoice: String, CaseIterable, Identifiable {
    case auto, mediapipe, vision

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动"
        case .mediapipe: return "MediaPipe"
        case .vision: return "Vision"
        }
    }

    var subtitle: String {
        switch self {
        case .auto: return "注册表主路径"
        case .mediapipe: return "478 全网格 + 虹膜"
        case .vision: return "152 外壳槽位兜底"
        }
    }
}

@MainActor
@Observable
final class FaceGeometryDebugModel {

    /// 当前选择（深链预设；用户可在面板内改）。
    var choice: FaceGeometryChoice = .auto
    /// 是否正在检测。
    var isRunning = false
    /// 最近一次成功检测的几何（nil = 未检出 / 失败 / 尚未跑）。
    var geometry: FaceGeometry?
    /// 最近一次失败 / 未检出的原因（面向调试者的可读信息）。
    var errorMessage: String?
    /// 最近一次检测耗时（ms）。
    var lastMillis: Double = 0
    /// 最近一次实际执行的 Provider ID（`geometry.providerID` 的镜像，未跑时显示 —）。
    var activeProviderID = "—"
    /// MediaPipe 模型是否已加载（启动注册结果 / warmUp 探测）。
    var mediapipeAvailable = false

    /// 演示人脸（资产目录；512×512 RGB PNG）。
    private var demoFace: UIImage? { UIImage(named: "DemoFace") }

    /// 同步查询可用性（`isAvailable` 已按协议 nonisolated 实现，无需 await）。
    func refreshAvailability() {
        mediapipeAvailable = MediaPipeFaceMeshProvider.shared.isAvailable()
    }

    /// 执行一次检测。未检出人脸与失败都写 `errorMessage`（诚实呈现，不假装成功）。
    func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        errorMessage = nil
        refreshAvailability()

        guard let face = demoFace, let cg = face.cgImage else {
            geometry = nil
            errorMessage = "演示人脸图缺失（Assets.xcassets/DemoFace）"
            return
        }

        // 选定 Provider（auto = 主路径；显式选择不经过注册表主路径，
        // 只为验收「同一张图两条轨的输出差异」）
        let provider: any FaceGeometryProviding & Sendable
        switch choice {
        case .auto:
            provider = FaceGeometryRegistry.shared.primary
        case .vision:
            provider = VisionLandmarksProvider.shared
        case .mediapipe:
            if let registered = FaceGeometryRegistry.shared.provider(
                withID: MediaPipeFaceMeshProvider.providerID
            ) {
                provider = registered
            } else {
                // 启动注册异步：深链打开面板时可能未完成。主动 warmUp（幂等，
                // 模型只建一次）后临时注册（不顶替主路径，仅让本次检测可用）。
                do {
                    _ = try await MediaPipeFaceMeshProvider.shared.warmUp()
                    FaceGeometryRegistry.shared.register(
                        MediaPipeFaceMeshProvider.shared, asPrimary: false
                    )
                    provider = MediaPipeFaceMeshProvider.shared
                } catch {
                    geometry = nil
                    errorMessage = "MediaPipe 不可用：\(error.localizedDescription)"
                    return
                }
            }
        }
        activeProviderID = provider.providerID
        refreshAvailability()

        let boxed = SendableSegmentImage(CIImage(cgImage: cg))
        let t0 = DispatchTime.now().uptimeNanoseconds
        do {
            let geo = try await provider.detect(boxed)
            lastMillis = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            if let geo {
                geometry = geo
            } else {
                geometry = nil
                errorMessage = "未检出人脸（演示图经同模型本地验证可检出，请检查资源与图像方向）"
            }
        } catch {
            lastMillis = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            geometry = nil
            errorMessage = "检测失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 视图

struct FaceGeometryDebugView: View {
    /// 深链预设的 Provider（sheet 出现时同步进 model，仅一次；生产入口省略 = 自动）。
    let initialChoice: FaceGeometryChoice = .auto

    @State private var model = FaceGeometryDebugModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    imageSection
                    providerSection
                    if model.geometry != nil {
                        statsSection
                    }
                    if let errorMessage = model.errorMessage {
                        errorSection(errorMessage)
                    }
                }
                .padding(DS.Spacing.md)
            }
            .background(DS.Brand.void)
            .navigationTitle("人脸几何")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                // 深链预设只同步一次（用户随后在面板内的切换以 onChange 为准）
                model.choice = initialChoice
                model.refreshAvailability()
                await model.run()
            }
            .onChange(of: model.choice) { _, _ in
                Task { await model.run() }
            }
        }
    }

    // MARK: 图像 + 叠加

    private var imageSection: some View {
        ZStack {
            if UIImage(named: "DemoFace") != nil {
                Image("DemoFace")
                    .resizable()
                    .scaledToFit()
                if let geometry = model.geometry {
                    FaceMeshOverlay(geometry: geometry)
                }
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Text("DemoFace 资源缺失")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        // 演示图 512×512 正方；ZStack 贴合图像绘制区，叠加坐标逐像素对齐
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small))
        .overlay(alignment: .topLeading) {
            if model.isRunning {
                ProgressView()
                    .padding(DS.Spacing.sm)
            }
        }
    }

    // MARK: Provider 切换

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Picker("Provider", selection: $model.choice) {
                ForEach(FaceGeometryChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: DS.Spacing.xs) {
                Text(model.choice.subtitle)
                Spacer()
                Text(model.mediapipeAvailable ? "MediaPipe 已加载" : "MediaPipe 未加载")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: DS.Spacing.xs) {
                Text("实际执行: \(model.activeProviderID)")
                Spacer()
                if model.lastMillis > 0 {
                    Text(String(format: "%.1f ms", model.lastMillis))
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Button {
                Task { await model.run() }
            } label: {
                Label("重新检测", systemImage: "arrow.trianglehead.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Spacing.sm)
                    .background(Capsule().fill(DS.accent))
                    .foregroundStyle(.white)
            }
            .disabled(model.isRunning)
        }
    }

    // MARK: 检测结果

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("检测结果")
                .font(.headline)
            if let geometry = model.geometry {
                Grid(alignment: .leading, horizontalSpacing: DS.Spacing.xs) {
                    statRow("提供方", geometry.providerID)
                    statRow("实测槽位", String(
                        format: "%d / %d（%.0f%%）",
                        geometry.measuredSlotCount, FaceGeometry.slotCount,
                        Double(geometry.slotCoverage) * 100
                    ))
                    statRow("虹膜点", "\(geometry.irisLandmarks.count) 个")
                    statRow("Roll", String(
                        format: "%+.2f°（置信 %.2f）",
                        geometry.pose.rollDegrees, geometry.pose.confidence
                    ))
                    statRow("Pitch", String(format: "%+.2f°", geometry.pose.pitchDegrees))
                    statRow("Yaw", String(format: "%+.2f°", geometry.pose.yawDegrees))
                    statRow("包围盒", String(
                        format: "x %.3f  y %.3f  w %.3f  h %.3f",
                        geometry.boundingBox.minX, geometry.boundingBox.minY,
                        geometry.boundingBox.width, geometry.boundingBox.height
                    ))
                    statRow("图像尺寸", String(
                        format: "%d × %d",
                        Int(geometry.imageSize.width), Int(geometry.imageSize.height)
                    ))
                    statRow("检测耗时", String(format: "%.1f ms", model.lastMillis))
                }
                .font(.caption)
            }
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
        }
    }

    private func errorSection(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 网格叠加

/// 468 槽位 + 区域折线 + 虹膜叠加。
///
/// 坐标约定（与 `FaceGeometry` 契约一致）：归一化、左上原点、x 右 y 下 ——
/// 与 SwiftUI 视图坐标同向，**无需翻转**。
/// 未实测槽位（confidence 0）跳过：Vision 兜底只有 152 个外壳槽位，
/// 折线断在哪、点缺在哪，覆盖率短板就如实呈现（不插值假装全网格）。
private struct FaceMeshOverlay: View {
    let geometry: FaceGeometry

    var body: some View {
        Canvas { context, size in
            // 区域折线（MediaPipe 规范连接序）
            for region in FaceMeshRegion.allCases {
                var path = Path()
                var started = false
                for slot in region.slots {
                    let lm = geometry.slot(slot)
                    guard lm.isMeasured else { continue }
                    let p = CGPoint(
                        x: CGFloat(lm.x) * size.width,
                        y: CGFloat(lm.y) * size.height
                    )
                    if started {
                        path.addLine(to: p)
                    } else {
                        path.move(to: p)
                        started = true
                    }
                }
                guard started else { continue }
                if region.isClosed { path.closeSubpath() }
                context.stroke(path, with: .color(.green.opacity(0.85)), lineWidth: 1)
            }
            // 468 网格点（仅实测槽位；MediaPipe = 全 468，Vision = 152 外壳）
            let dot: CGFloat = 2.5
            for lm in geometry.landmarks where lm.isMeasured {
                let rect = CGRect(
                    x: CGFloat(lm.x) * size.width - dot / 2,
                    y: CGFloat(lm.y) * size.height - dot / 2,
                    width: dot, height: dot
                )
                context.fill(Path(ellipseIn: rect), with: .color(.cyan))
            }
            // 虹膜（仅 MediaPipe 478 输出携带；10 点，放大以示区别）
            let iris: CGFloat = 4
            for lm in geometry.irisLandmarks {
                let rect = CGRect(
                    x: CGFloat(lm.x) * size.width - iris / 2,
                    y: CGFloat(lm.y) * size.height - iris / 2,
                    width: iris, height: iris
                )
                context.fill(Path(ellipseIn: rect), with: .color(.yellow))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 演示图取证（来源 / 许可 / 校验和）
//
// - 文件：App/Assets.xcassets/DemoFace.imageset/DemoFace.png（512×512 RGB PNG）
// - 来源：NASA 公有领域照片（scikit-image 示例图 `astronaut` 分发；NASA 作品
//   不受版权保护，公有领域）
// - sha256: 2418889d0d83962d51facc3832b55cf1849690018a1e873d1c551146555cd02f
// - 验证：经同一个 face_landmarker.task 模型（MediaPipe Tasks API）本地检测，
//   478 点全部检出、锚点 sane（slot 33 右眼外角 / 263 左眼外角 / 1 鼻尖 /
//   152 下巴 / 10 额顶位置全部合理）——保证 CI 截图两条 Provider 轨都有脸可检。
