import CoreGraphics
import Foundation

// MARK: - 地理范围

/// WGS84 经纬度包围盒。
public struct GeoBounds: Hashable, Sendable, Codable {
    public var west: Double
    public var south: Double
    public var east: Double
    public var north: Double

    public init(west: Double, south: Double, east: Double, north: Double) {
        self.west = west
        self.south = south
        self.east = east
        self.north = north
    }

    public init(_ a: GeoCoordinate, _ b: GeoCoordinate) {
        self.init(
            west: min(a.longitude, b.longitude),
            south: min(a.latitude, b.latitude),
            east: max(a.longitude, b.longitude),
            north: max(a.latitude, b.latitude)
        )
    }

    /// 由归一化世界矩形（x、y 均 0…1，y 向南递增）构造。
    public init(normalizedRect rect: CGRect) {
        let northWest = WebMercator.coordinate(fromNormalized: CGPoint(x: rect.minX, y: rect.minY))
        let southEast = WebMercator.coordinate(fromNormalized: CGPoint(x: rect.maxX, y: rect.maxY))
        self.init(
            west: northWest.longitude,
            south: southEast.latitude,
            east: southEast.longitude,
            north: northWest.latitude
        )
    }

    public var isValid: Bool {
        east > west && north > south && south >= -90 && north <= 90 && west >= -180 && east <= 180
    }

    /// 对应的归一化世界矩形。
    public var normalizedRect: CGRect {
        let northWest = WebMercator.normalized(GeoCoordinate(longitude: west, latitude: north))
        let southEast = WebMercator.normalized(GeoCoordinate(longitude: east, latitude: south))
        return CGRect(
            x: northWest.x,
            y: northWest.y,
            width: southEast.x - northWest.x,
            height: southEast.y - northWest.y
        )
    }

    public var displayText: String {
        String(format: "%.6f, %.6f → %.6f, %.6f", west, south, east, north)
    }
}

// MARK: - 瓦片源模板

/// 在线瓦片源描述：一个 URL 模板加上取图所需的元信息。
///
/// 模板支持 `{z}` `{x}` `{y}`，另有 `{-y}`（TMS 行号）、`{s}`（子域轮转）、`{key}`（密钥）。
/// 因此 XYZ 直连、`{z}/{y}/{x}` 顺序的服务、以及 WMTS KVP 风格（把 `TILEMATRIX={z}&TILEROW={y}&TILECOL={x}` 写进模板）
/// 都能用同一个模板表达。
public struct TileSourceTemplate: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var urlTemplate: String
    public var subdomains: [String]
    public var fileExtension: String
    public var maximumZoom: Int
    public var tileSize: Int
    public var attribution: String
    /// 使用条款提醒：界面与落盘清单里都会带上，避免把来源和授权搞丢。
    public var terms: String

    public init(
        id: String,
        name: String,
        urlTemplate: String,
        subdomains: [String] = [],
        fileExtension: String = "png",
        maximumZoom: Int = 19,
        tileSize: Int = 256,
        attribution: String = "",
        terms: String = ""
    ) {
        self.id = id
        self.name = name
        self.urlTemplate = urlTemplate
        self.subdomains = subdomains
        self.fileExtension = fileExtension
        self.maximumZoom = maximumZoom
        self.tileSize = tileSize
        self.attribution = attribution
        self.terms = terms
    }

    public var needsKey: Bool { urlTemplate.contains("{key}") }
}

extension TileSourceTemplate {
    /// 完全自定义：模板留空，由使用者填写。
    public static let custom = TileSourceTemplate(
        id: "custom",
        name: "自定义模板",
        urlTemplate: "",
        maximumZoom: 22,
        terms: "请自行确认所用服务的条款是否允许离线保存与批量取图。"
    )

    /// 天地图影像底图（官方 WMTS 接口，需要开发者密钥）。
    public static let tiandituImagery = TileSourceTemplate(
        id: "tianditu-image",
        name: "天地图 · 影像底图",
        urlTemplate: "https://t{s}.tianditu.gov.cn/img_w/wmts?SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0"
            + "&LAYER=img&STYLE=default&TILEMATRIXSET=w&FORMAT=tiles"
            + "&TILEMATRIX={z}&TILEROW={y}&TILECOL={x}&tk={key}",
        subdomains: ["0", "1", "2", "3", "4", "5", "6", "7"],
        fileExtension: "jpg",
        maximumZoom: 18,
        attribution: "© 天地图",
        terms: "需要天地图开发者密钥（tk）；请遵守天地图服务条款与配额限制。"
    )

