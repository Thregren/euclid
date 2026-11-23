import CSQLite
import CoreGraphics
import Foundation
import ImageIO
import TileKit

private final class CheckSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false
    func mark() { lock.withLock { marked = true } }
    var value: Bool { lock.withLock { marked } }
}

private actor RetryFetcher: TileFetching {
    var calls = 0
    let data: Data
    let failure: TileFetchError
    init(data: Data, failure: TileFetchError) { self.data = data; self.failure = failure }
    func fetch(_ request: TileRequest) async throws -> TileFetchResult {
        calls += 1
        if calls == 1 { throw failure }
        return TileFetchResult(data: data, statusCode: 200)
    }
}

@MainActor
func runNextCoreChecks() async {
    section("重试、文件身份、存档保护、数据工具与 Metal")
    let root = FileManager.default.temporaryDirectory.appending(path: "euclid-next-checks-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard let png = makeCheckPNG(size: 16) else { expect(false, "生成检查图片"); return }
        let template = TileSourceTemplate(id: "check", name: "check", urlTemplate: "https://example.invalid/{z}/{x}/{y}.png", maximumZoom: 8)
        for failure in [TileFetchError.transport("offline"), .httpStatus(404)] {
            let fetcher = RetryFetcher(data: png, failure: failure)
            let provider = TileProvider(source: RemoteTileSource(template: template, fetcher: fetcher, retryLimit: 0),
                                        retryDelay: 0.03, missingDelay: 0.03)
            let tile = SlippyTile(zoom: 2, x: 1, y: 1)
            expect(await provider.image(for: tile) == nil, "失败请求不产生图片")
            expect(await provider.image(for: tile) == nil, "过期前避免重复失败读取")
            expect(await fetcher.calls == 1, "负缓存期间只请求一次")
            try await Task.sleep(for: .milliseconds(45))
            expect(await provider.image(for: tile) != nil, "临时失败及真实缺片过期后均可恢复")
            expect(await fetcher.calls == 2, "恢复请求发出一次")
        }
        expect(TileGrid.webMercator.tileRange(zoom: 8, worldRect: CGRect(x: 2, y: 2, width: 1, height: 1)) == nil, "完全越界的瓦片范围不会构造倒置区间")
        expect(ImageDecoder.fileExtension(for: png) == "png", "按实际字节识别瓦片格式")
        expect(ImageDecoder.decode(Data(repeating: 0, count: 32)) == nil, "畸形图片安全拒绝")
        let identityFile = root.appending(path: "identity")
        try Data([1]).write(to: identityFile)
        let before = FileIdentity(url: identityFile)
        try Data([2]).write(to: identityFile, options: .atomic)
        expect(before != FileIdentity(url: identityFile), "同路径同大小原子替换应改变文件身份")

        let legacy = root.appending(path: "measurements.json")
        let repository = MeasurementRepository(legacyURL: legacy)
        let point = GeoMeasurement(kind: .point, points: [GeoCoordinate(longitude: 120, latitude: 30)])
        for index in 0..<45 { try await repository.save([point], for: "/dataset/\(index)") }
        expect(await repository.measurements(for: "/dataset/0") == [point], "超过 30 份数据不淘汰旧测量")
        try await repository.save([], for: "/dataset/0")
        expect(await repository.measurements(for: "/dataset/0").isEmpty, "清空测量写入独立空文档")
        let document = await repository.documentURL(for: "/dataset/0")
        try Data("corrupt".utf8).write(to: document)
        expect(await repository.measurements(for: "/dataset/0") == [point], "损坏当前文档可从上一代备份恢复")
        expect(await repository.takeNotice() != nil, "恢复备份产生一次提示")
        struct OldEntry: Codable { let updatedAt: Date; let measurements: [GeoMeasurement] }
        struct OldContents: Codable { let entries: [String: OldEntry] }
        let oldData = try JSONEncoder().encode(OldContents(entries: ["/old": OldEntry(updatedAt: Date(), measurements: [point])]))
        try oldData.write(to: legacy)
        expect(await repository.measurements(for: "/old") == [point], "兼容读取旧版合并存档")
        try await repository.save([], for: "/old")
        expect(await repository.measurements(for: "/old").isEmpty, "清空后不会从旧存档复活测量")
        expect(try Data(contentsOf: legacy) == oldData, "迁移不覆盖旧存档")

        let archiveURL = root.appending(path: "stream.zip")
        let writer = try StreamingZipWriter(url: archiveURL)
        for index in 0..<9 { try writer.append(name: "\(index % 3)/\(index).png", data: png) }
        try writer.finish()
        let archive = try ZipArchive(url: archiveURL)
        expect(archive.isZip64 && archive.entryCount == 9, "流式 ZIP64 归档可由读取器重开")
        expect(try archive.data(for: archive.entry(named: "2/8.png")!) == png, "乱序多区间索引读取正确")
        for row in 0..<3 { _ = archive.entryNames(inRow: String(row)) }
        let rowCost = archive.rowCacheCost
        archive.trimRows(toFraction: 0.5)
        expect(archive.rowCacheCost <= rowCost / 2 && archive.rowCacheCost > 0, "行缓存按实际占用比例裁剪，不按最大容量计算")
        let overviewStarted = CheckSignal(), overviewEnded = CheckSignal()
        let overviewFile = root.appending(path: "cancel-overview")
        try Data([1]).write(to: overviewFile)
        await RasterOverviewCache.shared.scheduleGeneration(fileURL: overviewFile, tileSize: 512) {
            overviewStarted.mark()
            while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.001) }
            overviewEnded.mark()
            return ImageDecoder.decode(png)
        }
        var didStart = false
        for _ in 0..<200 {
            if overviewStarted.value { didStart = true; break }
            try await Task.sleep(for: .milliseconds(2))
        }
        expect(didStart, "后台概览任务已开始")
        await RasterOverviewCache.shared.cancelGeneration()
        var didEnd = false
        for _ in 0..<200 {
            if overviewEnded.value { didEnd = true; break }
            try await Task.sleep(for: .milliseconds(2))
        }
        expect(didEnd, "取消传递到正在渲染的概览任务")
        expect(await RasterOverviewCache.shared.readyImage(fileURL: overviewFile, tileSize: 512) == nil, "取消后返回的概览不会进入缓存")
        let checkpoint = root.appending(path: "audit.json")
        let partial = try ArchiveAudit.run(url: archiveURL, full: true, checkpoint: checkpoint, maximumRecords: 4)
        expect(!partial.complete && partial.checked == 4 && partial.failureCount == 0, "审计保存准确的部分检查点")
        let complete = try ArchiveAudit.run(url: archiveURL, full: true, checkpoint: checkpoint)
        expect(complete.complete && complete.checked == 9 && complete.decodedImages == 9, "审计从检查点继续，既不重复也不遗漏")
        let sample = try ArchiveAudit.run(url: archiveURL, sampleCount: 3)
        expect(!sample.complete && sample.checked == 3, "抽样报告不声称全包完整")
        let pool = ZipArchivePool(maximumArchives: 16)
        var volumes: [URL] = []
        for index in 0..<8 {
            let file = root.appending(path: "year-\(index).zip")
            try FileManager.default.copyItem(at: archiveURL, to: file); volumes.append(file)
            expect(await pool.rawData("2/8.png", in: file) == png, "多归档首次读片")
        }
        for file in volumes { _ = await pool.rawData("2/8.png", in: file) }
        expect(await pool.statistics.opens == 8, "八份活跃归档再次读取不反复重开")
        await pool.trimCaches(toFraction: 0)
        expect(await pool.statistics.rowBytes == 0, "内存压力释放归档行表")

        let tiles = root.appending(path: "tiles/2/1")
        try FileManager.default.createDirectory(at: tiles, withIntermediateDirectories: true)
        try png.write(to: tiles.appending(path: "1.png"))
        let dataset = TileDataset(id: root.appending(path: "tiles").path, name: "subset", rootURL: root.appending(path: "tiles"), layout: .webODM, zoomRange: 2...2)
        let bounds = GeoBounds(west: -89, south: 1, east: -1, north: 65)
        let output = root.appending(path: "subset")
        let report = try await TileSubsetExport.extract(dataset: dataset, bounds: bounds, zoomRange: 2...2, output: output)
        expect(report.written == 1 && report.missing == 0, "局部提取覆盖指定瓦片")
        let subset = try TileDataTools.dataset(at: output)
        expect(await subset.source.data(for: SlippyTile(zoom: 2, x: 1, y: 1)) == png, "提取小包可通过现有数据集流程直接读回")
        do { _ = try await TileSubsetExport.extract(dataset: dataset, bounds: bounds, zoomRange: 2...2, output: output); expect(false, "不可覆盖已有输出") }
        catch { expect(true, "已有输出安全拒绝") }

        let mbURL = root.appending(path: "raster.mbtiles")
        try makeMBTilesCheck(url: mbURL, png: png)
        let mb = try MBTilesSource(url: mbURL)
        let reusedMB = try MBTilesSource(url: mbURL, info: mb.info)
        expect(reusedMB.blockingData(for: SlippyTile(zoom: 2, x: 1, y: 1)) == png, "复用已探测元信息仍使用只读瓦片查询")
        expect(mb.info.zoomRange == 2...2 && mb.info.tileSize == 16, "MBTiles 元信息和图片尺寸")
        expect(mb.blockingData(for: SlippyTile(zoom: 2, x: 1, y: 1)) == png, "MBTiles TMS 行号正确转为 XYZ")
        expect(mb.blockingData(for: SlippyTile(zoom: 2, x: 1, y: 2)) == nil, "MBTiles 不读取镜像行")
        let mbDataset = try TileDataTools.dataset(at: mbURL)
        expect(DatasetLocator.extent(of: mbDataset)?.worldRect == mb.info.worldRect, "MBTiles 通过共享数据集范围流程")
        let server = LocalTileServer()
        let port = try await server.startAsync(rootURL: output)
        let (served, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/2/1/1.png")!)
        expect((response as? HTTPURLResponse)?.statusCode == 200 && served == png, "本地 ZIP 服务返回原始瓦片字节")
        server.stop()
        let mbPort = try await server.startAsync(rootURL: mbURL)
        let (mbServed, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(mbPort)/2/1/1.png")!)
        expect(mbServed == png, "本地服务支持只读 MBTiles")
        server.stop()
        var head = URLRequest(url: URL(string: "http://127.0.0.1:\(mbPort)/2/1/1.png")!)
        // Restart because stop above intentionally closes all listeners.
        let headPort = try await server.startAsync(rootURL: mbURL)
        head.url = URL(string: "http://127.0.0.1:\(headPort)/2/1/1.png")!; head.httpMethod = "HEAD"
        let (headBody, headResponse) = try await URLSession.shared.data(for: head)
        expect(headBody.isEmpty && (headResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length") == String(png.count), "HEAD 保留实际长度且不发送图片")
        server.stop()
        let geographicURL = root.appending(path: "geographic.zip")
        let geographicWriter = try StreamingZipWriter(url: geographicURL)
        try geographicWriter.append(name: "0/1.png", data: makeGradientCheckPNG()); try geographicWriter.finish()
        let geographic = TileDataset(id: root.path, name: "geographic", rootURL: root, layout: .webODM, zoomRange: 2...2, grid: .geographic,
            zipInfo: ZipDatasetInfo(parts: [2: [ZipVolume(url: geographicURL, rowRange: 0...1)]]))
        let reprojected = await TileServerReprojection.data(dataset: geographic, source: geographic.source, tile: SlippyTile(zoom: 2, x: 1, y: 1))
        if let bytes = reprojected, let image = ImageDecoder.decode(bytes), let pixels = rgbaBytes(of: image) {
            let lastRow = (image.height - 1) * image.width * 4
            expect(pixels[0] < pixels[lastRow] && pixels[2] > pixels[lastRow + 2], "经纬度转 XYZ 保持南北像素顺序，无上下倒置")
        } else { expect(false, "重投影坐标纹理可解码") }
        expect(reprojected.flatMap(ImageDecoder.decode) != nil, "经纬度第 0 行转换为 XYZ 第 1 行，地图客户端不会整体错位")
        let zipSource = geographic.source
        if case .missing = await zipSource.loadTile(SlippyTile(zoom: 2, x: 0, y: 1)) { expect(true, "ZIP 真缺片单独分类") }
        else { expect(false, "ZIP 真缺片分类") }
        let absent = ZipTileSource(rootURL: root, grid: .webMercator, parts: [2: [ZipVolume(url: root.appending(path: "offline.zip"), rowRange: 0...2)]], zoomRange: 2...2)
        if case .retry = await absent.loadTile(SlippyTile(zoom: 2, x: 1, y: 1)) { expect(true, "离线归档作为可重试错误") }
        else { expect(false, "离线归档错误分类") }
        let sampleCheckpoint = root.appending(path: "sample.json")
        _ = try ArchiveAudit.run(url: archiveURL, sampleCount: 2, checkpoint: sampleCheckpoint)
        do { _ = try ArchiveAudit.run(url: archiveURL, full: true, checkpoint: sampleCheckpoint); expect(false, "不能用抽样报告恢复全量检查") }
        catch { expect(true, "抽样检查点不会重复计入全量检查") }
        let damagedURL = root.appending(path: "damaged.zip")
        var damaged = try Data(contentsOf: archiveURL)
        damaged[30 + "0/0.png".utf8.count + 20] ^= 1
        try damaged.write(to: damagedURL)
        let damagedReport = try ArchiveAudit.run(url: damagedURL, full: true)
        expect(damagedReport.checked == 9 && damagedReport.failureCount == 1, "完整性检查识别单条 CRC 损坏并继续其他记录")
        let canceled = Task.detached { try ArchiveAudit.run(url: archiveURL, full: true) }
        canceled.cancel()
        do { _ = try await canceled.value; expect(false, "取消检查应停止") }
        catch is CancellationError { expect(true, "全量审计响应取消") }
        catch { expect(false, "取消类型正确") }
        if let path = ProcessInfo.processInfo.environment["EUCLID_CHECK_ARTIFACTS"] {
            try FileManager.default.copyItem(at: root, to: URL(fileURLWithPath: path))
        }
        try checkMetalRaster()
    } catch { expect(false, "新功能检查执行失败：\(error)") }
}

private func makeGradientCheckPNG() throws -> Data {
    let side = 16
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    for row in 0..<side { for column in 0..<side {
        let index = (row * side + column) * 4
        pixels[index] = UInt8(row * 16); pixels[index + 2] = UInt8((15 - row) * 16); pixels[index + 3] = 255
    } }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
          let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw MBTilesError.invalid("纹理") }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw MBTilesError.invalid("纹理编码") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw MBTilesError.invalid("纹理写出") }
    return data as Data
}

