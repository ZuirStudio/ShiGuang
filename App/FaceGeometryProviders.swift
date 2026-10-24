import AICore
import FaceML

// MARK: - 人脸几何 Provider 启动注册（v1.5.0 Card 1）

/// App 启动期把人脸几何 Provider 装进注册表。
///
/// 语义（与 FaceGeometryRegistry 的不变量配合）：
/// - `MediaPipeFaceMeshProvider.warmUp()` 成功 → 注册并**顶替主路径**
///   （478 点全网格 + 虹膜，coverage = 1.0）；
/// - 失败（模型缺失/损坏/框架不可用）→ **不注册**，注册表自动留在
///   `VisionLandmarksProvider` 兜底轨（init 已常驻，不可注销）——
///   不存在「没有提供方」的状态，无脸照片的液化护栏仍有 152 槽位可用。
///
/// 为什么放启动期：模型加载（读 3.6MB .task + 建 FaceLandmarker）是重活，
/// 异步执行不阻塞首帧；编辑器真要用人脸几何时它早已就绪（或已确认失败）。
/// 失败静默是刻意设计——兜底轨常驻，用户无感，日志留证。
enum FaceGeometryProviders {
    /// 进程内仅调一次（幂等：重复 register 同 ID 只覆盖字典值）。
    static func install() {
        Task {
            do {
                let ms = try await MediaPipeFaceMeshProvider.shared.warmUp()
                FaceGeometryRegistry.shared.register(
                    MediaPipeFaceMeshProvider.shared, asPrimary: true
                )
                // %@ 显式传参：错误描述可能含 %，直接插值进格式串有解析风险
                NSLog("[FaceGeometry] MediaPipe 主路径已注册（模型加载 %.1fms）", ms)
            } catch {
                // 留在 Vision 兜底轨。CI 截图深链若显式指定 mediapipe，
                // 调试视图会据 isAvailable() 报告失败原因，不静默。
                NSLog(
                    "[FaceGeometry] MediaPipe 注册失败，留在 Vision 兜底轨：%@",
                    "\(error)"
                )
            }
        }
    }
}
