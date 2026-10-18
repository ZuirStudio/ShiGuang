import Testing
import Foundation
@testable import EditKit

/// R009 任务 2 验收：`Recipe` / `EditGraph` 作为**纯数据模型**完全独立于
/// `EditorModel`（无 UI / 无平台依赖），且同一 Recipe 可被多个 EditGraph
/// 共享、连续 / 并发应用而互不污染（为 v1.5.0 批量修图奠基）。
@Suite struct RecipeIndependenceTests {

    // MARK: 独立性与值语义

    @Test func recipeIsPureValueType() throws {
        // Recipe 只有值语义字段；副本互不影响（值类型证据）
        let ops: [EditOperation] = [
            .exposure(0.5),
            .colorGrading(ColorGrading(midtones: ColorWheel(hue: 120, saturation: 60))),
        ]
        var a = Recipe(name: "A", operations: ops)
        let b = a
        a.name = "改名"
        a.intensity = 0.3
        #expect(b.name == "A")
        #expect(b.intensity == 1)
        #expect(b.operations == ops)
    }

    @Test func multipleGraphsShareOneRecipeWithoutInterference() throws {
        let recipe = Recipe(name: "共享预设", operations: [
            .exposure(0.4),
            .contrast(20),
        ])
        var graphA = EditGraph()
        var graphB = EditGraph()
        for op in recipe.operations {
            graphA.append(op)
            graphB.append(op)
        }
        // B 继续编辑不影响 A（值语义）
        graphB.append(.saturation(30))
        #expect(graphA.operations.count == 2)
        #expect(graphB.operations.count == 3)
        // A 也不影响 recipe 本体
        graphA.append(.vignette(-10))
        #expect(recipe.operations.count == 2)
    }

    // MARK: 序列化（分享 / App Intents 复放载体）

    @Test func recipeCodableRoundTrip() throws {
        let recipe = Recipe(name: "往返", operations: [
            .exposure(0.25),
            .temperature(-12),
            .toneCurve(ToneCurveSet()),
            .colorGrading(ColorGrading(
                shadows: ColorWheel(hue: -30, saturation: 40),
                midtones: .identity,
                highlights: ColorWheel(hue: 200, saturation: 80),
                blending: 65,
                balance: -25
            )),
            .lut(LUTReference(name: "cinematic")),
        ], intensity: 0.8)

        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(Recipe.self, from: data)
        #expect(decoded == recipe)
    }

    // MARK: 强度混合（批量同 Recipe 不同强度的基础）

    @Test func resolvedOperationsIntensityZeroIsAllIdentity() throws {
        let recipe = Recipe(name: "零强度", operations: [
            .exposure(0.9),
            .colorGrading(ColorGrading(midtones: ColorWheel(hue: 90, saturation: 100))),
        ], intensity: 0)
        let resolved = recipe.resolvedOperations()
        #expect(resolved.count == 2)
        for op in resolved {
            #expect(op.blended(amount: 1) == op)  // 已是收敛态
            if case .exposure(let v) = op { #expect(abs(v) < 1e-9) }
            if case .colorGrading(let g) = op { #expect(g.isIdentity) }
        }
    }

    @Test func resolvedOperationsHalfIntensityBlendsNumerics() throws {
        let recipe = Recipe(name: "半强度", operations: [
            .exposure(1.0),
            .colorGrading(ColorGrading(midtones: ColorWheel(hue: 120, saturation: 100))),
        ], intensity: 0.5)
        let resolved = recipe.resolvedOperations()
        if case .exposure(let v) = resolved[0] { #expect(abs(v - 0.5) < 1e-9) }
        if case .colorGrading(let g) = resolved[1] {
            #expect(abs(g.midtones.saturation - 50) < 1e-9)
            #expect(abs(g.midtones.hue - 60) < 1e-9)
        }
    }

    @Test func resolvedOperationsFullIntensityPassesThrough() throws {
        let ops: [EditOperation] = [.exposure(0.3), .contrast(15)]
        let recipe = Recipe(name: "满强度", operations: ops, intensity: 1)
        #expect(recipe.resolvedOperations() == ops)
    }

    // MARK: 并发共享（Swift 6 严格并发下的 Sendable 证据）

    @Test func concurrentReadsOfSharedRecipe() async throws {
        let recipe = Recipe(name: "并发读", operations: [
            .exposure(0.2),
            .colorGrading(ColorGrading(midtones: ColorWheel(hue: 60, saturation: 50))),
        ])
        // 8 路并发读同一 Recipe，各自折叠出独立 EditGraph（互不写共享状态）
        await withTaskGroup(of: Int.self) { group in
            for i in 0..<8 {
                group.addTask {
                    var graph = EditGraph()
                    for op in recipe.operations { graph.append(op) }
                    graph.append(.exposure(Double(i) / 100))
                    return graph.operations.count
                }
            }
            var counts: [Int] = []
            for await count in group { counts.append(count) }
            #expect(counts.count == 8)
            #expect(counts.allSatisfy { $0 == 3 })
        }
        // 原 Recipe 未被并发写污染
        #expect(recipe.operations.count == 2)
    }
}
