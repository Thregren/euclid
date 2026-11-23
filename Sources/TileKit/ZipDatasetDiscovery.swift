import CoreGraphics
import Foundation

/// 从目录里认出「zip 分卷瓦片包」。
///
/// 下载器把瓦片按行分卷打包，名字里就带着层级与行范围：
///
/// ```
/// 福建省瓦片/
///   manifest.json
///   z12/fj_2026-08-31T000000_z12_r0000701-0000756.zip
///   z13/fj_2026-08-31T000000_z13_r0001403-0001513.zip
///   ...
/// ```
///
/// 包里是 `<行>/<列>.<扩展名>`。有了文件名里的行范围，就不必为了找一格翻遍所有分卷；
/// 同目录的 `manifest.json` / `_state.json` 还给出坐标系与覆盖范围，
/// 于是**整份数据可以不解压直接读，也不必递归遍历上千万个瓦片文件**。
///
/// 也认「一年一包」的合并包 —— 下载器收尾时（或者用户事后）把一年的分卷并成一个大包：
///
/// ```
/// 历史影像/2024/
///   manifest.json                     ← 逐卷记着「哪个层级、管哪几行」
///   2024.zip                          ← 全部层级都在这一个包里（包名里没有层级）
/// ```
///
/// 这时层级与行范围只剩 manifest 记着，于是把整个包按 manifest 的层级登记一遍：
/// 同一个文件在每一层各出现一次，各自带着自己那段行范围。
///
/// 没有 manifest 也能用：层级与行范围从文件名里读，瓦片边长与覆盖范围
/// 由最低层级的那一两个分卷现场探出来（中央目录顺带建好索引，后面取图直接复用）。
public enum ZipDatasetLocator {
    #if os(iOS)
    private static let maximumManifestBytes = 8 << 20
    #else
    private static let maximumManifestBytes = 32 << 20
    #endif

    /// 认出一个 zip 数据集；这个目录里没有 zip 分卷时返回 nil。
    public static func makeDataset(at url: URL) -> TileDataset? {
        guard !Task.isCancelled else { return nil }
        let candidates = zipFiles(in: url)
        guard !candidates.isEmpty else { return nil }
        let manifest = readManifest(at: url)

        var parts: [Int: [ZipVolume]] = [:]
        var declaredTiles = 0
        var orphans: [ZipFile] = []
        var attached: Set<String> = []
        for candidate in candidates {
            guard !Task.isCancelled else { return nil }
            // 行范围与层级以 manifest 为准（它是收尾时才写的，比文件名更可信）。
            let declared = manifest?.parts?[candidate.name]
            guard let zoom = declared?.zoom ?? candidate.zoom, (0...30).contains(zoom) else {
                // 名字里读不出层级、manifest 里也没有这一条 —— 先留着，
                // 回头看它是不是「一年合并成一个大包」的那种（见下）。
                if declared == nil, candidate.zoom == nil { orphans.append(candidate) }
                continue
            }
            let rows = declared?.rows ?? candidate.rows
            parts[zoom, default: []].append(
                ZipVolume(url: candidate.url, rowRange: rows.flatMap { rowRange($0, zoom: zoom) })
            )
            attached.insert(candidate.name)
            if let tiles = declared?.tiles { declaredTiles = addingTileCount(declaredTiles, tiles) }
        }

        // 合并包：manifest 逐卷记着层级与行范围，磁盘上却只有一整个 `<年份>.zip`。
        // 把整包按 manifest 的层级登记——一个文件、多个层级，取图的路子和分卷完全一样。
        if let merged = mergedVolumes(orphans: orphans, manifest: manifest, attached: attached) {
            for (zoom, volumes) in merged.parts {
                parts[zoom, default: []].append(contentsOf: volumes)
            }
            declaredTiles = addingTileCount(declaredTiles, merged.tiles)
        }

        guard !parts.isEmpty,
              let minZoom = parts.keys.min(),
              let maxZoom = parts.keys.max() else { return nil }
        // 同一层级里行范围窄的排前面：合并包和细分卷同时在场时，
        // 先问那些**只管这一小段**的包，命中就不必再去翻大包。
        for zoom in parts.keys {
            parts[zoom]?.sort { left, right in
                let leftWidth = left.rowRange.map { $0.upperBound - $0.lowerBound } ?? .max
                let rightWidth = right.rowRange.map { $0.upperBound - $0.lowerBound } ?? .max
                if leftWidth != rightWidth { return leftWidth < rightWidth }
                let leftStart = left.rowRange?.lowerBound ?? .max
                let rightStart = right.rowRange?.lowerBound ?? .max
                if leftStart != rightStart { return leftStart < rightStart }
                return left.name < right.name
            }
        }

        let grid = TileGrid(kind: gridKind(fromCRS: manifest?.crs) ?? .webMercator)
        var info = ZipDatasetInfo(
            parts: parts,
            boundingBox: manifest?.bounds,
            crs: manifest?.crs
        )
        info.tileCount = declaredTiles > 0 ? declaredTiles : nil

        // 探测只在「还缺信息」时做：最低层级的分卷最少也最小，翻开代价最低。
        if info.tileSize == nil || info.boundingBox == nil {
            if let probe = probe(parts: parts, grid: grid, needBounds: info.boundingBox == nil) {
                info.tileSize = info.tileSize ?? probe.tileSize
                info.boundingBox = info.boundingBox ?? probe.bounds
            }
        }

        var layout = TileLayout.webODM
        // 包内是 `<行>/<列>`，也就是「先 y 后 x」；行号与 XYZ 一致（自北向南）。
        layout.directoryAxis = .yFirst
        layout.rowOrigin = .north
        layout.tileSize = info.tileSize ?? 256
        return TileDataset(
            id: url.canonicalFilePath,
            name: url.lastPathComponent,
            rootURL: DatasetLocator.canonicalURL(url),
            layout: layout,
            zoomRange: minZoom...maxZoom,
            grid: grid,
            zipInfo: info
        )
    }

