import Testing
import Foundation
@testable import EditKit

// MARK: - EditOperation

@Suite struct EditOperationTests {
    @Test func clamping() {
        #expect(EditOperation.exposure(8).clamped == .exposure(5))
        #expect(EditOperation.exposure(-9).clamped == .exposure(-5))
        #expect(EditOperation.sharpen(-3).clamped == .sharpen(0))
        #expect(EditOperation.vignette(120).clamped == .vignette(100))
        #expect(EditOperation.straighten(60).clamped == .straighten(45))
        let crop = EditOperation.crop(CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        #expect(crop.clamped == crop)
    }

    @Test func parameterIdentity() {
        #expect(EditOperation.exposure(1).parameter == EditParameter.exposure)
        #expect(EditOperation.exposure(1).parameter == EditOperation.exposure(2).parameter)
        #expect(EditOperation.exposure(1).parameter != EditOperation.contrast(1).parameter)
        #expect(EditParameter.allCases.count == 17)
    }

    @Test func blendingRespectsStructuralOps() {
        #expect(EditOperation.exposure(2).blended(amount: 0.5) == .exposure(1))
        #expect(EditOperation.contrast(100).blended(amount: 0) == .contrast(0))
        #expect(EditOperation.vibrance(-40).blended(amount: 0.5) == .vibrance(-20))
        let crop = EditOperation.crop(CropRect(x: 0, y: 0, width: 1, height: 1))
        #expect(crop.blended(amount: 0.5) == crop)
        #expect(EditOperation.straighten(10).blended(amount: 0.5) == .straighten(10))
    }
}

// MARK: - EditGraph

@Suite struct EditGraphTests {
    @Test func codableRoundTrip() throws {
        let graph = EditGraph(operations: [
            .exposure(0.7), .contrast(-12), .temperature(9), .vibrance(30),
            .noiseReduction(15), .vignette(-20),
            .crop(CropRect(x: 0.05, y: 0.1, width: 0.9, height: 0.8)),
            .straighten(-3.5),
        ])
        let data = try JSONEncoder().encode(graph)
        let decoded = try JSONDecoder().decode(EditGraph.self, from: data)
        #expect(decoded == graph)
    }

    @Test func appendClampsValues() {
        var graph = EditGraph()
        graph.append(.exposure(99))
        #expect(graph.operations == [.exposure(5)])
    }

    @Test func interactiveCoalescing() {
        var graph = EditGraph()
        graph.updateInteractive(.exposure(0.2))
        #expect(graph.updateInteractive(.exposure(0.6)) == true)
        graph.updateInteractive(.contrast(10))
        #expect(graph.operations == [.exposure(0.6), .contrast(10)])
        // 新参数追加而非替换
        #expect(graph.updateInteractive(.contrast(20)) == true)
        #expect(graph.operations == [.exposure(0.6), .contrast(20)])
    }
}

// MARK: - EditHistory

@Suite struct EditHistoryTests {
    @Test func undoRedo() {
        var history = EditHistory()
        history.commit(label: "曝光", operations: [.exposure(0.5)])
        history.commit(label: "对比度", operations: [.contrast(10)])
        #expect(history.stepCount == 2)
        #expect(history.undo()?.label == "对比度")
        #expect(history.operations == [.exposure(0.5)])
        #expect(history.redo()?.label == "对比度")
        #expect(history.operations == [.exposure(0.5), .contrast(10)])
        #expect(history.redo() == nil)
    }

    @Test func commitClearsRedo() {
        var history = EditHistory()
        history.commit(label: "1", operations: [.exposure(0.1)])
        history.undo()
        #expect(history.redoSteps.count == 1)
        history.commit(label: "2", operations: [.contrast(5)])
        #expect(history.redoSteps.isEmpty)
    }

    @Test func jumpBackPreservesRedoOrder() {
        var history = EditHistory()
        history.commit(label: "1", operations: [.exposure(0.1)])
        history.commit(label: "2", operations: [.contrast(1)])
        history.commit(label: "3", operations: [.saturation(1)])
        history.jump(to: 1)
        #expect(history.operations == [.exposure(0.1)])
        #expect(history.redo()?.label == "2")
        #expect(history.redo()?.label == "3")
        #expect(history.operations.count == 3)
        // 越界安全
        history.jump(to: 99)
        #expect(history.stepCount == 3)
    }
}

// MARK: - Recipe 与文档

@Suite struct RecipeAndDocumentTests {
    @Test func recipeIntensityBlends() {
        let recipe = Recipe(
            name: "胶片",
            operations: [.exposure(2), .contrast(50), .straighten(8)],
            intensity: 0.5
        )
        let resolved = recipe.resolvedOperations()
        #expect(resolved[0] == .exposure(1))
        #expect(resolved[1] == .contrast(25))
        #expect(resolved[2] == .straighten(8)) // 结构化不混合
    }

    @Test func recipeIntensityClamped() {
        let recipe = Recipe(name: "X", operations: [.exposure(1)], intensity: 5)
        #expect(recipe.intensity == 1)
    }

    @Test func documentDefaultsAndRoundTrip() throws {
        let document = EditDocument()
        #expect(document.schemaVersion == 1)
        #expect(document.graph.isEmpty)
        var doc = document
        doc.history.commit(label: "饱和度", operations: [.saturation(12)])
        doc.graph.append(.saturation(12))
        let data = try JSONEncoder().encode(doc)
        let back = try JSONDecoder().decode(EditDocument.self, from: data)
        #expect(back == doc)
        #expect(back.history.operations == [.saturation(12)])
    }
}

// MARK: - 交互式提交与参数工厂

@Suite struct InteractiveAndFactoryTests {
    @Test func commitInteractiveCoalescesByLabel() {
        var history = EditHistory()
        history.commitInteractive(label: "曝光", operation: .exposure(0.2))
        history.commitInteractive(label: "曝光", operation: .exposure(0.8))
        history.commitInteractive(label: "对比度", operation: .contrast(10))
        #expect(history.stepCount == 2)
        #expect(history.operations == [.exposure(0.8), .contrast(10)])
        #expect(history.undo()?.label == "对比度")
        #expect(history.operations == [.exposure(0.8)])
        history.redo()
        history.undo()
        history.undo()
        #expect(history.operations.isEmpty)
    }

    @Test func interactiveCommitClearsRedo() {
        var history = EditHistory()
        history.commit(label: "1", operations: [.exposure(0.1)])
        history.undo()
        history.commitInteractive(label: "曝光", operation: .exposure(0.3))
        #expect(history.redoSteps.isEmpty)
        #expect(history.operations == [.exposure(0.3)])
    }

    @Test func factoryCoversAllParameters() {
        for parameter in EditParameter.allCases {
            let value = parameter.defaultRange.upperBound
            let op = EditOperation.make(parameter: parameter, value: value)
            #expect(op.parameter == parameter)
            if parameter != .crop {
                #expect(op.numericValue == value)
            }
        }
        // 工厂产物与直接构造一致
        #expect(EditOperation.make(parameter: .exposure, value: 1.5) == .exposure(1.5))
        #expect(EditParameter.exposure.defaultRange == (-5...5))
        #expect(EditParameter.sharpen.defaultRange == (0...100))
    }
}
