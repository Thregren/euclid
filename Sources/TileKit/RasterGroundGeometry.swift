import CoreGraphics
import Foundation

/// Local ground vectors for one source pixel. The determinant preserves shear and rotation.
package struct RasterGroundMetric: Sendable {
    let column: CGVector
    let row: CGVector

    package init(column: CGVector, row: CGVector) { self.column = column; self.row = row }

    var columnLength: Double { hypot(column.dx, column.dy) }
    var area: Double { abs(column.dx * row.dy - column.dy * row.dx) }
    var inverseBasis: (Double, Double, Double, Double)? {
        let determinant = Double(column.dx * row.dy - column.dy * row.dx)
        guard determinant.isFinite, determinant != 0 else { return nil }
        let coefficients = (Double(row.dy) / determinant, -Double(column.dy) / determinant,
                            -Double(row.dx) / determinant, Double(column.dx) / determinant)
        guard coefficients.0.isFinite, coefficients.1.isFinite,
              coefficients.2.isFinite, coefficients.3.isFinite else { return nil }
        return coefficients
    }

    func scaled(by scale: Double) -> RasterGroundMetric {
        RasterGroundMetric(column: CGVector(dx: column.dx * scale, dy: column.dy * scale),
                           row: CGVector(dx: row.dx * scale, dy: row.dy * scale))
    }
}

/// Ground measurements use the WGS84 ellipsoid, matching Geodesy.
/// Projected coordinates alone are not ground metres: Mercator scale varies with latitude.
package struct RasterGroundGeometry: Sendable {
    let reference: RasterGeoreference
    private static let radius = Projection.wgs84SemiMajorAxis
    private static let eccentricitySquared = Projection.wgs84Flattening * (2 - Projection.wgs84Flattening)

    /// Metres per radian of longitude / latitude at the local tangent plane.
    private static func scales(latitude: Double) -> (east: Double, north: Double) {
        let sine = sin(latitude)
        let denominator = 1 - eccentricitySquared * sine * sine
        let primeVertical = radius / sqrt(denominator)
        let meridian = radius * (1 - eccentricitySquared) / pow(denominator, 1.5)
        return (primeVertical * cos(latitude), meridian)
    }

    var constantAlongRows: Bool {
        guard reference.rotationY == 0 else { return false }
        switch reference.crs {
        case .webMercator, .geographic: return true
        default: return false
        }
    }

    func metric(column: Double, row: Double) -> RasterGroundMetric? {
        guard reference.isGeoreferenced, column.isFinite, row.isFinite else { return nil }
        let point = reference.crsPoint(column: column, row: row)
        let result: RasterGroundMetric
        switch reference.crs {
        case .webMercator:
            let latitude = atan(sinh(point.y / Self.radius))
            let scales = Self.scales(latitude: latitude)
            let east = scales.east / Self.radius
            let north = scales.north * cos(latitude) / Self.radius
            result = RasterGroundMetric(
                column: CGVector(dx: reference.pixelSizeX * east, dy: reference.rotationY * north),
                row: CGVector(dx: reference.rotationX * east, dy: reference.pixelSizeY * north))
        case .geographic:
            guard abs(point.y) < 90 else { return nil }
            let scales = Self.scales(latitude: point.y * .pi / 180)
            let north = scales.north * .pi / 180
            let east = scales.east * .pi / 180
            result = RasterGroundMetric(
                column: CGVector(dx: reference.pixelSizeX * east, dy: reference.rotationY * north),
                row: CGVector(dx: reference.rotationX * east, dy: reference.pixelSizeY * north))
        case .transverseMercator:
            guard let center = reference.coordinate(column: column, row: row), abs(center.latitude) < 90,
                  let left = reference.coordinate(column: column - 0.5, row: row),
                  let right = reference.coordinate(column: column + 0.5, row: row),
                  let top = reference.coordinate(column: column, row: row - 0.5),
                  let bottom = reference.coordinate(column: column, row: row + 0.5) else { return nil }
            let scales = Self.scales(latitude: center.latitude * .pi / 180)
            let north = scales.north * .pi / 180
            let east = scales.east * .pi / 180
            func vector(_ a: GeoCoordinate, _ b: GeoCoordinate) -> CGVector {
                var longitude = (b.longitude - a.longitude).truncatingRemainder(dividingBy: 360)
                if longitude > 180 { longitude -= 360 }
                if longitude < -180 { longitude += 360 }
                return CGVector(dx: longitude * east, dy: (b.latitude - a.latitude) * north)
            }
            result = RasterGroundMetric(column: vector(left, right), row: vector(top, bottom))
        case .unknown: return nil
        }
        guard result.inverseBasis != nil else { return nil }
        return result
    }
}
