import CoreGraphics
import Foundation
import TileKit

/// Small, self-contained GeoTIFFs with analytically known ground fields.
private func writeGeospatialFixture(to url: URL, width: Int = 16, height: Int = 16,
                                    matrix: [Double], epsg: UInt16? = 3857,
                                    value: (Int, Int) -> Float) throws {
    func integer<T: FixedWidthInteger>(_ value: T) -> Data {
        var little = value.littleEndian
        return withUnsafeBytes(of: &little) { Data($0) }
    }
    struct Tag { let id: UInt16; let type: UInt16; let count: UInt32; var bytes: Data }
    var tags = [
        Tag(id: 256, type: 4, count: 1, bytes: integer(UInt32(width))),
        Tag(id: 257, type: 4, count: 1, bytes: integer(UInt32(height))),
        Tag(id: 258, type: 3, count: 1, bytes: integer(UInt16(32))),
        Tag(id: 259, type: 3, count: 1, bytes: integer(UInt16(1))),
        Tag(id: 262, type: 3, count: 1, bytes: integer(UInt16(1))),
        Tag(id: 273, type: 4, count: 1, bytes: integer(UInt32(0))),
        Tag(id: 277, type: 3, count: 1, bytes: integer(UInt16(1))),
        Tag(id: 278, type: 4, count: 1, bytes: integer(UInt32(height))),
        Tag(id: 279, type: 4, count: 1, bytes: integer(UInt32(width * height * 4))),
        Tag(id: 339, type: 3, count: 1, bytes: integer(UInt16(3))),
    ]
    if let epsg {
        var transform = Data()
        for element in matrix { transform.append(integer(element.bitPattern)) }
        tags.append(Tag(id: 34264, type: 12, count: 16, bytes: transform))
        let keys: [UInt16] = [1, 1, 0, 3, 1024, 0, 1, epsg == 4326 ? 2 : 1,
                              1025, 0, 1, 1, epsg == 4326 ? 2048 : 3072, 0, 1, epsg]
        var directory = Data()
        for key in keys { directory.append(integer(key)) }
        tags.append(Tag(id: 34735, type: 3, count: UInt32(keys.count), bytes: directory))
    }
    tags.sort { $0.id < $1.id }
    let fixedBytes = 8 + 2 + 12 * tags.count + 4
    let extraBytes = tags.reduce(0) { $0 + ($1.bytes.count > 4 ? $1.bytes.count : 0) }
    var result = Data([0x49, 0x49])
    result.append(integer(UInt16(42))); result.append(integer(UInt32(8)))
    result.append(integer(UInt16(tags.count)))
    var extra = Data()
    for var tag in tags {
        if tag.id == 273 { tag.bytes = integer(UInt32(fixedBytes + extraBytes)) }
        result.append(integer(tag.id)); result.append(integer(tag.type)); result.append(integer(tag.count))
        if tag.bytes.count > 4 {
            result.append(integer(UInt32(fixedBytes + extra.count)))
            extra.append(tag.bytes)
        } else {
            result.append(tag.bytes)
            result.append(Data(repeating: 0, count: 4 - tag.bytes.count))
        }
    }
    result.append(integer(UInt32(0))); result.append(extra)
    for row in 0..<height { for column in 0..<width { result.append(integer(value(column, row).bitPattern)) } }
    try result.write(to: url)
}

