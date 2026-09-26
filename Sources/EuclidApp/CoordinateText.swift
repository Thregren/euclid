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
        // 进位逻辑在核心库里，自检能覆盖到（见 MeasureFormat.dms）。
        return MeasureFormat.dms(value, hemisphere: hemisphere)
    }

    /// 墨卡托米坐标。
    static func mercator(_ coordinate: GeoCoordinate) -> String {
        let projected = WebMercator.projected(coordinate)
        return String(format: "%.2f, %.2f m", projected.x, projected.y)
    }
}