    /// 天地图影像注记（地名、路名），通常叠在影像上使用。
    public static let tiandituImageryLabel = TileSourceTemplate(
        id: "tianditu-image-label",
        name: "天地图 · 影像注记",
        urlTemplate: "https://t{s}.tianditu.gov.cn/cia_w/wmts?SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0"
            + "&LAYER=cia&STYLE=default&TILEMATRIXSET=w&FORMAT=tiles"
            + "&TILEMATRIX={z}&TILEROW={y}&TILECOL={x}&tk={key}",
        subdomains: ["0", "1", "2", "3", "4", "5", "6", "7"],
        fileExtension: "png",
        maximumZoom: 18,
        attribution: "© 天地图",
        terms: "需要天地图开发者密钥（tk）；请遵守天地图服务条款与配额限制。"
    )

    /// 天地图矢量底图。
    public static let tiandituVector = TileSourceTemplate(
        id: "tianditu-vector",
        name: "天地图 · 矢量底图",
        urlTemplate: "https://t{s}.tianditu.gov.cn/vec_w/wmts?SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0"
            + "&LAYER=vec&STYLE=default&TILEMATRIXSET=w&FORMAT=tiles"
            + "&TILEMATRIX={z}&TILEROW={y}&TILECOL={x}&tk={key}",
        subdomains: ["0", "1", "2", "3", "4", "5", "6", "7"],
        fileExtension: "png",
        maximumZoom: 18,
        attribution: "© 天地图",
        terms: "需要天地图开发者密钥（tk）；请遵守天地图服务条款与配额限制。"
    )

    /// OpenStreetMap 官方栅格瓦片。
    public static let openStreetMap = TileSourceTemplate(
        id: "osm",
        name: "OpenStreetMap 标准图",
        urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
        fileExtension: "png",
        maximumZoom: 19,
        attribution: "© OpenStreetMap contributors",
        terms: "OSM 官方服务器禁止批量抓取（见 tile usage policy），只适合少量取用；"
            + "大批量请自建瓦片服务，或改用允许离线的商业源。"
    )

    /// 内置预设。刻意不内置 Google 地图：其条款不允许把瓦片抓取到服务之外保存；
    /// 需要别的源时用「自定义模板」填入自己的模板与授权信息。
    public static let presets: [TileSourceTemplate] = [
        .tiandituImagery,
        .tiandituImageryLabel,
        .tiandituVector,
        .openStreetMap,
        .custom,
    ]

    public static func preset(id: String) -> TileSourceTemplate? {
        presets.first { $0.id == id }
    }
}

/// URL 模板渲染。
public enum TileURLTemplate {
    /// 密钥按查询值编码：保留 `-._~`，其余转义，避免 key 里的字符破坏 URL 结构。
    static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    /// 把模板里的占位符换成具体瓦片参数。
    public static func url(
        for tile: SlippyTile,
        template: String,
        subdomains: [String] = [],
        key: String? = nil
    ) throws -> URL {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TileDownloadError.emptyTemplate }

        var text = trimmed
        // 先换 {-y}，否则 {y} 会把它的前半截吃掉。
        text = text.replacingOccurrences(of: "{-y}", with: String(tile.tileCountAtZoom - 1 - tile.y))
        text = text.replacingOccurrences(of: "{z}", with: String(tile.zoom))
        text = text.replacingOccurrences(of: "{x}", with: String(tile.x))
        text = text.replacingOccurrences(of: "{y}", with: String(tile.y))

        if text.contains("{s}") {
            let hosts = subdomains.isEmpty ? [""] : subdomains
            // 按坐标轮转子域，避免所有请求都落在同一台机器上。
            let index = abs(tile.x &+ tile.y &* 31) % hosts.count
            text = text.replacingOccurrences(of: "{s}", with: hosts[index])
        }

        if text.contains("{key}") {
            let value = (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw TileDownloadError.missingKey }
            let encoded = value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? value
            text = text.replacingOccurrences(of: "{key}", with: encoded)
        }

        guard !text.contains("{"), !text.contains("}") else {
            throw TileDownloadError.unknownPlaceholder(text)
        }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw TileDownloadError.invalidTemplate(text)
        }
        return url
    }
}

// MARK: - 下载计划

/// 某一层级上需要下载的行列范围。
public struct TileRange: Hashable, Sendable {
    public let zoom: Int
    public let columns: ClosedRange<Int>
    public let rows: ClosedRange<Int>

