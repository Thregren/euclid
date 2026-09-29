import CoreGraphics
import Foundation

/// 一张「内存里的影像」当瓦片源用：坡度图、两期差异图这类即时算出来的结果。
///
/// 与 `RasterTileSource`（按需解文件里的某一块）分开：那边管磁盘上亿像素的大图，
/// 这边只管一张已经算好、有地理参考的小图（几百万像素以内），因此可以直接裁剪采样。
/// 定位口径两边共用 `RasterTileSource.pixelRect(ofTileWorld:georeference:)`。
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

    public func image(for tile: SlippyTile) async -> CGImage? {
        let tileWorld = tile.worldRect
        guard tileWorld.intersects(worldRect),
              let rawPixelRect = RasterTileSource.pixelRect(
                  ofTileWorld: tileWorld,
                  georeference: georeference
              ) else { return nil }
        let clipped = rawPixelRect.intersection(
            CGRect(x: 0, y: 0, width: Double(pixelWidth), height: Double(pixelHeight))
        )
        guard !clipped.isNull, clipped.width >= 0.01, clipped.height >= 0.01,
              rawPixelRect.width > 0, rawPixelRect.height > 0 else { return nil }

        let scaleX = Double(image.width) / Double(pixelWidth)
        let scaleY = Double(image.height) / Double(pixelHeight)
        let source = CGRect(
            x: clipped.minX,
            y: clipped.minY,
            width: clipped.width,
            height: clipped.height
        )
        let destination = CGRect(
            x: (clipped.minX - rawPixelRect.minX) * Double(tileSize) / rawPixelRect.width,
            y: (clipped.minY - rawPixelRect.minY) * Double(tileSize) / rawPixelRect.height,
            width: clipped.width * Double(tileSize) / rawPixelRect.width,
            height: clipped.height * Double(tileSize) / rawPixelRect.height
        )

        // 影像像素 → CGImage 像素：两者常常一样（1:1），但缩略图会不一样。
        let crop = CGRect(
            x: source.minX * scaleX,
            y: source.minY * scaleY,
            width: max(1, source.width * scaleX),
            height: max(1, source.height * scaleY)
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !crop.isNull, crop.width >= 1, crop.height >= 1,
              let piece = image.cropping(to: crop) else { return nil }

        let pointsPerImagePixel = destination.width / max(0.0001, source.width * scaleX)
        let offsetX = (crop.minX - source.minX * scaleX) * pointsPerImagePixel
        let offsetY = (crop.minY - source.minY * scaleY) * pointsPerImagePixel
        let width = crop.width * pointsPerImagePixel
        let height = crop.height * pointsPerImagePixel
        let topDownY = destination.minY + offsetY

        var canvas = [UInt8](repeating: 0, count: tileSize * tileSize * 4)
        let drawn: Bool = canvas.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: base,
                      width: tileSize,
                      height: tileSize,
                      bitsPerComponent: 8,
                      bytesPerRow: tileSize * 4,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.interpolationQuality = .high
            // 缓冲区首行是画面顶部，而 CGContext 的用户坐标 y 向上，换算一次。
            context.draw(piece, in: CGRect(
                x: destination.minX + offsetX,
                y: CGFloat(tileSize) - (topDownY + height),
                width: width,
                height: height
            ))
            return true
        }
        guard drawn else { return nil }
        return RasterTileSource.makeImage(canvas: canvas, width: tileSize, height: tileSize)
    }
}
