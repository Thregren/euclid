import CoreGraphics
import Foundation

public enum TileDataTools {
    public static func dataset(at url: URL) throws -> TileDataset {
        let root = url.pathExtension.lowercased() == "zip" ? DatasetLocator.datasetRoot(containing: url) : url
        if let dataset = DatasetLocator.makeDataset(at: root) { return dataset }
        let datasets = DatasetLocator.discover(at: root)
        guard datasets.count == 1, let dataset = datasets.first else { throw MBTilesError.invalid("请指定单个瓦片数据集、ZIP 所在数据集或 MBTiles 文件") }
        return dataset
    }
    public static func checkCoverage(dataset: TileDataset, bounds: GeoBounds?, zoomRange: ClosedRange<Int>?,
                                     samples: Int = 128) async throws -> [String: Int] {
        let source = dataset.source
        let rect = bounds.map { value in
            CGRect(x: WebMercator.normalizedX(longitude: value.west), y: WebMercator.normalizedY(latitude: value.north),
                   width: (value.east - value.west) / 360,
                   height: WebMercator.normalizedY(latitude: value.south) - WebMercator.normalizedY(latitude: value.north))
        } ?? DatasetLocator.extent(of: dataset)?.worldRect
        guard let rect else { throw MBTilesError.invalid("数据集没有可检查的覆盖范围") }
        let range = zoomRange ?? dataset.zoomRange
        let low = max(range.lowerBound, dataset.zoomRange.lowerBound), high = min(range.upperBound, dataset.zoomRange.upperBound)
        guard low <= high, samples > 0 else { throw MBTilesError.invalid("检查层级或样本数无效") }
        var checked = 0, missing = 0, failed = 0
        let perLevel = max(1, samples / (high - low + 1))
        for zoom in low...high {
            guard let range = dataset.grid.tileRange(zoom: zoom, worldRect: rect) else { continue }
            let columns = range.columns.count, total = columns * range.rows.count, count = min(perLevel, total)
            for index in 0..<count {
                try Task.checkCancellation()
                let position = count == 1 ? total / 2 : Int(Double(index) * Double(total - 1) / Double(count - 1))
                let tile = SlippyTile(zoom: zoom, x: range.columns.lowerBound + position % columns,
                                      y: range.rows.lowerBound + position / columns)
                checked += 1
                switch await source.loadTile(tile) {
                case .image: break
                case .missing: missing += 1
                case .retry: failed += 1
                }
            }
        }
        return ["checked": checked, "missing": missing, "unreadable": failed]
    }
}
