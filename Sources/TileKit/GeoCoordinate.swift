import Foundation

/// WGS84 地理坐标（十进制度）。
public struct GeoCoordinate: Hashable, Sendable, Codable {
    public var longitude: Double
    public var latitude: Double

    public init(longitude: Double, latitude: Double) {
        self.longitude = longitude
        self.latitude = latitude
    }
}

extension GeoCoordinate: CustomStringConvertible {
    public var description: String {
        String(format: "%.7f, %.7f", longitude, latitude)
    }
}

/// Web Mercator (EPSG:3857) 与归一化世界坐标之间的换算。
///
/// 归一化世界坐标：x、y 均为 `0...1`，x 向东递增，y 向南递增（与 XYZ 瓦片一致）。
public enum WebMercator {
    public static let earthRadius = 6_378_137.0
    public static let maxLatitude = 85.051_128_779_806_59
    public static let earthCircumference = 2 * Double.pi * earthRadius

    public static func normalizedX(longitude: Double) -> Double {
        (longitude + 180) / 360
    }

    public static func normalizedY(latitude: Double) -> Double {
        let clamped = min(max(latitude, -maxLatitude), maxLatitude)
        let sinLatitude = sin(clamped * .pi / 180)
        return 0.5 - log((1 + sinLatitude) / (1 - sinLatitude)) / (4 * .pi)
    }

    public static func longitude(normalizedX x: Double) -> Double {
        x * 360 - 180
    }

    public static func latitude(normalizedY y: Double) -> Double {
        let n = Double.pi * (1 - 2 * y)
        return atan(sinh(n)) * 180 / .pi
    }

    public static func normalized(_ coordinate: GeoCoordinate) -> CGPoint {
        CGPoint(x: normalizedX(longitude: coordinate.longitude),
                y: normalizedY(latitude: coordinate.latitude))
    }

    public static func coordinate(fromNormalized point: CGPoint) -> GeoCoordinate {
        GeoCoordinate(longitude: longitude(normalizedX: point.x),
                      latitude: latitude(normalizedY: point.y))
    }

    /// 墨卡托平面米坐标。
    public static func projected(_ coordinate: GeoCoordinate) -> CGPoint {
        let x = normalizedX(longitude: coordinate.longitude) * earthCircumference - earthCircumference / 2
        let y = earthCircumference / 2 - normalizedY(latitude: coordinate.latitude) * earthCircumference
        return CGPoint(x: x, y: y)
    }

    /// 一个归一化世界单位在该纬度上对应的实地米数（沿纬线方向）。
    public static func groundMetersPerWorldUnit(latitude: Double) -> Double {
        earthCircumference * cos(latitude * .pi / 180)
    }
}
