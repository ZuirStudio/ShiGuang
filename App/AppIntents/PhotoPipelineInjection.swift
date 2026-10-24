import UIKit
import PhotoIO   // FilePhotoStore / BatchExporter / BatchExportRequest
import RenderKit // BatchRenderer
import EditKit   // Recipe

// 拾光 · R010-B 系统集成 · PhotoPipeline 服务注入 + 深链路由
//
// H1 起：本函数不再依赖「仅 App 启动时执行一次」的时序假设 ——
// 它被注册为 PhotoPipeline.installer，经 ServiceInstallGate 幂等装配：
//   - ShiGuangApp.init()：App 正常启动路径（注册 + 立即装配）；
//   - AppIntent.perform()：快捷指令后台进程入口（注册 + 惰性装配）。
// 同进程内重复调用由门去重；本函数自身保持纯装配（闭包赋值级），可重入安全。
//
// 本文件把主工程的真实服务接到 `PhotoPipeline` 闭包，并把 URL 深链路由到
// 一个待消费队列（完整 UI 导航接入为后续工作；此处只完成「路由 plumbing」，
// 保证链路不崩、App 正常启动）。

/// 深链待消费队列：`.onOpenURL` 解析到的目标暂存此处，由编辑器视图出现时消费。
@MainActor
final class PendingDeepLink {
    static let shared = PendingDeepLink()
    private init() {}

    var destination: DeepLinkDestination?

    /// 取出并清空（一次性消费）。
    func consume() -> DeepLinkDestination? {
        let d = destination
        destination = nil
        return d
    }
}

/// 在 App 启动早期调用一次：注入快捷指令服务实现 + 深链路由。
@MainActor
func installPhotoPipelineAndDeepLinks() {
    // 1) 注入快捷指令服务实现（后台线程执行：闭包内已按需 await）
    PhotoPipeline.applyPreset = { presetID, photoID in
        let store = try FilePhotoStore()
        let photos = try await store.allPhotos()
        guard let photo = photos.first(where: { $0.id.uuidString == photoID }) else {
            throw PhotoPipelineError.noPhoto
        }
        guard let source = store.fullCIImage(for: photo) else {
            throw PhotoPipelineError.exportFailed("无法读取照片原图")
        }
        // 预设匹配：presetID 先按 UUID 对齐，再按名称；都没有则取首条
        // RecipeStore 为 @MainActor 隔离；本闭包为 @Sendable（运行于非主线程），须 await 跳主线程读取
        let recipes = await RecipeStore().userRecipes
        guard let recipe = recipes.first(where: { $0.id.uuidString == presetID || $0.name == presetID })
                          ?? recipes.first else {
            // H1：无匹配预设是面向用户的业务错误，不再借用 notConfigured
            //（后者为内部 DI 信号，其文案已降级，不适合表达此场景）
            throw PhotoPipelineError.presetNotFound(presetID)
        }
        let rendered: [CGImage?] = await BatchRenderer().render([source], operations: recipe.resolvedOperations(), progress: { _ in })
        guard let cg = rendered.first, let cg else {
            throw PhotoPipelineError.exportFailed("渲染失败")
        }
        let request = BatchExportRequest(images: [cg])
        let results = try await BatchExporter().export(request) { _ in }
        guard let url = results.first?.url, let data = try? Data(contentsOf: url) else {
            throw PhotoPipelineError.exportFailed("导出失败")
        }
        _ = try await store.save(imageData: data, preferredExtension: "jpg")
        if let thumb = store.thumbnailCGImage(for: photo) {
            RecentEditsStore.shared.record(photoID: photoID, thumbnail: UIImage(cgImage: thumb))
        }
    }

    PhotoPipeline.exportPhoto = { photoID in
        let store = try FilePhotoStore()
        let photos = try await store.allPhotos()
        guard let photo = photos.first(where: { $0.id.uuidString == photoID }),
              let url = store.sourceURL(of: photo) else {
            throw PhotoPipelineError.noPhoto
        }
        return url
    }

    PhotoPipeline.recentPhotoIDs = {
        do {
            let store = try FilePhotoStore()
            let photos = try await store.allPhotos()
            return photos.map { $0.id.uuidString }
        } catch {
            return []
        }
    }

    PhotoPipeline.openEditor = { photoID, presetID in
        Task { @MainActor in
            PendingDeepLink.shared.destination = .applyPreset(presetID: presetID ?? "", photoID: photoID)
        }
    }

    // 2) 深链路由：URL → 导航意图（暂存，由编辑器视图消费）
    DeepLinkRouter.onRoute = { destination in
        Task { @MainActor in
            PendingDeepLink.shared.destination = destination
        }
    }

    // 3) 装配轨迹走内部日志（H1：排查快捷指令进程装配问题时只看这里，
    //    不再向用户暴露任何内部状态文案）
    NSLog("[PhotoPipeline] DI 装配完成（applyPreset/exportPhoto/recentPhotoIDs/openEditor + 深链路由）")
}
