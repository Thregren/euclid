import Foundation

/// 测量类型。
public enum MeasurementKind: String, Sendable, Codable, CaseIterable {
    /// 点坐标。
    case point
    /// 折线测距。
    case distance
    /// 多边形测面积。
    case area

    public var displayName: String {
        switch self {
        case .point: return "点坐标"
        case .distance: return "测距"
        case .area: return "测面积"
        }
    }

    public var symbolName: String {
        switch self {
        case .point: return "scope"
        case .distance: return "ruler"
        case .area: return "skew"
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

    public init(
        segments: [MeasurementSegment],
        totalLength: Double,
        straightDistance: Double? = nil,
        closingError: Double? = nil,
        area: Double? = nil
    ) {
        self.segments = segments
        self.totalLength = totalLength
        self.straightDistance = straightDistance
        self.closingError = closingError
        self.area = area
    }
}

/// 一条已完成的测量。
public struct GeoMeasurement: Identifiable, Sendable, Hashable {
    public var id: UUID
    public var kind: MeasurementKind
    public var points: [GeoCoordinate]
    public var colorIndex: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: MeasurementKind,
        points: [GeoCoordinate],
        colorIndex: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.points = points
        self.colorIndex = colorIndex
        self.createdAt = createdAt
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
        }
    }
}

/// 测量计算。
public enum MeasurementCalculator {
    public static func evaluate(kind: MeasurementKind, points: [GeoCoordinate]) -> MeasurementResult {
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
