import SwiftUI
import DesignSystem

@main
struct ShiGuangApp: App {
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
        }
    }
}
