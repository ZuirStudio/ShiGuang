import Foundation
import CoreGraphics
import ImageIO

// MARK: - CI 截图深链（R009 验收用）

/// CI 截图专用启动参数：`xcrun simctl launch ... com.shiguang.ShiGuang -ShiGuangScreenshotGradingPanel`
///
/// 用途（R009 任务 1 验收：CI 截图必须清晰看到色轮 UI）：
/// 主 App 常规启动落在照片库空态，看不到编辑器内的色轮分级面板。
/// 该参数让 App 走一条**仅 CI 存在**的调试路径：自动生成一张演示照片 →
/// 直接打开编辑器并落到「色彩 → 色轮分级」面板（附带一份非恒等分级，
/// 让色轮指示点 / 方向线在截图里可见）。
///
/// 生产路径不受影响：参数不存在时一切如常（App Store 无人传参）。
enum ScreenshotLaunch {
    /// 启动参数名（simctl launch 透传给 ProcessInfo.arguments）。
    static let gradingPanelArgument = "-ShiGuangScreenshotGradingPanel"

    /// 本次启动是否为「色轮分级截图」模式。
    static var isGradingPanelRun: Bool {
        ProcessInfo.processInfo.arguments.contains(gradingPanelArgument)
    }
}

// MARK: - 演示照片

/// 程序化生成的演示照片（纯 CoreGraphics / ImageIO，无外部资源依赖）。
/// 画面为仿自然场景（天空渐变 + 地面 + 光源 + 地平线压暗），
/// 明暗层次覆盖三色轮的阴影 / 中间调 / 高光三个亮度域。
enum DemoPhoto {
    /// 生成 JPEG 数据（默认 1440×960，与导入照片同路径落盘）。
    static func jpegData(width: Int = 1440, height: Int = 960) -> Data? {
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
        let skyLocations: [CGFloat] = [0, 1]
        let skyComponents: [CGFloat] = [0.16, 0.28, 0.52, 1.0, 0.55, 0.68, 0.82, 1.0]
        if let sky = CGGradient(
            colorSpace: space, locations: skyLocations, components: skyComponents, count: 2
        ) {
            context.drawLinearGradient(
                sky, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: h * 0.62), options: []
            )
        }

        // 地面：暖色渐变（与天空形成色温对比）
        let groundLocations: [CGFloat] = [0, 1]
        let groundComponents: [CGFloat] = [0.36, 0.28, 0.18, 1.0, 0.12, 0.10, 0.07, 1.0]
        if let ground = CGGradient(
            colorSpace: space, locations: groundLocations, components: groundComponents, count: 2
        ) {
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
        let horizon: [CGFloat] = [0, 0, 0, 0.18]
        context.setFillColor(CGColor(colorSpace: space, components: horizon))
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
        let glow: [CGFloat] = [1.0, 0.86, 0.62, alpha]
        context.setFillColor(CGColor(colorSpace: space, components: glow))
        context.fillEllipse(in: CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        ))
    }
}
