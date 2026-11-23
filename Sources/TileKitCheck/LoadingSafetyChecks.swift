import CoreGraphics
import Foundation
import TileKit
import TileRendering

private final class BoundedFetchProtocol: URLProtocol, @unchecked Sendable {
    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1ioAAAAASUVORK5CYII=")!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        var headers = ["Content-Type": "image/png"]
        var body = Self.png
        var status = 200
        switch url.path {
        case "/declared": headers["Content-Length"] = "1048576"
        case "/chunked": body.append(Data(repeating: 0, count: 4096))
        case "/html": headers["Content-Type"] = "text/html"; body = Data("<html>login</html>".utf8)
        case "/camouflage": body = Data("<html>login</html>".utf8)
        case "/missing": status = 404
        default: headers["Content-Length"] = String(body.count)
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor LoadingCounter {
    var count = 0
    func increment() { count += 1 }
}

private struct WaitingTileSource: TileImageSource {
    let counter: LoadingCounter
    let availableZoomRange = 0...20
    func data(for tile: SlippyTile) async -> Data? { nil }
    func loadTile(_ tile: SlippyTile) async -> TileLoadResult {
        await counter.increment()
        try? await Task.sleep(for: .seconds(5))
        return .missing
    }
}

private struct CountingTileSource: TileImageSource {
    let counter: LoadingCounter
    let png: Data
    let availableZoomRange = 0...20
    func data(for tile: SlippyTile) async -> Data? {
        await counter.increment()
        return png
    }
}

@MainActor
func runLoadingSafetyChecks() async throws {
    section("有界网络、隐藏图层与提取失败保护")
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [BoundedFetchProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let fetcher = URLSessionTileFetcher(session: session, maximumBytes: 1024)
    let valid = try await fetcher.fetch(TileRequest(url: URL(string: "https://bounded.test/valid")!))
    expect(ImageDecoder.fileExtension(for: valid.data) == "png", "有界请求保留正常 PNG")
    let exact = URLSessionTileFetcher(session: session, maximumBytes: valid.data.count)
    expect(try await exact.fetch(TileRequest(url: URL(string: "https://bounded.test/valid")!)).data == valid.data,
           "响应恰好等于字节上限时仍接受")
    for (path, expected) in [("declared", TileFetchError.tooLarge), ("chunked", .tooLarge),
                             ("html", .invalidContent), ("camouflage", .invalidContent), ("missing", .httpStatus(404))] {
        do {
            _ = try await fetcher.fetch(TileRequest(url: URL(string: "https://bounded.test/\(path)")!))
            expect(false, "拒绝异常网络响应 \(path)")
        } catch let error as TileFetchError { expect(error == expected, "响应 \(path) 保留准确错误") }
    }

    guard let png = makeCheckPNG() else { throw TileReadError.invalidImage }
    let waiting = LoadingCounter()
    let remote = TileProvider(source: WaitingTileSource(counter: waiting))
    let tasks = (0..<TileResourcePolicy.concurrentDecodes).map { index in
        Task { await remote.image(for: SlippyTile(zoom: 8, x: index, y: 0)) }
    }
    for _ in 0..<200 {
        if await waiting.count == tasks.count { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    expect(await waiting.count == tasks.count, "慢速来源已占满自身请求并发")
    let fast = TileProvider(source: CountingTileSource(counter: LoadingCounter(), png: png))
    let started = ContinuousClock.now
    expect(await fast.image(for: SlippyTile(zoom: 8, x: 0, y: 0)) != nil, "本地来源仍能解码")
    expect(started.duration(to: .now) < .seconds(1), "网络等待不占用全局解码容量")
    for task in tasks { task.cancel() }
    for task in tasks { _ = await task.value }

    let hiddenCounter = LoadingCounter()
    let stack = TileLayerStack()
    stack.configure(source: CountingTileSource(counter: hiddenCounter, png: png), name: "visibility",
                    tileSize: 256, zoomRange: 0...12, followsDisplayScale: false, maximumDataZoom: 12)
    let camera = MapCamera(center: CGPoint(x: 0.5, y: 0.5), zoomLevel: 4,
                           viewportSize: CGSize(width: 600, height: 400), tilePixelSize: 256)
    stack.setVisible(false)
    for _ in 0..<4 {
        expect(stack.sync(camera: camera, viewportSize: camera.viewportSize, displayScale: 1, showGrid: false) == nil,
               "隐藏层不布局或调度取图")
    }
    try await Task.sleep(for: .milliseconds(50))
    expect(await hiddenCounter.count == 0, "隐藏层产生零读取请求")
    stack.setVisible(true)
    _ = stack.sync(camera: camera, viewportSize: camera.viewportSize, displayScale: 1, showGrid: false)
    for _ in 0..<100 {
        if await hiddenCounter.count > 0 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    expect(await hiddenCounter.count > 0, "显示图层后恢复加载")
    stack.setVisible(false)
    expect((stack.hostLayer.sublayers?.count ?? 0) <= 1, "隐藏层释放瓦片 CALayer 图片引用")
    stack.clear()

    let root = FileManager.default.temporaryDirectory.appending(path: "euclid-loading-safety-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let tiles = root.appending(path: "tiles/2/1")
    try FileManager.default.createDirectory(at: tiles, withIntermediateDirectories: true)
    try png.write(to: tiles.appending(path: "1.png"))
    let source = DirectoryTileSource(rootURL: root.appending(path: "tiles"), layout: .webODM, zoomRange: 2...2)
    expect(try await source.readData(for: SlippyTile(zoom: 2, x: 1, y: 1)) == png, "目录严格读取正常瓦片")
    expect(try await source.readData(for: SlippyTile(zoom: 2, x: 1, y: 2)) == nil, "只有确认不存在的文件计为缺片")
    let outside = root.appending(path: "outside.png")
    try png.write(to: outside)
    try FileManager.default.createSymbolicLink(at: tiles.appending(path: "2.png"), withDestinationURL: outside)
    do { _ = try await source.readData(for: SlippyTile(zoom: 2, x: 1, y: 2)); expect(false, "拒绝瓦片符号链接") }
    catch { expect(true, "目录符号链接不会读出外部文件") }

    let archiveURL = root.appending(path: "part_z2_r1-1_tiles.zip")
    let writer = try StreamingZipWriter(url: archiveURL)
    try writer.append(name: "1/1.png", data: png)
    try writer.append(name: "1/2.png", data: png)
    try writer.finish()
    var damaged = try Data(contentsOf: archiveURL)
    let headerBytes = 30 + "1/1.png".utf8.count + 20
    damaged[headerBytes + png.count + headerBytes + 4] ^= 0x01
    try damaged.write(to: archiveURL)
    let dataset = TileDataset(id: archiveURL.path, name: "damaged", rootURL: root, layout: .webODM,
                              zoomRange: 2...2, zipInfo: ZipDatasetInfo(parts: [2: [ZipVolume(url: archiveURL, rowRange: 1...1)]]))
    let output = root.appending(path: "subset")
    do {
        _ = try await TileSubsetExport.extract(dataset: dataset,
                bounds: GeoBounds(west: -89, south: 1, east: 89, north: 65), zoomRange: 2...2, output: output)
        expect(false, "损坏源瓦片必须使提取失败")
    } catch { expect(true, "CRC 损坏作为提取错误传播") }
    expect(!FileManager.default.fileExists(atPath: output.path), "失败提取不留下成功目录")
    expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains(where: { $0.contains("-partial-") }),
           "失败提取清理全部暂存输出")

    let plan = try TileDownloadPlan(bounds: GeoBounds(west: -89, south: 1, east: -1, north: 65), zoomRange: 2...2)
    let badFetcher = FakeTileFetcher(responses: [:], defaultResponse: .ok(Data("<html>login</html>".utf8)))
    let downloadRoot = root.appending(path: "bad-download")
    let summary = try await TileDownloader(fetcher: badFetcher).run(plan: plan,
        options: TileDownloadOptions(urlTemplate: "https://bad.test/{z}/{x}/{y}.png", outputDirectory: downloadRoot,
                                     requestsPerSecond: 0, retryLimit: 0, writesManifest: false))
    expect(summary.downloaded == 0 && summary.failed == plan.totalTileCount, "下载器不将 HTML 成功响应写成瓦片")
}
