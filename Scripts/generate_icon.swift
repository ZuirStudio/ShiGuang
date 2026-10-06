// generate_icon.swift
// 拾光 App 图标生成器（方案 A「光圈」）— 权威生成源。
//
// 用法（CI 内跑一次；本机 macOS 亦可手动跑）：
//     swift Scripts/generate_icon.swift --out App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
//
// 设计与合规：
//   - 视觉**原创**：抽象三段弧线围成光圈（暗示镜头 / 对焦环），三处小缺口提供识别特征；
//     未复制任何竞品图标风格，无文字、无品牌标识，不使用任何 AI 生成素材。
//   - 1024×1024，**不带圆角**（圆角由 iOS 系统裁切），不透明（无 alpha 通道）。
//   - 仅依赖 Apple 系统框架：CoreGraphics + ImageIO（无第三方素材、无网络）。
//
// 与 Scripts/preview_icon.py 保持**同一组常数**（无 Xcode 环境时的本地预览 / 兜底生成）。
// 全部计算为确定性像素运算，同一输入必得同一输出。

import Foundation
import CoreGraphics
import ImageIO

// MARK: - 常数（必须与 Scripts/preview_icon.py 完全一致）

private let iconSize = 1024
private let bgColor = (r: 0x0A, g: 0x0A, b: 0x0A)        // 深空黑
private let goldColor = (r: 0xFF, g: 0xB3, b: 0x47)      // 暖金
private let orangeColor = (r: 0xFF, g: 0x7A, b: 0x45)    // 橙

private let ringRadius = 300.0        // 光圈半径（弧线中心线）
private let ringWidth = 56.0          // 弧线粗细
private let arcCount = 3              // 三段弧
private let arcSweepDeg = 101.0       // 每段弧张角 → 缺口张角 = 120 - 101 = 19°
private let arcStart0Deg = 279.5      // 首段弧起始角（数学角：+x 轴起、逆时针、y 向上）
                                      // 缺口中心 = 270° / 30° / 150°（缺口居下）
private let capRound = false          // 平端弧

private let bloomRadius = 600.0       // 中心柔光半径
private let bloomAlpha = 0.24         // 中心柔光峰值不透明度
private let bloomPower = 1.6          // 柔光衰减指数
private let glowSigma = 24.0          // 弧线外发光模糊 sigma
private let glowAlpha = 0.62          // 弧线外发光强度
private let glowBoxPasses = 3         // 用 3 次盒式模糊近似高斯（radius ≈ sigma）
private let gradCenter = (x: 400.0, y: 400.0)  // 渐变中心（屏幕坐标：左上原点、y 向下）
private let gradRadius = 620.0        // 渐变半径（金 → 橙）

// MARK: - 基础工具

@inline(__always)
private func clamp01(_ v: Double) -> Double {
    v < 0 ? 0 : (v > 1 ? 1 : v)
}

@inline(__always)
private func smoothstep(_ t: Double) -> Double {
    let c = clamp01(t)
    return c * c * (3 - 2 * c)
}

@inline(__always)
private func mix(_ a: Double, _ b: Double, _ t: Double) -> Double {
    a + (b - a) * t
}

// MARK: - 三段弧遮罩（CoreGraphics 描边，自带抗锯齿）

private func makeArcsMask(size: Int) -> [Float] {
    var buffer = [UInt8](repeating: 0, count: size * size)
    let drawn: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(
            data: raw.baseAddress,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return false }

        ctx.setShouldAntialias(true)
        ctx.setStrokeColor(gray: 1.0, alpha: 1.0)
        ctx.setLineWidth(ringWidth)
        ctx.setLineCap(capRound ? .round : .butt)

        let center = Double(size) / 2.0
        for i in 0..<arcCount {
            let a0 = arcStart0Deg + Double(i) * 360.0 / Double(arcCount)
            let a1 = a0 + arcSweepDeg
            ctx.beginPath()
            ctx.addArc(
                center: CGPoint(x: center, y: center),
                radius: ringRadius,
                startAngle: a0 * .pi / 180.0,
                endAngle: a1 * .pi / 180.0,
                clockwise: false
            )
            ctx.strokePath()
        }
        return true
    }
    guard drawn else {
        FileHandle.standardError.write(Data("错误：无法创建灰度位图上下文（弧线遮罩）\n".utf8))
        exit(1)
    }

    var out = [Float](repeating: 0, count: size * size)
    for i in 0..<(size * size) {
        out[i] = Float(buffer[i]) / 255.0
    }
    return out
}

// MARK: - 可分离盒式模糊（3 次近似高斯）

private func boxBlur(_ src: [Float], size: Int, radius: Int, passes: Int) -> [Float] {
    guard radius > 0, passes > 0 else { return src }
    var current = src
    var scratch = [Float](repeating: 0, count: src.count)
    let window = Double(radius * 2 + 1)

    for _ in 0..<passes {
        // 水平
        for y in 0..<size {
            let row = y * size
            var sum = 0.0
            for x in -radius...radius {
                sum += Double(current[row + min(max(x, 0), size - 1)])
            }
            for x in 0..<size {
                scratch[row + x] = Float(sum / window)
                let outIdx = min(max(x - radius, 0), size - 1)
                let inIdx = min(max(x + radius + 1, 0), size - 1)
                sum += Double(current[row + inIdx]) - Double(current[row + outIdx])
            }
        }
        // 垂直
        for x in 0..<size {
            var sum = 0.0
            for y in -radius...radius {
                sum += Double(scratch[min(max(y, 0), size - 1) * size + x])
            }
            for y in 0..<size {
                current[y * size + x] = Float(sum / window)
                let outIdx = min(max(y - radius, 0), size - 1)
                let inIdx = min(max(y + radius + 1, 0), size - 1)
                sum += Double(scratch[inIdx * size + x]) - Double(scratch[outIdx * size + x])
            }
        }
    }
    return current
}

