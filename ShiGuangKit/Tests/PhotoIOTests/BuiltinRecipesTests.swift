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
        // 语义断言（不锁死具体数值）：预设重调不应使测试失真
        let film = BuiltinRecipes.recipe(named: "胶片")
        #expect(film != nil)
        #expect(film?.operations.isEmpty == false)
        let desaturates = film?.operations.contains { (op: EditOperation) -> Bool in
            if case .saturation(let v) = op { return v < 0 }
            return false
        } ?? false
        #expect(desaturates) // 胶片预设语义：整体降饱和
        #expect(BuiltinRecipes.recipe(named: "不存在") == nil)
    }

    @Test func presetCodableRoundTrip() throws {
        // 遍历整个目录（不硬编码预设名，随预设增删重调自动跟随）
        for recipe in BuiltinRecipes.all {
            let data = try JSONEncoder().encode(recipe)
            let back = try JSONDecoder().decode(Recipe.self, from: data)
            #expect(back == recipe)
        }
    }

    @Test func intensityZeroIsIdentity() {
        let recipe = Recipe(name: "X", operations: [.exposure(2), .contrast(40)], intensity: 0)
        let resolved = recipe.resolvedOperations()
        #expect(resolved == [.exposure(0), .contrast(0)])
    }
}
