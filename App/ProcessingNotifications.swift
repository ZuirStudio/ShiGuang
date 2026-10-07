import Foundation
import UserNotifications

/// 完成提醒（R006 追加 C 第 7 条）。
///
/// 只用**本地通知**，不需要任何 entitlement；用户未授权时静默跳过，绝不阻塞主流程。
/// 授权在「用户点了后台处理」时才请求 —— 有上下文，用户更容易点同意。
enum ProcessingNotifications {

    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    static func postCompletion(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let status = settings.authorizationStatus
            guard status == .authorized || status == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: "shiguang.ai.completion",
                                                content: content,
                                                trigger: nil)
            center.add(request)
        }
    }
}
