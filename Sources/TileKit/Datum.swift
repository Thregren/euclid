import CoreGraphics
import Foundation

/// 大地坐标基准。
///
/// 国内常见底图与自采影像的基准并不一致：天地图、WebODM 正射影像按 CGCS2000/WGS84，
/// 高德 / 腾讯用 GCJ-02（火星坐标，城区偏差 100–500 m），百度用 BD-09。
/// 把偏差当作「数据源的属性」，叠加与下载时按它做平移，读数与图形才对得上。
public enum Datum: String, Codable, Sendable, CaseIterable, Identifiable {
    case wgs84
    case gcj02
    case bd09

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .wgs84: return "WGS84 / CGCS2000"
        case .gcj02: return "GCJ-02（高德、腾讯）"
        case .bd09: return "BD-09（百度）"
        }
    }

    public var shortTitle: String {
        switch self {
        case .wgs84: return "WGS84"
        case .gcj02: return "GCJ-02"
        case .bd09: return "BD-09"
        }
    }

    /// 该基准下的经纬度 → WGS84。
    public func toWGS84(_ coordinate: GeoCoordinate) -> GeoCoordinate {
        switch self {
        case .wgs84: return coordinate
        case .gcj02: return DatumShift.gcj02ToWGS84(coordinate)
        case .bd09: return DatumShift.gcj02ToWGS84(DatumShift.bd09ToGCJ02(coordinate))
        }
    }

    /// WGS84 经纬度 → 该基准。
    public func fromWGS84(_ coordinate: GeoCoordinate) -> GeoCoordinate {
        switch self {
        case .wgs84: return coordinate
        case .gcj02: return DatumShift.wgs84ToGCJ02(coordinate)
        case .bd09: return DatumShift.gcj02ToBD09(DatumShift.wgs84ToGCJ02(coordinate))
        }
    }

    /// 该基准相对 WGS84 在给定位置的偏移方向与距离（米，正东 / 正北）。
    ///
    /// Web Mercator 是等角投影，两个轴向的地面尺度相同，都等于
    /// `earthCircumference * cos(latitude)` 米 / 归一化世界单位。
    public func offsetMeters(at coordinate: GeoCoordinate) -> CGPoint {
        let base = WebMercator.normalized(coordinate)
        let target = WebMercator.normalized(fromWGS84(coordinate))
        let ground = WebMercator.groundMetersPerWorldUnit(latitude: coordinate.latitude)
        return CGPoint(x: (target.x - base.x) * ground, y: (target.y - base.y) * ground)
    }

    /// 偏移量（米），用于界面提示。
    public func offsetMetersMagnitude(at coordinate: GeoCoordinate) -> Double {
        let offset = offsetMeters(at: coordinate)
        return (offset.x * offset.x + offset.y * offset.y).squareRoot()
    }
}

/// 偏移算法本体：WGS84 ↔ GCJ-02 ↔ BD-09。
///
/// GCJ-02 用的是公开流传的椭球参数与多项式拟合（Krasovsky 椭球 + 三角函数扰动）：
/// 正向是解析式，反向用迭代逼近（几轮就收敛到厘米级）。
public enum DatumShift {
    static let semiMajorAxis = 6_378_245.0
    static let eccentricitySquared = 0.006_693_421_622_965_943

    /// 中国大陆范围粗判（境外不做偏移，与各家实现一致）。
    public static func isOutOfChina(_ coordinate: GeoCoordinate) -> Bool {
        coordinate.longitude < 72.004 || coordinate.longitude > 137.8347
            || coordinate.latitude < 0.8293 || coordinate.latitude > 55.8271
    }

    public static func wgs84ToGCJ02(_ coordinate: GeoCoordinate) -> GeoCoordinate {
        guard !isOutOfChina(coordinate) else { return coordinate }
        let delta = offset(
            longitude: coordinate.longitude - 105,
            latitude: coordinate.latitude - 35
        )
        let radianLatitude = coordinate.latitude / 180 * .pi
        let magic = 1 - eccentricitySquared * pow(sin(radianLatitude), 2)
        let sqrtMagic = magic.squareRoot()
        let deltaLatitude = delta.latitude * 180
            / ((semiMajorAxis * (1 - eccentricitySquared)) / (magic * sqrtMagic) * .pi)
        let deltaLongitude = delta.longitude * 180
            / (semiMajorAxis / sqrtMagic * cos(radianLatitude) * .pi)
        return GeoCoordinate(
            longitude: coordinate.longitude + deltaLongitude,
            latitude: coordinate.latitude + deltaLatitude
        )
    }

    /// 反解：以前向公式迭代逼近，默认 6 轮即可到厘米级。
    public static func gcj02ToWGS84(_ coordinate: GeoCoordinate, iterations: Int = 6) -> GeoCoordinate {
        guard !isOutOfChina(coordinate) else { return coordinate }
        var result = coordinate
        for _ in 0..<max(1, iterations) {
            let forward = wgs84ToGCJ02(result)
            result.longitude += coordinate.longitude - forward.longitude
            result.latitude += coordinate.latitude - forward.latitude
        }
        return result
    }

    public static func gcj02ToBD09(_ coordinate: GeoCoordinate) -> GeoCoordinate {
        let x = coordinate.longitude
        let y = coordinate.latitude
        let z = sqrt(x * x + y * y) + 0.00002 * sin(y * .pi * 3000 / 180)
        let theta = atan2(y, x) + 0.000003 * cos(x * .pi * 3000 / 180)
        return GeoCoordinate(
            longitude: z * cos(theta) + 0.0065,
            latitude: z * sin(theta) + 0.006
        )
    }

    public static func bd09ToGCJ02(_ coordinate: GeoCoordinate) -> GeoCoordinate {
        let x = coordinate.longitude - 0.0065
        let y = coordinate.latitude - 0.006
        let z = sqrt(x * x + y * y) - 0.00002 * sin(y * .pi * 3000 / 180)
        let theta = atan2(y, x) - 0.000003 * cos(x * .pi * 3000 / 180)
        return GeoCoordinate(
            longitude: z * cos(theta),
            latitude: z * sin(theta)
        )
    }

    /// 多项式扰动项。
    private static func offset(longitude x: Double, latitude y: Double) -> (longitude: Double, latitude: Double) {
        var deltaLatitude = -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * abs(x).squareRoot()
        deltaLatitude += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        deltaLatitude += (20 * sin(y * .pi) + 40 * sin(y / 3 * .pi)) * 2 / 3
        deltaLatitude += (160 * sin(y / 12 * .pi) + 320 * sin(y * .pi / 30)) * 2 / 3

        var deltaLongitude = 300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * abs(x).squareRoot()
        deltaLongitude += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        deltaLongitude += (20 * sin(x * .pi) + 40 * sin(x / 3 * .pi)) * 2 / 3
        deltaLongitude += (150 * sin(x / 12 * .pi) + 300 * sin(x / 30 * .pi)) * 2 / 3

        return (deltaLongitude, deltaLatitude)
    }
}
