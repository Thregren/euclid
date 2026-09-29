import CoreGraphics
import Foundation

/// 一个 zip 分卷：一个文件 + 它覆盖的行号范围。
///
/// 分卷的文件名里带着行范围（`fj_..._z18_r0044911-0044931.zip`），
/// 于是「这一格该去哪个包拿」不用读中央目录就能算出来 —— 这点很要紧：
/// 一个 z18 分卷的中央目录上百 MB，为了找一格去扫一遍全部分卷是不可接受的。
public struct ZipVolume: Sendable, Hashable {
    public let url: URL
    /// 该分卷覆盖的行号范围（含两端）；名字里读不出来时为 nil。
    public let rowRange: ClosedRange<Int>?

    public init(url: URL, rowRange: ClosedRange<Int>?) {
        self.url = url
        self.rowRange = rowRange
    }

    public var name: String { url.lastPathComponent }
}

/// zip 数据集的全部信息（分卷清单 + 可选的地理范围）。
public struct ZipDatasetInfo: Sendable, Hashable {
    /// 层级 → 该层级的分卷（按行号排序）。
    public var parts: [Int: [ZipVolume]]
    /// 覆盖范围；有 manifest 时直接用它的 bbox，没有就按分卷行范围估。
    public var boundingBox: GeoBounds?
    /// manifest 里写的坐标系（EPSG 名字），用于界面提示。
    public var crs: String?
    /// 瓦片边长（像素）；探测不出来时为 nil。
    public var tileSize: Int?
    /// manifest 里记的瓦片总数（估算用），没有 manifest 时为 nil。
    public var tileCount: Int?

    public init(
        parts: [Int: [ZipVolume]],
        boundingBox: GeoBounds? = nil,
        crs: String? = nil,
        tileSize: Int? = nil,
        tileCount: Int? = nil
    ) {
        self.parts = parts
        self.boundingBox = boundingBox
        self.crs = crs
        self.tileSize = tileSize
        self.tileCount = tileCount
    }

    /// 分卷总数。
    public var volumeCount: Int { parts.values.reduce(0) { $0 + $1.count } }
}

/// 从 zip 包里直接取瓦片（不用解压）。
///
/// 瓦片在包里的名字是 `<行>/<列>.<扩展名>`，与网格的行列号一一对应；
/// 扩展名可能是 jpg 也可能是 png（部分服务对空数据瓦片用 png），所以按顺序试。
public struct ZipTileSource: TileImageSource {
    public let rootURL: URL
    public let grid: TileGrid
    public let parts: [Int: [ZipVolume]]
    public let availableZoomRange: ClosedRange<Int>
    /// 尝试的扩展名顺序。
    public let fileExtensions: [String]

    public init(
        rootURL: URL,
        grid: TileGrid,
        parts: [Int: [ZipVolume]],
        zoomRange: ClosedRange<Int>,
        fileExtensions: [String] = ["jpg", "png", "jpeg", "webp"]
    ) {
        self.rootURL = rootURL
        self.grid = grid
        self.parts = parts
        self.availableZoomRange = zoomRange
        self.fileExtensions = fileExtensions
    }

    public func data(for tile: SlippyTile) async -> Data? {
        guard let volumes = parts[tile.zoom], !volumes.isEmpty else { return nil }
        let names = fileExtensions.map { "\(tile.y)/\(tile.x).\($0)" }

        // 先按文件名里的行范围挑；名字里没写范围的（少见）当兜底逐个体检，
        // 但最多试几个 —— 否则一个没有命名的分卷目录会退化成逐包全扫。
        let candidates = volumes.filter { $0.rowRange?.contains(tile.y) == true }
        for volume in candidates.isEmpty ? Array(volumes.prefix(4)) : candidates {
            if let data = await ZipArchivePool.shared.data(in: volume.url, names: names) {
                return data
            }
        }
        return nil
    }
}

