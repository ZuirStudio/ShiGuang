import Testing
import Foundation
import CoreGraphics
import EditKit

// MARK: - 内置预设目录

@Suite struct BuiltinRecipesTests {
    @Test func catalogIntegrity() {
        #expect(BuiltinRecipes.all.count >= 8)
        let names = BuiltinRecipes.all.map(\.name)
        #expect(Set(names).count == names.count) // 名称唯一
        for recipe in BuiltinRecipes.all {
            #expect(!recipe.name.isEmpty)
            #expect(!recipe.operations.isEmpty)
            // 全部指令数值必须在合法范围内（预设数据是手写的，防呆）
            for op in recipe.operations {
                #expect(op == op.clamped)
            }
        }
    }

    @Test func lookupByName() {
        #expect(BuiltinRecipes.recipe(named: "胶片")?.operations.contains(.saturation(-15)) == true)
        #expect(BuiltinRecipes.recipe(named: "不存在") == nil)
    }

    @Test func presetCodableRoundTrip() throws {
        let recipe = BuiltinRecipes.recipe(named: "黑白")!
        let data = try JSONEncoder().encode(recipe)
        let back = try JSONDecoder().decode(Recipe.self, from: data)
        #expect(back == recipe)
    }

    @Test func intensityZeroIsIdentity() {
        let recipe = Recipe(name: "X", operations: [.exposure(2), .contrast(40)], intensity: 0)
        let resolved = recipe.resolvedOperations()
        #expect(resolved == [.exposure(0), .contrast(0)])
    }
}
