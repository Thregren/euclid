import Foundation

/// 导入矢量数据时可能出的错。
public enum VectorImportError: Error, LocalizedError, Sendable {
    case unreadable
    case unsupportedFormat
    case empty

    public var errorDescription: String? {
        switch self {
        case .unreadable: return "文件读不出来（可能不是文本格式）"
        case .unsupportedFormat: return "不认识的矢量格式（支持 GeoJSON 与 KML）"
        case .empty: return "文件里没有可导入的图形"
        }
    }
}

/// 把 GeoJSON / KML 读成测量（等于「矢量叠加层」）。
///
/// 复用测量这套模型是有意的：它们本来就有样式、存档、导出与画布渲染，
/// 导入的图形因此天然能跟着数据集存档、也能再导出去 —— 不为了「叠加」再维护第二套图形模型。
public enum VectorImporter {
    /// 上限：一次导入这么多图形就打住（免得一份几十万要素的文件把界面按死）。
    public static let defaultFeatureLimit = 2000
    /// 单个图形的顶点上限（超出就抽稀，保留首尾与均匀采样）。
    public static let defaultPointLimit = 20000

    /// 按扩展名（内容嗅探兜底）选择解析器。
    public static func measurements(
        from url: URL,
        featureLimit: Int = defaultFeatureLimit
    ) throws -> [GeoMeasurement] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else {
            throw VectorImportError.unreadable
        }
        let ext = url.pathExtension.lowercased()
        let looksLikeXML = firstNonSpace(in: data) == UInt8(ascii: "<")
        let result: [GeoMeasurement]
        if ext == "kml" || ext == "xml" || (ext != "json" && ext != "geojson" && looksLikeXML) {
            result = try parseKML(data, featureLimit: featureLimit)
        } else {
            result = try parseGeoJSON(data, featureLimit: featureLimit)
        }
        guard !result.isEmpty else { throw VectorImportError.empty }
        return result
    }

    private static func firstNonSpace(in data: Data) -> UInt8? {
        for byte in data.prefix(4096) where byte != 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D {
            return byte
        }
        return nil
    }

    // MARK: - GeoJSON

    static func parseGeoJSON(_ data: Data, featureLimit: Int) throws -> [GeoMeasurement] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VectorImportError.unsupportedFormat
        }
        var features: [[String: Any]] = []
        if let list = root["features"] as? [[String: Any]] {
            features = list
        } else if root["type"] as? String != nil {
            // 单个 Geometry / Feature 也照收。
            features = [root]
        }
        var result: [GeoMeasurement] = []
        for feature in features {
            if result.count >= featureLimit { break }
            let properties = feature["properties"] as? [String: Any] ?? [:]
            let name = (properties["name"] as? String) ?? (properties["title"] as? String)
            let geometry = (feature["geometry"] as? [String: Any]) ?? feature
            if let measurement = measurement(fromGeometry: geometry, name: name) {
                result.append(measurement)
            }
        }
        return result
    }

    private static func measurement(fromGeometry geometry: [String: Any], name: String?) -> GeoMeasurement? {
        guard let type = geometry["type"] as? String else { return nil }
        let coordinates = geometry["coordinates"]
        switch type {
        case "Point":
            guard let position = position(from: coordinates) else { return nil }
            return make(kind: .point, points: [position], name: name)
        case "MultiPoint":
            guard let list = coordinates as? [Any],
                  let first = list.compactMap(position(from:)).first else { return nil }
            return make(kind: .point, points: [first], name: name)
        case "LineString":
            guard let list = coordinates as? [Any] else { return nil }
            let points = list.compactMap(position(from:))
            guard points.count >= 2 else { return nil }
            return make(kind: .distance, points: points, name: name)
        case "MultiLineString", "Polygon":
            // 多段线取最长的那一段；多边形取点最多的那个环。
            guard let list = coordinates as? [Any] else { return nil }
            let rings = list.compactMap { $0 as? [Any] }.map { $0.compactMap(position(from:)) }
            let kind: MeasurementKind = type == "Polygon" ? .area : .distance
            let minimum = kind == .area ? 3 : 2
            guard let ring = rings.filter({ $0.count >= minimum }).max(by: { $0.count < $1.count }) else {
                return nil
            }
            return make(kind: kind, points: ring, name: name)
        case "MultiPolygon":
            guard let list = coordinates as? [Any] else { return nil }
            let rings = list.compactMap { $0 as? [Any] }
                .compactMap { $0.first as? [Any] }
                .map { $0.compactMap(position(from:)) }
            guard let ring = rings.filter({ $0.count >= 3 }).max(by: { $0.count < $1.count }) else { return nil }
            return make(kind: .area, points: ring, name: name)
        case "GeometryCollection":
            guard let list = geometry["geometries"] as? [[String: Any]] else { return nil }
            for item in list {
                if let measurement = measurement(fromGeometry: item, name: name) { return measurement }
            }
            return nil
        default:
            return nil
        }
    }

    /// GeoJSON 坐标：`[经度, 纬度, 高度]`（高度忽略）。
    private static func position(from value: Any?) -> GeoCoordinate? {
        guard let list = value as? [Any], list.count >= 2,
              let longitude = number(list[0]), let latitude = number(list[1]),
              longitude.isFinite, latitude.isFinite,
              (-180...180).contains(longitude), (-90...90).contains(latitude) else { return nil }
        return GeoCoordinate(longitude: longitude, latitude: latitude)
    }

    private static func number(_ value: Any) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func make(kind: MeasurementKind, points: [GeoCoordinate], name: String?) -> GeoMeasurement {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return GeoMeasurement(
            kind: kind,
            points: simplified(points, limit: defaultPointLimit),
            name: (trimmed?.isEmpty == false) ? trimmed : nil
        )
    }

    /// 顶点太多就抽稀：首尾一定保留，其余按等间隔取，形状还在、内存不至于爆。
    package static func simplified(_ points: [GeoCoordinate], limit: Int) -> [GeoCoordinate] {
        guard points.count > limit, limit >= 2 else { return points }
        var result: [GeoCoordinate] = []
        result.reserveCapacity(limit)
        let step = Double(points.count - 1) / Double(limit - 1)
        for index in 0..<limit {
            let position = Int((Double(index) * step).rounded())
            result.append(points[min(position, points.count - 1)])
        }
        return result
    }

    // MARK: - KML

    static func parseKML(_ data: Data, featureLimit: Int) throws -> [GeoMeasurement] {
        let parser = XMLParser(data: data)
        let delegate = KMLDelegate(featureLimit: featureLimit)
        parser.delegate = delegate
        // 不关命名空间处理：前缀写法（`kml:coordinates`）也要认。
        guard parser.parse() else { throw VectorImportError.unsupportedFormat }
        return delegate.measurements
    }

    /// KML 的解析器：只关心 `<Placemark>` 里的名字与坐标串。
    ///
    /// 坐标在 KML 里是一整段文本（`经度,纬度[,高度]` 用空白分隔），
    /// 因此按「进入 coordinates 元素 → 攒文本 → 出元素时收尾」处理。
    private final class KMLDelegate: NSObject, XMLParserDelegate {
        let featureLimit: Int
        private(set) var measurements: [GeoMeasurement] = []

        private var insideCoordinates = false
        private var coordinatesText = ""
        private var insideName = false
        private var placemarkName = ""
        private var pendingOuter = false

        init(featureLimit: Int) {
            self.featureLimit = featureLimit
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            switch elementName.lowercased() {
            case "placemark":
                placemarkName = ""
                pendingOuter = false
            case "name":
                insideName = true
            case "outerboundaryis":
                pendingOuter = true
            case "coordinates":
                insideCoordinates = true
                coordinatesText = ""
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if insideCoordinates {
                coordinatesText += string
            } else if insideName {
                placemarkName += string
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            switch elementName.lowercased() {
            case "name":
                insideName = false
            case "coordinates":
                insideCoordinates = false
                let points = Self.points(from: coordinatesText)
                coordinatesText = ""
                guard !points.isEmpty else { return }
                // 外环（多边形的边界）按面积收；其余按折线 / 点收。
                let kind: MeasurementKind = pendingOuter ? .area : (points.count >= 2 ? .distance : .point)
                append(kind: kind, points: points)
            case "outerboundaryis":
                pendingOuter = false
            default:
                break
            }
        }

        private func append(kind: MeasurementKind, points: [GeoCoordinate]) {
            guard measurements.count < featureLimit else { return }
            let minimum = kind == .area ? 3 : (kind == .distance ? 2 : 1)
            guard points.count >= minimum else { return }
            let trimmed = placemarkName.trimmingCharacters(in: .whitespacesAndNewlines)
            measurements.append(GeoMeasurement(
                kind: kind,
                points: VectorImporter.simplified(points, limit: VectorImporter.defaultPointLimit),
                name: trimmed.isEmpty ? nil : trimmed
            ))
        }

        /// `经度,纬度[,高度]` 用空白分隔。
        static func points(from text: String) -> [GeoCoordinate] {
            var result: [GeoCoordinate] = []
            for chunk in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
                let parts = chunk.split(separator: ",")
                guard parts.count >= 2,
                      let longitude = Double(parts[0]), let latitude = Double(parts[1]),
                      longitude.isFinite, latitude.isFinite,
                      (-180...180).contains(longitude), (-90...90).contains(latitude) else { continue }
                result.append(GeoCoordinate(longitude: longitude, latitude: latitude))
            }
            return result
        }
    }
}
