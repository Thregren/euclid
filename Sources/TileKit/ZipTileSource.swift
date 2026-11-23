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

    /// 磁盘上实际的**文件**个数。
    ///
    /// 一年合并成一个大包时，同一个文件会在每个层级各登记一条，`volumeCount` 于是等于层级数，
    /// 界面上说「12 个包」会让人以为要去找 12 个文件。要报给使用者的数字用这个。
    public var fileCount: Int {
        Set(parts.values.flatMap { $0.map { $0.url.path(percentEncoded: false) } }).count
    }
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

    public func data(for tile: SlippyTile) async -> Data? { await bytes(for: tile).data }
    public func readData(for tile: SlippyTile) async throws -> Data? {
        let result = await bytes(for: tile)
        try Task.checkCancellation()
        switch result {
        case .data(let data): return data
        case .missing: return nil
        case .retry: throw TileReadError.unavailable
        }
    }
    public func loadTile(_ tile: SlippyTile) async -> TileLoadResult {
        let result = await bytes(for: tile)
        switch result {
        case .data(let data): return await TileDecodeScheduler.decode(data).map(TileLoadResult.image) ?? .retry
        case .missing: return .missing
        case .retry: return .retry
        }
    }
    private func bytes(for tile: SlippyTile) async -> ZipBytesResult {
        guard !Task.isCancelled else { return .retry }
        guard let volumes = parts[tile.zoom], !volumes.isEmpty else { return .missing }
        let names = fileExtensions.map { "\(tile.y)/\(tile.x).\($0)" }
        let candidates = volumes.filter { $0.rowRange?.contains(tile.y) == true }
        let unknown = volumes.filter { $0.rowRange == nil }
        var failed = false
        for volume in candidates + unknown {
            if Task.isCancelled { return .retry }
            switch await ZipArchivePool.shared.bytes(in: volume.url, names: names) {
            case .data(let data): return .data(data)
            case .retry: failed = true
            case .missing: break
            }
        }
        return failed ? .retry : .missing
    }

}

