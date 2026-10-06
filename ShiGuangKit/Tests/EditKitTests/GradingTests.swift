import Testing
import Foundation
import EditKit

// MARK: - 色调曲线数据模型

@Suite struct ToneCurveModelTests {
    @Test func identityCurveIsIdentity() {
        let curve = ToneCurve()
        #expect(curve.isIdentity)
        #expect(curve.points.count == 2)
        for i in 0...20 {
            let x = Double(i) / 20
            #expect(abs(curve.sample(at: x) - x) < 1e-9)
        }
    }

    @Test func addingPointBreaksIdentity() {
        var curve = ToneCurve()
        let mut0 = curve.addPoint(CurvePoint(0.5, 0.7))
        #expect(mut0)
        #expect(!curve.isIdentity)
        #expect(curve.interiorCount == 1)
    }

    @Test func sanitizeSortsDedupesAndPinsEndpoints() {
        let curve = ToneCurve(points: [
            CurvePoint(0.5, 0.20),
            CurvePoint(0.5, 0.90),   // 同 x 取后者
            CurvePoint(0.2, 0.10),
        ])
        let xs = curve.points.map(\.x)
        #expect(xs.first == 0)
        #expect(xs.last == 1)
        for i in 1..<xs.count {
            #expect(xs[i] > xs[i - 1])          // 严格递增
        }
        #expect(abs(curve.sample(at: 0.5) - 0.90) < 1e-6)
    }

    @Test func outOfRangePointsAreClamped() {
        let curve = ToneCurve(points: [
            CurvePoint(-3, -1),
            CurvePoint(2, 5),
        ])
        for p in curve.points {
            #expect(p.x >= 0 && p.x <= 1)
            #expect(p.y >= 0 && p.y <= 1)
        }
    }

    @Test func curveSamplingIsMonotoneNonDecreasing() {
        // Fritsch–Carlson 单调插值：陡峭过渡也不得过冲（暗部不得反转）
        var curve = ToneCurve()
        let mut1 = curve.addPoint(CurvePoint(0.25, 0.10))
        #expect(mut1)
        let mut2 = curve.addPoint(CurvePoint(0.50, 0.85))
        #expect(mut2)
        let mut3 = curve.addPoint(CurvePoint(0.75, 0.90))
        #expect(mut3)
        var previous = -1.0
        for i in 0...400 {
            let y = curve.sample(at: Double(i) / 400)
            #expect(y >= previous - 1e-9)
            #expect(y >= 0 && y <= 1)
            previous = y
        }
    }

    @Test func movePointKeepsStrictIncrease() {
        var curve = ToneCurve()
        let mut4 = curve.addPoint(CurvePoint(0.5, 0.5))
        #expect(mut4)
        let mut5 = curve.addPoint(CurvePoint(0.8, 0.5))
        #expect(mut5)
        // 试图越过右邻居
        let mut6 = curve.movePoint(at: 1, to: CurvePoint(0.99, 0.6))
        #expect(mut6)
        let xs = curve.points.map(\.x)
        for i in 1..<xs.count {
            #expect(xs[i] > xs[i - 1])
        }
        // 端点 x 被钉死，可上下移动
        let mut7 = curve.movePoint(at: 0, to: CurvePoint(0.4, 0.3))
        #expect(mut7)
        #expect(curve.points[0].x == 0)
        #expect(abs(curve.points[0].y - 0.3) < 1e-9)
    }

    @Test func endpointsCannotBeRemoved() {
        var curve = ToneCurve()
        let mut8 = curve.addPoint(CurvePoint(0.5, 0.5))
        #expect(mut8)
        let mut9 = curve.removePoint(at: 0)
        #expect(!mut9)
        let mut10 = curve.removePoint(at: curve.points.count - 1)
        #expect(!mut10)
        let mut11 = curve.removePoint(at: 1)
        #expect(mut11)
        #expect(curve.points.count == 2)
    }

    @Test func pointCountIsCapped() {
        var curve = ToneCurve()
        for i in 1..<40 {
            _ = curve.addPoint(CurvePoint(Double(i) / 40, 0.5))
        }
        #expect(curve.points.count <= ToneCurve.maxPoints)
    }

