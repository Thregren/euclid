import Foundation

/// 把测量结果导出为常见格式。
public enum MeasurementExporter {
    public static func geoJSON(_ measurements: [GeoMeasurement]) -> String {
        var features: [String] = []
        for measurement in measurements {
            let geometry: String
            switch measurement.kind {
            case .point:
                guard let point = measurement.points.first else { continue }
                geometry = """
                {"type":"Point","coordinates":[\(number(point.longitude)),\(number(point.latitude))]}
                """
            case .distance:
                guard measurement.points.count >= 2 else { continue }
                geometry = """
                {"type":"LineString","coordinates":[\(coordinateList(measurement.points))]}
                """
            case .area:
                guard measurement.points.count >= 3 else { continue }
                var ring = measurement.points
                ring.append(measurement.points[0])
                geometry = """
                {"type":"Polygon","coordinates":[[\(coordinateList(ring))]]}
                """
            }
            let result = measurement.result
            var properties = [
                "\"name\":\"\(escape(measurement.kind.displayName))\"",
                "\"kind\":\"\(measurement.kind.rawValue)\"",
                "\"pointCount\":\(measurement.points.count)",
            ]
            if measurement.kind != .point {
                properties.append("\"lengthMeters\":\(number(result.totalLength))")
            }
            if let area = result.area {
                properties.append("\"areaSquareMeters\":\(number(area))")
            }
            features.append("""
            {"type":"Feature","geometry":\(geometry),"properties":{\(properties.joined(separator: ","))}}
            """)
        }
        return """
        {
          "type": "FeatureCollection",
          "crs": { "type": "name", "properties": { "name": "urn:ogc:def:crs:OGC:1.3:CRS84" } },
          "features": [
        \(features.map { "    " + $0 }.joined(separator: ",\n"))
          ]
        }
        """
    }

    public static func kml(_ measurements: [GeoMeasurement]) -> String {
        var placemarks: [String] = []
        for (index, measurement) in measurements.enumerated() {
            let result = measurement.result
            var descriptionParts: [String] = ["类型：\(measurement.kind.displayName)"]
            if measurement.kind != .point {
                descriptionParts.append("长度：\(MeasureFormat.distance(result.totalLength))")
            }
            if let area = result.area {
                descriptionParts.append("面积：\(MeasureFormat.area(area))")
            }
            let description = descriptionParts.joined(separator: "；")

            let geometry: String
            switch measurement.kind {
            case .point:
                guard let point = measurement.points.first else { continue }
                geometry = """
                      <Point><coordinates>\(number(point.longitude)),\(number(point.latitude)),0</coordinates></Point>
                """
            case .distance:
                geometry = """
                      <LineString><tessellate>1</tessellate><coordinates>\(kmlCoordinates(measurement.points))</coordinates></LineString>
                """
            case .area:
                var ring = measurement.points
                ring.append(measurement.points[0])
                geometry = """
                      <Polygon><outerBoundaryIs><LinearRing><coordinates>\(kmlCoordinates(ring))</coordinates></LinearRing></outerBoundaryIs></Polygon>
                """
            }
            placemarks.append("""
                <Placemark>
                  <name>\(escape(measurement.kind.displayName)) \(index + 1)</name>
                  <description>\(escape(description))</description>
            \(geometry)
                </Placemark>
            """)
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
          <Document>
            <name>尺规测量结果</name>
        \(placemarks.joined(separator: "\n"))
          </Document>
        </kml>
        """
    }

    public static func csv(_ measurements: [GeoMeasurement]) -> String {
        var lines = ["测量编号,类型,点序号,经度,纬度,累计长度(米),方位角(度)"]
        for (index, measurement) in measurements.enumerated() {
            let result = measurement.result
            for (pointIndex, coordinate) in measurement.points.enumerated() {
                let segment = result.segments.indices.contains(pointIndex) ? result.segments[pointIndex] : nil
                let cumulative = pointIndex == 0 ? "0" : (segment.map { number($0.cumulative) } ?? "")
                let bearing = segment.map { number($0.bearing) } ?? ""
                lines.append([
                    "\(index + 1)",
                    measurement.kind.displayName,
                    "\(pointIndex + 1)",
                    number(coordinate.longitude),
                    number(coordinate.latitude),
                    cumulative,
                    bearing,
                ].joined(separator: ","))
            }
            if let area = result.area {
                lines.append([
                    "\(index + 1)",
                    "面积(平方米)",
                    "",
                    "",
                    "",
                    number(area),
                    "",
                ].joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func coordinateList(_ points: [GeoCoordinate]) -> String {
        points.map { "[\(number($0.longitude)),\(number($0.latitude))]" }.joined(separator: ",")
    }

    private static func kmlCoordinates(_ points: [GeoCoordinate]) -> String {
        points.map { "\(number($0.longitude)),\(number($0.latitude)),0" }.joined(separator: " ")
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.8f", value)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