package enum ZipBytesResult: Sendable {
    case data(Data), missing, retry
    var data: Data? { if case .data(let data) = self { return data }; return nil }
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
    private struct Opening: Sendable {
        let id = UUID()
        let task: Task<ZipArchive?, Never>
    }
    private var openings: [String: Opening] = [:]
    private let openingLimiter = AsyncLimiter(limit: 2)
    private let readLimiter = AsyncLimiter(limit: TileResourcePolicy.concurrentDecodes)
    /// 同时保留的归档个数。一屏的瓦片通常只落在相邻的一两个分卷里。
    private let limit: Int
    private var identities: [String: FileIdentity] = [:]
    private var checkedAt: [String: Date] = [:]
    private var activePaths: Set<String> = []
    private var openCount = 0
    private let rowBudget = max(16 << 20, TileResourcePolicy.rasterChunkCacheBytes)
    public var statistics: (archives: Int, opens: Int, rowBytes: Int) {
        (archives.count, openCount, archives.values.reduce(0) { $0 + $1.rowCacheCost })
    }

    public func trimCaches(toFraction fraction: Double) {
        for archive in archives.values { archive.trimRows(toFraction: fraction) }
        for key in Array(archives.keys) where !activePaths.contains(key) {
            archives[key] = nil; identities[key] = nil; checkedAt[key] = nil
        }
        order.removeAll { archives[$0] == nil }
    }

    private func enforceBudget() {
        while order.count > limit {
            let key = order.first(where: { !activePaths.contains($0) }) ?? order[0]
            order.removeAll { $0 == key }
            archives[key] = nil; identities[key] = nil; checkedAt[key] = nil
        }
        let bytes = archives.values.reduce(0) { $0 + $1.rowCacheCost }
        if bytes > rowBudget {
            let fraction = Double(rowBudget) / Double(bytes)
            for archive in archives.values { archive.trimRows(toFraction: fraction) }
        }
    }

    public init(maximumArchives: Int = 16) { limit = max(1, maximumArchives) }

    /// 依次用给定的名字找一条记录并读出内容。
    public func data(in url: URL, names: [String]) async -> Data? { await bytes(in: url, names: names).data }
    package func bytes(in url: URL, names: [String]) async -> ZipBytesResult {
        guard !Task.isCancelled, let archive = await archive(for: url), !Task.isCancelled else { return .retry }
        let limiter = readLimiter
        let priority = Task.currentPriority
        let read = Task.detached(priority: priority) { () -> ZipBytesResult in
            guard await limiter.acquire(priority: priority) else { return .retry }
            var result = ZipBytesResult.missing
            do {
                for name in names {
                    try Task.checkCancellation()
                    guard let entry = try archive.checkedEntry(named: name) else { continue }
                    result = .data(try archive.data(for: entry)); break
                }
            } catch { result = .retry }
            await limiter.release()
            return Task.isCancelled ? .retry : result
        }
        return await withTaskCancellationHandler {
            let result = await read.value
            enforceBudget()
            return Task.isCancelled ? .retry : result
        } onCancel: { read.cancel() }
    }

    /// 该文件里是否已有某个名字（自检与探测用）。
    public func contains(_ name: String, in url: URL) async -> Bool {
        guard let archive = await archive(for: url) else { return false }
        return await Task.detached { archive.entry(named: name) != nil }.value
    }

    /// 读一条具体记录（自检与探测用）。
    public func rawData(_ name: String, in url: URL) async -> Data? {
        await data(in: url, names: [name])
    }

    /// 某一行里有哪些列（探测覆盖范围用）。
    public func columns(in url: URL, row: Int) async -> [Int] {
        guard let archive = await archive(for: url) else { return [] }
        return await Task.detached { archive.columnNumbers(inRow: String(row)) }.value
    }

    /// 某一行里的条目名（含扩展名）。
    public func entryNames(in url: URL, row: Int) async -> [String] {
        guard let archive = await archive(for: url) else { return [] }
        return await Task.detached { archive.entryNames(inRow: String(row)) }.value
    }

    /// 该归档索引里出现过的行号（升序）。
    public func indexedRows(in url: URL) async -> [Int] {
        await archive(for: url)?.indexedRows ?? []
    }

    /// 忘掉一个归档（文件被换掉、数据集被移除时）。
    public func forget(_ url: URL) {
        let key = url.path(percentEncoded: false)
        archives[key] = nil
        identities[key] = nil; checkedAt[key] = nil
        openings.removeValue(forKey: key)?.task.cancel()
        order.removeAll { $0 == key }
    }

    /// 把一个**已经建好索引**的归档放进缓存。
    ///
    /// 数据集探测时已经为某一卷读过一次中央目录了，那次结果直接在这里复用，
    /// 免得铺第一屏图时再扫一遍（大分卷的中央目录能有几十 MB）。
    public func adopt(_ archive: ZipArchive) {
        let key = archive.url.path(percentEncoded: false)
        guard archives[key] == nil else { return }
        openings.removeValue(forKey: key)?.task.cancel()
        archives[key] = archive
        identities[key] = FileIdentity(url: archive.url)
        order.append(key)
        enforceBudget()
    }

    public func forgetAll() {
        archives.removeAll()
        identities.removeAll(); checkedAt.removeAll(); activePaths.removeAll()
        order.removeAll()
        for opening in openings.values { opening.task.cancel() }
        openings.removeAll()
    }

    /// 只留下仍然在用的归档，其余全放掉。
    ///
    /// 换数据集、删图层时按「当前还有哪些图层真的在用」过一遍：池子本来就有归档数量的
    /// 上限，但主动清一次能立刻把名额与文件句柄让给新数据，不必等下一屏图把它们挤出去。
    public func forgetAll(except keeping: Set<String>) {
        activePaths = keeping
        for key in Array(archives.keys) where !keeping.contains(key) {
            archives[key] = nil; identities[key] = nil; checkedAt[key] = nil
        }
        order.removeAll { !keeping.contains($0) }
        for key in Array(openings.keys) where !keeping.contains(key) {
            openings.removeValue(forKey: key)?.task.cancel()
        }
    }

    private func archive(for url: URL) async -> ZipArchive? {
        let key = url.path(percentEncoded: false)
        if let cached = archives[key] {
            let now = Date()
            if now.timeIntervalSince(checkedAt[key] ?? .distantPast) >= 1 {
                checkedAt[key] = now
                if identities[key] != FileIdentity(url: url) { forget(url) }
            }
            if archives[key] != nil {
                order.removeAll { $0 == key }; order.append(key)
                return cached
            }
        }
        // 打不开就是打不开（多半是分卷还在下载、中央目录还没写）：**不记失败**，
        // 下次取图再试一次，否则这一格会被一直当成缺片，直到重开数据集。
        let opening: Opening
        if let existing = openings[key] { opening = existing }
        else {
            let limiter = openingLimiter
            let priority = Task.currentPriority
            opening = Opening(task: Task.detached(priority: priority) {
                guard await limiter.acquire(priority: priority) else { return nil }
                let archive = Task.isCancelled ? nil : try? ZipArchive(url: url)
                await limiter.release()
                return archive
            })
            openings[key] = opening
        }
        let result = await opening.task.value
        guard openings[key]?.id == opening.id else { return archives[key] }
        openings[key] = nil
        guard let archive = result else { return nil }
        openCount += 1
        archives[key] = archive
        identities[key] = FileIdentity(url: archive.url)
        order.append(key)
        enforceBudget()
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
