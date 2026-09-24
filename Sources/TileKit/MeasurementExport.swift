import Foundation

/// 把测量结果导出为常见格式。
///
/// 四种格式共用同一套「行模型」（`VertexRow` / `SegmentRow`），
/// 因此 CSV、Excel 与几何格式里的数值口径完全一致。
public enum MeasurementExporter {
    // MARK: - 行模型

    /// 一个顶点的导出行。
    struct VertexRow {
        var measurementNumber: Int
        var kind: MeasurementKind
        var pointIndex: Int
        var label: String
        var coordinate: GeoCoordinate
        /// 从测量起点累计到该点的长度（米）。
        var cumulative: Double?
        /// 从该点出发的那一段长度（米）。
        var segmentLength: Double?
        /// 从该点出发的那一段方位角（度）。
        var bearing: Double?
        /// 该测量所属的面积（平方米，多边形与圆）。
        var area: Double?
        /// 该测量的半径（米，圆）。
        var radius: Double?
    }

    /// 一段折线/多边形的导出行。
    struct SegmentRow {
        var measurementNumber: Int
        var kind: MeasurementKind
        var segmentIndex: Int
        var fromLabel: String
        var toLabel: String
        var length: Double
        var bearing: Double
        var turn: Double?
        var cumulative: Double
    }

    static func vertexRows(of measurement: GeoMeasurement, number: Int) -> [VertexRow] {
        let result = measurement.result
        var rows: [VertexRow] = []
        for (index, coordinate) in measurement.points.enumerated() {
            // 顶点 i 的累计长度是「前面所有段」之和；半径段对圆同样适用。
            let cumulative: Double? = index == 0 ? 0 : result.segments.indices.contains(index - 1)
                ? result.segments[index - 1].cumulative
                : nil
            let segment = result.segments.indices.contains(index) ? result.segments[index] : nil
            rows.append(VertexRow(
                measurementNumber: number,
                kind: measurement.kind,
                pointIndex: index,
                label: measurement.pointLabel(at: index),
                coordinate: coordinate,
                cumulative: cumulative,
                segmentLength: segment?.length,
                bearing: segment?.bearing,
                area: result.area,
                radius: measurement.kind == .circle ? result.radius : nil
            ))
        }
        return rows
    }

    static func segmentRows(of measurement: GeoMeasurement, number: Int) -> [SegmentRow] {
        let result = measurement.result
        return result.segments.map { segment in
            SegmentRow(
                measurementNumber: number,
                kind: measurement.kind,
                segmentIndex: segment.index,
                fromLabel: measurement.pointLabel(at: segment.index),
                toLabel: measurement.pointLabel(at: segment.index + 1),
                length: segment.length,
                bearing: segment.bearing,
                turn: segment.turn,
                cumulative: segment.cumulative
            )
        }
    }