    // MARK: - 分卷清单

    struct ZipFile {
        var url: URL
        /// 文件名（含扩展名），用来对 manifest 里的记录。
        var name: String
        /// 从文件名或所在目录名里读出的层级。
        var zoom: Int?
        /// 从文件名里读出的行号范围。
        var rows: [Int]?
    }

    /// 目录里的全部分卷。只往下看一层（`z12/…zip`），绝不递归 ——
    /// 数据盘上可能有上千万个瓦片文件，递归遍历就是给自己找麻烦。
    static func zipFiles(in url: URL) -> [ZipFile] {
        var result: [ZipFile] = []
        // 1) 子目录（`z12/` 这种）里的分卷。
        for child in DatasetLocator.subdirectories(of: url) {
            let fallbackZoom = Int(child.lastPathComponent)
            for name in archiveNames(in: child) {
                result.append(makeZipFile(
                    url: child.appending(path: name),
                    name: name,
                    fallbackZoom: fallbackZoom
                ))
            }
        }
        // 2) 目录本身就放着一堆 zip 的情况。
        for name in archiveNames(in: url) {
            result.append(makeZipFile(
                url: url.appending(path: name),
                name: name,
                fallbackZoom: nil
            ))
        }
        return result
    }

    /// 目录里的 zip 文件名。
    ///
    /// `DatasetLocator.entryNames` 已经滤掉了 `._` 伴随文件 —— exFAT 盘上每个 zip
    /// 都拖着一条 4 KB 的空壳，混进来会被当成「打不开的分卷」。
    private static func archiveNames(in url: URL) -> [String] {
        DatasetLocator.entryNames(of: url).filter { $0.lowercased().hasSuffix(".zip") }
    }

    private static func makeZipFile(url: URL, name: String, fallbackZoom: Int?) -> ZipFile {
        let parsed = parseArchiveName(name)
        return ZipFile(url: url, name: name, zoom: parsed.zoom ?? fallbackZoom, rows: parsed.rows)
    }

    /// 从文件名里读层级与行范围：`fj_…_z18_r0044911-0044931.zip` → `(18, [44911, 44931])`。
    ///
    /// 按 `_` 分词再逐段判断，不做正则：名字里还有时间戳（`2026-08-31T000000`）
    /// 这种含 `-` 的段，逐字符扫很容易读错。
    static func parseArchiveName(_ name: String) -> (zoom: Int?, rows: [Int]?) {
        var zoom: Int?
        var rows: [Int]?
        for token in name.lowercased().split(separator: "_") {
            if zoom == nil, token.first == "z", let value = Int(token.dropFirst()) {
                zoom = value
                continue
            }
            if rows == nil, token.first == "r" {
                let numbers = token.dropFirst().split(separator: "-").map { Int($0) }
                if numbers.count == 2, let first = numbers[0], let second = numbers[1] {
                    rows = [first, second]
                }
            }
        }
        return (zoom, rows)
    }

    static func rowRange(_ rows: [Int], zoom: Int = 30) -> ClosedRange<Int>? {
        guard (0...30).contains(zoom), rows.count == 2, let first = rows.first, let last = rows.last,
              first >= 0, last >= 0, first < 1 << zoom, last < 1 << zoom else { return nil }
        return min(first, last)...max(first, last)
    }