/// 全局的 zip 归档池：按路径复用「已建好索引」的归档，最多同时留几个。
///
/// 为什么要池化：建索引要把中央目录流式扫一遍（大分卷几十 MB），
/// 每次取图都重扫一遍是不可想象的；而同时开太多归档又会一直占着文件句柄与行缓存。
///
/// 失败的打开**不进缓存**：正在下载、只写了一半的分卷下次还会再试一次
/// （否则这一格会被永久记成缺片，直到重开数据集）。
public actor ZipArchivePool {
    public static let shared = ZipArchivePool()

    private var archives: [String: ZipArchive] = [:]
    private var order: [String] = []
    /// 同时保留的归档个数。一屏的瓦片通常只落在相邻的一两个分卷里。
    private let limit = 4

    public init() {}

    /// 依次用给定的名字找一条记录并读出内容。
    public func data(in url: URL, names: [String]) -> Data? {
        guard let archive = archive(for: url) else { return nil }
        for name in names {
            guard let entry = archive.entry(named: name) else { continue }
            if let data = try? archive.data(for: entry) { return data }
        }
        return nil
    }

    /// 该文件里是否已有某个名字（自检与探测用）。
    public func contains(_ name: String, in url: URL) -> Bool {
        archive(for: url)?.entry(named: name) != nil
    }

    /// 读一条具体记录（自检与探测用）。
    public func rawData(_ name: String, in url: URL) -> Data? {
        guard let archive = archive(for: url), let entry = archive.entry(named: name) else { return nil }
        return try? archive.data(for: entry)
    }

    /// 某一行里有哪些列（探测覆盖范围用）。
    public func columns(in url: URL, row: Int) -> [Int] {
        guard let archive = archive(for: url) else { return [] }
        return archive.columnNumbers(inRow: String(row))
    }

    /// 某一行里的条目名（含扩展名）。
    public func entryNames(in url: URL, row: Int) -> [String] {
        archive(for: url)?.entryNames(inRow: String(row)) ?? []
    }

    /// 该归档索引里出现过的行号（升序）。
    public func indexedRows(in url: URL) -> [Int] {
        archive(for: url)?.indexedRows ?? []
    }

    /// 忘掉一个归档（文件被换掉、数据集被移除时）。
    public func forget(_ url: URL) {
        let key = url.path(percentEncoded: false)
        archives[key] = nil
        order.removeAll { $0 == key }
    }

    /// 把一个**已经建好索引**的归档放进缓存。
    ///
    /// 数据集探测时已经为某一卷读过一次中央目录了，那次结果直接在这里复用，
    /// 免得铺第一屏图时再扫一遍（大分卷的中央目录能有几十 MB）。
    public func adopt(_ archive: ZipArchive) {
        let key = archive.url.path(percentEncoded: false)
        guard archives[key] == nil else { return }
        archives[key] = archive
        order.append(key)
        while order.count > limit {
            archives[order.removeFirst()] = nil
        }
    }

    public func forgetAll() {
        archives.removeAll()
        order.removeAll()
    }

    /// 只留下仍然在用的归档，其余全放掉。
    ///
    /// 换数据集、删图层时按「当前还有哪些图层真的在用」过一遍：池子本来就有 4 个名额的
    /// 上限，但主动清一次能立刻把名额与文件句柄让给新数据，不必等下一屏图把它们挤出去。
    public func forgetAll(except keeping: Set<String>) {
        for key in Array(archives.keys) where !keeping.contains(key) {
            archives[key] = nil
        }
        order.removeAll { !keeping.contains($0) }
    }

    private func archive(for url: URL) -> ZipArchive? {
        let key = url.path(percentEncoded: false)
        if let cached = archives[key] { return cached }
        // 打不开就是打不开（多半是分卷还在下载、中央目录还没写）：**不记失败**，
        // 下次取图再试一次，否则这一格会被一直当成缺片，直到重开数据集。
        guard let archive = try? ZipArchive(url: url) else { return nil }
        archives[key] = archive
        order.append(key)
        while order.count > limit {
            archives[order.removeFirst()] = nil
        }
        return archive
    }
}

public extension ZipArchive {
    /// 某一行里出现过的列号（升序，去重）。
    func columnNumbers(inRow row: String) -> [Int] {
        var columns = Set<Int>()
        for name in entryNames(inRow: row) {
            let rest = name.dropFirst(row.count + 1)
            guard let dot = rest.firstIndex(of: ".") else { continue }
            if let value = Int(rest[rest.startIndex..<dot]) { columns.insert(value) }
        }
        return columns.sorted()
    }
}