// MARK: - 合成（中心柔光 → 弧线外发光 → 弧线本体渐变）

private func compose(size: Int, arcs: [Float], glow: [Float]) -> [UInt8] {
    let center = Double(size) / 2.0
    let scale = Double(size) / Double(iconSize)
    let bloomR = bloomRadius * scale
    let gradR = gradRadius * scale
    let gcx = gradCenter.x * scale
    let gcy = gradCenter.y * scale

    var rgb = [Double](repeating: 0, count: size * size * 3)
    var idx = 0
    for y in 0..<size {
        let dy = Double(y)
        for x in 0..<size {
            let dx = Double(x)

            // 1) 底色
            var r = Double(bgColor.r)
            var g = Double(bgColor.g)
            var b = Double(bgColor.b)

            // 2) 中心柔光
            let bd = (dx - center) * (dx - center) + (dy - center) * (dy - center)
            let bDist = bd.squareRoot() / bloomR
            let bloomA = pow(max(0, 1 - bDist), bloomPower) * bloomAlpha
            if bloomA > 0 {
                r = mix(r, Double(goldColor.r), bloomA)
                g = mix(g, Double(goldColor.g), bloomA)
                b = mix(b, Double(goldColor.b), bloomA)
            }

            // 3) 弧线外发光
            let glowA = Double(glow[y * size + x]) * glowAlpha
            if glowA > 0 {
                r = mix(r, Double(orangeColor.r), glowA)
                g = mix(g, Double(orangeColor.g), glowA)
                b = mix(b, Double(orangeColor.b), glowA)
            }

            // 4) 弧线本体：金 → 橙 径向渐变
            let arcA = Double(arcs[y * size + x])
            if arcA > 0 {
                let gd = (dx - gcx) * (dx - gcx) + (dy - gcy) * (dy - gcy)
                let t = smoothstep(gd.squareRoot() / gradR)
                r = mix(r, mix(Double(goldColor.r), Double(orangeColor.r), t), arcA)
                g = mix(g, mix(Double(goldColor.g), Double(orangeColor.g), t), arcA)
                b = mix(b, mix(Double(goldColor.b), Double(orangeColor.b), t), arcA)
            }

            rgb[idx] = r
            rgb[idx + 1] = g
            rgb[idx + 2] = b
            idx += 3
        }
    }

    // 输出 32bpp RGB（无 alpha 通道，第 4 字节被 noneSkipLast 忽略）
    var out = [UInt8](repeating: 255, count: size * size * 4)
    var o = 0
    for p in stride(from: 0, to: rgb.count, by: 3) {
        out[o] = UInt8(min(max(rgb[p].rounded(), 0), 255))
        out[o + 1] = UInt8(min(max(rgb[p + 1].rounded(), 0), 255))
        out[o + 2] = UInt8(min(max(rgb[p + 2].rounded(), 0), 255))
        o += 4
    }
    return out
}

// MARK: - PNG 输出

private func writePNG(_ rgba: [UInt8], size: Int, to path: String) throws {
    let bytesPerRow = size * 4
    let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
    guard let provider = CGDataProvider(data: Data(rgba) as CFData),
          let image = CGImage(
            width: size,
            height: size,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
          )
    else {
        FileHandle.standardError.write(Data("错误：无法构造 CGImage\n".utf8))
        exit(1)
    }

    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil
    ) else {
        FileHandle.standardError.write(Data("错误：无法创建 PNG 输出（\(path)）\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write(Data("错误：PNG 写入失败（\(path)）\n".utf8))
        exit(1)
    }
}

// MARK: - 入口

private func runGenerator() {
    var outPath = "App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
    var args = Array(CommandLine.arguments.dropFirst())
    while let first = args.first {
        args.removeFirst()
        switch first {
        case "--out":
            if let v = args.first {
                outPath = v
                args.removeFirst()
            }
        case "-h", "--help":
            print("用法: swift Scripts/generate_icon.swift [--out <path>]")
            exit(0)
        default:
            FileHandle.standardError.write(Data("未知参数：\(first)\n".utf8))
            exit(2)
        }
    }

    let arcs = makeArcsMask(size: iconSize)
    let blurRadius = Int((glowSigma * 1.0).rounded())
    let glow = boxBlur(arcs, size: iconSize, radius: blurRadius, passes: glowBoxPasses)
    let pixels = compose(size: iconSize, arcs: arcs, glow: glow)

    let dir = URL(fileURLWithPath: outPath).deletingLastPathComponent().path
    if !dir.isEmpty {
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
    }

    do {
        try writePNG(pixels, size: iconSize, to: outPath)
    } catch {
        FileHandle.standardError.write(Data("PNG 写入异常：\(error)\n".utf8))
        exit(1)
    }

    let attrs = try? FileManager.default.attributesOfItem(atPath: outPath)
    let bytes = (attrs?[.size] as? NSNumber)?.intValue ?? 0
    print("icon -> \(outPath) (\(bytes) bytes, \(iconSize)x\(iconSize), RGB, 无圆角)")
}

runGenerator()