    @Test func blendToIdentityConverges() {
        let dark = ToneCurve(points: [CurvePoint(0, 0), CurvePoint(1, 0)])   // 全黑
        #expect(dark.sample(at: 0.9) < 1e-9)
        #expect(dark.blended(towardsIdentity: 0).isIdentity)
        let half = dark.blended(towardsIdentity: 0.5)
        let y = half.sample(at: 0.9)
        #expect(y > 0.35 && y < 0.55)
    }

    @Test func decodingSanitizesHostilePoints() throws {
        // 外部预设可能带入乱序 / 越界 / 同 x 的控制点
        let json = """
        [{"x":0.9,"y":0.2},{"x":0.9,"y":0.8},{"x":-1,"y":2},{"x":3,"y":-1}]
        """.data(using: .utf8)!
        let curve = try JSONDecoder().decode(ToneCurve.self, from: json)
        let xs = curve.points.map(\.x)
        #expect(xs.first == 0)
        #expect(xs.last == 1)
        for i in 1..<xs.count {
            #expect(xs[i] > xs[i - 1])
        }
        for p in curve.points {
            #expect(p.y >= 0 && p.y <= 1)
        }
    }

    @Test func codableRoundTripIsStable() throws {
        var curve = ToneCurve()
        let mut12 = curve.addPoint(CurvePoint(0.3, 0.7))
        #expect(mut12)
        let data = try JSONEncoder().encode(curve)
        let decoded = try JSONDecoder().decode(ToneCurve.self, from: data)
        #expect(decoded == curve)
    }
}

// MARK: - 四通道曲线集合

@Suite struct ToneCurveSetTests {
    @Test func defaultsToIdentity() {
        let set = ToneCurveSet()
        #expect(set.isIdentity)
        for channel in CurveChannel.allCases {
            #expect(set.isIdentity(for: channel))
            #expect(set[channel].isIdentity)
        }
    }

    @Test func subscriptRoundTrip() {
        var set = ToneCurveSet()
        let lifted = ToneCurve(points: [CurvePoint(0, 0.2), CurvePoint(1, 1)])
        set[.red] = lifted
        #expect(set.red == lifted)
        #expect(!set.isIdentity)
        #expect(set.isIdentity(for: .green))
        #expect(!set.isIdentity(for: .red))
    }

    @Test func tableComposesMasterThenSubChannel() {
        var set = ToneCurveSet()
        set.rgb = ToneCurve(points: [CurvePoint(0, 0), CurvePoint(1, 0.5)])          // 压暗
        set.red = ToneCurve(points: [CurvePoint(0, 0), CurvePoint(0.5, 1), CurvePoint(1, 1)]) // 提亮

        let count = 33
        let master = set.table(for: .rgb, count: count)
        let red = set.table(for: .red, count: count)
        #expect(master == set.rgb.table(count: count))
        #expect(red != master)

        // 分通道 = 主曲线输出再过分通道曲线：red[i] ≈ red.sample(master[i])
        for i in 0..<count {
            let expected = set.red.sample(at: master[i])
            #expect(abs(red[i] - expected) < 0.02)
        }
    }

    @Test func tableWithIdentitySubChannelEqualsMaster() {
        var set = ToneCurveSet()
        set.rgb = ToneCurve(points: [CurvePoint(0, 0.1), CurvePoint(1, 1)])
        let master = set.table(for: .rgb, count: 17)
        #expect(set.table(for: .blue, count: 17) == master)
    }

    @Test func blendedScalesAllChannels() {
        var set = ToneCurveSet()
        set.rgb = ToneCurve(points: [CurvePoint(0, 0), CurvePoint(1, 0)])
        set.green = ToneCurve(points: [CurvePoint(0, 0), CurvePoint(1, 0)])
        #expect(!set.isIdentity)
        #expect(set.blended(towardsIdentity: 0).isIdentity)
        #expect(!set.blended(towardsIdentity: 0.5).isIdentity)
    }
}

// MARK: - HSL 折叠容器