    /// Invalid counts stay unknown across the whole aggregation instead of overflowing or becoming a partial total.
    private static func addingTileCount(_ lhs: Int, _ rhs: Int) -> Int {
        guard lhs >= 0, rhs >= 0 else { return -1 }
        let (total, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? -1 : total
    }

    // MARK: - 合并包

    /// 把「一年合并成一个大包」解释成一份数据集。
    ///
    /// 前提有两条：目录里确实躺着一个名字里看不出层级的 zip（`2024.zip`），
    /// 而同目录的 manifest 逐卷记着「哪个层级、管哪几行」。
    /// 返回 nil 表示这不是合并包，调用方照常处理。
    ///
    /// 行范围按层级取**并集**：一个层级往往被切成好几段下载（`z16` 可能有三卷），
    /// 合并之后它们都在同一个包里，只看其中一段会给不出另外几段的范围。
    /// 范围放宽不会出错 —— 取图时按行号找名字，包里没有就是没有。
    static func mergedVolumes(
        orphans: [ZipFile],
        manifest: Manifest?,
        attached: Set<String>
    ) -> (parts: [Int: [ZipVolume]], tiles: Int)? {
        guard !orphans.isEmpty, let declared = manifest?.parts, !declared.isEmpty else { return nil }
        var ranges: [Int: ClosedRange<Int>] = [:]
        var tiles: [Int: Int] = [:]
        for (name, part) in declared {
            guard !Task.isCancelled else { return nil }
            guard let zoom = part.zoom, (0...30).contains(zoom),
                  let range = part.rows.flatMap({ rowRange($0, zoom: zoom) }) else { continue }
            if let existing = ranges[zoom] {
                let lower = min(existing.lowerBound, range.lowerBound)
                let upper = max(existing.upperBound, range.upperBound)
                ranges[zoom] = lower...upper
            } else {
                ranges[zoom] = range
            }
            // 已经在磁盘上找到对应文件的那些卷不重复计数。
            if !attached.contains(name) { tiles[zoom] = addingTileCount(tiles[zoom] ?? 0, part.tiles ?? 0) }
        }
        guard !ranges.isEmpty else { return nil }

        var parts: [Int: [ZipVolume]] = [:]
        for (zoom, range) in ranges {
            parts[zoom] = orphans.map { ZipVolume(url: $0.url, rowRange: range) }
        }
        return (parts, tiles.values.reduce(0, addingTileCount))
    }

    // MARK: - manifest

    struct Manifest: Decodable {
        struct Part: Decodable {
            var zoom: Int?
            var rows: [Int]?
            var tiles: Int?
        }
        var crs: String?
        var bbox: [Double]?
        var parts: [String: Part]?

        /// manifest 里的 bbox（GeoJSON 顺序：西、南、东、北）。
        var bounds: GeoBounds? {
            guard let bbox, bbox.count == 4, bbox.allSatisfy(\.isFinite),
                  bbox[0] >= -180, bbox[2] <= 180, bbox[1] >= -90, bbox[3] <= 90,
                  bbox[2] > bbox[0], bbox[3] > bbox[1] else { return nil }
            return GeoBounds(west: bbox[0], south: bbox[1], east: bbox[2], north: bbox[3])
        }
    }

    /// 读同目录的 `manifest.json`；没有就读下载器一直在写的 `_state.json`（两者结构相同）。
    static func readManifest(at url: URL) -> Manifest? {
        for name in ["manifest.json", "_state.json"] {
            let file = url.appending(path: name)
            guard !Task.isCancelled else { return nil }
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize, size <= maximumManifestBytes,
                  let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: maximumManifestBytes + 1),
                  data.count <= maximumManifestBytes else { continue }
            if let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
               let parts = manifest.parts, parts.count <= 262_144 {
                return manifest
            }
        }
        return nil
    }

    /// 从 manifest 的坐标系字段认网格。认不出来时交给调用方用默认值。
    static func gridKind(fromCRS crs: String?) -> TileGridKind? {
        guard let crs = crs?.lowercased() else { return nil }
        if crs.contains("mercator") || crs.contains("3857") || crs.contains("900913") {
            return .webMercator
        }
        if crs.contains("4490") || crs.contains("4326") || crs.contains("geographic")
            || crs.contains("longlat") || crs.contains("经纬度") {
            return .geographic
        }
        return nil
    }

    // MARK: - 探测

