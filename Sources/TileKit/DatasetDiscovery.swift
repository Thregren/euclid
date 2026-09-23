import CoreGraphics
import Foundation

/// 一个可打开的瓦片数据集。
public struct TileDataset: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let rootURL: URL
    public let layout: TileLayout
    public let zoomRange: ClosedRange<Int>

    public init(id: String, name: String, rootURL: URL, layout: TileLayout, zoomRange: ClosedRange<Int>) {
        self.id = id
        self.name = name
        self.rootURL = rootURL
        self.layout = layout
        self.zoomRange = zoomRange
    }

    public var source: DirectoryTileSource {
        DirectoryTileSource(rootURL: rootURL, layout: layout, zoomRange: zoomRange)
    }

}

/// 数据集覆盖范围。
public struct DatasetExtent: Sendable, Hashable {
    public let worldRect: CGRect
    public let level: Int
    public let tileCount: Int

    public init(worldRect: CGRect, level: Int, tileCount: Int) {
        self.worldRect = worldRect
        self.level = level
        self.tileCount = tileCount
    }

    public var boundingBox: (southWest: GeoCoordinate, northEast: GeoCoordinate) {
        let sw = WebMercator.coordinate(fromNormalized: CGPoint(x: worldRect.minX, y: worldRect.maxY))
        let ne = WebMercator.coordinate(fromNormalized: CGPoint(x: worldRect.maxX, y: worldRect.minY))
        return (sw, ne)
    }
}

/// 在目录中查找瓦片数据集。
public enum DatasetLocator {
    private static let maxDiscoveryDepth = 3

    /// 在给定目录中查找所有数据集。给定的目录可以本身就是数据集，也可以是数据集的容器。
    public static func discover(at url: URL, depth: Int = 0) -> [TileDataset] {
        if let dataset = makeDataset(at: url) {
            return [dataset]
        }
        guard depth < maxDiscoveryDepth else { return [] }
        let children = subdirectories(of: url)
        var result: [TileDataset] = []
        for child in children {
            result.append(contentsOf: discover(at: child, depth: depth + 1))
        }
        return result
    }

    /// 若目录自身就是数据集则返回描述，否则返回 nil。
    public static func makeDataset(at url: URL) -> TileDataset? {
        let levels = zoomLevels(of: url)
        guard let minZoom = levels.first, let maxZoom = levels.last else { return nil }
        let layout = detectLayout(at: url, levels: levels)
        let name = url.lastPathComponent
        return TileDataset(
            id: url.path(percentEncoded: false),
            name: name,
            rootURL: url,
            layout: layout,
            zoomRange: minZoom...maxZoom
        )
    }

    /// 目录下所有形如 `<z>` 的子目录层级号。
    public static func zoomLevels(of url: URL) -> [Int] {
        subdirectories(of: url)
            .compactMap { Int($0.lastPathComponent) }
            .filter { (0...30).contains($0) }
            .sorted()
    }

    /// 判定目录名与文件名的轴向：`<z>/<a>/<b>` 中 a 是列号还是行号。
    ///
    /// 判据是「另一种编排方式是否存在」：若 a 为行号，则磁盘上应存在 `<z>/<b>/<a>.<ext>`。
    static func detectLayout(at url: URL, levels: [Int]) -> TileLayout {
        var layout = TileLayout.webODM
        guard let sample = samplePaths(at: url, levels: levels) else { return layout }

        let manager = FileManager.default
        if manager.fileExists(atPath: sample.transposedDirectory.path(percentEncoded: false)) {
            var isDirectory: ObjCBool = false
            manager.fileExists(atPath: sample.transposedDirectory.path(percentEncoded: false), isDirectory: &isDirectory)
            if isDirectory.boolValue {
                layout.directoryAxis = .yFirst
            }
        }
        if let ext = sample.fileExtension {
            layout.fileExtensions = [ext] + TileLayout.webODM.fileExtensions.filter { $0 != ext }
        }
        if let size = sample.tileSize {
            layout.tileSize = size
        }
        return layout
    }

