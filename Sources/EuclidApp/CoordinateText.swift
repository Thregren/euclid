import Foundation
import TileKit

/// 坐标文本格式化。
enum CoordinateText {
    static func decimal(_ coordinate: GeoCoordinate, precision: Int = 6) -> String {
        String(format: "%.\(precision)f, %.\(precision)f", coordinate.longitude, coordinate.latitude)
    }

    static func dms(_ coordinate: GeoCoordinate) -> String {
        "\(dms(coordinate.longitude, axis: .longitude)) \(dms(coordinate.latitude, axis: .latitude))"
    }

    enum Axis {
        case longitude
        case latitude
    }

    static func dms(_ value: Double, axis: Axis) -> String {
        let hemisphere: String
        switch axis {
        case .longitude:
            hemisphere = value >= 0 ? "E" : "W"
        case .latitude:
            hemisphere = value >= 0 ? "N" : "S"
        }
        let magnitude = abs(value)
        let degrees = floor(magnitude)
        let minutesFull = (magnitude - degrees) * 60
        let minutes = floor(minutesFull)
        let seconds = (minutesFull - minutes) * 60
        return String(format: "%.0f°%02.0f′%04.1f″%@", degrees, minutes, seconds, hemisphere)
    }

    /// 墨卡托米坐标。
    static func mercator(_ coordinate: GeoCoordinate) -> String {
        let projected = WebMercator.projected(coordinate)
        return String(format: "%.2f, %.2f m", projected.x, projected.y)
    }
}