    /// 探一个分卷：拿瓦片边长；覆盖范围缺失时顺带把它估出来。
    ///
    /// `needBounds` 为假（manifest 已经给了 bbox）时只抽几行拿边长就收手 ——
    /// 一个年度合并包的中央目录上 GB，为了量一下边长去逐行翻几十行纯属白读。
    ///
    /// 探完把归档**交给池子**：这次读过的中央目录与行索引，真正铺图时直接复用，
    /// 不必为一个几十 MB 的中央目录再扫一遍。
    static func probe(
        parts: [Int: [ZipVolume]],
        grid: TileGrid,
        needBounds: Bool = true
    ) -> (tileSize: Int?, bounds: GeoBounds?)? {
        guard let zoom = parts.keys.min(), let volumes = parts[zoom] else { return nil }
        let ordered = volumes.sorted { fileSize(of: $0.url) < fileSize(of: $1.url) }

        var rows: [Int] = []
        var columns: Set<Int> = []
        var tileSize: Int?
        var sampled = 0
        for volume in ordered.prefix(3) {
            // 一、轻量取样：只读中央目录开头的一小块，量得出边长就不必建全量索引
            //     （一个年度合并包的中央目录上 GB，为了边长扫一遍是白读）。
            if !needBounds, tileSize == nil,
               let sample = try? ZipArchive.sampleEntry(at: volume.url) {
                tileSize = ImageDecoder.decode(sample.data).map(\.width)
            }
            if !needBounds, tileSize != nil {
                sampled += 1
                break
            }

            // 二、要么还得估覆盖范围（manifest 没给 bbox），要么轻量取样没量出边长：
            //     老老实实把中央目录扫一遍，顺带建好索引交给池子。
            // 正在下载、还没写完中央目录的分卷打不开：换下一个，别把它当成数据缺陷。
            guard let archive = try? ZipArchive(url: volume.url) else { continue }
            defer { Task { await ZipArchivePool.shared.adopt(archive) } }
            let indexed = archive.indexedRows
            guard !indexed.isEmpty else { continue }
            if needBounds { rows.append(contentsOf: indexed) }
            // 抽样的上限：估范围要盖住首尾与中段，只要边长时几行就够（首行可能是空壳）。
            let sampledRows = sample(indexed, limit: needBounds ? 24 : 3)
            for row in sampledRows {
                let names = archive.entryNames(inRow: String(row))
                if needBounds { columns.formUnion(columnNumbers(in: names, row: row)) }
                // 瓦片边长取第一个读得出来的条目：一张 256px 的 JPEG 读一次也就一毫秒。
                if tileSize == nil, let name = names.first,
                   let entry = archive.entry(named: name),
                   let data = try? archive.data(for: entry) {
                    tileSize = ImageDecoder.decode(data).map(\.width)
                }
                if !needBounds, tileSize != nil { break }
            }
            sampled += 1
            if !needBounds, tileSize != nil { break }
            if sampled >= 2, tileSize != nil, !columns.isEmpty { break }
        }
        guard needBounds, let minRow = rows.min(), let maxRow = rows.max() else {
            return (tileSize, nil)
        }

        var bounds: GeoBounds?
        if let minColumn = columns.min(), let maxColumn = columns.max(), minColumn <= maxColumn {
            let northWest = grid.bounds(zoom: zoom, column: minColumn, row: minRow)
            let southEast = grid.bounds(zoom: zoom, column: maxColumn, row: maxRow)
            bounds = GeoBounds(
                west: northWest.west,
                south: southEast.south,
                east: southEast.east,
                north: northWest.north
            )
        }
        return (tileSize, bounds)
    }

    /// 从条目名里取列号（`45224/215425.jpg` → 215425）。
    static func columnNumbers(in names: [String], row: Int) -> Set<Int> {
        let prefix = "\(row)/"
        var result: Set<Int> = []
        for name in names where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count)
            guard let dot = rest.firstIndex(of: "."),
                  let value = Int(rest[rest.startIndex..<dot]) else { continue }
            result.insert(value)
        }
        return result
    }

    /// 从一串行号里均匀取若干个样本（首尾都要）。整包扫一遍很贵，抽查足够定位范围。
    static func sample(_ values: [Int], limit: Int) -> [Int] {
        guard values.count > limit, limit > 1 else { return values }
        var result: [Int] = []
        result.reserveCapacity(limit)
        let step = Double(values.count - 1) / Double(limit - 1)
        for index in 0..<limit {
            result.append(values[Int((Double(index) * step).rounded())])
        }
        return Array(Set(result)).sorted()
    }

    static func fileSize(of url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }
}
