import CSQLite
import CoreGraphics
import Foundation

public struct MBTilesInfo: Hashable, Sendable {
    public let name: String
    public let format: String
    public let zoomRange: ClosedRange<Int>
    public let worldRect: CGRect
    public let tileSize: Int
}

public enum MBTilesError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let reason) = self { return reason }; return nil }
}

/// Read-only SQLite connection; prepared statements and the connection share one lock.
public final class MBTilesSource: TileImageSource, @unchecked Sendable {
    public let url: URL
    public let info: MBTilesInfo
    private let database: OpaquePointer
    private let tileQuery: OpaquePointer
    private let lock = NSLock()
    public var availableZoomRange: ClosedRange<Int> { info.zoomRange }

    public init(url: URL) throws {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let connection else {
            if let connection { sqlite3_close(connection) }
            throw MBTilesError.invalid("无法以只读方式打开 MBTiles")
        }
        sqlite3_busy_timeout(connection, 1500)
        do {
            var metadata: [String: String] = [:]
            let metadataQuery = try Self.prepare("SELECT name,value FROM metadata LIMIT 256", db: connection)
            defer { sqlite3_finalize(metadataQuery) }
            while sqlite3_step(metadataQuery) == SQLITE_ROW {
                if let name = sqlite3_column_text(metadataQuery, 0), let value = sqlite3_column_text(metadataQuery, 1) {
                    metadata[String(cString: name)] = String(cString: value)
                }
            }
            let format = (metadata["format"] ?? "").lowercased()
            guard ["png", "jpg", "jpeg", "webp", "image/png", "image/jpeg", "image/webp"].contains(format) else {
                throw MBTilesError.invalid("MBTiles 仅支持栅格 PNG / JPEG / WebP，当前为 \(format)")
            }
            let low = try Self.integer("SELECT zoom_level FROM tiles ORDER BY zoom_level ASC LIMIT 1", db: connection)
            let high = try Self.integer("SELECT zoom_level FROM tiles ORDER BY zoom_level DESC LIMIT 1", db: connection)
            guard let low, let high, low >= 0, high <= 30, low <= high else {
                throw MBTilesError.invalid("MBTiles 没有有效瓦片层级")
            }
            let query = try Self.prepare("SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=? LIMIT 1", db: connection)
            var ownsQuery = true
            defer { if ownsQuery { sqlite3_finalize(query) } }
            var rect: CGRect?
            if let raw = metadata["bounds"] {
                let parts = raw.split(separator: ",").compactMap { Double($0) }
                if parts.count == 4, parts.allSatisfy(\.isFinite), parts[0] >= -180, parts[2] <= 180,
                   parts[1] >= -90, parts[3] <= 90, parts[0] < parts[2], parts[1] < parts[3] {
                    let nw = WebMercator.normalized(GeoCoordinate(longitude: parts[0], latitude: parts[3]))
                    let se = WebMercator.normalized(GeoCoordinate(longitude: parts[2], latitude: parts[1]))
                    rect = CGRect(x: nw.x, y: nw.y, width: se.x - nw.x, height: se.y - nw.y)
                }
            }
            if rect == nil {
                let bounds = try Self.prepare("SELECT min(tile_column),max(tile_column),min(tile_row),max(tile_row) FROM tiles WHERE zoom_level=\(low)", db: connection)
                defer { sqlite3_finalize(bounds) }
                if sqlite3_step(bounds) == SQLITE_ROW {
                    let n = Double(1 << low)
                    let x0 = Double(sqlite3_column_int64(bounds, 0)), x1 = Double(sqlite3_column_int64(bounds, 1))
                    let y0 = Double(sqlite3_column_int64(bounds, 2)), y1 = Double(sqlite3_column_int64(bounds, 3))
                    if x0 >= 0, x1 < n, y0 >= 0, y1 < n {
                        rect = CGRect(x: x0 / n, y: (n - 1 - y1) / n, width: (x1 - x0 + 1) / n, height: (y1 - y0 + 1) / n)
                    }
                }
            }
            guard let rect, rect.width > 0, rect.height > 0 else { throw MBTilesError.invalid("MBTiles 范围无效") }
            let sample = try Self.prepare("SELECT tile_data FROM tiles LIMIT 1", db: connection)
            defer { sqlite3_finalize(sample) }
            var side = 256
            if sqlite3_step(sample) == SQLITE_ROW, let bytes = Self.blob(sample), let image = ImageDecoder.decode(bytes) { side = image.width }
            self.url = url
            database = connection
            tileQuery = query
            ownsQuery = false
            info = MBTilesInfo(name: metadata["name"] ?? url.deletingPathExtension().lastPathComponent,
                               format: format, zoomRange: low...high, worldRect: rect, tileSize: side)
        } catch { sqlite3_close(connection); throw error }
    }
    /// Reuse metadata already validated during background discovery; do not rescan tiles on the UI thread.
    public init(url: URL, info: MBTilesInfo) throws {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw MBTilesError.invalid("无法以只读方式打开 MBTiles")
        }
        do {
            tileQuery = try Self.prepare("SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=? LIMIT 1", db: connection)
            database = connection; self.url = url; self.info = info
            sqlite3_busy_timeout(connection, 1500)
        } catch { sqlite3_close(connection); throw error }
    }
    deinit { sqlite3_finalize(tileQuery); sqlite3_close(database) }

    public func data(for tile: SlippyTile) async -> Data? { blockingData(for: tile) }
    public func readData(for tile: SlippyTile) async throws -> Data? {
        try Task.checkCancellation()
        let result = query(tile)
        try Task.checkCancellation()
        if let data = result.data { return data }
        if result.missing { return nil }
        throw TileReadError.unavailable
    }
    public func blockingData(for tile: SlippyTile) -> Data? { query(tile).data }
    private func query(_ tile: SlippyTile) -> (data: Data?, missing: Bool) {
        guard !Task.isCancelled, info.zoomRange.contains(tile.zoom), tile.x >= 0, tile.y >= 0,
              tile.x < 1 << tile.zoom, tile.y < 1 << tile.zoom else { return (nil, true) }
        return lock.withLock {
            defer { sqlite3_reset(tileQuery); sqlite3_clear_bindings(tileQuery) }
            sqlite3_bind_int64(tileQuery, 1, Int64(tile.zoom))
            sqlite3_bind_int64(tileQuery, 2, Int64(tile.x))
            sqlite3_bind_int64(tileQuery, 3, Int64((1 << tile.zoom) - 1 - tile.y))
            let status = sqlite3_step(tileQuery)
            return (status == SQLITE_ROW ? Self.blob(tileQuery) : nil, status == SQLITE_DONE)
        }
    }
    public func loadTile(_ tile: SlippyTile) async -> TileLoadResult {
        let result = query(tile)
        guard let bytes = result.data else { return result.missing ? .missing : .retry }
        return await TileDecodeScheduler.decode(bytes).map(TileLoadResult.image) ?? .retry
    }
    private static func prepare(_ sql: String, db: OpaquePointer) throws -> OpaquePointer {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK, let query else {
            throw MBTilesError.invalid("MBTiles 表结构无效：\(String(cString: sqlite3_errmsg(db)))")
        }
        return query
    }
    private static func integer(_ sql: String, db: OpaquePointer) throws -> Int? {
        let query = try prepare(sql, db: db)
        defer { sqlite3_finalize(query) }
        return sqlite3_step(query) == SQLITE_ROW ? Int(sqlite3_column_int64(query, 0)) : nil
    }
    private static func blob(_ query: OpaquePointer) -> Data? {
        let count = Int(sqlite3_column_bytes(query, 0))
        guard count > 0, count <= 64 << 20, let pointer = sqlite3_column_blob(query, 0) else { return nil }
        return Data(bytes: pointer, count: count)
    }
}
