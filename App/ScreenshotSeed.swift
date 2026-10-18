import Foundation
import CoreGraphics
import ImageIO

// MARK: - CI 截图深链（R009/R010 验收用）

/// CI 截图专用启动参数（`xcrun simctl launch ... com.shiguang.ShiGuang <参数>`）：
///
/// - `-ShiGuangScreenshotGradingPanel`（R009）：演示照片 → 编辑器「色轮分级」面板
/// - `-ShiGuangScreenshotHistoryPanel`（R010）：演示照片 → 编辑器 + 两步历史 → 历史面板
/// - `-ShiGuangScreenshotBatch:<模式>`（R010）：多张演示照片 → 图库多选态，模式：
///   - `select`：只进多选态（验收勾选 UI + 底部批量条，不开面板）
///   - `config`：多选态 + 打开批量面板配置态（验收预设选择 UI，不自动开跑）
///   - `run`：多选态 + 打开批量面板并自动开始（分两次截图捕获进度条与结果态）
///
/// 生产路径不受影响：参数不存在时一切如常（App Store 无人传参）。
enum ScreenshotLaunch {
    /// 批量深链的参数前缀（模式以 `:<模式>` 后缀携带）。
    static let batchArgumentPrefix = "-ShiGuangScreenshotBatch"

    /// 批量截图模式。
    enum BatchMode: String {
        case select, config, run
    }

    /// 本次启动的批量截图模式（nil = 非批量截图）。
    static var batchMode: BatchMode? {
        let prefix = batchArgumentPrefix + ":"
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }),
              let mode = BatchMode(rawValue: String(arg.dropFirst(prefix.count))) else { return nil }
        return mode
    }

    /// 是否为任意批量截图模式（演示照片预置判据）。
    static var isBatchRun: Bool { batchMode != nil }

    /// 本次启动是否为「色轮分级截图」模式。
    static var isGradingPanelRun: Bool {
        ProcessInfo.processInfo.arguments.contains("-ShiGuangScreenshotGradingPanel")
    }

    /// 本次启动是否为「历史面板截图」模式。
    static var isHistoryPanelRun: Bool {
        ProcessInfo.processInfo.arguments.contains("-ShiGuangScreenshotHistoryPanel")
    }
}

// MARK: - 演示照片

/// 程序化生成的演示照片（纯 CoreGraphics / ImageIO，无外部资源依赖）。
/// 画面为仿自然场景（天空渐变 + 地面 + 光源 + 地平线压暗），
/// 明暗层次覆盖三色轮的阴影 / 中间调 / 高光三个亮度域。
enum DemoPhoto {
    /// 生成 JPEG 数据（默认 1440×960，与导入照片同路径落盘）。
    ///
    /// async：2160×1440 的 CG 绘制 + JPEG 编码是重 CPU 活，放进 generic
    /// executor 执行，避免在主 actor 上同步跑把首帧卡成黑屏（R010 CI 实测：
    /// 8 张 2160×1440 同步生成 ≈ 2-4s 主线程阻塞，+4s 定时截图全黑）。
    /// 纯函数式（自建 context/渐变/数据，无共享状态），跨 executor 安全。
    static func jpegData(width: Int = 1440, height: Int = 960) async -> Data? {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let w = Double(width), h = Double(height)

        // 天空：上深下浅的竖向渐变
        // （CGGradient 用 colors 数组构造：CGColor(red:green:blue:alpha:) 非可选，
        //  locations 传 nil = 首尾均分，正是两段渐变所需）
        let skyColors: [CGColor] = [
            CGColor(red: 0.16, green: 0.28, blue: 0.52, alpha: 1.0),
            CGColor(red: 0.55, green: 0.68, blue: 0.82, alpha: 1.0)
        ]
        if let sky = CGGradient(colorsSpace: space, colors: skyColors as CFArray, locations: nil) {
            context.drawLinearGradient(
                sky, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: h * 0.62), options: []
            )
        }

        // 地面：暖色渐变（与天空形成色温对比）
        let groundColors: [CGColor] = [
            CGColor(red: 0.36, green: 0.28, blue: 0.18, alpha: 1.0),
            CGColor(red: 0.12, green: 0.10, blue: 0.07, alpha: 1.0)
        ]
        if let ground = CGGradient(colorsSpace: space, colors: groundColors as CFArray, locations: nil) {
            context.drawLinearGradient(
                ground, start: CGPoint(x: 0, y: h * 0.62), end: CGPoint(x: 0, y: h), options: []
            )
        }

        // 光源：右上暖色圆 + 两层光晕
        let sunCenter = CGPoint(x: w * 0.74, y: h * 0.22)
        drawGlow(context: context, center: sunCenter, radius: w * 0.22, alpha: 0.10, space: space)
        drawGlow(context: context, center: sunCenter, radius: w * 0.13, alpha: 0.20, space: space)
        drawGlow(context: context, center: sunCenter, radius: w * 0.07, alpha: 0.95, space: space)

        // 地平线压暗（增加明暗层次：阴影域与高光域都有可染像素）
        // （CGContext.setFillColor(red:green:blue:alpha:) 非可选，避免 CGColor? 解包）
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.18)
        context.fill(CGRect(x: 0, y: h * 0.60, width: w, height: h * 0.04))

        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func drawGlow(
        context: CGContext, center: CGPoint, radius: Double, alpha: Double, space: CGColorSpace
    ) {
        context.setFillColor(red: 1.0, green: 0.86, blue: 0.62, alpha: alpha)
        context.fillEllipse(in: CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        ))
    }
}