@MainActor
func runGeospatialRegressionChecks() async throws {
    section("地理分析回归：非方形像素、仿射地面面积与共同网格")
    let directory = FileManager.default.temporaryDirectory.appending(path: "euclid-geospatial-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    func matrix(_ x: Double, _ y: Double, shearX: Double = 0, shearY: Double = 0,
                originX: Double = 0, originY: Double = 0) -> [Double] {
        [x, shearX, 0, originX, shearY, y, 0, originY, 0, 0, 1, 0, 0, 0, 0, 1]
    }
    func reader(_ name: String, width: Int = 16, height: Int = 16, transform: [Double],
                epsg: UInt16? = 3857, value: (Int, Int) -> Float) throws -> RasterSampleReader {
        let url = directory.appending(path: "\(name).tif")
        try writeGeospatialFixture(to: url, width: width, height: height, matrix: transform, epsg: epsg, value: value)
        guard let reader = RasterSampleReader.open(url: url) else {
            throw NSError(domain: "GeospatialRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture cannot open: \(name)"])
        }
        return reader
    }
    let polygon = [CGPoint(x: 0, y: 0), CGPoint(x: 16, y: 0), CGPoint(x: 16, y: 16), CGPoint(x: 0, y: 16)]
    let flattening = 1.0 / 298.257_223_563
    let eccentricitySquared = flattening * (2 - flattening)
    let equatorialNorthScale = 1 - eccentricitySquared
    let rectangular = try reader("rectangular", transform: matrix(10, -20)) { _, row in Float(Double(row * 20) * equatorialNorthScale) }
    let slope = DEMAnalysis.slope(reader: rectangular)
    expect(slope != nil, "10 × 20 投影米像素支持坡度分析")
    expectClose(Double(slope?.values[8 * 16 + 8] ?? .nan), 45, accuracy: 0.0001, "非方形像素的 45° 地面坡度")
    let constant = try reader("constant", transform: matrix(10, -20)) { _, _ in 10 }
    let volume = DEMAnalysis.volume(reader: constant, polygon: polygon, baseElevation: 0)
    expectClose(volume?.cutVolume ?? .nan, 512_000 * equatorialNorthScale, accuracy: 1, "非方形像素按 WGS84 地面面积积分")
    expectClose(volume?.cellArea ?? .nan, 200 * equatorialNorthScale, accuracy: 0.001, "体积使用横纵像素的椭球地面面积")

    let sheared = try reader("shear", transform: matrix(10, -20, shearX: 10)) { _, row in Float(Double(row * 20) * equatorialNorthScale) }
    let shearSlope = DEMAnalysis.slope(reader: sheared)
    expectClose(Double(shearSlope?.values[8 * 16 + 8] ?? .nan), 45, accuracy: 0.0001, "剪切网格通过完整度量恢复 45° 坡度")
    let shearConstant = try reader("shear-volume", transform: matrix(10, -20, shearX: 10)) { _, _ in 10 }
    expectClose(DEMAnalysis.volume(reader: shearConstant, polygon: polygon, baseElevation: 0)?.cutVolume ?? .nan,
                512_000 * equatorialNorthScale, accuracy: 1, "剪切像素面积取行列式而非边长乘积")

    let geographic = try reader("geographic", transform: matrix(0.001, -0.002, originY: 60), epsg: 4326) { _, _ in 10 }
    let geographicVolume = DEMAnalysis.volume(reader: geographic, polygon: polygon, baseElevation: 0)
    let radius = Projection.wgs84SemiMajorAxis
    // Independent closed-form ellipsoid surface integral over this latitude band.
    let eccentricity = sqrt(eccentricitySquared)
    func primitive(_ latitude: Double) -> Double {
        let sine = sin(latitude * .pi / 180)
        return sine / (2 * (1 - eccentricitySquared * sine * sine)) + atanh(eccentricity * sine) / (2 * eccentricity)
    }
    let trueArea = radius * radius * (1 - eccentricitySquared) * (0.016 * .pi / 180) * (primitive(60) - primitive(59.968))
    expectClose((geographicVolume?.sampledArea ?? .nan) / trueArea, 1, accuracy: 1e-8, "高纬经纬度网格按纬度修正地面面积")
    let downsampled = DEMAnalysis.volume(reader: constant, polygon: polygon, baseElevation: 0, maxDimension: 6)
    expectClose(downsampled?.sampledArea ?? .nan, volume?.sampledArea ?? .nan, accuracy: 0.001,
                "抽稀后的末尾半格按实际覆盖面积计入")
    let unreferenced = try reader("unreferenced", transform: matrix(10, -20), epsg: nil) { _, _ in 10 }
    expect(DEMAnalysis.slope(reader: unreferenced) == nil, "未配准影像不会默认按一米输出坡度")
    expect(DEMAnalysis.volume(reader: unreferenced, polygon: polygon, baseElevation: 0) == nil, "未配准影像不会默认按一米输出工程量")

    let first = try reader("first", transform: matrix(10, -10)) { column, _ in Float(column * 10 + 5) }
    let nativeDifference = RasterDifference.compute(first: first, second: first)
    expect(nativeDifference?.comparedSamples == 256 && nativeDifference?.georeference == first.georeference,
           "同网格保留全部有效像素及原始地理参考")
    let transposed = try reader("transposed", transform: matrix(0, 0, shearX: 10, shearY: -10)) { _, row in Float(row * 10 + 5) }
    let transposedDifference = RasterDifference.compute(first: first, second: transposed)
    expect(transposedDifference?.comparedSamples == 256, "行列轴交换后仍在同一地理位置比较")
    expectClose(transposedDifference?.absoluteMaximum ?? .nan, 0, accuracy: 1e-4, "同一地理场交换行列轴后差值为零")
    let finer = try reader("finer", width: 32, height: 32, transform: matrix(5, -5)) { column, _ in Float(column) * 5 + 2.5 }
    expectClose(RasterDifference.compute(first: first, second: finer)?.absoluteMaximum ?? .nan,
                0, accuracy: 1e-4, "同一线性地理场在不同分辨率下差值为零")
    let shifted = try reader("shifted", transform: matrix(10, -10, originX: 80)) { column, _ in Float(column * 10 + 85) }
    let overlap = RasterDifference.compute(first: first, second: shifted)
    expect(overlap != nil && (overlap?.comparedSamples ?? 0) < 256, "只比较部分重叠的地理范围")
    expectClose(overlap?.absoluteMaximum ?? .nan, 0, accuracy: 1e-4, "平移源在共同地理位置的差值为零")
    let degrees = 10 / radius * 180 / .pi
    let otherCRS = try reader("other-crs", transform: matrix(degrees, -degrees), epsg: 4326) { column, _ in Float(column * 10 + 5) }
    expectClose(RasterDifference.compute(first: first, second: otherCRS)?.absoluteMaximum ?? .nan,
                0, accuracy: 0.001, "经纬度和墨卡托两个投影采样同一地理场")
    let absent = try reader("absent", transform: matrix(10, -10, originX: 1000)) { _, _ in 0 }
    expect(RasterDifference.compute(first: first, second: absent) == nil, "无交集时不产生差值图")
    let missing = try reader("missing", transform: matrix(10, -10)) { column, row in row == 8 && column == 8 ? .nan : Float(column * 10 + 5) }
    let missingResult = RasterDifference.compute(first: first, second: missing)
    expect((missingResult?.comparedSamples ?? 256) < 256, "NoData 不参与双线性差值统计")

    if RasterCompute.metalAvailable {
        let values = (0..<(64 * 64)).map { Float($0 / 64) * 20 }
        let metric = RasterGroundMetric(column: CGVector(dx: 10, dy: 0), row: CGVector(dx: 10, dy: -20))
        let rows = Array(repeating: metric, count: 64)
        let cpu = RasterCompute.slope(values: values, width: 64, height: 64, rowMetrics: rows, backend: .cpu)
        let gpu = RasterCompute.slope(values: values, width: 64, height: 64, rowMetrics: rows, backend: .metal)
        expect(cpu != nil && gpu != nil, "仿射地面度量 CPU 与 Metal 均可计算")
        expectClose(Double(cpu?[2000] ?? .nan), 45, accuracy: 0.0001, "CPU 仿射度量保持已知坡度")
        expectClose(Double(gpu?[2000] ?? .nan), Double(cpu?[2000] ?? .nan), accuracy: 0.0001, "Metal 仿射度量与 CPU 一致")
        RasterCompute.trimMetalBuffers()
        _ = RasterCompute.color(values: values, scale: 1280, difference: false, backend: .metal)
        let before = RasterCompute.metalBufferStatistics
        _ = RasterCompute.color(values: values, scale: 1280, difference: false, backend: .metal)
        let after = RasterCompute.metalBufferStatistics
        expect(after.reuses > before.reuses, "连续 Metal 运算复用缓冲区")
        expect(after.idleBytes <= 64 << 20, "Metal 空闲缓冲池有字节上限")
        let concurrentCorrect = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let source = [Float](repeating: Float(index % 3) / 2, count: 8192)
                    let expected = RasterCompute.color(values: source, scale: 1, difference: false, backend: .cpu)
                    let actual = RasterCompute.color(values: source, scale: 1, difference: false, backend: .metal)
                    return actual != nil && actual == expected
                }
            }
            var valid = true
            for await result in group { valid = valid && result }
            return valid
        }
        expect(concurrentCorrect, "并发 Metal 命令不共享仍在使用的缓冲区")
        RasterCompute.trimMetalBuffers()
        expect(RasterCompute.metalBufferStatistics.idleBytes == 0, "内存压力释放 Metal 空闲缓冲")
    }
}
