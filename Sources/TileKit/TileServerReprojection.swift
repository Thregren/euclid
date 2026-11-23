import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Convert geographic matrix tiles to standard XYZ for consumers such as QGIS and Leaflet.
/// Only the geographic rows intersecting one output tile are decoded; no full mosaic is built.
package enum TileServerReprojection {
    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }
    package static func data(dataset: TileDataset, source: any TileImageSource, tile: SlippyTile) async -> Data? {
        guard dataset.grid.kind == .geographic else { return await source.data(for: tile) }
        let n = Double(1 << tile.zoom)
        let bounds = TileGrid.webMercator.bounds(zoom: tile.zoom, column: tile.x, row: tile.y)
        guard let range = dataset.grid.tileRange(zoom: tile.zoom, worldRect: bounds.normalizedRect), range.rows.count <= 8 else { return nil }
        var rows: [Int: Pixels] = [:]
        for row in range.rows {
            guard !Task.isCancelled else { return nil }
            guard let image = await source.image(for: SlippyTile(zoom: tile.zoom, x: tile.x, y: row)),
                  let pixels = rgba(image) else { continue }
            rows[row] = pixels
        }
        guard !rows.isEmpty else { return nil }
        let side = min(1024, max(1, dataset.layout.tileSize))
        var output = [UInt8](repeating: 0, count: side * side * 4)
        let span = 360 / n
        for y in 0..<side {
            if Task.isCancelled { return nil }
            let latitude = WebMercator.latitude(normalizedY: (Double(tile.y) + (Double(y) + 0.5) / Double(side)) / n)
            let coordinate = (90 - latitude) / span
            let row = Int(floor(coordinate))
            guard let pixels = rows[row] else { continue }
            let sampleY = min(pixels.height - 1, max(0, Int((coordinate - Double(row)) * Double(pixels.height))))
            for x in 0..<side {
                let sampleX = min(pixels.width - 1, Int((Double(x) + 0.5) * Double(pixels.width) / Double(side)))
                let sourceIndex = (sampleY * pixels.width + sampleX) * 4
                let destination = (y * side + x) * 4
                for channel in 0..<4 { output[destination + channel] = pixels.bytes[sourceIndex + channel] }
            }
        }
        guard let provider = CGDataProvider(data: Data(output) as CFData),
              let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let bytes = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(encoder, image, nil)
        return CGImageDestinationFinalize(encoder) ? bytes as Data : nil
    }
    private static func rgba(_ image: CGImage) -> Pixels? {
        guard image.width > 0, image.height > 0, image.width * image.height <= 4_194_304 else { return nil }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let success = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return success ? Pixels(width: image.width, height: image.height, bytes: bytes) : nil
    }
}
