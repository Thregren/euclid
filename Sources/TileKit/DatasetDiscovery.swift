import CoreGraphics
import Foundation

public extension URL {
    /// 「路径即身份」时用的规范路径：**去掉末尾的 `/`**。
    ///
    /// 数据集 / 影像的 `id` 就是这段路径字符串。拖放给的目录 URL 常常带尾斜杠
    /// （`URL(fileURLWithPath:)` 对**已存在的目录**往返一圈也会把斜杠加回来），
    /// 不规范化的话同一份数据会变成两个 id：列表里出现两行、叠加时去重也认不出来。
    var canonicalFilePath: String {
        var path = path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// 一个可打开的瓦片数据集。
public struct TileDataset: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let rootURL: URL
    public let layout: TileLayout
    public let zoomRange: ClosedRange<Int>
    /// 瓦片编号的网格：散文件目录里的 XYZ 数据是墨卡托，天地图那类 WMTS 数据是经纬度。
    public let grid: TileGrid
    /// 非 nil 表示这是一份 **zip 分卷**数据集（不解压直接读）。
    public let zipInfo: ZipDatasetInfo?

    public init(
        id: String,
        name: String,
        rootURL: URL,
        layout: TileLayout,
        zoomRange: ClosedRange<Int>,
        grid: TileGrid = .webMercator,
        zipInfo: ZipDatasetInfo? = nil
    ) {
        self.id = id
        self.name = name
        self.rootURL = rootURL
        self.layout = layout
        self.zoomRange = zoomRange
        self.grid = grid
        self.zipInfo = zipInfo
    }

    /// 是不是 zip 分卷数据集。
    public var isArchive: Bool { zipInfo != nil }

    public var source: any TileImageSource {
        if let zipInfo {
            return ZipTileSource(
                rootURL: rootURL,
                grid: grid,
                parts: zipInfo.parts,
                zoomRange: zoomRange
            )
        }
        return DirectoryTileSource(rootURL: rootURL, layout: layout, zoomRange: zoomRange)
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
    ///
    /// 既认散文件目录（`<z>/<x>/<y>`），也认 zip 分卷包（`z12/….zip` + `manifest.json`）。
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

    /// 把新扫到的数据并进「已经打开的数据」列表：同一条只留一份、新的排前面。
    ///
    /// 「又打开一份数据」不该把已经打开的那些从列表里抹掉 —— 它们还挂在画布上，
    /// 也还要能在 ＋ 菜单里再叠一层（见 `AppModel.addDatasetLayer`）。
    /// 同 id 时留新扫到的那份：目录被重新扫过，新的描述更可信。
    public static func merging(_ existing: [TileDataset], with found: [TileDataset]) -> [TileDataset] {
        var seen: Set<String> = []
        var merged: [TileDataset] = []
        for dataset in found + existing where seen.insert(dataset.id).inserted {
            merged.append(dataset)
        }
        return merged
    }

    /// 在一批数据里找出「包含这个分卷文件」的那一份。
    ///
    /// 拖进来的可能是 `z12/xxx-0001.zip` 这样的一个分卷：用户要的是它所属的那份数据，
    /// 不是某个分卷；找不到归属（比如散文件目录）时返回 nil。
    public static func dataset(containingVolume volume: URL, in datasets: [TileDataset]) -> TileDataset? {
        let path = volume.canonicalFilePath
        return datasets.first { dataset in
            guard let info = dataset.zipInfo else { return false }
            return info.parts.values.contains { volumes in
                volumes.contains { $0.url.canonicalFilePath == path }
            }
        }
    }

    /// 拖进来一个分卷文件时，推出它所属的那份数据的根目录。
    ///
    /// 分卷通常躺在 `z12/`（或 `12/`）这样的层级目录里 —— 那就再看上一层本身是不是一份数据：
    /// 认得出就用上一层，于是打开的是**整份**数据，而不是只剩 z12 这一层的残缺数据集；
    /// 认不出（分卷直接堆在自己的根目录里）就仍用分卷所在目录。
    ///
    /// 判定要列一次目录、读一次 manifest，因此只在「拖进来一个分卷」这条路上用。
    public static func datasetRoot(containing volume: URL) -> URL {
        let parent = volume.deletingLastPathComponent()
        guard isZoomLevelDirectoryName(parent.lastPathComponent) else { return canonicalURL(parent) }
        let higher = parent.deletingLastPathComponent()
        return canonicalURL(makeDataset(at: higher) != nil ? higher : parent)
    }

    /// 目录名是不是「层级目录」：`12`、`z12`、`Z12` 都算，`z12副本`、`福建省瓦片` 不算。
    public static func isZoomLevelDirectoryName(_ name: String) -> Bool {
        var digits = Substring(name)
        if let first = digits.first, first == "z" || first == "Z" { digits = digits.dropFirst() }
        return !digits.isEmpty && digits.allSatisfy { $0.isNumber }
    }

    /// 去掉目录 URL 末尾的 `/`（数据集的 `id` / `rootURL` 都走它）。
    ///
    /// `deletingLastPathComponent()` 出来的目录 URL 带尾斜杠，面板 / 拖放给的又常常不带；
    /// 而数据集的身份就是这段路径字符串，两种写法会让同一份数据变成两个 id。
    public static func canonicalURL(_ url: URL) -> URL {
        let canonical = url.canonicalFilePath
        guard canonical != url.path(percentEncoded: false) else { return url }
        // `isDirectory: false` 很关键：默认构造会对**已存在的目录**把尾斜杠加回来。
        return URL(fileURLWithPath: canonical, isDirectory: false)
    }

    /// 若目录自身就是数据集则返回描述，否则返回 nil。
    public static func makeDataset(at url: URL) -> TileDataset? {
        // zip 分卷包优先：它自带覆盖范围，描述比「扫一遍目录猜出来的」更准。
        if let archive = ZipDatasetLocator.makeDataset(at: url) { return archive }
        return makeDirectoryDataset(at: url)
    }

    /// 散文件目录（`<z>/<x>/<y>.<ext>`）。
    ///
    /// 「有 `<z>` 子目录」不算数 —— 目录里真的存在瓦片才算，否则把一个装着 zip 的
    /// `z12/` 目录误认成空数据集，界面就会打开一份什么都没有的数据。
    static func makeDirectoryDataset(at url: URL) -> TileDataset? {
        let levels = zoomLevels(of: url)
        guard let minZoom = levels.first, let maxZoom = levels.last else { return nil }
        guard let layout = detectLayout(at: url, levels: levels) else { return nil }
        let name = url.lastPathComponent
        return TileDataset(
            id: url.canonicalFilePath,
            name: name,
            rootURL: canonicalURL(url),
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
    static func detectLayout(at url: URL, levels: [Int]) -> TileLayout? {
        var layout = TileLayout.webODM
        guard let sample = samplePaths(at: url, levels: levels) else { return nil }

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
    /// zip 分卷数据集不必扫盘：范围就记在 manifest / 分卷行范围里。
    public static func extent(of dataset: TileDataset, preferredMaxDirectories: Int = 400) -> DatasetExtent? {
        if let info = dataset.zipInfo {
            return archiveExtent(of: dataset, info: info)
        }
        let levels = Array(dataset.zoomRange).filter { level in
            FileManager.default.fileExists(atPath: dataset.rootURL.appending(path: String(level)).path(percentEncoded: false))
        }
        guard !levels.isEmpty else { return nil }

        // 候选层级：优先取目录数在预算内的最高层；若所有层级都超预算，
        // 退化成目录数最少的那一层——统计得粗一点，也好过完全给不出范围。
        let scanned: [(level: Int, columns: [Int])] = levels.reversed().map { level in
            (level, numericDirectories(in: dataset.rootURL.appending(path: String(level))))
        }
        let preferred = scanned.first { !$0.columns.isEmpty && $0.columns.count <= preferredMaxDirectories }
        let candidates = preferred.map { [$0] }
            ?? scanned.filter { !$0.columns.isEmpty }
                .sorted { $0.columns.count < $1.columns.count }
                .prefix(1)

        for candidate in candidates {
            let level = candidate.level
            let columns = candidate.columns
            let levelURL = dataset.rootURL.appending(path: String(level))

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

    /// zip 数据集的覆盖范围：manifest 的 bbox（或探测出来的范围）换算成归一化世界矩形。
    private static func archiveExtent(of dataset: TileDataset, info: ZipDatasetInfo) -> DatasetExtent? {
        guard let bbox = info.boundingBox,
              bbox.east > bbox.west, bbox.north > bbox.south else { return nil }
        let west = WebMercator.normalizedX(longitude: bbox.west)
        let east = WebMercator.normalizedX(longitude: bbox.east)
        let north = WebMercator.normalizedY(latitude: bbox.north)
        let south = WebMercator.normalizedY(latitude: bbox.south)
        guard east > west, south > north else { return nil }
        return DatasetExtent(
            worldRect: CGRect(x: west, y: north, width: east - west, height: south - north),
            level: dataset.zoomRange.upperBound,
            tileCount: info.tileCount ?? 0
        )
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
