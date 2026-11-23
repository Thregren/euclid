import CoreGraphics
import Foundation

/// 瓦片网格的种类。
///
/// 应用内部的「世界坐标」固定是 Web 墨卡托（归一化 0…1），网格只决定
/// **瓦片编号怎么摆到这个世界里**。两者不是一回事：
///
/// - `webMercator`：OSM / Google / 高德那一套 XYZ 网格，行号按墨卡托等分，
///   因此一张瓦片在世界上是正方形。
/// - `geographic`：经纬度等分网格（EPSG:4490 CGCS2000 / EPSG:4326），
///   天地图 WMTS 的 `default028mm` 矩阵集就是它：
///   `span = 360 / 2^z`，`列 = (经度 + 180) / span`，`行 = (90 - 纬度) / span`。
///
/// 两种网格的**列**是一回事（墨卡托的 x 与经度成正比），差别只在行：
/// 经纬度网格的行是纬度等分，换算到墨卡托世界后越往高纬越高
/// （这正是「经纬度影像叠在墨卡托底图上会被纵向拉伸」的原因），
/// 于是同一层里每张瓦片的 frame 高度都不一样，不能再按正方形铺。
public enum TileGridKind: String, Sendable, Codable, CaseIterable {
    case webMercator
    case geographic

    public var title: String {
        switch self {
        case .webMercator: return "Web 墨卡托（XYZ）"
        case .geographic: return "经纬度网格（EPSG:4490）"
        }
    }

    public var shortTitle: String {
        switch self {
        case .webMercator: return "墨卡托"
        case .geographic: return "经纬度"
        }
    }
}

/// 一套瓦片网格的换算：瓦片编号 ↔ 经纬度 ↔ 归一化世界矩形。
public struct TileGrid: Hashable, Sendable, Codable {
    public var kind: TileGridKind

    public init(kind: TileGridKind = .webMercator) {
        self.kind = kind
    }

    public static let webMercator = TileGrid(kind: .webMercator)
    public static let geographic = TileGrid(kind: .geographic)

    public var title: String { kind.title }
    public var shortTitle: String { kind.shortTitle }

    /// 层级夹到 0…30：`1 << zoom` 在这之上会直接崩。
    private static func clampedZoom(_ zoom: Int) -> Int { min(max(zoom, 0), 30) }

    /// 该层级一边有多少格。
    public func tileCount(zoom: Int) -> Int { 1 << Self.clampedZoom(zoom) }

    /// 瓦片覆盖的经纬度范围。
    public func bounds(zoom: Int, column: Int, row: Int) -> GeoBounds {
        let n = tileCount(zoom: zoom)
        let span = 360 / Double(n)
        let west = -180 + Double(column) * span
        let north: Double
        let south: Double
        switch kind {
        case .webMercator:
            north = WebMercator.latitude(normalizedY: Double(row) / Double(n))
            south = WebMercator.latitude(normalizedY: Double(row + 1) / Double(n))
        case .geographic:
            north = 90 - Double(row) * span
            south = north - span
        }
        return GeoBounds(
            west: west,
            south: south,
            east: west + span,
            north: north
        )
    }

    /// 瓦片在归一化世界坐标（y 向南）里的矩形。
    ///
    /// 墨卡托网格走直通分支（`row / n`），与 `SlippyTile.worldRect` **逐位一致** ——
    /// 铺图位置要是差一个浮点尾数，相邻瓦片之间就会渗出细缝。
    /// 经纬度网格才需要过一遍「纬度 → 墨卡托」的换算。
    public func worldRect(zoom: Int, column: Int, row: Int) -> CGRect {
        let n = tileCount(zoom: zoom)
        if kind == .webMercator {
            return CGRect(
                x: Double(column) / Double(n),
                y: Double(row) / Double(n),
                width: 1 / Double(n),
                height: 1 / Double(n)
            )
        }
        let bounds = bounds(zoom: zoom, column: column, row: row)
        let top = WebMercator.normalizedY(latitude: bounds.north)
        // 高纬处一张经纬度瓦片的北边界可能落到墨卡托的截断纬度之外（两极附近），
        // 高度算出来 ≤ 0 时给一个极薄的高度，调用方按 0 处理即可（那个范围根本不在画面上）。
        let bottom = WebMercator.normalizedY(latitude: bounds.south)
        return CGRect(
            x: Double(column) / Double(n),
            y: top,
            width: 1 / Double(n),
            height: max(bottom - top, 0)
        )
    }

