import Foundation

/// CAD / GIS 交换格式的导出：DXF（R12 ASCII）与 ESRI Shapefile。
///
/// 与 `MeasurementExport.swift` 里那四种分开放：那边是「人看的表 / 通用交换」，
/// 这边是「给 CAD、测绘软件继续加工的矢量」。
///
/// 口径：
/// - DXF 按 Web 墨卡托米制坐标写（EPSG:3857，与应用内显示一致），
///   并在文件头写上 `$INSUNITS = 6`（米），因此量出来的长度就是米。
/// - Shapefile 按 WGS84 经纬度写，`.prj` 带标准 WKT，`.cpg` 声明 UTF-8，
///   属性表里带名称 / 备注 / 长度 / 面积。
public enum MeasurementCADExporter {
    /// 一条测量在 DXF 里的图层名（用 ASCII，避免老版本 CAD 的代码页问题）。
    private static func layerName(for kind: MeasurementKind) -> String {
        switch kind {
        case .point: return "POINT"
        case .annotation: return "ANNOTATION"
        case .distance: return "LINE"
        case .area: return "AREA"
        case .circle: return "CIRCLE"
        }
    }

    /// 一条测量的几何类别（Shapefile 一个文件只能装一种几何）。
    enum GeometryClass: CaseIterable {
        case point
        case line
        case polygon

        var shapeType: Int32 {
            switch self {
            case .point: return 1
            case .line: return 3
            case .polygon: return 5
            }
        }

        var fileSuffix: String {
            switch self {
            case .point: return "point"
            case .line: return "line"
            case .polygon: return "polygon"
            }
        }

        static func classify(_ kind: MeasurementKind) -> GeometryClass {
            switch kind {
            case .point, .annotation: return .point
            case .distance: return .line
            case .area, .circle: return .polygon
            }
        }
    }

    /// Web 墨卡托（EPSG:3857）平面米制坐标。y 向北为正。
    static func mercator(_ coordinate: GeoCoordinate) -> (x: Double, y: Double) {
        let normalized = WebMercator.normalized(coordinate)
        let half = Projection.earthCircumference / 2
        return (
            x: normalized.x * Projection.earthCircumference - half,
            y: half - normalized.y * Projection.earthCircumference
        )
    }

    /// 采样成环的顶点（圆按 128 边）；返回不带重复闭合点。
    static func ringPoints(of measurement: GeoMeasurement) -> [GeoCoordinate] {
        switch measurement.kind {
        case .circle:
            return MeasurementCalculator.circleRing(of: measurement, samples: 128)
        default:
            return measurement.points
        }
    }

    // MARK: - DXF（R12 ASCII）

    /// 把测量写成一份 DXF（R12 ASCII）。
    public static func dxf(_ measurements: [GeoMeasurement]) -> String {
        var entities: [String] = []
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        func track(_ x: Double, _ y: Double) {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }

        for (index, measurement) in measurements.enumerated() {
            let layer = layerName(for: measurement.kind)
            let ordinal = index + 1
            switch measurement.kind {
            case .point, .annotation:
                guard let point = measurement.points.first else { continue }
                let projected = mercator(point)
                track(projected.x, projected.y)
                entities.append(pair(0, "POINT") + pair(8, layer)
                    + pair(10, number(projected.x)) + pair(20, number(projected.y)) + pair(30, "0.0"))
                if let text = annotationText(of: measurement, number: ordinal) {
                    entities.append(pair(0, "TEXT") + pair(8, layer)
                        + pair(10, number(projected.x)) + pair(20, number(projected.y)) + pair(30, "0.0")
                        + pair(40, "2.5") + pair(1, text))
                }

            case .distance:
                guard measurement.points.count >= 2 else { continue }
                let projected = measurement.points.map(mercator)
                for point in projected { track(point.x, point.y) }
                entities.append(polyline(projected, closed: false, layer: layer))

            case .area, .circle:
                let ring = ringPoints(of: measurement)
                guard ring.count >= 3 else { continue }
                let projected = ring.map(mercator)
                for point in projected { track(point.x, point.y) }
                entities.append(polyline(projected, closed: true, layer: layer))
                if let text = annotationText(of: measurement, number: ordinal), !projected.isEmpty {
                    let sum = projected.reduce((x: 0.0, y: 0.0)) { ($0.x + $1.x, $0.y + $1.y) }
                    entities.append(pair(0, "TEXT") + pair(8, layer)
                        + pair(10, number(sum.x / Double(projected.count)))
                        + pair(20, number(sum.y / Double(projected.count)))
                        + pair(30, "0.0") + pair(40, "2.5") + pair(1, text))
                }
            }
        }

        if !minX.isFinite { minX = 0; minY = 0; maxX = 0; maxY = 0 }
        var output = ""
        output += pair(0, "SECTION") + pair(2, "HEADER")
        output += pair(9, "$ACADVER") + pair(1, "AC1009")
        output += pair(9, "$INSUNITS") + pair(70, "6")
        output += pair(9, "$EXTMIN") + pair(10, number(minX)) + pair(20, number(minY)) + pair(30, "0.0")
        output += pair(9, "$EXTMAX") + pair(10, number(maxX)) + pair(20, number(maxY)) + pair(30, "0.0")
        output += pair(0, "ENDSEC")
        output += pair(0, "SECTION") + pair(2, "ENTITIES")
        output += entities.joined()
        output += pair(0, "ENDSEC")
        output += pair(0, "EOF")
        return output
    }

