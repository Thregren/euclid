import CoreGraphics
import Foundation
import ImageIO

/// 以散文件目录形式存放的瓦片数据源。
public struct DirectoryTileSource: TileImageSource {
    public let rootURL: URL
    public let layout: TileLayout
    public let zoomRange: ClosedRange<Int>

    public init(rootURL: URL, layout: TileLayout, zoomRange: ClosedRange<Int>) {
        self.rootURL = rootURL
        self.layout = layout
        self.zoomRange = zoomRange
    }

    /// 瓦片在磁盘上的路径；若瓦片编号越界则返回 nil。
    public func fileCandidates(for tile: SlippyTile) -> [URL] {
        guard zoomRange.contains(tile.zoom) else { return [] }
        let n = tile.tileCountAtZoom
        guard tile.x >= 0, tile.x < n, tile.y >= 0, tile.y < n else { return [] }
        return layout.fileExtensions.map {
            rootURL.appending(path: layout.relativePath(for: tile, fileExtension: $0))
        }
    }

    /// 读取瓦片原始数据；瓦片不存在时返回 nil。**会阻塞调用线程**，请在后台调用。
    public func blockingData(for tile: SlippyTile) -> Data? {
        try? blockingReadData(for: tile)
    }

    private func blockingReadData(for tile: SlippyTile) throws -> Data? {
        for url in fileCandidates(for: tile) {
            try Task.checkCancellation()
            let relativePath = String(url.path.dropFirst(rootURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            do { return try BoundedTileFile.read(root: rootURL, relativePath: relativePath) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { continue }
        }
        return nil
    }

    public func readData(for tile: SlippyTile) async throws -> Data? {
        try blockingReadData(for: tile)
    }

    public func loadTile(_ tile: SlippyTile) async -> TileLoadResult {
        do {
            guard let data = try await readData(for: tile) else { return .missing }
            return await TileDecodeScheduler.decode(data).map(TileLoadResult.image) ?? .retry
        } catch { return .retry }
    }

    public var availableZoomRange: ClosedRange<Int> { zoomRange }

    /// 协议实现：`TileProvider` 已经在后台任务里调用，这里直接做阻塞读取。
    public func data(for tile: SlippyTile) async -> Data? {
        blockingData(for: tile)
    }
}

/// 轻量的图片解码工具。
public enum ImageDecoder {
    public static func fileExtension(for data: Data) -> String? {
        let bytes = Array(data.prefix(12))
        if bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { return "png" }
        if bytes.starts(with: [255, 216, 255]) { return "jpg" }
        if bytes.count >= 12, String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
           String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP" { return "webp" }
        return nil
    }
    public static func decode(_ data: Data) -> CGImage? {
        guard data.count <= 64 << 20,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              width <= 16_384, height <= 16_384,
              height <= TileResourcePolicy.maximumDecodedImagePixels / width else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false,
        ]
        return TilePerformance.measure("Image decode") { CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) }
    }

    /// 读取磁盘上图片的像素尺寸，不完整解码。
    public static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }
}