    /// 行号边界在归一化世界坐标里的 y（画网格线、算行范围用）。
    ///
    /// 墨卡托网格就是 `row / n`；经纬度网格的行按纬度等分，得先把纬度换算成墨卡托 y。
    public func worldRowBoundary(zoom: Int, row: Int) -> Double {
        let n = tileCount(zoom: zoom)
        switch kind {
        case .webMercator:
            return Double(row) / Double(n)
        case .geographic:
            return WebMercator.normalizedY(latitude: 90 - Double(row) * (360 / Double(n)))
        }
    }

    /// 世界矩形覆盖的行列范围（含边界）。
    public func tileRange(
        zoom: Int,
        worldRect rect: CGRect
    ) -> (columns: ClosedRange<Int>, rows: ClosedRange<Int>)? {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite else { return nil }
        let rect = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }
        let n = tileCount(zoom: zoom)
        let maximum = n - 1
        let span = 360 / Double(n)

        let firstColumn = Int(floor(rect.minX * Double(n)))
        let lastColumn = Int(ceil(rect.maxX * Double(n))) - 1
        let columns = max(0, firstColumn)...min(maximum, max(0, lastColumn))
        guard columns.lowerBound <= columns.upperBound,
              firstColumn <= maximum, lastColumn >= 0 else { return nil }

        let firstRow: Int
        let lastRow: Int
        switch kind {
        case .webMercator:
            firstRow = Int(floor(rect.minY * Double(n)))
            lastRow = Int(ceil(rect.maxY * Double(n))) - 1
        case .geographic:
            // 墨卡托世界 → 纬度 → 行号：经度网格的行边界是纬度等分，这里必须反算纬度。
            let north = WebMercator.latitude(normalizedY: rect.minY)
            let south = WebMercator.latitude(normalizedY: rect.maxY)
            firstRow = Int(floor((90 - north) / span))
            lastRow = Int(floor((90 - south) / span))
        }
        let rows = max(0, firstRow)...min(maximum, max(0, lastRow))
        guard rows.lowerBound <= rows.upperBound,
              firstRow <= maximum, lastRow >= 0 else { return nil }
        return (columns, rows)
    }

    /// 经纬度落在哪一张瓦片里。
    public func tile(at coordinate: GeoCoordinate, zoom: Int) -> (column: Int, row: Int) {
        let n = tileCount(zoom: zoom)
        let maximum = n - 1
        let column = min(max(Int(floor((coordinate.longitude + 180) / 360 * Double(n))), 0), maximum)
        let row: Int
        switch kind {
        case .webMercator:
            let y = WebMercator.normalizedY(latitude: coordinate.latitude)
            row = min(max(Int(floor(y * Double(n))), 0), maximum)
        case .geographic:
            let span = 360 / Double(n)
            row = min(max(Int(floor((90 - coordinate.latitude) / span)), 0), maximum)
        }
        return (column, row)
    }

    /// 该层级、该纬度上一像素对应的地面米数（按经线方向算，取赤道米制换算）。
    public func metersPerPixel(zoom: Int, latitude: Double, tilePixels: Int = 256) -> Double {
        let n = Double(tileCount(zoom: zoom))
        let pixels = Double(max(1, tilePixels))
        switch kind {
        case .webMercator:
            return WebMercator.earthCircumference * cos(latitude * .pi / 180) / (n * pixels)
        case .geographic:
            let span = 360 / n
            return span / pixels * (WebMercator.earthCircumference / 360) * cos(latitude * .pi / 180)
        }
    }
}
