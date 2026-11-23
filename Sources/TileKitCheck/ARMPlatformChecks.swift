import CoreGraphics
import Foundation
import TileKit
import TileRendering

/// 手动放行的来源模拟不可立即取消的 IO，复现旧请求晚于 invalidate 返回的竞态。
private actor GatedImageSource: TileImageSource {
    nonisolated let availableZoomRange = 0...8
    private(set) var calls = 0
    private var pending: [Int: CheckedContinuation<CGImage?, Never>] = [:]

    func data(for tile: SlippyTile) async -> Data? { nil }
    func image(for tile: SlippyTile) async -> CGImage? {
        calls += 1
        let id = calls
        return await withCheckedContinuation { pending[id] = $0 }
    }
    func complete(_ id: Int, image: CGImage?) { pending.removeValue(forKey: id)?.resume(returning: image) }
    func completeAll(image: CGImage?) {
        let work = pending.values
        pending.removeAll()
        for continuation in work { continuation.resume(returning: image) }
    }
}

@MainActor
private func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<500 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor
func runARMPlatformChecks() async {
    section("ARM64：共享渲染、任务生命周期与向量计算")
    var queue = FIFOQueue<Int>()
    for value in 0..<2000 { queue.append(value) }
    var ordered = true
    for value in 0..<1500 { ordered = ordered && queue.popFirst() == value }
    queue.removeAll { $0 % 2 == 0 }
    expect(ordered && queue.count == 250 && queue.popFirst() == 1501, "FIFO 压缩与过滤后顺序正确")

    let camera = MapCamera(center: CGPoint(x: 0.6, y: 0.4), zoomLevel: 12,
                           viewportSize: CGSize(width: 400, height: 300), tilePixelSize: 512, displayScale: 3)
    let mobileViewpoint = Data(#"{"center":[0.6,0.4],"pointsPerWorldUnit":699050.7}"#.utf8)
    let decoded = try? JSONDecoder().decode(MapViewpoint.self, from: mobileViewpoint)
    let desktop = MapCamera(center: .zero, zoomLevel: 1, viewportSize: CGSize(width: 1024, height: 768),
                            tilePixelSize: 256, displayScale: 2)
    let restored = decoded?.applying(to: desktop)?.clamped(zoomLevelRange: 0...30)
    expect(restored?.center == camera.center && restored?.pixelsPerWorldUnit == 699050.7,
           "旧移动端视野跨屏幕恢复时保留中心和视图比例")
    expect(restored?.viewportSize == desktop.viewportSize && restored?.displayScale == desktop.displayScale
           && restored?.tilePixelSize == desktop.tilePixelSize,
           "恢复视野使用当前屏幕尺寸、像素比和瓦片边长")
    let roundTripped = (try? JSONEncoder().encode(MapViewpoint(camera))).flatMap {
        try? JSONDecoder().decode(MapViewpoint.self, from: $0)
    }
    expect(roundTripped == MapViewpoint(camera), "共享视野可无损写入和恢复")
    let invalidCamera = MapCamera(center: camera.center, pixelsPerWorldUnit: 0,
                                  viewportSize: .zero, tilePixelSize: 512)
    expect(MapViewpoint(invalidCamera).applying(to: desktop) == nil, "无效的视图比例不会覆盖当前相机")
    expect(TileLayerStack.rasterCameraZoomLimit(dataLimit: 20, fittedZoom: 25) == 28
           && TileLayerStack.rasterCameraZoomLimit(dataLimit: 20, fittedZoom: 29, maximumFitZoom: 30) == 30
           && TileLayerStack.rasterCameraZoomLimit(dataLimit: 24, fittedZoom: 10) == 24,
           "小幅影像保留适配后的放大空间，原数据层级和桌面上限仍生效")
    let point = CGPoint(x: 83, y: 42)
    let coordinate = camera.coordinate(forLayerPoint: point)
    let roundtrip = camera.layerPoint(for: coordinate)
    expectClose(roundtrip.x, point.x, accuracy: 1e-6, "UIKit 横坐标往返")
    expectClose(roundtrip.y, point.y, accuracy: 1e-6, "UIKit 纵坐标往返")
    expect(camera.translated(byLayerDelta: CGPoint(x: 0, y: 10)).center.y < camera.center.y,
           "手指向下拖动时视野移向北方")

    guard let png = makeCheckPNG(), let image = ImageDecoder.decode(png) else {
        expect(false, "ARM 自检图片应可解码")
        return
    }
    let snapshot = MapRenderSnapshot(size: CGSize(width: 8, height: 8), scale: 2, background: nil,
                                     placements: [.init(image: image, frame: CGRect(x: 0, y: 0, width: 8, height: 8), opacity: 1)],
                                     overlay: nil, measurementCount: 0)
    expect(snapshot.makeImage()?.width == 16, "共享出图快照遵循设备像素比")
    var invalid = snapshot
    invalid.scale = .nan
    expect(invalid.makeImage() == nil, "非法出图倍率不应崩溃")
    expect(snapshot.makeImage(maximumPixelCount: 4) == nil, "出图像素预算生效")
    let stack = TileLayerStack(flipsGeometry: false)
    expect(!stack.hostLayer.isGeometryFlipped, "UIKit 画布可使用 y 向下的原生图层几何")

    let tile = SlippyTile(zoom: 3, x: 2, y: 2)
    do {
        let source = GatedImageSource()
        let provider = TileProvider(source: source)
        let old = Task { await provider.image(for: tile) }
        expect(await eventually { await source.calls == 1 }, "旧请求已启动")
        await provider.invalidate()
        let current = Task { await provider.image(for: tile) }
        expect(await eventually { await source.calls == 2 }, "失效后启动新请求")
        await source.complete(1, image: image)
        expect(await old.value == nil, "失效前的结果应丢弃")
        expect(await provider.requestStats.flights == 1, "旧请求结束不能清掉同位置的新请求")
        let joined = Task { await provider.image(for: tile) }
        expect(await eventually { await provider.requestStats.consumers == 2 }, "第三个调用方合并到新请求")
        await source.completeAll(image: image)
        let currentImage = await current.value
        let joinedImage = await joined.value
        expect(currentImage != nil && joinedImage != nil, "合并请求都拿到新图片")
        expect(await source.calls == 2, "同一瓦片的并发调用不重复取图")
        await provider.setMemoryLimitBytes(0)
        expect(await provider.cacheStats.bytes == 0, "动态内存额度可收缩到零")
    }
    do {
        let source = GatedImageSource()
        let provider = TileProvider(source: source)
        let first = Task { await provider.image(for: tile) }
        let second = Task { await provider.image(for: tile) }
        expect(await eventually { await provider.requestStats.consumers == 2 }, "两个调用方共享请求")
        first.cancel()
        expect(await eventually { await provider.requestStats.consumers == 1 }, "取消只移除对应调用方")
        await source.completeAll(image: image)
        expect(await first.value == nil, "取消的调用方不接收结果")
        expect(await second.value != nil, "取消一方不会影响另一方")
    }
    do {
        let source = GatedImageSource()
        let provider = TileProvider(source: source)
        let abandoned = Task { await provider.image(for: tile, priority: .utility) }
        expect(await eventually { await source.calls == 1 }, "预取请求已启动")
        abandoned.cancel()
        expect(await eventually { await provider.requestStats.flights == 0 }, "最后一个调用方取消后释放请求")
        await source.completeAll(image: nil)
        _ = await abandoned.value
        let retry = Task { await provider.image(for: tile) }
        expect(await eventually { await source.calls == 2 }, "取消不能把瓦片永久记为缺片")
        await source.completeAll(image: image)
        expect(await retry.value != nil, "取消后可重新读取同一瓦片")
    }

    let limiter = AsyncLimiter(limit: 1)
    expect(await limiter.acquire(), "并发名额可获取")
    let background = Task { await limiter.acquire(priority: .utility) }
    expect(await eventually { await limiter.queuedCount == 1 }, "预取等待解码名额")
    let foreground = Task { await limiter.acquire(priority: .userInitiated) }
    expect(await eventually { await limiter.queuedCount == 2 }, "前台请求入队")
    await limiter.release()
    expect(await foreground.value, "前台请求先获得名额")
    expect(await limiter.queuedCount == 1, "预取仍在等待")
    await limiter.release()
    expect(await background.value, "前台结束后放行预取")
    let cancelled = Task { await limiter.acquire() }
    expect(await eventually { await limiter.queuedCount == 1 }, "取消测试已入队")
    cancelled.cancel()
    expect(await cancelled.value == false, "取消等待者立即退出")
    await limiter.release()
    expect(await limiter.acquire(), "取消等待者不泄漏名额")
    await limiter.release()

    let cache = TIFFChunkCache(byteLimit: 64 << 10)
    let key = TIFFChunkCache.Key(path: "/tmp/coalesced.tif", level: 8, index: 0)
    let decodes = LockedCounter()
    let badResults = LockedCounter()
    DispatchQueue.concurrentPerform(iterations: 16) { _ in
        let bytes = try? cache.loadPixels(for: key) {
            decodes.increment()
            Thread.sleep(forTimeInterval: 0.005)
            return [UInt8](repeating: 17, count: 4096)
        }
        if bytes?.first != 17 { badResults.increment() }
    }
    expect(decodes.value == 1 && badResults.value == 0, "16 个并发请求只解码一次且像素一致")
    let started = LockedCounter()
    let finish = DispatchSemaphore(value: 0)
    let pendingKey = TIFFChunkCache.Key(path: "/tmp/invalidated.tif", level: 8, index: 0)
    let oldDecode = Task.detached {
        try? cache.loadPixels(for: pendingKey) {
            started.increment()
            _ = finish.wait(timeout: .now() + 2)
            return [1]
        }
    }
    expect(await eventually { started.value == 1 }, "旧块解码已开始")
    cache.invalidate(path: pendingKey.path)
    _ = try? cache.loadPixels(for: pendingKey) { [2] }
    finish.signal()
    _ = await oldDecode.value
    expect(cache.pixels(for: pendingKey) == [2], "旧块解码不能污染失效后的缓存")
    enum ProbeError: Error { case failed }
    cache.invalidate(path: key.path)
    let failure = try? cache.loadPixels(for: key) { throw ProbeError.failed }
    let recovery = try? cache.loadPixels(for: key) { [3] }
    expect(failure == nil && recovery == [3], "解码失败不永久缓存，可以重试")

    do {
        let pool = TIFFChunkCache()
        let url = tiffFixtures.appending(path: "rgba_strip_lzw.tif")
        var oldLease: TIFFReaderLease? = try pool.acquireReader(url: url)
        let oldReader = oldLease?.reader
        pool.invalidate(path: url.path(percentEncoded: false))
        let newLease = try pool.acquireReader(url: url)
        expect(oldReader !== newLease.reader, "文件失效后重新打开新句柄")
        oldLease = nil
        expect(newLease.reader.read(offset: 0, count: 8)?.count == 8,
               "归还旧租约不能关闭同路径的新句柄")
    } catch { expect(false, "句柄身份自检：\(error)") }

    for size in [0, 7, 4096, 8193] {
        var values = (0..<size).map { Float($0 % 123) * 0.25 - 6 }
        if size > 3 { values[1] = .nan; values[2] = .infinity; values[3] = -.infinity }
        let expected = RasterStatistics.scalar(values)
        let actual = DEMAnalysis.statistics(of: values)
        expect(actual.validCount == expected.validCount, "向量统计过滤非有限值（\(size)）")
        if !expected.isEmpty {
            expect(actual.minimum == expected.minimum && actual.maximum == expected.maximum, "统计极值一致（\(size)）")
            expectClose(actual.mean, expected.mean, accuracy: 1e-10, "统计均值一致（\(size)）")
        } else { expect(actual.mean.isNaN, "空统计返回 NaN") }
    }
    let nonFinite = DEMAnalysis.statistics(of: [Float](repeating: .nan, count: 8192))
    expect(nonFinite.isEmpty && nonFinite.minimum.isNaN, "全 NoData 的向量统计返回空结果")

    if let reader = RasterSampleReader.open(url: tiffFixtures.appending(path: "dem_f32_p3.tif")) {
        expect(reader.value(column: Double.greatestFiniteMagnitude, row: 0) == nil,
               "极大采样坐标应返回 nil，不转整数崩溃")
        expect(reader.grid(rect: CGRect(x: CGFloat.nan, y: 0, width: 4, height: 4)) == nil,
               "NaN 原点的采样矩形应被拒绝")
        expect(reader.grid(rect: CGRect(x: -5e299, y: -5e299, width: 1e300, height: 1e300), maxDimension: 8) != nil,
               "极大有限采样范围先裁剪到影像内，再转整数")
    } else { expect(false, "采样边界自检的 DEM 应可打开") }

    let grid = RasterSampleGrid(width: 19, height: 13, rect: CGRect(x: 10, y: 20, width: 57, height: 39),
                                step: 3, values: [])
    let polygons: [[CGPoint]] = [
        [CGPoint(x: 11.5, y: 21.5), CGPoint(x: 62.5, y: 21.5), CGPoint(x: 62.5, y: 54.5), CGPoint(x: 11.5, y: 54.5)],
        [CGPoint(x: 10, y: 20), CGPoint(x: 60, y: 55), CGPoint(x: 55, y: 20), CGPoint(x: 15, y: 55)],
        [CGPoint(x: 0, y: 0), CGPoint(x: 80, y: 0), CGPoint(x: 80, y: 80), CGPoint(x: 30, y: 40), CGPoint(x: 0, y: 80)],
    ]
    for (index, polygon) in polygons.enumerated() {
        var matches = true
        for row in 0..<grid.height {
            let spans = RasterPolygonScanlines.spans(polygon: polygon, grid: grid, row: row)
            for column in 0..<grid.width {
                let contains = spans.contains { $0.contains(column) }
                matches = matches && contains == DEMAnalysis.contains(polygon, point: grid.pixelPoint(column: column, row: row))
            }
        }
        expect(matches, "扫描行与逐点判定一致，覆盖边界、凹形及自交（\(index)）")
    }
}
