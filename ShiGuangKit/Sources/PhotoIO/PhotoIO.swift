import Foundation
import CoreGraphics
import CoreImage
import ImageIO

// MARK: - 导入照片模型

/// 已导入的照片（应用沙盒内拷贝；原图不经我们上传 — 合规 A2/C4）。
/// 文件名 = UUID，不保留原文件名（避免隐私泄露）。
public struct ImportedPhoto: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let fileName: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let importedAt: Date

    public init(
        id: UUID = UUID(),
        fileName: String,
        pixelWidth: Int,
        pixelHeight: Int,
        importedAt: Date = Date()
    ) {
        self.id = id
        self.fileName = fileName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.importedAt = importedAt
    }

    public var aspectRatio: CGFloat {
        guard pixelHeight > 0, pixelWidth > 0 else { return 1 }
        return CGFloat(pixelWidth) / CGFloat(pixelHeight)
    }
}

// MARK: - 存储协议

public protocol PhotoStoring: Sendable {
    func save(imageData: Data, preferredExtension: String) async throws -> ImportedPhoto
    func delete(_ photo: ImportedPhoto) async throws
    func allPhotos() async throws -> [ImportedPhoto]
    /// 全尺寸 CIImage（RAW / ProRAW 经 CIImage(contentsOf:) 自动接管）。
    func fullCIImage(for photo: ImportedPhoto) -> CIImage?
    /// 缩略图（ImageIO 降采样，避免全图解码）。
    func thumbnailCGImage(for photo: ImportedPhoto, maxPixel: CGFloat) -> CGImage?
}

// MARK: - 文件存储

/// 照片存储（actor 隔离）：Application Support/ShiGuang/Photos/ + index.json 清单。
/// - P2 迁移到 SwiftData 时保持此协议不变
public actor FilePhotoStore: PhotoStoring {
    private let directory: URL
    private let indexURL: URL
    private var index: [ImportedPhoto] = []
    private let fileManager = FileManager.default

    public init(directory: URL? = nil) throws {
        let dir = directory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ShiGuang/Photos", isDirectory: true)
        self.directory = dir
        self.indexURL = dir.appendingPathComponent("index.json")
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([ImportedPhoto].self, from: data) {
            index = decoded
        }
    }

    // MARK: 协议实现

    public func save(imageData: Data, preferredExtension: String = "jpg") throws -> ImportedPhoto {
        let id = UUID()
        let ext = preferredExtension.isEmpty ? "jpg" : preferredExtension
        let fileName = "\(id.uuidString).\(ext)"
        try imageData.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        let size = Self.pixelSize(of: imageData)
        let photo = ImportedPhoto(
            id: id,
            fileName: fileName,
            pixelWidth: size?.width ?? 0,
            pixelHeight: size?.height ?? 0
        )
        index.insert(photo, at: 0)
        try persistIndex()
        return photo
    }

    public func delete(_ photo: ImportedPhoto) throws {
        try? fileManager.removeItem(at: directory.appendingPathComponent(photo.fileName))
        index.removeAll { $0.id == photo.id }
        try persistIndex()
    }

    public func allPhotos() throws -> [ImportedPhoto] { index }

    public nonisolated func fullCIImage(for photo: ImportedPhoto) -> CIImage? {
        CIImage(contentsOf: fileURL(of: photo))
    }

    public nonisolated func thumbnailCGImage(for photo: ImportedPhoto, maxPixel: CGFloat = 512) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(fileURL(of: photo) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - 私有

    /// directory 为 let（Sendable）→ nonisolated 可访问。
    private nonisolated func fileURL(of photo: ImportedPhoto) -> URL {
        directory.appendingPathComponent(photo.fileName)
    }

    private nonisolated static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    private func persistIndex() throws {
        let data = try JSONEncoder().encode(index)
        try data.write(to: indexURL, options: .atomic)
    }
}
