import XCTest
@testable import AppPipeline

// 拾光 · v1.0.x Hotfix H1 · Tests/AppPipelineTests/PhotoPipelineLazyInstallTests.swift
// 编译目标：Linux 逻辑测试隔离包（真源 = Shared/PhotoPipeline.swift +
// Shared/ServiceInstallGate.swift，CI 每次从仓库复制，见 ios.yml）
//
// H1 验收（用户原文）：「Linux 单测 = 模拟无启动流程直接调用 handler 可解析 pipeline」。
// 本文件直接驱动真实 PhotoPipeline 代码（非模拟替身）：
//   - 不经过 ShiGuangApp.init()（无 App 启动副作用）；
//   - 按 intent 入口的方式注册 installer + ensureInstalled()；
//   - 断言 handler 闭包从事前抛错态变为可解析态。
//
// 隔离说明：测试类保持 nonisolated（corelibs-xctest 的 allTests 注册机制对
// @MainActor 测试类会触发 non-Sendable 警告）；所有 @MainActor 隔离入口
// （PhotoPipeline / InstallCounter）经 await 显式跳转访问。

final class PhotoPipelineLazyInstallTests: XCTestCase {

    override func setUp() async throws {
        // 不调 super.setUp()：corelibs-xctest 父实现 nonisolated，
        // @MainActor 上下文里 await 它会触发发送检查误报（Linux 特有；
        // 本文件仅 Linux 隔离包编译，App target 无此测试 target）。
        // 每个用例从出厂态开始：PhotoPipeline 出厂态 + 测试桩清零
        await PhotoPipeline.resetForTesting()
        await InstallCounter.shared.reset()
        await TestPipelineLog.shared.reset()
    }

    // ── 验收 1（核心）：无启动流程 → intent 入口装配 → handler 可解析 ──

    func testIntentProcessResolvesPipelineWithoutAppLaunch() async throws {
        // 事前：无 App 启动副作用（本进程没有人调用过 ShiGuangApp.init()）
        let installerBefore = await PhotoPipeline.installer
        XCTAssertNil(installerBefore)

        // 装配前直接调 handler：复现旧 bug 现象（抛 notConfigured，不崩）
        do {
            try await PhotoPipeline.applyPreset("preset.qingxin", "photo-1")
            XCTFail("装配前 handler 应抛 notConfigured")
        } catch let error as PhotoPipelineError {
            XCTAssertEqual(error, .notConfigured)
        }

        // intent 入口动作（与 ApplyPresetAndExportIntent.perform() 首行同构）：
        // 注册 installer → ensureInstalled()
        await PhotoPipeline.setInstallerForTesting {
            InstallCounter.shared.bump()
            PhotoPipeline.applyPresetForTesting { presetID, photoID in
                // 测试装配实现：记录入参，模拟真实管线的成功路径
                // （record 为 @MainActor 隔离；本闭包为 @Sendable nonisolated，
                //  Swift 6 下须显式 await 跳转 —— 与真实装配闭包调用
                //  RecipeStore 等 @MainActor 服务的模式一致）
                await TestPipelineLog.shared.record(apply: "\(presetID)|\(photoID)")
            }
            PhotoPipeline.exportPhotoForTesting { photoID in
                URL(fileURLWithPath: "/tmp/\(photoID)-export.jpg")
            }
        }
        await PhotoPipeline.ensureInstalled()

        // 事后：handler 可解析（不再抛错，且拿到装配实现的结果）
        try await PhotoPipeline.applyPreset("preset.qingxin", "photo-1")
        let applied = await TestPipelineLog.shared.applied
        XCTAssertEqual(applied, "preset.qingxin|photo-1")

        let url = try await PhotoPipeline.exportPhoto("photo-1")
        XCTAssertEqual(url.lastPathComponent, "photo-1-export.jpg")

        let installCount = await InstallCounter.shared.count
        XCTAssertEqual(installCount, 1, "装配应恰好执行一次")
    }

    // ── 验收 2：幂等 —— intent 与 App 启动两路共用一门，不重复装配 ──

    func testEnsureInstalledIsIdempotent() async throws {
        await PhotoPipeline.setInstallerForTesting {
            InstallCounter.shared.bump()
            PhotoPipeline.recentPhotoIDsForTesting { ["photo-A", "photo-B"] }
        }

        // 模拟：intent 入口先装配，App 启动路径（若同进程）再装配
        await PhotoPipeline.ensureInstalled()
        await PhotoPipeline.ensureInstalled()
        await PhotoPipeline.ensureInstalled()

        let installCount = await InstallCounter.shared.count
        XCTAssertEqual(installCount, 1)
        let ids = await PhotoPipeline.recentPhotoIDs()
        XCTAssertEqual(ids, ["photo-A", "photo-B"])
    }

    // ── 验收 3：无宿主进程（Widget / Linux 无 App）不误装 ──

    func testNoInstallerKeepsGateClosed() async throws {
        // Widget Extension 不注册 installer；Linux 隔离包默认同样为 nil
        await PhotoPipeline.setInstallerForTesting(nil)
        await PhotoPipeline.ensureInstalled()

        // 门保持未装配态，闭包维持默认（不崩、不误装）
        do {
            _ = try await PhotoPipeline.exportPhoto("photo-1")
            XCTFail("无宿主时 handler 应保持默认抛错态")
        } catch let error as PhotoPipelineError {
            XCTAssertEqual(error, .notConfigured)
        }
    }

    // ── 验收 4：resetForTesting 后门可重新装配（隔离用例间状态） ──

    func testResetForTestingReopensGate() async throws {
        await PhotoPipeline.setInstallerForTesting { InstallCounter.shared.bump() }
        await PhotoPipeline.ensureInstalled()
        var installCount = await InstallCounter.shared.count
        XCTAssertEqual(installCount, 1)

        // resetForTesting = 出厂态（installer 亦置空，模拟新进程）；
        // 重设 installer 后门应可再次装配
        await PhotoPipeline.resetForTesting()
        await PhotoPipeline.setInstallerForTesting { InstallCounter.shared.bump() }
        await PhotoPipeline.ensureInstalled()
        installCount = await InstallCounter.shared.count
        XCTAssertEqual(installCount, 2, "reset 后门应可再次装配")
    }

    // ── 验收 5：错误文案降级（内部术语不得泄漏给用户） ──

    func testNotConfiguredDescriptionIsGeneric() async throws {
        let description = PhotoPipelineError.notConfigured.errorDescription ?? ""
        XCTAssertFalse(
            description.contains("注入"),
            "notConfigured 文案不得包含内部术语「注入」：\(description)"
        )
        XCTAssertFalse(description.contains("未配置"))
        XCTAssertTrue(description.contains("快捷指令"), "应保留「快捷指令」语境：\(description)")
    }

    func testPresetNotFoundDescription() async throws {
        let description = PhotoPipelineError.presetNotFound("preset.fanku").errorDescription ?? ""
        XCTAssertTrue(description.contains("preset.fanku"))
        XCTAssertTrue(description.contains("预设"))
    }
}

/// 测试装配实现的入参记录桩（@MainActor 单例，仅本测试文件使用）。
@MainActor
final class TestPipelineLog {
    static let shared = TestPipelineLog()
    private init() {}
    var applied: String?
    func record(apply value: String) { applied = value }
    func reset() { applied = nil }
}

/// 装配次数计数器（@MainActor 单例，仅本测试文件使用）。
@MainActor
final class InstallCounter {
    static let shared = InstallCounter()
    private init() {}
    private(set) var count = 0
    func bump() { count += 1 }
    func reset() { count = 0 }
}
