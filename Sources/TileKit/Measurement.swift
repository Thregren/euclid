import Foundation

/// 测量类型。
public enum MeasurementKind: String, Sendable, Codable, CaseIterable {
    /// 点坐标。
    case point
    /// 折线测距。
    case distance
    /// 多边形测面积。
    case area
    /// 圆（圆心 + 半径）。
    case circle

    public var displayName: String {
        switch self {
        case .point: return "点坐标"
        case .distance: return "测距"
        case .area: return "测面积"
        case .circle: return "画圆"
        }
    }

    public var symbolName: String {
        switch self {
        case .point: return "scope"
        case .distance: return "ruler"
        case .area: return "skew"
        case .circle: return "circle"
        }
    }

    /// 是否使用填充色（多边形与圆）。
    public var hasFill: Bool {
        switch self {
        case .area, .circle: return true
        case .point, .distance: return false
        }
    }
}

/// 单段测量结果。
public struct MeasurementSegment: Sendable, Hashable {
    public var index: Int
    public var length: Double
    public var bearing: Double
    /// 从起点累计的长度。
    public var cumulative: Double
    /// 与上一段的转角（度，左转为正）。
    public var turn: Double?

    public init(index: Int, length: Double, bearing: Double, cumulative: Double, turn: Double? = nil) {
        self.index = index
        self.length = length
        self.bearing = bearing
        self.cumulative = cumulative
        self.turn = turn
    }
}

/// 一次测量的完整结果。
public struct MeasurementResult: Sendable, Hashable {
    public var segments: [MeasurementSegment]
    /// 折线总长 / 多边形周长（米）。
    public var totalLength: Double
    /// 起点到终点直线距离（测距用）。
    public var straightDistance: Double?
    /// 闭合差：终点与起点之间的距离（多边形用）。
    public var closingError: Double?
    /// 测地面积（平方米，多边形用）。
    public var area: Double?
    /// 半径（米，圆用）。
    public var radius: Double?

    public init(
        segments: [MeasurementSegment],
        totalLength: Double,
        straightDistance: Double? = nil,
        closingError: Double? = nil,
        area: Double? = nil,
        radius: Double? = nil
    ) {
        self.segments = segments
        self.totalLength = totalLength
        self.straightDistance = straightDistance
        self.closingError = closingError
        self.area = area
        self.radius = radius
    }
}

/// 一条已完成的测量。
public struct GeoMeasurement: Identifiable, Sendable, Hashable, Codable {
    public var id: UUID
    public var kind: MeasurementKind
    public var points: [GeoCoordinate]
    public var colorIndex: Int
    public var createdAt: Date
    /// 描边/填充样式。
    public var style: MeasurementStyle

    public init(
        id: UUID = UUID(),
        kind: MeasurementKind,
        points: [GeoCoordinate],
        colorIndex: Int = 0,
        createdAt: Date = Date(),
        style: MeasurementStyle = .standard
    ) {
        self.id = id
        self.kind = kind
        self.points = points
        self.colorIndex = colorIndex
        self.createdAt = createdAt
        self.style = style
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case points
        case colorIndex
        case createdAt
        case style
    }

