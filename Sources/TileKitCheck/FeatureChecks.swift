import Foundation
import TileKit

@MainActor
func runFeatureChecks() async throws {
// MARK: - G1：新功能自检

section("G1：新功能自检（流式下载 / zip 索引 / 矢量导入 / 导出 / 概览缓存 / 本地服务）")

do {
    let plan = try TileDownloadPlan(
        bounds: GeoBounds(west: 120.10, south: 30.20, east: 120.32, north: 30.38),
        zoomRange: 12...13
    )
    for range in plan.ranges {
        var streamed: [SlippyTile] = []
        var buffer: [SlippyTile] = []
        var iterator = plan.tileChunks(for: range, chunkSize: 7)
        while let chunk = iterator.next() {
            expect(chunk.count <= 7, "流式分块不应超过块大小")
            buffer.append(contentsOf: chunk)
            if buffer.count >= 7 {
                streamed.append(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        streamed.append(contentsOf: buffer)
        expect(streamed == plan.tiles(for: range), "z\(range.zoom) 流式顺序应与物化顺序一致")
    }
}

do {
    let directory = FileManager.default.temporaryDirectory.appending(path: "euclid-zipindex-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "part.zip")
    try? Data(repeating: 0x41, count: 4096).write(to: file)
    let size = UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    let spans: [String: [ZipDirectorySpan]] = [
        "12/3400": [ZipDirectorySpan(start: 1, end: 2048)],
        "12/3401\tx": [ZipDirectorySpan(start: 2049, end: 4095)],
        "12/3402\n换行": [ZipDirectorySpan(start: 0, end: 0)],
    ]
    ZipIndexCache.save(
        rowSpans: spans,
        entryCount: 3,
        centralDirectorySize: 4096,
        isZip64: false,
        for: file,
        fileSize: size
    )
    let loaded = ZipIndexCache.load(for: file, fileSize: size)
    expect(
        loaded?.rowSpans.count == spans.count && loaded?.entryCount == 3 && loaded?.isZip64 == false,
        "索引应命中并还原表头"
    )
    expect(
        loaded?.rowSpans["12/3401\tx"]?.first?.start == 2049 && loaded?.rowSpans["12/3402\n换行"]?.first?.end == 0,
        "含制表符 / 换行的行名应原样还原"
    )
    expect(ZipIndexCache.load(for: file, fileSize: size + 1) == nil, "文件大小变了应不命中")

    let sample = GeoMeasurement(
        kind: .distance,
        points: [
            GeoCoordinate(longitude: 120, latitude: 30),
            GeoCoordinate(longitude: 120.001, latitude: 30),
        ],
        name: "道路"
    )
    let dxf = MeasurementCADExporter.dxf([sample])
    expect(dxf.contains("SECTION") && dxf.contains("ENTITIES") && dxf.contains("EOF"), "DXF 应含标准段")
    expect(MeasurementCADExporter.pair(1, "注记").contains("\\U+6CE8"), "非 ASCII 应转成 \\U+XXXX")

    let shapefile = MeasurementCADExporter.shapefile([sample], baseName: "自检")
    for suffix in ["_line.shp", "_line.shx", "_line.dbf", "_line.prj", "_line.cpg"] {
        let match = shapefile.first { $0.name.hasSuffix(suffix) }
        expect(match?.name == "自检\(suffix)" && !(match?.data.isEmpty ?? true), "Shapefile 应含 \(suffix)")
    }
    let shp = shapefile.first { $0.name.hasSuffix("_line.shp") }?.data
    expect(shp?.count ?? 0 >= 100, ".shp 应含 100 字节头与记录")

    let geojson = #"{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"name":"干道"},"geometry":{"type":"LineString","coordinates":[[120,30],[120.001,30.001]]}}]}"#
    let jsonURL = directory.appending(path: "sample.geojson")
    try? Data(geojson.utf8).write(to: jsonURL)
    let imported = try? VectorImporter.measurements(from: jsonURL)
    expect(imported?.count == 1 && imported?.first?.kind == .distance, "GeoJSON 应导入为折线")

    let kml = "<kml><Document><Placemark><name>测区</name><Polygon><outerBoundaryIs><LinearRing><coordinates>120,30 120.01,30 120.01,30.01 120,30.01 120,30</coordinates></LinearRing></outerBoundaryIs></Polygon></Placemark></Document></kml>"
    let kmlURL = directory.appending(path: "sample.kml")
    try? Data(kml.utf8).write(to: kmlURL)
    let parsedKML = try? VectorImporter.measurements(from: kmlURL)
    expect(parsedKML?.count == 1 && parsedKML?.first?.kind == .area, "KML 外环应导入为面积")

    let dense = (0..<5000).map { GeoCoordinate(longitude: 120 + Double($0) * 1e-6, latitude: 30) }
    let simplified = VectorImporter.simplified(dense, limit: 100)
    expect(
        simplified.count == 100 && simplified.first == dense.first && simplified.last == dense.last,
        "抽稀应保留首尾"
    )

    let key = RasterOverviewCache.key(fileURL: file, tileSize: 256)
    expect(key.contains("part.zip") && key.hasSuffix("|256"), "概览缓存键应按 路径|大小|时间|尺寸 拼出")
    expect(RasterOverviewCache.fileName(for: key).count == 16, "概览缓存文件名应是定长十六进制")

    let root = FileManager.default.temporaryDirectory.appending(path: "euclid-server-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root.appending(path: "3/4"), withIntermediateDirectories: true)
    try? Data([0x89, 0x50]).write(to: root.appending(path: "3/4/5.png"))
    defer { try? FileManager.default.removeItem(at: root) }
    if let json = LocalTileServer.tileJSON(
        root: root,
        rootName: "自检瓦片",
        port: 8766,
        metadata: LocalTileServer.RootMetadata()
    ), let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] {
        expect(
            object["tilejson"] as? String == "2.2.0"
                && (object["tiles"] as? [String])?.first?.contains("{z}/{x}/{y}") == true,
            "TileJSON 应给出标准模板"
        )
    } else {
        expect(false, "TileJSON 应能序列化")
    }
    let html = LocalTileServer.previewHTML(rootName: "自检<瓦片>", start: (zoom: 3, x: 4, y: 5), tileSize: 256)
    expect(html.contains("<title>预览 · 自检&lt;瓦片&gt;</title>"), "预览页标题应转义 HTML")
}


}
