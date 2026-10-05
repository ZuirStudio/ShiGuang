import Testing
import Foundation
import RenderKit

// MARK: - .cube LUT 解析

@Suite struct LUTParserTests {
    /// 最小 2×2×2 cube（8 行数据）
    private var minimalCube: String {
        """
        # test lut
        TITLE "Test LUT"

        LUT_3D_SIZE 2

        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 1.0 1.0 1.0

        0.0 0.0 0.0
        0.0 0.0 1.0
        0.0 1.0 0.0
        0.0 1.0 1.0
        1.0 0.0 0.0
        1.0 0.0 1.0
        1.0 1.0 0.0
        1.0 1.0 1.0
        """
    }

    @Test func parsesMinimalCube() throws {
        let cube = try LUTParser.parse(minimalCube)
        #expect(cube.title == "Test LUT")
        #expect(cube.size == 2)
        #expect(cube.rgb.count == 2 * 2 * 2 * 3)
        // 首行 r=0,g=0,b=0
        #expect(cube.rgb[0] == 0 && cube.rgb[1] == 0 && cube.rgb[2] == 0)
        // 末行 1,1,1
        #expect(cube.rgb[21] == 1 && cube.rgb[22] == 1 && cube.rgb[23] == 1)
    }

    @Test func supportsFullSizeCubeLineCount() throws {
        // 4³ = 64 行
        var text = "LUT_3D_SIZE 4\n"
        for i in 0..<(4 * 4 * 4) {
            let v = String(format: "%.4f", Double(i) / Double(4 * 4 * 4 - 1))
            text += "\(v) \(v) \(v)\n"
        }
        let cube = try LUTParser.parse(text)
        #expect(cube.size == 4)
        #expect(cube.rgb.count == 64 * 3)
    }

    @Test func missingSizeThrows() {
        #expect(throws: LUTParseError.missingSize) {
            try LUTParser.parse("0.5 0.5 0.5\n0.5 0.5 0.5\n")
        }
    }

    @Test func wrongLineCountThrows() {
        let truncated = "LUT_3D_SIZE 3\n" + (0..<26).map { _ in "0.5 0.5 0.5" }.joined(separator: "\n")
        #expect(throws: LUTParseError.self) {
            try LUTParser.parse(truncated)
        }
    }

    @Test func invalidLineThrows() {
        let bad = "LUT_3D_SIZE 2\n" + ["a b c"] + (0..<7).map { _ in "0 0 0" }.joined(separator: "\n")
        #expect(throws: LUTParseError.self) {
            try LUTParser.parse(bad)
        }
    }

    @Test func colorCubeDataLayout() throws {
        let cube = try LUTParser.parse(minimalCube)
        let data = LUTParser.colorCubeData(cube)
        // RGBA float：N^3 × 4 通道 × 4 字节
        #expect(data.count == 2 * 2 * 2 * 4 * MemoryLayout<Float>.size)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let floats = raw.bindMemory(to: Float.self)
            // 第 4 个格点（index 3）：rgb = (0,1,1)、alpha = 1
            #expect(floats[3 * 4 + 0] == 0)
            #expect(floats[3 * 4 + 1] == 1)
            #expect(floats[3 * 4 + 2] == 1)
            #expect(floats[3 * 4 + 3] == 1)
        }
    }
}