    /// 手工解码：旧存档没有 `style` 字段，缺省时按调色板默认样式处理。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(MeasurementKind.self, forKey: .kind)
        points = try container.decode([GeoCoordinate].self, forKey: .points)
        colorIndex = try container.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        style = try container.decodeIfPresent(MeasurementStyle.self, forKey: .style) ?? .standard
    }

    /// 圆心（仅圆有效）。
    public var circleCenter: GeoCoordinate? {
        kind == .circle ? points.first : nil
    }

    /// 半径端点（仅圆有效）。
    public var circleRimPoint: GeoCoordinate? {
        kind == .circle && points.count >= 2 ? points[1] : nil
    }

    /// 半径（米，仅圆有效）。
    public var circleRadius: Double? {
        guard let center = circleCenter, let rim = circleRimPoint else { return nil }
        return Geodesy.distance(from: center, to: rim)
    }

    public var result: MeasurementResult {
        MeasurementCalculator.evaluate(kind: kind, points: points)
    }

    /// 顶点的显示名。
    public func pointLabel(at index: Int) -> String {
        switch kind {
        case .point:
            return "取点"
        case .distance:
            return "P\(index + 1)"
        case .area:
            let scalar = UnicodeScalar(UInt8(65 + index % 26))
            return String(Character(scalar))
        case .circle:
            return index == 0 ? "圆心" : "半径点"
        }
    }

    /// 覆盖全部顶点的世界范围（用于「定位到该测量」）。单点时给出一小块范围。
    public var worldRect: CGRect? {
        // 圆的范围要按圆周采样点算，否则「定位到该测量」会裁掉圆的一半。
        var outline = points
        if kind == .circle, let center = circleCenter, let radius = circleRadius, radius > 0 {
            outline = Geodesy.circleRing(center: center, radius: radius, samples: 72)
        }
        guard let first = outline.first else { return nil }
        var rect = CGRect(origin: WebMercator.normalized(first), size: .zero)
        for point in outline.dropFirst() {
            rect = rect.union(CGRect(origin: WebMercator.normalized(point), size: .zero))
        }
        let minimumSpan = 0.0004
        if rect.width < minimumSpan {
            rect = rect.insetBy(dx: -(minimumSpan - rect.width) / 2, dy: 0)
        }
        if rect.height < minimumSpan {
            rect = rect.insetBy(dx: 0, dy: -(minimumSpan - rect.height) / 2)
        }
        return rect
    }
}

/// 测量计算。
public enum MeasurementCalculator {
    /// 圆的显示与计算统一使用同一组采样点，保证「画出来的」和「算出来的」一致。
    public static var circleSamples: Int { Geodesy.circleSampleCount }

    /// 最近算过的结果。标注图层与检查器会在平移、缩放、重绘时**反复**取同一条测量的结果，
    /// 而一次求值要走几十次 Vincenty（圆更狠：360 点采样 + 周长 + 面积，上千次测地运算），
    /// 缓存命中就直接复用，拖动地图时不再每帧重算。
    private static let cache = MeasurementMetricsCache()

    /// 结果缓存的上限（自检用）。超出后按写入顺序淘汰最早的条目。
    public static let resultCacheLimit = 256
    /// 缓存命中次数（自检用）。
    public static var resultCacheHits: Int { cache.hits }
    /// 缓存当前条目数（自检用）。
    public static var resultCacheCount: Int { cache.count }
    /// 清空结果缓存。
    public static func resetResultCache() { cache.removeAll() }

    /// 圆的度量结果。
    public struct CircleMetrics: Sendable, Hashable {
        /// 半径（米）。
        public var radius: Double
        /// 周长（米）。
        public var circumference: Double
        /// 面积（平方米）。
        public var area: Double
        /// 圆周采样点（不含与首点重复的闭合点）。
        public var ring: [GeoCoordinate]
    }

    /// 由圆心与半径算出圆周采样点、周长与面积。
    ///
    /// 不传 `ring` 时走缓存：同一个圆（圆心与半径都一样）只有第一次真的算，
    /// 之后连采样点一起复用，因此标注图层与检查器取到的是同一组点。
    public static func circleMetrics(
        center: GeoCoordinate,
        radius: Double,
        ring: [GeoCoordinate]? = nil
    ) -> CircleMetrics {
        if let ring {
            return metrics(center: center, radius: radius, ring: ring)
        }
        return cache.circleMetrics(center: center, radius: radius) {
            metrics(center: center, radius: radius, ring: Geodesy.circleRing(center: center, radius: radius))
        }
    }

    private static func metrics(
        center: GeoCoordinate,
        radius: Double,
        ring samples: [GeoCoordinate]
    ) -> CircleMetrics {
        return CircleMetrics(
            radius: radius,
            circumference: Geodesy.perimeter(of: samples),
            area: Geodesy.area(of: samples),
            ring: samples
        )
    }

