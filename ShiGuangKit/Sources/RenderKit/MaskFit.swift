import Foundation
import CoreImage
import CoreGraphics

/// 蒙版尺寸适配（R007c P0-B 根因修复）。
///
/// ## 背景
/// Core Image 的 `CIImage.cropped(to:)` **只裁不缩**：把一张 4032×3024（全分辨率）的
/// 人像掩码裁到 180×135（缩略图）只是「取左上角那一小块」，两张图不再对齐；
/// 一旦掩码与目标 extent 不再相交，裁完就是**空图**（extent 为空），
/// 下游 `CIBlendWithMask` 的输出随之变成空图 → `createCGImage` 拿不到像素 → 缩略图永久停在占位态。
///
/// ## 语义
/// `fit(_:to:)` 把掩码**等比缩放**到目标 extent 的尺寸，再平移到目标原点并裁到该范围：
/// 缩放后掩码必然覆盖目标 extent，裁剪不可能落到空图。
/// 掩码与源图同源（都由同一张照片派生），所以按宽度比例等比缩放即可保持对齐，
/// 无需 `aspectFit` 那种留边逻辑。
public enum MaskFit {

    /// 把 `mask` 等比缩放到 `extent` 的尺寸并裁到该范围。
    ///
    /// - 掩码或目标为空尺寸时原样返回（调用方自行兜底）。
    /// - 掩码原始尺寸已与目标一致时，只做平移 + 裁剪（零缩放开销）。
    public static func fit(_ mask: CIImage, to extent: CGRect) -> CIImage {
        let m = mask.extent
        guard m.width >= 1, m.height >= 1,
              extent.width >= 1, extent.height >= 1,
              m.width.isFinite, m.height.isFinite else { return mask }

        // 1) 平移到原点（掩码可能带非零 origin，例如上游做过裁剪）
        var out = m.origin == .zero
            ? mask
            : mask.transformed(by: CGAffineTransform(translationX: -m.origin.x, y: -m.origin.y))

        // 2) 等比缩放（横向比例为准：掩码与源图同源、长宽比一致）
        let factor = extent.width / m.width
        if abs(factor - 1) > 0.001 {
            out = out.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        }

        // 3) 平移回目标原点 + 裁到目标范围
        if extent.origin != .zero {
            out = out.transformed(by: CGAffineTransform(translationX: extent.origin.x, y: extent.origin.y))
        }
        return out.cropped(to: extent)
    }

    /// 把掩码规整成 `CIBlendWithMask` 能正确解释的形态：**三通道不透明**（白 = 生效）。
    ///
    /// CI 取证（`grayChannelMaskSemantics` 用例）：单通道灰度图（`CGColorSpaceCreateDeviceGray()`
    /// + `CGImageAlphaInfo.none`）当 `inputMaskImage` 时几何反常 —— 掩码外区域会被压成黑
    /// （实测左半均值 0.0，而未施效果的对照是 128.1）。生产链路掩码目前都是三通道
    /// （AICore `makeOpaqueGray` 的 premultipliedLast、MaskRenderer 的渐变掩码），
    /// 所以这里是**防御性**规整：后续若接入单通道掩码源（Vision 原生输出、外部导入），
    /// 也不会把画面烧成黑块。三通道输入原样返回（零开销、零行为变化）。
    public static func canonical(_ mask: CIImage) -> CIImage {
        guard let cg = mask.cgImage else { return mask }               // 滤镜产物：已是三通道
        let isSingleChannel = cg.bitsPerPixel < 24 || cg.colorSpace?.model == .monochrome
        guard isSingleChannel else { return mask }
        guard let ctx = CGContext(data: nil, width: cg.width, height: cg.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return mask }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let converted = ctx.makeImage() else { return mask }
        return CIImage(cgImage: converted)
    }

    /// 掩码是否需要缩放（用于埋点/测试断言，不参与渲染）。
    public static func needsScaling(_ mask: CIImage, to extent: CGRect) -> Bool {
        let m = mask.extent
        guard m.width >= 1, extent.width >= 1 else { return false }
        return abs(extent.width / m.width - 1) > 0.001
    }
}
