import CoreGraphics
import Foundation
import ImageIO

/// 以散文件目录形式存放的瓦片数据源。
public struct DirectoryTileSource: Sendable {
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

    /// 读取瓦片原始数据；瓦片不存在时返回 nil。会阻塞调用线程，请在后台调用。
    public func data(for tile: SlippyTile) -> Data? {
        for url in fileCandidates(for: tile) {
            if let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty {
                return data
            }
        }
        return nil
    }

}

/// 轻量的图片解码工具。
public enum ImageDecoder {
    public static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false,
        ]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
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
