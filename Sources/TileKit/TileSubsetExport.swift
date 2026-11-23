import Foundation
import CoreGraphics

public struct TileSubsetReport: Codable, Sendable {
    public var requested = 0
    public var written = 0
    public var missing = 0
    public var bytes = 0
    public var parts: [String] = []
}

public enum TileSubsetExport {
    /// Produces directly browsable per-level ZIPs and a geographic manifest, without expanding the source archive.
    public static func extract(dataset: TileDataset, bounds: GeoBounds, zoomRange: ClosedRange<Int>,
                               output: URL, maximumTiles: Int = 1_000_000) async throws -> TileSubsetReport {
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        guard bounds.west.isFinite, bounds.east.isFinite, bounds.north.isFinite, bounds.south.isFinite,
              bounds.west < bounds.east, bounds.south < bounds.north, bounds.west >= -180, bounds.east <= 180,
              bounds.south >= -90, bounds.north <= 90 else { throw MBTilesError.invalid("提取范围或层级无效") }
        let low = max(zoomRange.lowerBound, dataset.zoomRange.lowerBound)
        let high = min(zoomRange.upperBound, dataset.zoomRange.upperBound)
        guard low <= high, maximumTiles > 0 else { throw MBTilesError.invalid("提取范围或层级无效") }
        struct Level { let zoom: Int; let columns: ClosedRange<Int>; let rows: ClosedRange<Int> }
        var levels: [Level] = []
        var requested = 0
        for zoom in low...high {
            guard let range = dataset.grid.tileRange(zoom: zoom, worldRect: CGRect(x: WebMercator.normalizedX(longitude: bounds.west), y: WebMercator.normalizedY(latitude: bounds.north), width: WebMercator.normalizedX(longitude: bounds.east) - WebMercator.normalizedX(longitude: bounds.west), height: WebMercator.normalizedY(latitude: bounds.south) - WebMercator.normalizedY(latitude: bounds.north))) else { continue }
            let columns = range.columns.count, rows = range.rows.count
            guard rows <= maximumTiles / max(1, columns), columns * rows <= maximumTiles - requested else {
                throw MBTilesError.invalid("提取范围超过 \(maximumTiles) 张瓦片；请缩小范围或明确提高 --max-tiles")
            }
            requested += columns * rows
            levels.append(Level(zoom: zoom, columns: range.columns, rows: range.rows))
        }
        let staging = output.deletingLastPathComponent().appending(path: ".\(output.lastPathComponent)-partial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: staging) } }
        var report = TileSubsetReport(); report.requested = requested
        var parts: [String: [String: Any]] = [:]
        let source = dataset.source
        for level in levels {
            try Task.checkCancellation()
            let directory = staging.appending(path: "z\(level.zoom)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "part_z\(level.zoom)_r\(level.rows.lowerBound)-\(level.rows.upperBound)_tiles.zip"
            let writer = try StreamingZipWriter(url: directory.appending(path: name))
            let prior = report.written
            for row in level.rows {
                for column in level.columns {
                    try Task.checkCancellation()
                    guard let data = try await source.readData(for: SlippyTile(zoom: level.zoom, x: column, y: row)) else {
                        report.missing += 1; continue
                    }
                    let decoded = await TileDecodeScheduler.decode(data)
                    try Task.checkCancellation()
                    guard let ext = ImageDecoder.fileExtension(for: data), decoded != nil else { throw MBTilesError.invalid("源瓦片不是有效图片：\(level.zoom)/\(column)/\(row)") }
                    try writer.append(name: "\(row)/\(column).\(ext)", data: data)
                    report.written += 1; report.bytes += data.count
                }
            }
            try writer.finish()
            let relative = "z\(level.zoom)/\(name)"
            if report.written > prior {
                report.parts.append(relative)
                parts[name] = ["zoom": level.zoom, "rows": [level.rows.lowerBound, level.rows.upperBound], "tiles": report.written - prior]
            } else { try FileManager.default.removeItem(at: directory) }
        }
        guard report.written > 0 else { throw MBTilesError.invalid("范围内没有读到瓦片") }
        try Task.checkCancellation()
        let manifest: [String: Any] = ["crs": dataset.grid.kind == .geographic ? "EPSG:4490" : "EPSG:3857",
            "bbox": [bounds.west, bounds.south, bounds.east, bounds.north], "parts": parts,
            "source": dataset.rootURL.canonicalFilePath, "tileSize": dataset.layout.tileSize]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: staging.appending(path: "manifest.json"), options: .atomic)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: output)
        finished = true
        return report
    }
}
