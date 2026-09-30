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
/// 没有 manifest 也能用：层级与行范围从文件名里读，瓦片边长与覆盖范围
/// 由最低层级的那一两个分卷现场探出来（中央目录顺带建好索引，后面取图直接复用）。
public enum ZipDatasetLocator {

    /// 认出一个 zip 数据集；这个目录里没有 zip 分卷时返回 nil。
    public static func makeDataset(at url: URL) -> TileDataset? {
        let candidates = zipFiles(in: url)
        guard !candidates.isEmpty else { return nil }
        let manifest = readManifest(at: url)

        var parts: [Int: [ZipVolume]] = [:]
        var declaredTiles = 0
        for candidate in candidates {
            // 行范围与层级以 manifest 为准（它是收尾时才写的，比文件名更可信）。
            let declared = manifest?.parts?[candidate.name]
            guard let zoom = declared?.zoom ?? candidate.zoom, (0...30).contains(zoom) else { continue }
            let rows = declared?.rows ?? candidate.rows
            parts[zoom, default: []].append(
                ZipVolume(url: candidate.url, rowRange: rows.flatMap(rowRange))
            )
            if let tiles = declared?.tiles { declaredTiles += tiles }
        }
        guard !parts.isEmpty,
              let minZoom = parts.keys.min(),
              let maxZoom = parts.keys.max() else { return nil }
        for zoom in parts.keys {
            parts[zoom]?.sort {
                ($0.rowRange?.lowerBound ?? .max) < ($1.rowRange?.lowerBound ?? .max)
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
            if let probe = probe(parts: parts, grid: grid) {
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

    static func rowRange(_ rows: [Int]) -> ClosedRange<Int>? {
        guard rows.count == 2, let first = rows.first, let last = rows.last else { return nil }
        return min(first, last)...max(first, last)
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
                  bbox[2] > bbox[0], bbox[3] > bbox[1] else { return nil }
            return GeoBounds(west: bbox[0], south: bbox[1], east: bbox[2], north: bbox[3])
        }
    }

    /// 读同目录的 `manifest.json`；没有就读下载器一直在写的 `_state.json`（两者结构相同）。
    static func readManifest(at url: URL) -> Manifest? {
        for name in ["manifest.json", "_state.json"] {
            let file = url.appending(path: name)
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
            if let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
               manifest.parts != nil {
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
    /// 探完把归档**交给池子**：这次读过的中央目录与行索引，真正铺图时直接复用，
    /// 不必为一个几十 MB 的中央目录再扫一遍。
    static func probe(
        parts: [Int: [ZipVolume]],
        grid: TileGrid
    ) -> (tileSize: Int?, bounds: GeoBounds?)? {
        guard let zoom = parts.keys.min(), let volumes = parts[zoom] else { return nil }
        let ordered = volumes.sorted { fileSize(of: $0.url) < fileSize(of: $1.url) }

        var rows: [Int] = []
        var columns: Set<Int> = []
        var tileSize: Int?
        var sampled = 0
        for volume in ordered.prefix(3) {
            // 正在下载、还没写完中央目录的分卷打不开：换下一个，别把它当成数据缺陷。
            guard let archive = try? ZipArchive(url: volume.url) else { continue }
            defer { Task { await ZipArchivePool.shared.adopt(archive) } }
            let indexed = archive.indexedRows
            guard !indexed.isEmpty else { continue }
            rows.append(contentsOf: indexed)
            for row in sample(indexed, limit: 24) {
                let names = archive.entryNames(inRow: String(row))
                columns.formUnion(columnNumbers(in: names, row: row))
                // 瓦片边长取第一个读得出来的条目：一张 256px 的 JPEG 读一次也就一毫秒。
                if tileSize == nil, let name = names.first,
                   let entry = archive.entry(named: name),
                   let data = try? archive.data(for: entry) {
                    tileSize = ImageDecoder.decode(data).map(\.width)
                }
            }
            sampled += 1
            if sampled >= 2, tileSize != nil, !columns.isEmpty { break }
        }
        guard let minRow = rows.min(), let maxRow = rows.max() else { return (nil, nil) }

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
