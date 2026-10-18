import Testing
import Foundation
import CoreGraphics
import ImageIO
import PhotoIO

/// R009 任务 2 验收：批量导出并发队列 —— 多张不同尺寸图一次导出，
/// 结果与输入同序、进度单调收敛、单张失败不中断整批。
@Suite struct BatchExportTests {

    /// 进度收集盒：`export` 的 progress 闭包是 `@Sendable` 且在 TaskGroup
    /// 子任务中被调用 —— Swift 6 禁止闭包内直接变更捕获的 var（实测 CI 报
    /// `#SendableClosureCaptures`），用 NSLock 盒收集（保序、线程安全）。
    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [BatchExportProgress] = []
        func append(_ progress: BatchExportProgress) {
            lock.lock()
            defer { lock.unlock() }
            items.append(progress)
        }
        var snapshot: [BatchExportProgress] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    /// 造一张指定尺寸的纯色图（与 PhotoExporterTests 同款）。
    private func makeImage(width: Int, height: Int) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4] = 180
            pixels[i * 4 + 1] = 140
            pixels[i * 4 + 2] = 90
            pixels[i * 4 + 3] = 255
        }
        let image = pixels.withUnsafeMutableBytes { ptr -> CGImage? in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return ctx.makeImage()
        }
        guard let image else {
            Issue.record("无法创建测试图")
            return CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!.makeImage()!
        }
        return image
    }

    // MARK: 并发度纯逻辑

    @Test func effectiveConcurrencyCapsAndClamps() {
        // 上限 8；不超过图数；不小于 1
        let many = BatchExportRequest(images: Array(repeating: makeImage(width: 2, height: 2), count: 20))
        #expect(many.effectiveConcurrency() == 8)

        let few = BatchExportRequest(images: [
            makeImage(width: 2, height: 2),
            makeImage(width: 2, height: 2),
            makeImage(width: 2, height: 2),
        ])
        #expect(few.effectiveConcurrency() == 3)

        let capped = BatchExportRequest(
            images: Array(repeating: makeImage(width: 2, height: 2), count: 20),
            maxConcurrentTasks: 3
        )
        #expect(capped.effectiveConcurrency() == 3)

        let empty = BatchExportRequest(images: [])
        #expect(empty.effectiveConcurrency() == 1)

        let zero = BatchExportRequest(
            images: Array(repeating: makeImage(width: 2, height: 2), count: 4),
            maxConcurrentTasks: 0
        )
        #expect(zero.effectiveConcurrency() == 1)
    }

    // MARK: 批量导出主路径

    @Test func batchExportsMixedSizesInOrder() async throws {
        let sizes = [(8, 6), (6, 8), (16, 16), (5, 12), (24, 10)]
        let request = BatchExportRequest(
            images: sizes.map { makeImage(width: $0.0, height: $0.1) },
            options: ExportOptions(format: .png)
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShiGuang-BatchTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var requestWithDir = request
        requestWithDir.directory = directory

        let box = ProgressBox()
        let results = try await BatchExporter().export(requestWithDir) { progress in
            box.append(progress)
        }
        let progresses = box.snapshot

        // 结果与输入同序、同数
        #expect(results.count == sizes.count)
        for (index, result) in results.enumerated() {
            #expect(result.index == index)
            #expect(result.isSuccess)
            let url = try #require(result.url)
            #expect(url.deletingLastPathComponent() == directory)
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(url.pathExtension == "png")
            // 尺寸一致（多尺寸不互相覆盖的直接证据）
            let data = try Data(contentsOf: url)
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            #expect(props?[kCGImagePropertyPixelWidth] as? Int == sizes[index].0)
            #expect(props?[kCGImagePropertyPixelHeight] as? Int == sizes[index].1)
        }

        // 进度：单调不减，最终等于总数
        #expect(!progresses.isEmpty)
        #expect(progresses.last == BatchExportProgress(completed: sizes.count, total: sizes.count))
        for pair in zip(progresses, progresses.dropFirst()) {
            #expect(pair.1.completed >= pair.0.completed)
        }
    }

    // MARK: 失败隔离

    @Test func singleFailureDoesNotAbortBatch() async throws {
        let request = BatchExportRequest(
            images: [
                makeImage(width: 4, height: 4),
                makeImage(width: 6, height: 6),
                makeImage(width: 8, height: 8),
            ],
            options: ExportOptions(format: .png)
        )
        // 把 directory 指向一个**文件** URL：追加路径后写盘必然失败
        // （CGImageDestination 创建失败 → cannotCreateDestination）
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShiGuang-BatchBlocker-\(UUID().uuidString)")
        try Data([0x01]).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }

        var broken = request
        broken.directory = blocker

        let results = try await BatchExporter().export(broken) { _ in }

        #expect(results.count == 3)
        for result in results {
            #expect(!result.isSuccess)
            #expect(result.url == nil)
            #expect(result.errorDescription != nil)
        }
    }

    // MARK: 空图集

    @Test func emptyRequestReturnsEmpty() async throws {
        let results = try await BatchExporter().export(BatchExportRequest(images: [])) { _ in
            Issue.record("空图集不应上报进度")
        }
        #expect(results.isEmpty)
    }
}
