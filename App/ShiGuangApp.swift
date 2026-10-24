import SwiftUI
import DesignSystem

@main
struct ShiGuangApp: App {
    init() {
        // R010-B 系统集成：注入快捷指令服务实现 + 深链路由（仅此一处接触导航）。
        // H1：注册为 PhotoPipeline.installer —— AppIntent 后台进程（不经 init）
        // 在 perform() 入口自行注册并惰性装配；两路共用同一幂等门。
        PhotoPipeline.installer = installPhotoPipelineAndDeepLinks
        installPhotoPipelineAndDeepLinks()
        // v1.5.0 Card 1：MediaPipe 人脸几何模型异步预热，成功即顶替注册表主路径；
        // 失败留在 Vision 兜底轨（注册表不变量保证任意时刻有提供方可用）。
        FaceGeometryProviders.install()
    }

    var body: some Scene {
        WindowGroup {
            // P1-C（R007d）：根视图强制深空黑底。
            //
            // v0.7.2 真机「全局白底」的根因：WindowGroup 的根视图没有不透明背景，
            // 系统按 UIUserInterfaceStyle 给窗口铺底色 —— 设备处于浅色模式时
            // 就是白底，编辑页内部的 .background(void) 只遮得住图像画布，
            // 遮不住窗口层与列表容器。
            // 双保险：① 根 ZStack 第一层铺 DS.Brand.void 并 ignoresSafeArea
            //（连安全区外延一起遮）；② project.yml 强制 UIUserInterfaceStyle = Dark，
            // 不跟随系统（见 App/Info.plist 生成配置）。
            ZStack {
                DS.Brand.void.ignoresSafeArea()
                LibraryView()
            }
            // R010-B：Widget 点击 / 快捷指令深链经此进入（解析 → DeepLinkRouter → PendingDeepLink）
            .onOpenURL { url in
                DeepLinkRouter.handle(url)
            }
        }
    }
}
