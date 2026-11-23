import Foundation

public enum VectorImportError: Error, LocalizedError, Sendable {
    case unreadable
    case unsupportedFormat
    case empty
    case limitExceeded(String)
    case unsupportedGeometry(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable: return "文件读不出来（可能不是文本格式）"
        case .unsupportedFormat: return "不认识的矢量格式（支持 GeoJSON 与 KML）"
        case .empty: return "文件里没有可导入的图形"
        case .limitExceeded(let reason): return "矢量文件超过安全上限：\(reason)"
        case .unsupportedGeometry(let reason): return reason
        }
    }
}

/// Imports bounded vector geometry into the existing measurement model.
/// Unsupported holes fail explicitly because GeoMeasurement cannot represent their area correctly.
public enum VectorImporter {
    public static let defaultFeatureLimit = 2000
    public static let defaultPointLimit = 20000
    #if os(iOS)
    package static let maximumInputBytes = 8 << 20
    #else
    package static let maximumInputBytes = 32 << 20
    #endif
    package static let maximumInputPoints = 250_000
    package static let maximumGeometryPoints = 100_000
    private static let maximumCoordinateTextBytes = 8 << 20
    private static let maximumNameBytes = 64 << 10

    public static func measurements(from url: URL, featureLimit: Int = defaultFeatureLimit) throws -> [GeoMeasurement] {
        try Task.checkCancellation()
        guard url.isFileURL, featureLimit > 0 else { throw VectorImportError.unreadable }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw VectorImportError.unreadable }
        defer { try? handle.close() }
        var data = Data()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: min(1 << 20, maximumInputBytes + 1 - data.count)) ?? Data()
            guard !chunk.isEmpty else { break }
            data.append(chunk)
            guard data.count <= maximumInputBytes else { throw VectorImportError.limitExceeded("文件字节数") }
        }
        guard !data.isEmpty else { throw VectorImportError.unreadable }
        let ext = url.pathExtension.lowercased()
        let looksLikeXML = data.prefix(4096).first { ![0x20, 0x09, 0x0A, 0x0D].contains($0) } == 0x3C
        let limit = min(featureLimit, defaultFeatureLimit)
        let result: [GeoMeasurement]
        if ext == "kml" || ext == "xml" || (ext != "json" && ext != "geojson" && looksLikeXML) {
            result = try parseKML(data, featureLimit: limit)
        } else {
            result = try parseGeoJSON(data, featureLimit: limit)
        }
        guard !result.isEmpty else { throw VectorImportError.empty }
        return result
    }

    private struct Budget {
        var points = maximumInputPoints
        var geometries = 10_000
        mutating func takePoints(_ count: Int) throws {
            guard count <= maximumGeometryPoints, count <= points else { throw VectorImportError.limitExceeded("坐标点数量") }
            points -= count
        }
        mutating func enter(depth: Int) throws {
            try Task.checkCancellation()
            guard depth <= 64, geometries > 0 else { throw VectorImportError.limitExceeded("几何数量或嵌套层数") }
            geometries -= 1
        }
    }

    static func parseGeoJSON(_ data: Data, featureLimit: Int) throws -> [GeoMeasurement] {
        guard data.count <= maximumInputBytes else { throw VectorImportError.limitExceeded("文件字节数") }
        try Task.checkCancellation()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VectorImportError.unsupportedFormat
        }
        try Task.checkCancellation()
        let features = root["features"] as? [[String: Any]] ?? [root]
        guard features.count <= 10_000 else { throw VectorImportError.limitExceeded("要素数量") }
        var result: [GeoMeasurement] = []
        var budget = Budget()
        for feature in features {
            let properties = feature["properties"] as? [String: Any] ?? [:]
            let name = properties["name"] as? String ?? properties["title"] as? String
            let geometry = feature["geometry"] as? [String: Any] ?? feature
            try appendGeometry(geometry, name: name, depth: 0, budget: &budget, result: &result, featureLimit: featureLimit)
        }
        return result
    }

    private static func appendGeometry(_ geometry: [String: Any], name: String?, depth: Int,
                                       budget: inout Budget, result: inout [GeoMeasurement], featureLimit: Int) throws {
        try budget.enter(depth: depth)
        guard let type = geometry["type"] as? String else { return }
        func append(_ kind: MeasurementKind, _ points: [GeoCoordinate]) throws {
            let minimum = kind == .area ? 3 : kind == .distance ? 2 : 1
            guard points.count >= minimum else { return }
            guard result.count < featureLimit else { throw VectorImportError.limitExceeded("可导入图形数量") }
            guard (name?.utf8.count ?? 0) <= maximumNameBytes else { throw VectorImportError.limitExceeded("图形名称长度") }
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(GeoMeasurement(kind: kind, points: simplified(points, limit: defaultPointLimit),
                                         name: trimmed?.isEmpty == false ? trimmed : nil))
        }
        let coordinates = geometry["coordinates"]
        switch type {
        case "Point":
            try budget.takePoints(1)
            if let position = position(from: coordinates) { try append(.point, [position]) }
        case "MultiPoint":
            for point in try positions(coordinates, budget: &budget) { try append(.point, [point]) }
        case "LineString":
            try append(.distance, positions(coordinates, budget: &budget))
        case "MultiLineString":
            guard let lines = coordinates as? [Any] else { return }
            for line in lines { try budget.enter(depth: depth); try append(.distance, positions(line, budget: &budget)) }
        case "Polygon":
            try append(.area, polygon(coordinates, budget: &budget))
        case "MultiPolygon":
            guard let polygons = coordinates as? [Any] else { return }
            for item in polygons { try budget.enter(depth: depth); try append(.area, polygon(item, budget: &budget)) }
        case "GeometryCollection":
            guard let geometries = geometry["geometries"] as? [[String: Any]] else { return }
            for item in geometries {
                try appendGeometry(item, name: name, depth: depth + 1, budget: &budget, result: &result, featureLimit: featureLimit)
            }
        default: break
        }
    }

    private static func polygon(_ value: Any?, budget: inout Budget) throws -> [GeoCoordinate] {
        guard let rings = value as? [Any], let outer = rings.first else { return [] }
        guard rings.count == 1 else {
            throw VectorImportError.unsupportedGeometry("暂不支持带内洞的多边形；未导入，以免产生错误面积")
        }
        // GeoJSON specifies the first ring as the exterior, irrespective of vertex counts.
        return try positions(outer, budget: &budget)
    }

    private static func positions(_ value: Any?, budget: inout Budget) throws -> [GeoCoordinate] {
        guard let list = value as? [Any] else { return [] }
        try budget.takePoints(list.count)
        var result: [GeoCoordinate] = []
        result.reserveCapacity(min(list.count, maximumGeometryPoints))
        for (index, item) in list.enumerated() {
            if index % 1024 == 0 { try Task.checkCancellation() }
            guard let position = position(from: item) else { throw VectorImportError.unsupportedGeometry("图形含无效经纬度，未导入") }
            result.append(position)
        }
        return result
    }

    private static func position(from value: Any?) -> GeoCoordinate? {
        guard let list = value as? [Any], list.count >= 2,
              let longitude = number(list[0]), let latitude = number(list[1]),
              longitude.isFinite, latitude.isFinite,
              (-180...180).contains(longitude), (-90...90).contains(latitude) else { return nil }
        return GeoCoordinate(longitude: longitude, latitude: latitude)
    }

    private static func number(_ value: Any) -> Double? {
        if let value = value as? NSNumber {
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            return value.doubleValue
        }
        if let value = value as? String { return Double(value) }
        return nil
    }

    package static func simplified(_ points: [GeoCoordinate], limit: Int) -> [GeoCoordinate] {
        guard points.count > limit, limit >= 2 else { return points }
        let step = Double(points.count - 1) / Double(limit - 1)
        return (0..<limit).map { points[min(Int((Double($0) * step).rounded()), points.count - 1)] }
    }

    static func parseKML(_ data: Data, featureLimit: Int) throws -> [GeoMeasurement] {
        guard data.count <= maximumInputBytes else { throw VectorImportError.limitExceeded("文件字节数") }
        try Task.checkCancellation()
        let parser = XMLParser(data: data)
        let delegate = KMLDelegate(featureLimit: featureLimit)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        let parsed = parser.parse()
        if let failure = delegate.failure { throw failure }
        try Task.checkCancellation()
        guard parsed else { throw VectorImportError.unsupportedFormat }
        return delegate.measurements
    }

    private final class KMLDelegate: NSObject, XMLParserDelegate {
        let featureLimit: Int
        var measurements: [GeoMeasurement] = []
        var failure: Error?
        private var budget = Budget()
        private var insideCoordinates = false
        private var coordinatesText = ""
        private var coordinateBytes = 0
        private var insideName = false
        private var placemarkName = ""
        private var nameBytes = 0
        private var pendingOuter = false
        private var placemarkDepth = 0
        private var depth = 0

        init(featureLimit: Int) { self.featureLimit = featureLimit }
        private func perform(_ parser: XMLParser, _ work: () throws -> Void) {
            guard failure == nil else { return }
            do { try Task.checkCancellation(); try work() }
            catch { failure = error; parser.abortParsing() }
        }
        private func recognized(_ uri: String?) -> Bool {
            uri == nil || uri == "" || uri == "http://www.opengis.net/kml/2.2" || uri == "http://earth.google.com/kml/2.0" || uri == "http://earth.google.com/kml/2.1"
        }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            perform(parser) {
                depth += 1
                guard depth <= 64 else { throw VectorImportError.limitExceeded("XML 嵌套层数") }
                guard recognized(namespaceURI) else { return }
                switch elementName.lowercased() {
                case "placemark":
                    try budget.enter(depth: depth)
                    placemarkDepth = depth; placemarkName = ""; nameBytes = 0; pendingOuter = false
                case "name" where placemarkDepth > 0: insideName = true
                case "outerboundaryis" where placemarkDepth > 0: pendingOuter = true
                case "innerboundaryis" where placemarkDepth > 0:
                    throw VectorImportError.unsupportedGeometry("暂不支持带内洞的多边形；未导入，以免产生错误面积")
                case "coordinates" where placemarkDepth > 0:
                    insideCoordinates = true; coordinatesText = ""; coordinateBytes = 0
                default: break
                }
            }
        }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard let text = String(data: CDATABlock, encoding: .utf8) else {
                failure = VectorImportError.unsupportedFormat; parser.abortParsing(); return
            }
            self.parser(parser, foundCharacters: text)
        }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            failure = VectorImportError.unsupportedFormat; parser.abortParsing()
        }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
                    publicID: String?, systemID: String?) {
            failure = VectorImportError.unsupportedFormat; parser.abortParsing()
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            perform(parser) {
                if insideCoordinates {
                    coordinateBytes += string.utf8.count
                    guard coordinateBytes <= maximumCoordinateTextBytes else { throw VectorImportError.limitExceeded("坐标文本长度") }
                    coordinatesText += string
                } else if insideName {
                    nameBytes += string.utf8.count
                    guard nameBytes <= maximumNameBytes else { throw VectorImportError.limitExceeded("图形名称长度") }
                    placemarkName += string
                }
            }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            perform(parser) {
                defer { depth -= 1 }
                guard recognized(namespaceURI) else { return }
                switch elementName.lowercased() {
                case "name": insideName = false
                case "placemark": placemarkDepth = 0
                case "outerboundaryis": pendingOuter = false
                case "coordinates" where insideCoordinates:
                    insideCoordinates = false
                    let points = try parsePoints(coordinatesText)
                    coordinatesText = ""
                    let kind: MeasurementKind = pendingOuter ? .area : points.count >= 2 ? .distance : .point
                    let minimum = kind == .area ? 3 : kind == .distance ? 2 : 1
                    guard points.count >= minimum else { return }
                    guard measurements.count < featureLimit else { throw VectorImportError.limitExceeded("可导入图形数量") }
                    let name = placemarkName.trimmingCharacters(in: .whitespacesAndNewlines)
                    measurements.append(GeoMeasurement(kind: kind, points: simplified(points, limit: defaultPointLimit),
                                                       name: name.isEmpty ? nil : name))
                default: break
                }
            }
        }
        private func parsePoints(_ text: String) throws -> [GeoCoordinate] {
            var result: [GeoCoordinate] = []
            // Stream tokens rather than creating an unbounded array of substrings first.
            var start = text.startIndex
            var index = start
            while index < text.endIndex {
                let end = text.index(after: index)
                if text[index].isWhitespace {
                    if start < index { try appendPoint(text[start..<index], to: &result) }
                    start = end
                }
                index = end
            }
            if start < text.endIndex { try appendPoint(text[start...], to: &result) }
            return result
        }
        private func appendPoint(_ text: Substring, to result: inout [GeoCoordinate]) throws {
            if result.count % 1024 == 0 { try Task.checkCancellation() }
            guard result.count < maximumGeometryPoints else { throw VectorImportError.limitExceeded("单个图形坐标点数量") }
            try budget.takePoints(1)
            let values = text.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            guard values.count >= 2, let longitude = Double(values[0]), let latitude = Double(values[1]),
                  longitude.isFinite, latitude.isFinite,
                  (-180...180).contains(longitude), (-90...90).contains(latitude) else {
                throw VectorImportError.unsupportedGeometry("图形含无效经纬度，未导入")
            }
            result.append(GeoCoordinate(longitude: longitude, latitude: latitude))
        }
    }
}
