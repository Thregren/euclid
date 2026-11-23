import Foundation
import TileKit

@MainActor
func runParserSafetyChecks() async throws {
    section("解析安全：恶意长度、整数边界、矢量几何与输入预算")
    let root = FileManager.default.temporaryDirectory.appending(path: "euclid-parser-safety-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    func write(_ name: String, _ data: Data) throws -> URL {
        let url = root.appending(path: name)
        try data.write(to: url)
        return url
    }
    func rejectsTIFF(_ name: String, _ bytes: Data) throws {
        let url = try write(name, bytes)
        do { _ = try TIFFReader.parse(url: url); expect(false, "TIFF 应安全拒绝 \(name)") }
        catch { expect(true, "TIFF 应安全拒绝 \(name)") }
        do { _ = try RasterLoader.load(url: url); expect(false, "RasterLoader 不应绕过 TIFF 安全拒绝 \(name)") }
        catch { expect(true, "RasterLoader 不应绕过 TIFF 安全拒绝 \(name)") }
    }
    var bigHeader = Data([0x49, 0x49, 43, 0, 8, 0, 0, 0])
    parserAppendLE(UInt64.max, to: &bigHeader)
    try rejectsTIFF("overflow-offset.tif", bigHeader)
    var nan = Data(); parserAppendLE(Double.nan.bitPattern, to: &nan)
    try rejectsTIFF("nan-width.tif", parserClassicTIFF([(256, 12, 1, 38), (257, 4, 1, 1)], payload: nan))
    try rejectsTIFF("huge-channels.tif", parserClassicTIFF([(256, 4, 1, 1), (257, 4, 1, 1), (277, 4, 1, .max)]))
    try rejectsTIFF("huge-count.tif", parserClassicTIFF([(256, 4, 1, 1), (257, 4, 1, 1),
                                                       (273, 4, 1, 74), (279, 4, 1, .max), (277, 4, 1, 1)], payload: Data([0])))
    try rejectsTIFF("truncated-ifd.tif", Data(parserClassicTIFF([(256, 4, 1, 1), (257, 4, 1, 1)]).dropLast(3)))
    try rejectsTIFF("invalid-palette.tif", parserClassicTIFF([(256, 4, 1, 1), (257, 4, 1, 1),
                                                            (320, 11, 1, Float.nan.bitPattern)]))
    let multiBand = try write("multiband.tif", parserClassicTIFF([(256, 4, 1, 1), (257, 4, 1, 1),
                                                               (277, 4, 1, 16), (273, 4, 1, 74), (279, 4, 1, 16)],
                                                              payload: Data(repeating: 0x7F, count: 16)))
    expect((try? TIFFReader.parse(url: multiBand))?.pixelWidth == 1, "合法 16 波段 TIFF 应保留支持")
    let source = try TIFFSourceFile(url: multiBand)
    defer { source.close() }
    expect(source.read(offset: 0, count: Int.max) == nil, "读取巨大长度应在分配前拒绝")
    expect(source.read(offset: 0, count: 1024)?.count == 90, "有限读取应以文件实际长度为界")
    expect(TIFFLimits.chunkBytes(width: 512, height: 512, samples: 16, bits: 32) != nil,
           "常见多波段瓦片应符合解码预算")
    expect(TIFFLimits.chunkBytes(width: 8192, height: 8192, samples: 1024, bits: 64) == nil,
           "像素数有效但总字节过大的块应拒绝")

    var zip64 = Data()
    parserAppendLE(UInt32(0x06064B50), to: &zip64); parserAppendLE(UInt64(44), to: &zip64)
    parserAppendLE(UInt16(45), to: &zip64); parserAppendLE(UInt16(45), to: &zip64)
    parserAppendLE(UInt32(0), to: &zip64); parserAppendLE(UInt32(0), to: &zip64)
    parserAppendLE(UInt64.max, to: &zip64); parserAppendLE(UInt64.max, to: &zip64)
    parserAppendLE(UInt64(0), to: &zip64); parserAppendLE(UInt64(0), to: &zip64)
    parserAppendLE(UInt32(0x07064B50), to: &zip64); parserAppendLE(UInt32(0), to: &zip64)
    parserAppendLE(UInt64(0), to: &zip64); parserAppendLE(UInt32(1), to: &zip64)
    parserAppendLE(UInt32(0x06054B50), to: &zip64); parserAppendLE(UInt32(0), to: &zip64)
    parserAppendLE(UInt16.max, to: &zip64); parserAppendLE(UInt16.max, to: &zip64)
    parserAppendLE(UInt32.max, to: &zip64); parserAppendLE(UInt32.max, to: &zip64); parserAppendLE(UInt16(0), to: &zip64)
    let oversizedZip = try write("overflow-count.zip", zip64)
    do { _ = try ZipArchive(url: oversizedZip); expect(false, "ZIP64 UInt64.max 条目数应拒绝") }
    catch { expect(true, "ZIP64 UInt64.max 条目数应拒绝") }

    let manifestRoot = root.appending(path: "manifest")
    try FileManager.default.createDirectory(at: manifestRoot, withIntermediateDirectories: true)
    let emptyZip = try ZIP.stored([])
    try emptyZip.write(to: manifestRoot.appending(path: "z1_a.zip"))
    try emptyZip.write(to: manifestRoot.appending(path: "z1_b.zip"))
    let parts: [String: Any] = ["z1_a.zip": ["zoom": 1, "rows": [Int.min, Int.max], "tiles": Int.max],
                                "z1_b.zip": ["zoom": 1, "rows": [0, 1], "tiles": Int.max]]
    try JSONSerialization.data(withJSONObject: ["parts": parts]).write(to: manifestRoot.appending(path: "manifest.json"))
    let manifestDataset = ZipDatasetLocator.makeDataset(at: manifestRoot)
    expect(manifestDataset == nil || manifestDataset?.zoomRange == (1...1),
           "恶意 manifest 行范围和累计数量应安全拒绝或忽略，不能溢出")

    func vector(_ name: String, _ text: String, limit: Int = VectorImporter.defaultFeatureLimit) throws -> [GeoMeasurement] {
        try VectorImporter.measurements(from: write(name, Data(text.utf8)), featureLimit: limit)
    }
    let prefixed = "<kml:kml xmlns:kml=\"http://www.opengis.net/kml/2.2\"><kml:Placemark><kml:Point><kml:coordinates>118,25</kml:coordinates></kml:Point></kml:Placemark></kml:kml>"
    let prefixedPoints = try vector("prefixed.kml", prefixed).first?.points
    expect(prefixedPoints == [GeoCoordinate(longitude: 118, latitude: 25)],
           "KML 前缀命名空间应正确导入")
    let simple = #"{"type":"Polygon","coordinates":[[[0,0],[2,0],[2,2],[0,2],[0,0]]]}"#
    let outerFirst = try vector("outer.geojson", simple).first?.points.first
    expect(outerFirst == GeoCoordinate(longitude: 0, latitude: 0),
           "简单 Polygon 应使用第一条外环")
    let hole = #"{"type":"Polygon","coordinates":[[[0,0],[2,0],[2,2],[0,2],[0,0]],[[0.5,0.5],[0.5,1.5],[1,1.5],[1.5,1.5],[1.5,0.5],[0.5,0.5]]]}"#
    do { _ = try vector("hole.geojson", hole); expect(false, "含洞 Polygon 应明确拒绝，不能把洞当外环") }
    catch VectorImportError.unsupportedGeometry(_) { expect(true, "含洞 Polygon 应明确拒绝，不能把洞当外环") }
    let multi = #"{"type":"MultiPoint","coordinates":[[118,25],[119,26]]}"#
    let importedMulti = try vector("multi.geojson", multi)
    expect(importedMulti.count == 2, "MultiPoint 的各点应完整导入")
    do { _ = try vector("limit.geojson", multi, limit: 1); expect(false, "超出图形预算应明确报错") }
    catch VectorImportError.limitExceeded(_) { expect(true, "超出图形预算应明确报错") }
    let dense = "{\"type\":\"LineString\",\"coordinates\":[" + Array(repeating: "[118,25]", count: VectorImporter.maximumGeometryPoints + 1).joined(separator: ",") + "]}"
    do { _ = try vector("dense.geojson", dense); expect(false, "原始顶点预算应在创建坐标数组前生效") }
    catch VectorImportError.limitExceeded(_) { expect(true, "原始顶点预算应在创建坐标数组前生效") }
    let hugeURL = try write("huge.geojson", Data([0x7B]))
    let hugeHandle = try FileHandle(forWritingTo: hugeURL)
    try hugeHandle.truncate(atOffset: UInt64(VectorImporter.maximumInputBytes + 1)); try hugeHandle.close()
    do { _ = try VectorImporter.measurements(from: hugeURL); expect(false, "矢量字节预算应拒绝超限文件") }
    catch VectorImportError.limitExceeded(_) { expect(true, "矢量字节预算应拒绝超限文件") }
    let cancelled = Task { try TIFFReader.parse(url: multiBand) }
    cancelled.cancel()
    do { _ = try await cancelled.value; expect(false, "取消后的 TIFF 解析应停止") }
    catch is CancellationError { expect(true, "取消后的 TIFF 解析应停止") }
    let vectorURL = try write("cancel.geojson", Data(multi.utf8))
    let cancelledVector = Task { try VectorImporter.measurements(from: vectorURL) }
    cancelledVector.cancel()
    do { _ = try await cancelledVector.value; expect(false, "取消后的矢量解析应停止") }
    catch is CancellationError { expect(true, "取消后的矢量解析应停止") }
}

private func parserAppendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var value = value.littleEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}

private func parserClassicTIFF(_ entries: [(UInt16, UInt16, UInt32, UInt32)], payload: Data = Data()) -> Data {
    var data = Data([0x49, 0x49, 42, 0, 8, 0, 0, 0])
    parserAppendLE(UInt16(entries.count), to: &data)
    for (tag, type, count, value) in entries {
        parserAppendLE(tag, to: &data); parserAppendLE(type, to: &data)
        parserAppendLE(count, to: &data); parserAppendLE(value, to: &data)
    }
    parserAppendLE(UInt32(0), to: &data)
    data.append(payload)
    return data
}