    // MARK: - GeoJSON

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
            case .circle:
                var ring = MeasurementCalculator.circleRing(of: measurement, samples: 180)
                guard ring.count >= 3 else { continue }
                ring.append(ring[0])
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
            if let radius = result.radius {
                properties.append("\"radiusMeters\":\(number(radius))")
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

    // MARK: - KML

    public static func kml(_ measurements: [GeoMeasurement]) -> String {
        var placemarks: [String] = []
        for (index, measurement) in measurements.enumerated() {
            let result = measurement.result
            var descriptionParts: [String] = ["类型：\(measurement.kind.displayName)"]
            if measurement.kind != .point {
                descriptionParts.append("长度：\(MeasureFormat.distance(result.totalLength))")
            }
            if let radius = result.radius {
                descriptionParts.append("半径：\(MeasureFormat.distance(radius))")
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
            case .circle:
                var ring = MeasurementCalculator.circleRing(of: measurement, samples: 180)
                guard ring.count >= 3 else { continue }
                ring.append(ring[0])
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

    // MARK: - CSV

    public static func csv(_ measurements: [GeoMeasurement]) -> String {
        var lines = ["测量编号,类型,点序号,点名称,经度,纬度,累计长度(米),本段长度(米),方位角(度),面积(平方米),半径(米)"]
        for (index, measurement) in measurements.enumerated() {
            for row in vertexRows(of: measurement, number: index + 1) {
                lines.append([
                    "\(row.measurementNumber)",
                    row.kind.displayName,
                    "\(row.pointIndex + 1)",
                    row.label,
                    number(row.coordinate.longitude),
                    number(row.coordinate.latitude),
                    row.cumulative.map(number) ?? "",
                    row.segmentLength.map(number) ?? "",
                    row.bearing.map(number) ?? "",
                    row.area.map(number) ?? "",
                    row.radius.map(number) ?? "",
                ].joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Excel

    /// 导出为 xlsx：汇总、点坐标、分段明细三张表，外加一页说明。
    public static func excel(
        _ measurements: [GeoMeasurement],
        datasetName: String? = nil,
        exportedAt: Date = Date()
    ) -> Data {
        XLSX.workbook(sheets: [
            summarySheet(measurements),
            vertexSheet(measurements),
            segmentSheet(measurements),
            notesSheet(measurements, datasetName: datasetName, exportedAt: exportedAt),
        ])
    }

    private static func summarySheet(_ measurements: [GeoMeasurement]) -> XLSX.Sheet {
        var rows: [[XLSX.Cell]] = [[
            .text("编号"), .text("类型"), .text("点数"),
            .text("长度 / 周长(米)"), .text("直线距离(米)"), .text("面积(平方米)"),
            .text("半径(米)"), .text("圆心经度"), .text("圆心纬度"), .text("记录时间"),
        ]]
        for (index, measurement) in measurements.enumerated() {
            let result = measurement.result
            rows.append([
                .number(Double(index + 1)),
                .text(measurement.kind.displayName),
                .number(Double(measurement.points.count)),
                measurement.kind == .point ? .blank : .number(result.totalLength),
                result.straightDistance.map { XLSX.Cell.number($0) } ?? .blank,
                result.area.map { XLSX.Cell.number($0) } ?? .blank,
                result.radius.map { XLSX.Cell.number($0) } ?? .blank,
                measurement.circleCenter.map { XLSX.Cell.precise($0.longitude) } ?? .blank,
                measurement.circleCenter.map { XLSX.Cell.precise($0.latitude) } ?? .blank,
                .text(timestamp(measurement.createdAt)),
            ])
        }
        return XLSX.Sheet(name: "测量汇总", rows: rows)
    }

    private static func vertexSheet(_ measurements: [GeoMeasurement]) -> XLSX.Sheet {
        var rows: [[XLSX.Cell]] = [[
            .text("测量编号"), .text("类型"), .text("点序号"), .text("点名称"),
            .text("经度(°)"), .text("纬度(°)"),
            .text("东坐标(米)"), .text("北坐标(米)"),
            .text("累计长度(米)"), .text("本段长度(米)"), .text("方位角(°)"),
        ]]
        for (index, measurement) in measurements.enumerated() {
            let projected = measurement.points.map { WebMercator.projected($0) }
            for row in vertexRows(of: measurement, number: index + 1) {
                let meridian = projected[row.pointIndex]
                rows.append([
                    .number(Double(row.measurementNumber)),
                    .text(row.kind.displayName),
                    .number(Double(row.pointIndex + 1)),
                    .text(row.label),
                    .precise(row.coordinate.longitude),
                    .precise(row.coordinate.latitude),
                    .number(meridian.x),
                    .number(meridian.y),
                    row.cumulative.map { XLSX.Cell.number($0) } ?? .blank,
                    row.segmentLength.map { XLSX.Cell.number($0) } ?? .blank,
                    row.bearing.map { XLSX.Cell.number($0) } ?? .blank,
                ])
            }
        }
        return XLSX.Sheet(name: "点坐标", rows: rows)
    }

    private static func segmentSheet(_ measurements: [GeoMeasurement]) -> XLSX.Sheet {
        var rows: [[XLSX.Cell]] = [[
            .text("测量编号"), .text("类型"), .text("段序号"), .text("起点"), .text("终点"),
            .text("长度(米)"), .text("方位角(°)"), .text("方位"),
            .text("转角(°)"), .text("累计长度(米)"),
        ]]
        for (index, measurement) in measurements.enumerated() {
            for segment in segmentRows(of: measurement, number: index + 1) {
                rows.append([
                    .number(Double(segment.measurementNumber)),
                    .text(segment.kind.displayName),
                    .number(Double(segment.segmentIndex + 1)),
                    .text(segment.fromLabel),
                    .text(segment.toLabel),
                    .number(segment.length),
                    .number(segment.bearing),
                    .text(MeasureFormat.compass(segment.bearing)),
                    segment.turn.map { XLSX.Cell.number($0) } ?? .blank,
                    .number(segment.cumulative),
                ])
            }
        }
        return XLSX.Sheet(name: "分段明细", rows: rows)
    }

    private static func notesSheet(
        _ measurements: [GeoMeasurement],
        datasetName: String?,
        exportedAt: Date
    ) -> XLSX.Sheet {
        let rows: [[XLSX.Cell]] = [
            [.text("项目"), .text("内容")],
            [.text("来源"), .text("尺规 Euclid · macOS 本地瓦片查看器")],
            [.text("数据集"), .text(datasetName ?? "—")],
            [.text("测量条数"), .number(Double(measurements.count))],
            [.text("导出时间"), .text(timestamp(exportedAt))],
            [.text("坐标系"), .text("经纬度为 WGS84 (EPSG:4326)；东/北坐标为 Web Mercator 米 (EPSG:3857)")],
            [.text("距离"), .text("WGS84 椭球 Vincenty 反向公式，单位米")],
            [.text("面积"), .text("闭合环的球面过剩面积（等面积球半径 6371007.181 m），单位平方米")],
            [.text("圆"), .text("半径由「圆心 → 半径点」的测地距离确定；周长与面积按 360 点测地采样环计算")],
        ]
        return XLSX.Sheet(name: "说明", rows: rows, freezesHeader: false)
    }

    // MARK: - 辅助

    private static func coordinateList(_ points: [GeoCoordinate]) -> String {
        points.map { "[\(number($0.longitude)),\(number($0.latitude))]" }.joined(separator: ",")
    }

    private static func kmlCoordinates(_ points: [GeoCoordinate]) -> String {
        points.map { "\(number($0.longitude)),\(number($0.latitude)),0" }.joined(separator: " ")
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.8f", value)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