func makeMBTilesCheck(url: URL, png: Data) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else { throw MBTilesError.invalid("创建自检数据库") }
    defer { sqlite3_close(database) }
    let sql = "CREATE TABLE metadata(name TEXT,value TEXT); CREATE TABLE tiles(zoom_level INTEGER,tile_column INTEGER,tile_row INTEGER,tile_data BLOB); CREATE UNIQUE INDEX tile_index ON tiles(zoom_level,tile_column,tile_row); INSERT INTO metadata VALUES('name','Check'),('format','png'),('bounds','-90,0,0,66');"
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw MBTilesError.invalid("写入自检元信息") }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "INSERT INTO tiles VALUES(2,1,2,?)", -1, &statement, nil) == SQLITE_OK, let statement else { throw MBTilesError.invalid("自检 SQL") }
    defer { sqlite3_finalize(statement) }
    let status = png.withUnsafeBytes { bytes in
        sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), nil)
        return sqlite3_step(statement)
    }
    guard status == SQLITE_DONE else { throw MBTilesError.invalid("写入自检瓦片") }
}

@MainActor private func checkMetalRaster() throws {
    let width = 127, height = 61
    let values = (0..<(width * height)).map { index -> Float in index % 197 == 0 ? .nan : Float(sin(Double(index) / 80) * 100) }
    let cpu = RasterCompute.slope(values: values, width: width, height: height, spacing: 0.5, backend: .cpu)!
    guard RasterCompute.metalAvailable else { print("  Metal 不可用；已验证 CPU 回退"); return }
    let gpu = RasterCompute.slope(values: values, width: width, height: height, spacing: 0.5, backend: .metal)!
    expect(zip(cpu, gpu).allSatisfy { a, b in (a.isNaN && b.isNaN) || abs(a - b) < 0.0001 }, "Metal 坡度包含边缘与 NaN，误差小于 0.0001°")
    for difference in [false, true] {
        let a = RasterCompute.color(values: values, scale: 100, difference: difference, backend: .cpu)!
        let b = RasterCompute.color(values: values, scale: 100, difference: difference, backend: .metal)!
        expect(zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= 1 }, "Metal 着色预乘与透明度，单通道误差不超过 1")
    }
    let extreme: [Float] = [-Float.greatestFiniteMagnitude, 0, Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, 0, Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, 0, Float.greatestFiniteMagnitude]
    let extremeCPU = RasterCompute.slope(values: extreme, width: 3, height: 3, spacing: 1, backend: .cpu)!
    let extremeGPU = RasterCompute.slope(values: extreme, width: 3, height: 3, spacing: 1, backend: .metal)!
    expect(zip(extremeCPU, extremeGPU).allSatisfy { ($0.isNaN && $1.isNaN) || abs($0 - $1) < 0.0001 }, "极值坡度 CPU 与 Metal 一致")
    expect(RasterCompute.color(values: [1], scale: 1e-300, difference: false, backend: .metal) == RasterCompute.color(values: [1], scale: 1e-300, difference: false, backend: .cpu), "超出 Float 范围的着色参数自动回退")
    let largeSpacingValues: [Float] = [0, 1e38, 2e38, 0, 1e38, 2e38, 0, 1e38, 2e38]
    expect(RasterCompute.slope(values: largeSpacingValues, width: 3, height: 3, spacing: 3e38, backend: .metal) == RasterCompute.slope(values: largeSpacingValues, width: 3, height: 3, spacing: 3e38, backend: .cpu), "中间表达式可能溢出的 Metal 间距自动回退")
    let second = Array(values.prefix(63 * 31))
    let a = RasterCompute.differences(first: values, firstWidth: width, firstHeight: height, second: second, secondWidth: 63, secondHeight: 31, width: 63, height: 31, backend: .cpu)!
    let b = RasterCompute.differences(first: values, firstWidth: width, firstHeight: height, second: second, secondWidth: 63, secondHeight: 31, width: 63, height: 31, backend: .metal)!
    expect(zip(a, b).allSatisfy { ($0.isNaN && $1.isNaN) || $0 == $1 }, "Metal 差异重采样与 CPU 逐像素一致")
}
