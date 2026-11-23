import CoreGraphics
import Foundation

/// 一张「内存里的影像」当瓦片源用：坡度图、两期差异图这类即时算出来的结果。
///
/// 与 `RasterTileSource`（按需解文件里的某一块）分开：那边管磁盘上亿像素的大图，
/// 这边只管一张已经算好、有地理参考的小图（几百万像素以内），因此可以直接裁剪采样。
/// 定位口径两边共用 `RasterTileSource.mapping(ofTileWorld:georeference:tileSize:)`：
/// 影像的平面坐标与铺图网格之间可能有旋转，按包围盒摊开会让接缝错位。
public struct ImageTileSource: TileImageSource {
    public let image: CGImage
    public let georeference: RasterGeoreference
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let tileSize: Int
    /// 一个影像像素对应多少屏幕点：用来给「适应窗口」「实际大小」定上限。
    public let pixelsPerUnit: Double

    public init(
        image: CGImage,
        georeference: RasterGeoreference,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        tileSize: Int = 512,
        pixelsPerUnit: Double = 1
    ) {
        self.image = image
        self.georeference = georeference
        self.pixelWidth = max(1, pixelWidth ?? image.width)
        self.pixelHeight = max(1, pixelHeight ?? image.height)
        self.tileSize = max(64, tileSize)
        self.pixelsPerUnit = max(0.001, pixelsPerUnit)
    }

    /// 这张图覆盖的世界矩形（归一化墨卡托）。
    public var worldRect: CGRect {
        georeference.worldRect(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    public var availableZoomRange: ClosedRange<Int> { 0...30 }

    /// 「一个图像像素对一个设备像素」的那一级（与 `RasterDataset` 同一口径）。
    ///
    /// 用来给「适应窗口 / 实际大小」定上限：算出来的是虚拟金字塔里刚好 1:1 的层级。
    public var maximumDataZoom: Double {
        let widthInWorld = max(worldRect.width, 1e-12)
        let native = log2(Double(max(pixelWidth, pixelHeight)) / (widthInWorld * Double(tileSize)))
        return min(max(0, native), 30)
    }

    public var zoomRange: ClosedRange<Int> {
        0...min(30, max(0, Int(ceil(maximumDataZoom))))
    }

    public func data(for tile: SlippyTile) async -> Data? { nil }

    public func loadTile(_ tile: SlippyTile) async -> TileLoadResult {
        guard !Task.isCancelled else { return .retry }
        guard tile.worldRect.intersects(worldRect) else { return .missing }
        return await TileDecodeScheduler.perform { await image(for: tile) }.map(TileLoadResult.image) ?? .retry
    }

    public func image(for tile: SlippyTile) async -> CGImage? {
        let tileWorld = tile.worldRect
        guard tileWorld.intersects(worldRect),
              let mapping = RasterTileSource.mapping(
                  ofTileWorld: tileWorld,
                  georeference: georeference,
                  tileSize: Double(tileSize)
              ) else { return nil }
        let imageBounds = CGRect(x: 0, y: 0, width: Double(pixelWidth), height: Double(pixelHeight))
        let canvasBounds = CGRect(x: 0, y: 0, width: Double(tileSize), height: Double(tileSize))
        let clipped = mapping.sourceBoundingBox(ofCanvas: canvasBounds).intersection(imageBounds)
        guard !clipped.isNull, clipped.width >= 0.01, clipped.height >= 0.01 else { return nil }
        let destination = mapping.canvasBoundingBox(ofSource: clipped).integral.intersection(canvasBounds)
        guard !destination.isNull, destination.width >= 0.5, destination.height >= 0.5 else { return nil }

        // 影像像素 → CGImage 像素：两者常常一样（1:1），但缩略图会不一样。
        let imageMapping = mapping.scaled(
            columnScale: Double(image.width) / Double(max(1, pixelWidth)),
            rowScale: Double(image.height) / Double(max(1, pixelHeight))
        )
        let bounds = CGRect(x: 0, y: 0, width: Double(image.width), height: Double(image.height))
        // 多留 1 像素边：旋转 / 双线性插值会用到边界外侧的像素。
        let crop = imageMapping.sourceBoundingBox(ofCanvas: destination)
            .integral
            .insetBy(dx: -1, dy: -1)
            .intersection(bounds)
        guard !crop.isNull, crop.width >= 1, crop.height >= 1,
              let piece = image.cropping(to: crop) else { return nil }

        var canvas = [UInt8](repeating: 0, count: tileSize * tileSize * 4)
        let drawn: Bool = canvas.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return false }
            return imageMapping.draw(piece: piece, pieceRect: crop, canvas: base, canvasSize: tileSize)
        }
        guard drawn else { return nil }
        return RasterTileSource.makeImage(canvas: canvas, width: tileSize, height: tileSize)
    }
}