    /// 求值（带缓存）。同一条测量在界面上会被反复取用，见 `cache` 的说明。
    public static func evaluate(kind: MeasurementKind, points: [GeoCoordinate]) -> MeasurementResult {
        cache.result(kind: kind, points: points) {
            evaluateUncached(kind: kind, points: points)
        }
    }

    /// 不走缓存求值：自检用它跟缓存路径逐字段对照，也供「确定只要算一次」的场合使用。
    public static func evaluateUncached(kind: MeasurementKind, points: [GeoCoordinate]) -> MeasurementResult {
        var segments: [MeasurementSegment] = []
        var cumulative = 0.0
        var previousBearing: Double?

        if points.count >= 2 {
            for index in 0..<(points.count - 1) {
                let inverse = Geodesy.inverse(from: points[index], to: points[index + 1])
                cumulative += inverse.distance
                var turn: Double?
                if let previous = previousBearing {
                    var delta = inverse.initialBearing - previous
                    if delta > 180 { delta -= 360 }
                    if delta < -180 { delta += 360 }
                    turn = delta
                }
                segments.append(MeasurementSegment(
                    index: index,
                    length: inverse.distance,
                    bearing: inverse.initialBearing,
                    cumulative: cumulative,
                    turn: turn
                ))
                previousBearing = inverse.initialBearing
            }
        }

        switch kind {
        case .point:
            return MeasurementResult(segments: [], totalLength: 0)

        case .circle:
            return evaluateCircle(points: points)

        case .distance:
            var straight: Double?
            if let first = points.first, let last = points.last, points.count >= 2 {
                straight = Geodesy.distance(from: first, to: last)
            }
            return MeasurementResult(segments: segments, totalLength: cumulative, straightDistance: straight)

        case .area:
            guard points.count >= 3 else {
                return MeasurementResult(segments: segments, totalLength: cumulative, area: nil)
            }
            let closing = Geodesy.inverse(from: points[points.count - 1], to: points[0])
            var closingSegments = segments
            closingSegments.append(MeasurementSegment(
                index: segments.count,
                length: closing.distance,
                bearing: closing.initialBearing,
                cumulative: cumulative + closing.distance
            ))
            return MeasurementResult(
                segments: closingSegments,
                totalLength: cumulative + closing.distance,
                straightDistance: nil,
                closingError: closing.distance,
                area: Geodesy.area(of: points)
            )
        }
    }

    /// 圆的周长、面积与半径。
    ///
    /// 周长与面积都按测地圆采样出的闭合环计算，与标注图层画出的图形完全一致；
    /// 采样足够密（默认 360 点）时与解析值 `2πr`、`πr²` 的偏差在 1e-5 量级。
    private static func evaluateCircle(points: [GeoCoordinate]) -> MeasurementResult {
        guard points.count >= 2 else {
            return MeasurementResult(segments: [], totalLength: 0, radius: nil)
        }
        let center = points[0]
        let rim = points[1]
        let inverse = Geodesy.inverse(from: center, to: rim)
        let radius = inverse.distance
        guard radius > 0 else {
            return MeasurementResult(segments: [], totalLength: 0, radius: 0)
        }
        let metrics = circleMetrics(center: center, radius: radius)
        // 半径段保留下来，导出时能说明「圆心 → 半径点」这一段的意义。
        let segments = [MeasurementSegment(
            index: 0,
            length: radius,
            bearing: inverse.initialBearing,
            cumulative: radius
        )]
        return MeasurementResult(
            segments: segments,
            totalLength: metrics.circumference,
            straightDistance: nil,
            closingError: nil,
            area: metrics.area,
            radius: radius
        )
    }