@Suite struct HSLAdjustmentTests {
    @Test func defaultsAreIdentity() {
        let hsl = HSLAdjustment()
        #expect(HSLAdjustment.count == 24)
        #expect(hsl.isIdentity)
        for channel in HSLChannel.allCases {
            #expect(!hsl.isAdjusted(channel))
            for component in HSLComponent.allCases {
                #expect(hsl[channel, component] == 0)
            }
        }
    }

    @Test func clampingToParameterRange() {
        var hsl = HSLAdjustment()
        hsl[.red, .hue] = 1000
        #expect(hsl[.red, .hue] == 100)
        hsl[.red, .luminance] = -1000
        #expect(hsl[.red, .luminance] == -100)
        hsl[.aqua, .saturation] = 37.5
        #expect(hsl[.aqua, .saturation] == 37.5)
    }

    @Test func absorbFoldsHueAndSaturationPerChannel() {
        var hsl = HSLAdjustment()
        let mut13 = hsl.absorb(.hsl(.green, .hue, 30))
        #expect(mut13)
        let mut14 = hsl.absorb(.hsl(.green, .saturation, -60))
        #expect(mut14)
        let mut15 = hsl.absorb(.exposure(1))
        #expect(!mut15)          // 不属 HSL 折叠
        #expect(hsl[.green, .hue] == 30)
        #expect(hsl[.green, .saturation] == -60)
        #expect(hsl.isAdjusted(.green))
        #expect(!hsl.isAdjusted(.blue))
        #expect(!hsl.isIdentity)
        // 后写覆盖（管线语义：最后一条指令生效）
        let mut16 = hsl.absorb(.hsl(.green, .hue, -20))
        #expect(mut16)
        #expect(hsl[.green, .hue] == -20)
    }

    @Test func hueShiftDegreesCoversFullCircle() {
        var hsl = HSLAdjustment()
        hsl[.red, .hue] = 100
        #expect(abs(hsl.hueShiftDegrees(.red) - 180) < 1e-9)
        hsl[.red, .hue] = -100
        #expect(abs(hsl.hueShiftDegrees(.red) + 180) < 1e-9)
        hsl[.red, .hue] = 0
        #expect(hsl.hueShiftDegrees(.red) == 0)
    }
}

// MARK: - 参数标识映射（24 参数 ↔ 指令）

@Suite struct GradingParameterMappingTests {
    @Test func everyHSLParameterMapsToUniqueSlot() {
        var seen = Set<String>()
        for parameter in EditParameter.allCases {
            guard let binding = parameter.hslBinding else { continue }
            let key = "\(binding.channel.rawValue)/\(binding.component.rawValue)"
            #expect(!seen.contains(key), "重复映射：\(key)")
            seen.insert(key)
            #expect(EditParameter.hsl(binding.channel, binding.component) == parameter)
        }
        #expect(seen.count == 24)
    }

    @Test func nonHSLParametersHaveNoBinding() {
        #expect(EditParameter.exposure.hslBinding == nil)
        #expect(EditParameter.toneCurve.hslBinding == nil)
        #expect(EditParameter.crop.hslBinding == nil)
    }

    @Test func hslParameterGroupAndGestures() {
        for parameter in EditParameter.allCases where parameter.hslBinding != nil {
            #expect(parameter.group == .hsl)
            #expect(!parameter.isGestureAdjustable)   // HSL 走专用面板
            #expect(parameter.defaultRange == -100...100)
            // 越界输入必须被钳到声明的区间
            let high = EditOperation.make(parameter: parameter, value: 1e6).clamped.numericValue
            let low = EditOperation.make(parameter: parameter, value: -1e6).clamped.numericValue
            #expect(high == parameter.defaultRange.upperBound)
            #expect(low == parameter.defaultRange.lowerBound)
        }
        #expect(EditParameter.toneCurve.group == .curve)
        #expect(!EditParameter.toneCurve.isGestureAdjustable)
    }

