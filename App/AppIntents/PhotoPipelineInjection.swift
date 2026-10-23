import UIKit
import PhotoIO   // FilePhotoStore / BatchExporter / BatchExportRequest
import RenderKit // BatchRenderer
import EditKit   // Recipe

// 拾光 · R010-B 系统集成 · PhotoPipeline 服务注入 + 深链路由
//
// 在 App 启动早期由 `ShiGuangApp.init()` 调用一次（见 ShiGuangApp.swift）。
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
        let recipes = RecipeStore().userRecipes
        guard let recipe = recipes.first(where: { $0.id.uuidString == presetID || $0.name == presetID })
                          ?? recipes.first else {
            throw PhotoPipelineError.notConfigured
        }
        let rendered: [CGImage?] = await BatchRenderer().render([source], operations: recipe.resolvedOperations())
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
}