    public init(zoom: Int, columns: ClosedRange<Int>, rows: ClosedRange<Int>) {
        self.zoom = zoom
        self.columns = columns
        self.rows = rows
    }

    public var count: Int { columns.count * rows.count }
}

/// 一次下载任务的范围：地理包围盒 + 层级范围，按层展开成行列范围。
///
/// 只保存每层的范围而不是逐个瓦片，超大范围也不会先把内存吃满；
/// 具体瓦片在下载时逐层展开。
public struct TileDownloadPlan: Hashable, Sendable {
    public let bounds: GeoBounds
    public let zoomRange: ClosedRange<Int>
    public let ranges: [TileRange]

    public init(bounds: GeoBounds, zoomRange: ClosedRange<Int>) throws {
        guard bounds.isValid else { throw TileDownloadError.invalidBounds }
        guard zoomRange.lowerBound >= 0, zoomRange.upperBound <= 30,
              zoomRange.lowerBound <= zoomRange.upperBound else {
            throw TileDownloadError.invalidZoomRange
        }
        var list: [TileRange] = []
        for zoom in zoomRange {
            list.append(Self.tileRange(bounds: bounds, zoom: zoom))
        }
        guard !list.isEmpty else { throw TileDownloadError.emptyPlan }
        self.bounds = bounds
        self.zoomRange = zoomRange
        self.ranges = list
    }

    /// 计算某一层级上被包围盒覆盖的瓦片行列范围。
    ///
    /// 东西、南北边界都取「覆盖到即算」：东、南边界正好落在瓦片分界线上时不把下一列/下一行算进来，
    /// 并用一点容差吸收「经纬度 ↔ 归一化坐标」往返的浮点误差，否则贴着边界的范围每次都会多取一圈。
    public static func tileRange(bounds: GeoBounds, zoom: Int) -> TileRange {
        let n = 1 << zoom
        let northWest = WebMercator.normalized(GeoCoordinate(longitude: bounds.west, latitude: bounds.north))
        let southEast = WebMercator.normalized(GeoCoordinate(longitude: bounds.east, latitude: bounds.south))
        let maximumIndex = n - 1
        let epsilon = edgeEpsilon

        let minColumn = clamp(Int(floor(northWest.x * Double(n) + epsilon)), 0, maximumIndex)
        let maxColumn = clamp(Int(floor(southEast.x * Double(n) - epsilon)), 0, maximumIndex)
        let minRow = clamp(Int(floor(northWest.y * Double(n) + epsilon)), 0, maximumIndex)
        let maxRow = clamp(Int(floor(southEast.y * Double(n) - epsilon)), 0, maximumIndex)

        return TileRange(
            zoom: zoom,
            columns: min(minColumn, maxColumn)...max(minColumn, maxColumn),
            rows: min(minRow, maxRow)...max(minRow, maxRow)
        )
    }

    /// 边界容差，单位是「瓦片」，远大于浮点往返误差（z22 上约 4e-10），又小到不影响取值。
    static let edgeEpsilon = 1e-9

    public var totalTileCount: Int {
        ranges.reduce(0) { $0 + $1.count }
    }

    public var isEmpty: Bool { totalTileCount == 0 }

    /// 逐层展开瓦片，靠近范围中心的先给出（中途取消时中间区域已经可用）。
    public func tiles(for range: TileRange) -> [SlippyTile] {
        let centerColumn = (range.columns.lowerBound + range.columns.upperBound) / 2
        let centerRow = (range.rows.lowerBound + range.rows.upperBound) / 2
        let columns = Self.centerOut(range.columns, center: centerColumn)
        let rows = Self.centerOut(range.rows, center: centerRow)

        var tiles: [SlippyTile] = []
        tiles.reserveCapacity(range.count)
        for row in rows {
            for column in columns {
                tiles.append(SlippyTile(zoom: range.zoom, x: column, y: row))
            }
        }
        return tiles
    }

    public func allTiles() -> [SlippyTile] {
        ranges.flatMap { tiles(for: $0) }
    }

    private static func centerOut(_ range: ClosedRange<Int>, center: Int) -> [Int] {
        var values: [Int] = []
        values.reserveCapacity(range.count)
        values.append(center)
        var offset = 1
        while values.count < range.count {
            let left = center - offset
            let right = center + offset
            if range.contains(left) { values.append(left) }
            if range.contains(right) { values.append(right) }
            offset += 1
        }
        return values
    }

    private static func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
        min(max(value, lower), upper)
    }
}