    @Test func makeAndClampRouteHSLParameters() {
        let op = EditOperation.make(parameter: .hslBlueSaturation, value: 45)
        guard case .hsl(let channel, let component, let value) = op else {
            Issue.record("工厂未产出 HSL 指令")
            return
        }
        #expect(channel == .blue)
        #expect(component == .saturation)
        #expect(value == 45)

        let clamped = EditOperation.hsl(.blue, .saturation, 999).clamped
        guard case .hsl(_, _, let clampedValue) = clamped else {
            Issue.record("clamped 丢失 HSL 载荷")
            return
        }
        #expect(clampedValue == 100)
        #expect(clamped.parameter == .hslBlueSaturation)
    }

    @Test func toneCurveOperationCarriesCurveSet() {
        var set = ToneCurveSet()
        set.red = ToneCurve(points: [CurvePoint(0, 0.3), CurvePoint(1, 1)])
        let op = EditOperation.toneCurve(set)
        #expect(op.parameter == .toneCurve)
        guard case .toneCurve(let carried) = op else {
            Issue.record("载荷类型错误")
            return
        }
        #expect(carried == set)
    }

    @Test func gradingOperationsRoundTripThroughCodable() throws {
        var set = ToneCurveSet()
        set.rgb = ToneCurve(points: [CurvePoint(0, 0), CurvePoint(0.5, 0.6), CurvePoint(1, 1)])
        let operations: [EditOperation] = [
            .toneCurve(set),
            .hsl(.magenta, .luminance, -25),
        ]
        let data = try JSONEncoder().encode(operations)
        let decoded = try JSONDecoder().decode([EditOperation].self, from: data)
        #expect(decoded == operations)
    }
}

// MARK: - 图内合并与历史原子性

@Suite struct GradingGraphTests {
    /// 与渲染管线同语义的取值：对图中全部指令做 HSL 折叠（后写覆盖）。
    private func hslValue(
        _ graph: EditGraph, _ channel: HSLChannel, _ component: HSLComponent
    ) -> Double {
        var hsl = HSLAdjustment()
        for operation in graph.operations {
            _ = hsl.absorb(operation)
        }
        return hsl[channel, component]
    }

    @Test func interactiveUpdatesMergeByParameter() {
        var graph = EditGraph()
        _ = graph.updateInteractive(.hsl(.orange, .hue, 10))
        _ = graph.updateInteractive(.hsl(.orange, .hue, 25))
        #expect(graph.operations.count == 1)
        #expect(hslValue(graph, .orange, .hue) == 25)

        // 换分量 → 新指令
        _ = graph.updateInteractive(.hsl(.orange, .saturation, 8))
        #expect(graph.operations.count == 2)

        // 换通道 → 新指令
        _ = graph.updateInteractive(.hsl(.purple, .hue, 4))
        #expect(graph.operations.count == 3)
    }

    @Test func curveUpdatesMergeIntoOneInstruction() {
        var graph = EditGraph()
        var first = ToneCurveSet()
        first.red = ToneCurve(points: [CurvePoint(0, 0.1), CurvePoint(1, 1)])
        _ = graph.updateInteractive(.toneCurve(first))
        var second = first
        second.red = ToneCurve(points: [CurvePoint(0, 0.3), CurvePoint(1, 1)])
        _ = graph.updateInteractive(.toneCurve(second))
        #expect(graph.operations.count == 1)
        guard case .toneCurve(let carried) = graph.operations[0] else {
            Issue.record("载荷类型错误")
            return
        }
        #expect(carried.red == second.red)
    }

    @Test func channelResetIsSingleAtomicHistoryStep() {
        var graph = EditGraph()
        var history = EditHistory()
        let seeded = EditOperation.hsl(.red, .hue, 40)
        _ = graph.updateInteractive(seeded)
        history.commitInteractive(label: "红色相", operation: seeded)

        let operations = HSLComponent.allCases.map { EditOperation.hsl(.red, $0, 0) }
        for op in operations {
            _ = graph.updateInteractive(op)
        }
        history.commit(label: "重置红色域", operations: operations)

        #expect(history.stepCount == 2)
        #expect(hslValue(graph, .red, .hue) == 0)

        _ = history.undo()
        graph = EditGraph(operations: history.operations)
        #expect(hslValue(graph, .red, .hue) == 40)
        #expect(history.stepCount == 1)
    }
}