    /// 圆的圆周采样点（供标注绘制与导出使用）。
    public static func circleRing(of measurement: GeoMeasurement, samples: Int? = nil) -> [GeoCoordinate] {
        guard let center = measurement.circleCenter,
              let radius = measurement.circleRadius,
              radius > 0 else { return [] }
        return Geodesy.circleRing(center: center, radius: radius, samples: samples ?? circleSamples)
    }

    /// 多边形质心（经纬度平均的近似值，用于放置面积标注）。
    public static func centroid(of points: [GeoCoordinate]) -> GeoCoordinate? {
        guard !points.isEmpty else { return nil }
        let sum = points.reduce(into: (lon: 0.0, lat: 0.0)) { partial, coordinate in
            partial.lon += coordinate.longitude
            partial.lat += coordinate.latitude
        }
        return GeoCoordinate(
            longitude: sum.lon / Double(points.count),
            latitude: sum.lat / Double(points.count)
        )
    }
}

/// 测量结果的小型备忘录。
///
/// 键就是「算结果的输入」——类型 + 顶点序列（圆另按圆心与半径存一份度量），
/// 因此只有输入真的变了才会重算。条目按写入顺序淘汰，容量固定，
/// 不会随用户量了多久而无限增长；圆圈的采样点也一并缓存，省下每帧上千次测地运算。
///
/// `TileKit` 本身不绑定主线程，而标注图层与检查器可能从不同线程取用，所以这里加锁。
final class MeasurementMetricsCache: @unchecked Sendable {
    private struct ResultKey: Hashable {
        var kind: MeasurementKind
        var points: [GeoCoordinate]
    }

    private struct CircleKey: Hashable {
        var center: GeoCoordinate
        var radius: Double
    }

    private let lock = NSLock()
    private var results: [ResultKey: MeasurementResult] = [:]
    private var resultOrder: [ResultKey] = []
    private var circles: [CircleKey: MeasurementCalculator.CircleMetrics] = [:]
    private var circleOrder: [CircleKey] = []
    private var hitCount = 0

    /// 结果的条目上限（一条折线的结果很小）。
    private let resultLimit = MeasurementCalculator.resultCacheLimit
    /// 圆的条目上限：每个圆要存 360 个采样点（约 6 KB），单独给一个更紧的额度。
    private let circleLimit = 64

    var hits: Int {
        lock.lock()
        defer { lock.unlock() }
        return hitCount
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return results.count + circles.count
    }

    func removeAll() {
        lock.lock()
        results.removeAll()
        resultOrder.removeAll()
        circles.removeAll()
        circleOrder.removeAll()
        hitCount = 0
        lock.unlock()
    }

    func result(
        kind: MeasurementKind,
        points: [GeoCoordinate],
        compute: () -> MeasurementResult
    ) -> MeasurementResult {
        let key = ResultKey(kind: kind, points: points)
        if let cached = lookup(results[key]) { return cached }
        let value = compute()
        insert(value, for: key)
        return value
    }

    func circleMetrics(
        center: GeoCoordinate,
        radius: Double,
        compute: () -> MeasurementCalculator.CircleMetrics
    ) -> MeasurementCalculator.CircleMetrics {
        let key = CircleKey(center: center, radius: radius)
        if let cached = lookup(circles[key]) { return cached }
        let value = compute()
        lock.lock()
        if circles[key] == nil {
            circles[key] = value
            circleOrder.append(key)
            while circleOrder.count > circleLimit {
                circles.removeValue(forKey: circleOrder.removeFirst())
            }
        }
        lock.unlock()
        return value
    }

    /// 命中时记一笔并返回；未命中返回 nil（不在此处持锁做计算）。
    private func lookup<T>(_ value: T?) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let value else { return nil }
        hitCount += 1
        return value
    }

    private func insert(_ value: MeasurementResult, for key: ResultKey) {
        lock.lock()
        defer { lock.unlock() }
        guard results[key] == nil else { return }
        results[key] = value
        resultOrder.append(key)
        while resultOrder.count > resultLimit {
            results.removeValue(forKey: resultOrder.removeFirst())
        }
    }
}
