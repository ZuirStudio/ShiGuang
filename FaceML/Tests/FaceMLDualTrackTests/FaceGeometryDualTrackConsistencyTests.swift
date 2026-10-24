#if canImport(UIKit) || canImport(AppKit)
import Testing
import Foundation
import CoreGraphics
import CoreImage
import FaceML
import AICore
import FaceGeometry

// MARK: - 双轨一致性测试（真实 Provider 级，仅 Apple 平台可跑）

/// v1.5.0 Card 1 双轨验收的真实 Provider 级落地：同一张 `DemoFace` 同时喂给
/// **MediaPipe 主路径**（`MediaPipeFaceMeshProvider`）与 **Vision 兜底轨**
/// （`VisionLandmarksProvider`），断言两条轨产出的规范 468 槽位坐标、包围盒、
/// roll 姿态在容忍度内一致 —— 证明「切换 Provider 不改变几何语义」（Card 1 硬约束）。
///
/// 平台：FaceML 包为 iOS-only（MediaPipeTasksVision 二进制约束），本测试只能在
/// iOS 模拟器 / Xcode 下运行；CI 的 macOS `xcodebuild build`（build-only，无 test target）
/// 与 Linux 隔离包均不编译/运行本文件。本地验证：`swift test --platform ios` 或 Xcode。
///
/// 资源：`DemoFace.png` 由本测试 target 的 `Resources/` 提供（从 App 资产拷贝，
/// 保证两条轨喂同一张图）；`face_landmarker.task` 由 FaceML target 的 `Resources/` 提供。
@Suite struct FaceGeometryDualTrackConsistencyTests {

    private enum TestError: Error { case missingDemoFaceAsset }

    /// 从测试 target 资源加载 DemoFace → CIImage → SendableSegmentImage（正立图契约）。
    private func loadDemoFace() throws -> SendableSegmentImage {
        guard let url = Bundle.module.url(forResource: "DemoFace", withExtension: "png"),
              let data = try? Data(contentsOf: url) as CFData,
              let src = CGImageSourceCreateWithData(data, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw TestError.missingDemoFaceAsset
        }
        return SendableSegmentImage(CIImage(cgImage: cg))
    }

    // MARK: - 双轨一致性

    /// 两条轨在同一张脸上：都能检出、providerID 契约、包围盒/IoU、共享槽位坐标、roll 一致。
    @Test func dualTrackAgreesOnSameFace() async throws {
        let image = try loadDemoFace()

        let vision = VisionLandmarksProvider.shared
        let mediapipe = MediaPipeFaceMeshProvider.shared

        // 真实推理（含 MediaPipe 模型加载；缺失模型时 mediapipe.detect 会 throw，显式暴露）
        let vGeo = try await vision.detect(image)
        let mGeo = try await mediapipe.detect(image)

        let v = try #require(vGeo, "Vision 兜底轨未在 DemoFace 检出人脸")
        let m = try #require(mGeo, "MediaPipe 主路径未在 DemoFace 检出人脸")

        // 1) providerID 契约（注册表键 + 诊断显示）
        #expect(v.providerID == "vision.landmarks.rev3")
        #expect(m.providerID == "mediapipe.face_landmarker")

        // 2) 槽位覆盖率：MediaPipe 主路径应覆盖全部 468 规范槽位（契约 slotCoverage == 1.0）；
        //    Vision 兜底轨仅外壳 ~152 槽位（≈0.32），只需 > 0
        #expect(m.slotCoverage == 1.0, "MediaPipe 主路径槽位覆盖率应为 1.0（实际 \(m.slotCoverage)）")
        #expect(v.slotCoverage > 0, "Vision 兜底轨应至少覆盖部分槽位（实际 \(v.slotCoverage)）")

        // 3) 包围盒一致性：两条轨定位同一张脸，IoU 应较高
        let boxIoU = Self.iou(v.boundingBox, m.boundingBox)
        #expect(boxIoU > 0.4, "两条轨包围盒 IoU 应 > 0.4（实际 \(boxIoU)）")

        // 4) 规范槽位坐标一致性：对两条轨都实测（isMeasured）的槽位，归一化坐标应在容忍度内一致。
        //    两条轨共用同一 468 规范拓扑（MediaPipe 拓扑），slot[i] 对应同一面部点。
        let tol: Float = 0.05
        var compared = 0, agreed = 0
        for i in 0..<FaceGeometry.slotCount {
            let vv = v.landmarks[i], mm = m.landmarks[i]
            guard vv.isMeasured, mm.isMeasured else { continue }
            compared += 1
            if abs(vv.x - mm.x) <= tol && abs(vv.y - mm.y) <= tol { agreed += 1 }
        }
        #expect(compared > 80, "两条轨共同实测的槽位应 > 80（实际 \(compared)）")
        let agreeRatio = compared > 0 ? Double(agreed) / Double(compared) : 0
        #expect(agreeRatio > 0.8, "共同实测槽位坐标一致率应 > 0.8（实际 \(agreeRatio)）")

        // 5) roll 姿态一致性：两条轨共用 HeadPoseSolver（Horn 解算），语义不漂移
        #expect(abs(v.pose.roll - m.pose.roll) < 0.15,
                "roll 姿态差应 < 0.15 rad（V=\(v.pose.roll) M=\(m.pose.roll)）")
    }

    // MARK: - 私有

    /// 两个归一化包围盒的 IoU（图像归一化、左上原点、x右y下；两轨坐标契约一致）。
    private static func iou(_ a: CGRect, _ b: CGRect) -> Float {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let union = a.width * a.height + b.width * b.height - interArea
        guard union > 0 else { return 0 }
        return Float(interArea / union)
    }
}
#endif