    /// 点 / 面上的说明文字（名称 + 备注）；两样都没有就不写 TEXT。
    static func annotationText(of measurement: GeoMeasurement, number: Int) -> String? {
        var parts: [String] = []
        let name = measurement.exportName.trimmingCharacters(in: .whitespacesAndNewlines)
        if measurement.kind == .annotation {
            parts.append(name.isEmpty ? "标注 \(number)" : name)
        } else if !name.isEmpty {
            parts.append(name)
        }
        if let note = measurement.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            parts.append(note)
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }

    private static func polyline(_ points: [(x: Double, y: Double)], closed: Bool, layer: String) -> String {
        var output = pair(0, "POLYLINE") + pair(8, layer)
            + pair(66, "1") + pair(70, closed ? "1" : "0")
            + pair(10, "0.0") + pair(20, "0.0") + pair(30, "0.0")
        for point in points {
            output += pair(0, "VERTEX") + pair(8, layer)
                + pair(10, number(point.x)) + pair(20, number(point.y)) + pair(30, "0.0")
        }
        output += pair(0, "SEQEND") + pair(8, layer)
        return output
    }

    /// DXF 的一组「组码 + 值」两行。
    package static func pair(_ code: Int, _ value: String) -> String {
        "\(code)\n\(dxfText(value))\n"
    }