    private struct SamplePaths {
        var transposedDirectory: URL
        var fileExtension: String?
        var tileSize: Int?
    }

    /// 取样：挑一个规模适中的层级，取出第一组 (目录值, 文件值)。
    private static func samplePaths(at url: URL, levels: [Int]) -> SamplePaths? {
        for level in levels.reversed() {
            let levelURL = url.appending(path: String(level))
            let columns = numericDirectories(in: levelURL)
            guard let column = columns.first else { continue }
            let columnURL = levelURL.appending(path: String(column))
            let files = numericFiles(in: columnURL)
            guard let row = files.first else { continue }

            let ext = fileExtension(of: row.url) ?? "png"
            let transposed = levelURL
                .appending(path: String(row.value))
                .appending(path: "\(column).\(ext)")
            let tileSize = ImageDecoder.pixelSize(of: row.url).map { Int($0.width) }
            return SamplePaths(
                transposedDirectory: transposed,
                fileExtension: ext,
                tileSize: tileSize
            )
        }
        return nil
    }

    private static func fileExtension(of url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }

    /// 计算数据集覆盖范围（归一化世界矩形）。
    ///
    /// 为避免遍历几十万文件，选取一个规模适中的层级做统计；该范围对所有层级都成立。
    public static func extent(of dataset: TileDataset, preferredMaxDirectories: Int = 400) -> DatasetExtent? {
        let levels = Array(dataset.zoomRange).filter { level in
            FileManager.default.fileExists(atPath: dataset.rootURL.appending(path: String(level)).path(percentEncoded: false))
        }
        guard !levels.isEmpty else { return nil }

        for level in levels.reversed() {
            let levelURL = dataset.rootURL.appending(path: String(level))
            let columns = numericDirectories(in: levelURL)
            guard !columns.isEmpty, columns.count <= preferredMaxDirectories else { continue }

            var minColumn = Int.max, maxColumn = Int.min
            var minRow = Int.max, maxRow = Int.min
            var count = 0
            for column in columns {
                minColumn = min(minColumn, column)
                maxColumn = max(maxColumn, column)
                let columnURL = levelURL.appending(path: String(column))
                let rows = numericFiles(in: columnURL)
                guard let first = rows.first, let last = rows.last else { continue }
                minRow = min(minRow, first.value)
                maxRow = max(maxRow, last.value)
                count += rows.count
            }
            guard count > 0, minColumn <= maxColumn, minRow <= maxRow else { continue }

            let n = Double(1 << level)
            let rect = CGRect(
                x: Double(minColumn) / n,
                y: Double(minRow) / n,
                width: Double(maxColumn - minColumn + 1) / n,
                height: Double(maxRow - minRow + 1) / n
            )
            return DatasetExtent(worldRect: rect, level: level, tileCount: count)
        }
        return nil
    }

    // MARK: - 目录工具

    /// 列出目录中的条目名。
    ///
    /// 使用路径版 API：URL 版在路径最后一段是符号链接时会直接报错（不跟随链接），
    /// 而瓦片盘经常是软链挂载的。同时省去逐项取属性的开销，几十万文件时差别明显。
    static func entryNames(of url: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []
        return names.filter { !$0.hasPrefix(".") }
    }

    static func subdirectories(of url: URL) -> [URL] {
        entryNames(of: url)
            .map { url.appending(path: $0) }
            .filter { isDirectory($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// 判断是否为目录，跟随符号链接（便于把瓦片盘软链到数据集目录里）。
    static func isDirectory(_ url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return true
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    static func numericDirectories(in url: URL) -> [Int] {
        subdirectories(of: url).compactMap { Int($0.lastPathComponent) }.sorted()
    }

    struct NumericFile {
        var value: Int
        var url: URL
    }

    static func numericFiles(in url: URL) -> [NumericFile] {
        entryNames(of: url).compactMap { name -> NumericFile? in
            let value = Int((name as NSString).deletingPathExtension)
            guard let value else { return nil }
            return NumericFile(value: value, url: url.appending(path: name))
        }
        .sorted { $0.value < $1.value }
    }
}
