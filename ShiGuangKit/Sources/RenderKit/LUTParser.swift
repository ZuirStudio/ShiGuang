import Foundation
import CoreGraphics

// MARK: - .cube LUT 解析（行业标准 3D LUT 文本格式）

/// 解析后的 3D LUT。
public struct LUTCube: Equatable, Sendable {
    public let title: String?
    /// 每轴网格数 N（数据长度 = N^3 × 3）
    public let size: Int
    /// RGB 三元组，行序遵循 .cube 规范：red 最慢、blue 最快
    public let rgb: [Float]

    public init(title: String?, size: Int, rgb: [Float]) {
        self.title = title
        self.size = size
        self.rgb = rgb
    }
}

public enum LUTParseError: Error, Equatable, Sendable {
    case empty
    case missingSize
    case invalidSize(String)
    case wrongLineCount(expected: Int, got: Int)
    case invalidLine(Int)
}

/// `.cube` 解析器（纯逻辑，100% 可单测）。
/// 支持：TITLE / LUT_3D_SIZE / DOMAIN_MIN / DOMAIN_MAX / # 注释 / 空行。
public enum LUTParser {
    public static func parse(_ text: String) throws -> LUTCube {
        var title: String?
        var size: Int?
        var rgb: [Float] = []

        for (lineNumber, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("TITLE") {
                // TITLE "名称"
                let quoted = line.dropFirst("TITLE".count).trimmingCharacters(in: .whitespaces)
                title = quoted.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                continue
            }
            if line.hasPrefix("LUT_3D_SIZE") {
                let value = line.dropFirst("LUT_3D_SIZE".count).trimmingCharacters(in: .whitespaces)
                guard let n = Int(value), n >= 2, n <= 128 else {
                    throw LUTParseError.invalidSize(value)
                }
                size = n
                continue
            }
            if line.hasPrefix("DOMAIN_MIN") || line.hasPrefix("DOMAIN_MAX") {
                continue // v1 仅支持标准 [0,1] 域
            }

            // 数据行：r g b（浮点 0...1）
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 3,
                  let r = Float(parts[0]),
                  let g = Float(parts[1]),
                  let b = Float(parts[2])
            else {
                throw LUTParseError.invalidLine(lineNumber + 1)
            }
            rgb.append(r); rgb.append(g); rgb.append(b)
        }

        guard let n = size else { throw LUTParseError.missingSize }
        guard rgb.count == n * n * n * 3 else {
            throw LUTParseError.wrongLineCount(expected: n * n * n, got: rgb.count / 3)
        }
        return LUTCube(title: title, size: n, rgb: rgb)
    }

    /// 转换为 CIColorCubeWithColorSpace 的 inputCubeData（RGBA float，premultiplied）。
    /// 只做 stride 重排（rgb[3i…] → rgba[4i…]），**不重排条目顺序** ——
    /// LUTCube.rgb 已按 CIColorCube 契约（red 最快、blue 最慢）存放。
    public static func colorCubeData(_ cube: LUTCube) -> Data {
        var rgba = [Float](repeating: 0, count: cube.size * cube.size * cube.size * 4)
        for i in 0..<(cube.size * cube.size * cube.size) {
            rgba[i * 4 + 0] = cube.rgb[i * 3 + 0]
            rgba[i * 4 + 1] = cube.rgb[i * 3 + 1]
            rgba[i * 4 + 2] = cube.rgb[i * 3 + 2]
            rgba[i * 4 + 3] = 1
        }
        return Data(bytes: rgba, count: rgba.count * MemoryLayout<Float>.size)
    }
}