    /// 非 ASCII 字符转成 AutoCAD 认识的 `\U+XXXX` 转义，免得代码页不对时变成乱码。
    static func dxfText(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value > 0x7F }) else { return text }
        var output = ""
        for scalar in text.unicodeScalars {
            if scalar.value > 0x7F {
                output += String(format: "\\U+%04X", scalar.value)
            } else {
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    // MARK: - Shapefile

    /// 一份 Shapefile 导出里的一个文件。
    public struct File {
        public var name: String
        public var data: Data
    }

    /// 把测量写成一组 Shapefile（按几何类别拆成点 / 线 / 面三套）。
    ///
    /// - Parameter baseName: 用户选定的文件名（不含扩展名）。
    /// - Returns: 形如 `基础名_point.shp` 的一批文件；没有任何要素时返回空数组。
    public static func shapefile(_ measurements: [GeoMeasurement], baseName: String) -> [File] {
        var files: [File] = []
        for geometryClass in GeometryClass.allCases {
            let members = measurements.filter { GeometryClass.classify($0.kind) == geometryClass }
            guard !members.isEmpty else { continue }
            let stem = "\(baseName)_\(geometryClass.fileSuffix)"
            files.append(contentsOf: shapefileSet(members, stem: stem, geometryClass: geometryClass))
        }
        return files
    }

    static func shapefileSet(
        _ measurements: [GeoMeasurement],
        stem: String,
        geometryClass: GeometryClass
    ) -> [File] {
        var shapes: [Data] = []
        var bounds = BoundingBox()
        for measurement in measurements {
            guard let shape = shapeBytes(of: measurement, geometryClass: geometryClass, bounds: &bounds) else { continue }
            shapes.append(shape)
        }
        guard !shapes.isEmpty else { return [] }

        // .shp：100 字节头 + 每条记录（8 字节记录头 + 形状字节）。
        var shp = Data()
        var shx = Data()
        let recordCount = shapes.count
        let shpLengthWords = (100 + shapes.reduce(0) { $0 + 8 + $1.count }) / 2
        let shxLengthWords = (100 + recordCount * 8) / 2
        shp.append(bigEndian: Int32(9994))
        shp.append(shpHeaderTail(shapeType: geometryClass.shapeType, lengthWords: shpLengthWords, bounds: bounds))
        shx.append(bigEndian: Int32(9994))
        shx.append(shpHeaderTail(shapeType: geometryClass.shapeType, lengthWords: shxLengthWords, bounds: bounds))
        var offsetWords = 50
        for (index, shape) in shapes.enumerated() {
            shp.append(bigEndian: Int32(index + 1))
            shp.append(bigEndian: Int32(shape.count / 2))
            shp.append(shape)
            shx.append(bigEndian: Int32(offsetWords))
            shx.append(bigEndian: Int32(shape.count / 2))
            offsetWords += 4 + shape.count / 2
        }

        // 属性表只装真正写出形状的那些要素（顺序与 shapes 一致）。
        let kept = measurements.filter { measurement in
            switch geometryClass {
            case .point: return !measurement.points.isEmpty
            case .line: return measurement.points.count >= 2
            case .polygon: return ringPoints(of: measurement).count >= 3
            }
        }
        let dbf = dbfFile(kept.isEmpty ? measurements : kept)
        return [
            File(name: "\(stem).shp", data: shp),
            File(name: "\(stem).shx", data: shx),
            File(name: "\(stem).dbf", data: dbf),
            File(name: "\(stem).prj", data: Data(wgs84WKT.utf8)),
            File(name: "\(stem).cpg", data: Data("UTF-8".utf8)),
        ]
    }

    /// 文件头的后 76 字节（5 个保留字之后的全部内容）。
    private static func shpHeaderTail(shapeType: Int32, lengthWords: Int, bounds: BoundingBox) -> Data {
        var data = Data()
        for _ in 0..<5 { data.append(bigEndian: Int32(0)) }
        data.append(bigEndian: Int32(lengthWords))
        data.append(littleEndian: Int32(1000))
        data.append(littleEndian: shapeType)
        let box = bounds.isFinite ? bounds : BoundingBox()
        for value in [box.minX, box.minY, box.maxX, box.maxY, 0, 0, 0, 0] {
            data.append(littleEndian: value)
        }
        return data
    }

    struct BoundingBox {
        var minX = 0.0
        var minY = 0.0
        var maxX = 0.0
        var maxY = 0.0
        private var isEmpty = true

        /// 还没放进去任何点时不写包围盒（都写 0）。
        var isFinite: Bool { !isEmpty }

        mutating func add(x: Double, y: Double) {
            if isEmpty {
                minX = x; maxX = x; minY = y; maxY = y
                isEmpty = false
            } else {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }

    /// 一条测量的形状记录体（小端）：形状类型 + 几何。
    static func shapeBytes(
        of measurement: GeoMeasurement,
        geometryClass: GeometryClass,
        bounds: inout BoundingBox
    ) -> Data? {
        switch geometryClass {
        case .point:
            guard let point = measurement.points.first else { return nil }
            var data = Data()
            data.append(littleEndian: geometryClass.shapeType)
            data.append(littleEndian: point.longitude)
            data.append(littleEndian: point.latitude)
            bounds.add(x: point.longitude, y: point.latitude)
            return data

        case .line, .polygon:
            let ring = geometryClass == .polygon ? ringPoints(of: measurement) : measurement.points
            let minimum = geometryClass == .polygon ? 3 : 2
            guard ring.count >= minimum else { return nil }
            // Shapefile 的外环按顺时针存；数学上逆时针（面积为正）的环翻过来。
            var points = ring
            if geometryClass == .polygon, Geodesy.area(of: ring) > 0 {
                points = ring.reversed()
            }
            var box = BoundingBox()
            for point in points { box.add(x: point.longitude, y: point.latitude) }
            var data = Data()
            data.append(littleEndian: geometryClass.shapeType)
            data.append(littleEndian: box.minX)
            data.append(littleEndian: box.minY)
            data.append(littleEndian: box.maxX)
            data.append(littleEndian: box.maxY)
            data.append(littleEndian: Int32(1))                 // 一个 part
            data.append(littleEndian: Int32(points.count))      // 顶点数
            data.append(littleEndian: Int32(0))                 // part 起始下标
            for point in points {
                data.append(littleEndian: point.longitude)
                data.append(littleEndian: point.latitude)
            }
            bounds.add(x: box.minX, y: box.minY)
            bounds.add(x: box.maxX, y: box.maxY)
            return data
        }
    }

    // MARK: - DBF（dBASE III）

    static func dbfFile(_ measurements: [GeoMeasurement]) -> Data {
        // 字段宽度按「UTF-8 字节数」算，多的部分截掉，保证记录长度恒定。
        let fields: [(name: String, type: UInt8, length: Int, decimals: Int)] = [
            ("NAME", 0x43 /* C */, 64, 0),
            ("NOTE", 0x43, 128, 0),
            ("KIND", 0x43, 12, 0),
            ("LEN", 0x4E /* N */, 18, 3),
            ("AREA", 0x4E, 18, 3),
        ]
        let recordLength = 1 + fields.reduce(0) { $0 + $1.length }
        let headerLength = 32 + fields.count * 32 + 1

        var data = Data()
        let now = Date()
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: now)
        data.append(0x03)                                      // dBASE III
        data.append(UInt8(clamping: (parts.year ?? 2000) - 1900))
        data.append(UInt8(clamping: parts.month ?? 1))
        data.append(UInt8(clamping: parts.day ?? 1))
        data.append(littleEndian: Int32(measurements.count))
        data.append(littleEndian: Int16(headerLength))
        data.append(littleEndian: Int16(recordLength))
        data.append(contentsOf: [UInt8](repeating: 0, count: 20))
        for field in fields {
            data.append(contentsOf: fieldDescriptor(field.name, type: field.type, length: field.length, decimals: field.decimals))
        }
        data.append(0x0D)                                      // 头部结束
        for measurement in measurements {
            data.append(0x20)                                  // 未删除
            data.append(dbfText(measurement.exportName, width: fields[0].length))
            data.append(dbfText(measurement.note ?? "", width: fields[1].length))
            data.append(dbfText(measurement.kind.displayName, width: fields[2].length))
            let result = measurement.result
            let length = measurement.kind.isPointLike ? 0 : result.totalLength
            data.append(dbfNumber(length, width: fields[3].length, decimals: fields[3].decimals))
            data.append(dbfNumber(result.area ?? 0, width: fields[4].length, decimals: fields[4].decimals))
        }
        data.append(0x1A)                                      // 文件结束
        return data
    }

    static func fieldDescriptor(_ name: String, type: UInt8, length: Int, decimals: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32)
        for (index, scalar) in name.uppercased().unicodeScalars.prefix(10).enumerated() {
            bytes[index] = UInt8(clamping: Int(scalar.value))
        }
        bytes[11] = type
        bytes[16] = UInt8(clamping: length)
        bytes[17] = UInt8(clamping: decimals)
        return bytes
    }

    /// 字符串按 UTF-8 截断 / 补空格到固定字节数。
    static func dbfText(_ text: String, width: Int) -> Data {
        var bytes = Array(text.utf8.prefix(width))
        if bytes.count < width { bytes.append(contentsOf: [UInt8](repeating: 0x20, count: width - bytes.count)) }
        return Data(bytes)
    }

    static func dbfNumber(_ value: Double, width: Int, decimals: Int) -> Data {
        dbfText(String(format: "%.\(decimals)f", value), width: width)
    }

    /// EPSG:4326 的标准 WKT（ESRI 与 GDAL 都认）。
    static let wgs84WKT = #"GEOGCS["GCS_WGS_1984",DATUM["D_WGS_1984",SPHEROID["WGS_1984",6378137.0,298.257223563]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]]"#
}

// MARK: - 字节序小工具

extension Data {
    mutating func append<T: FixedWidthInteger>(bigEndian value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func append(littleEndian value: Double) {
        var bits = value.bitPattern.littleEndian
        Swift.withUnsafeBytes(of: &bits) { append(contentsOf: $0) }
    }
}
