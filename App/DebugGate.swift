import Foundation
import Observation

/// P1-F：性能诊断的隐藏开关。
///
/// 默认隐藏。在「设置」页连点版本号 7 次（相邻两次间隔 < 2 秒）解锁；
/// 解锁后编辑器工具栏出现「性能诊断」按钮、设置页出现诊断入口，
/// 可随时在设置页「隐藏性能诊断」重新收起。状态持久化到 UserDefaults，
/// 重启 App 保持（与 `EditorModel` 的存储策略同属用户偏好层）。
///
/// 进程级单例 + 主 actor 隔离：只从 UI 线程读写（同 `PerfSignpost.shared` 模式）。
/// 视图在 body 内读取 `unlocked` 即自动建立观察依赖，解锁/隐藏即时生效。
@MainActor
@Observable
final class DebugGate {
    /// 进程级共享实例。
    static let shared = DebugGate()

    /// UserDefaults 键。解锁状态是用户偏好，非敏感数据，明文存储即可。
    private static let defaultsKey = "debug.perfDiagnosticsUnlocked"

    /// 当前是否已解锁。
    private(set) var unlocked: Bool

    private init() {
        unlocked = UserDefaults.standard.bool(forKey: Self.defaultsKey)
    }

    /// 解锁（设置页连点版本号达到次数时调用）。持久化。
    func unlock() {
        unlocked = true
        UserDefaults.standard.set(true, forKey: Self.defaultsKey)
    }

    /// 重新隐藏（设置页「隐藏性能诊断」行）。持久化：工具栏按钮与设置页入口同步消失。
    func lock() {
        unlocked = false
        UserDefaults.standard.set(false, forKey: Self.defaultsKey)
    }
}
