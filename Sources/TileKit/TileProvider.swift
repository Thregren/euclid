import CoreGraphics
import Foundation

/// 瓦片图片供应者：LRU 内存缓存 + 并发取图/解码 + 缺片负缓存。
///
/// 来源可以是本地目录，也可以是在线服务（见 `TileImageSource`）；
/// 对上层来说只有「拿到图 / 这片没有」两种结果。
public actor TileProvider {
    private let source: any TileImageSource
    private var memoryLimitBytes: Int
    private let limiter: AsyncLimiter

    private var cache: [SlippyTile: CGImage] = [:]
    /// 每片的「最近使用序号」。命中时只改一个整数，淘汰时按序号排一次 ——
    /// 老写法每次命中都要在数组里线性查找一遍（缓存上千片时，每片瓦片上屏都要扫过整个队列）。
    private var lastUse: [SlippyTile: UInt64] = [:]
    private var clock: UInt64 = 0
    private var cachedBytes = 0
    private struct Flight: Sendable {
        let id: UInt64
        let task: Task<CGImage?, Never>
        var consumers: Set<UUID>
    }
    private var inFlight: [SlippyTile: Flight] = [:]
    private var nextFlightID: UInt64 = 0
    private var missingTiles: [SlippyTile: Date] = [:]
    private let retryDelay: TimeInterval
    private let missingDelay: TimeInterval
    /// 每次 `invalidate` 加一：用来丢掉「invalidate 之前发出、之后才回来」的取图结果。
    private var generation = 0

    public init(
        source: any TileImageSource,
        memoryLimitBytes: Int = TileResourcePolicy.defaultTileCacheBytes,
        maxConcurrentDecodes: Int = TileResourcePolicy.concurrentDecodes,
        retryDelay: TimeInterval = 1, missingDelay: TimeInterval = 30
    ) {
        self.source = source
        self.retryDelay = max(0, retryDelay)
        self.missingDelay = max(0, missingDelay)
        self.memoryLimitBytes = max(0, memoryLimitBytes)
        self.limiter = AsyncLimiter(limit: maxConcurrentDecodes)
    }

    /// 来源能提供的层级范围，供相机夹取缩放用。
    public var availableZoomRange: ClosedRange<Int> { source.availableZoomRange }

    /// 当前内存缓存里的瓦片数（状态栏 / 自检用）。
    public var cachedTileCount: Int { cache.count }

    /// 当前内存缓存占用的字节数与瓦片数（内存压力与调试输出用）。
    public var cacheStats: (tiles: Int, bytes: Int) { (cache.count, cachedBytes) }
    package var requestStats: (flights: Int, consumers: Int) {
        (inFlight.count, inFlight.values.reduce(0) { $0 + $1.consumers.count })
    }

    /// 把缓存压到给定字节以内：从最久没用到的开始丢（内存压力下由界面调用）。
    ///
    /// 只丢缓存、不动在途请求与「缺片」负缓存，因此正在看的这一屏不会被清掉。
    public func trimCache(keepingBytes limit: Int) {
        evict(downTo: max(0, limit))
    }

    public func setMemoryLimitBytes(_ limit: Int) {
        memoryLimitBytes = max(0, limit)
        evict(downTo: memoryLimitBytes)
    }

    /// 取瓦片图片；不存在时返回 nil。
    public func image(for tile: SlippyTile, priority: TaskPriority = .userInitiated) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        if let image = cache[tile] {
            touch(tile)
            return image
        }
        if let until = missingTiles[tile], until > Date() { return nil }
        missingTiles[tile] = nil

        let consumer = UUID()
        let flight: Flight
        if var existing = inFlight[tile] {
            existing.consumers.insert(consumer)
            inFlight[tile] = existing
            flight = existing
        } else {
            nextFlightID &+= 1
            let id = nextFlightID
            let source = self.source
            let limiter = self.limiter
            let generation = self.generation
            let task = Task.detached(priority: priority) { () -> CGImage? in
                guard await limiter.acquire(priority: priority) else {
                    return await self.finish(tile: tile, id: id, generation: generation, image: nil, cancelled: true)
                }
                let result: TileLoadResult = Task.isCancelled ? .retry : await source.loadTile(tile)
                await limiter.release()
                return await self.finish(tile: tile, id: id, generation: generation,
                                         image: result.image, cancelled: Task.isCancelled, confirmedMissing: { if case .missing = result { return true }; return false }())
            }
            flight = Flight(id: id, task: task, consumers: [consumer])
            inFlight[tile] = flight
        }

        let image = await withTaskCancellationHandler {
            await flight.task.value
        } onCancel: {
            Task { await self.cancelConsumer(consumer, tile: tile, id: flight.id) }
        }
        return Task.isCancelled ? nil : image
    }

    /// 老请求结束时不能移除 invalidate 后同一瓦片的新请求，也不能写入新缓存。
    private func finish(tile: SlippyTile, id: UInt64, generation: Int,
                        image: CGImage?, cancelled: Bool, confirmedMissing: Bool = false) -> CGImage? {
        guard generation == self.generation, inFlight[tile]?.id == id else { return nil }
        inFlight[tile] = nil
        guard !cancelled else { return nil }
        if let image {
            store(image, for: tile)
        } else {
            if missingTiles.count >= 50_000 { missingTiles.removeAll(keepingCapacity: true) }
            missingTiles[tile] = Date().addingTimeInterval(confirmedMissing ? missingDelay : retryDelay)
        }
        return image
    }

    private func cancelConsumer(_ consumer: UUID, tile: SlippyTile, id: UInt64) {
        guard var flight = inFlight[tile], flight.id == id else { return }
        flight.consumers.remove(consumer)
        if flight.consumers.isEmpty {
            inFlight[tile] = nil
            flight.task.cancel()
        } else {
            inFlight[tile] = flight
        }
    }

    /// 预取一批瓦片（通常是当前视野外面一圈），填进内存缓存让接下来的平移更顺。
    ///
    /// 命中缓存或已确认缺片的直接跳过；失败不抛出，也不影响调用方。
    public func prefetch(_ tiles: [SlippyTile]) async {
        for tile in tiles {
            if Task.isCancelled { return }
            if cache[tile] != nil || (missingTiles[tile].map { $0 > Date() } ?? false) { continue }
            _ = await image(for: tile, priority: .utility)
        }
    }

    /// 清空缓存与负缓存（切换数据源、外部改动过磁盘文件时用）。
    public func invalidate() {
        generation &+= 1
        // 在途任务要真的取消：只丢引用的话它们还会跑完，
        // 既白占并发名额，也需要靠上面的 generation 兜住结果。
        for flight in inFlight.values { flight.task.cancel() }
        cache.removeAll()
        lastUse.removeAll()
        cachedBytes = 0
        missingTiles.removeAll()
        inFlight.removeAll()
    }

    public func retryDate(for tile: SlippyTile) -> Date? { missingTiles[tile] }

    // MARK: - 缓存

    private func store(_ image: CGImage, for tile: SlippyTile) {
        if let existing = cache[tile] {
            cachedBytes -= cost(of: existing)
        }
        cache[tile] = image
        cachedBytes += cost(of: image)
        clock &+= 1
        lastUse[tile] = clock
        // 到顶之后一次退到九成：卡在临界点上每片都要排一次序，
        // 攒一批一起丢反而更省（排序的是键，不复制像素）。
        if cachedBytes > memoryLimitBytes {
            evict(downTo: memoryLimitBytes * 9 / 10)
        }
    }

    private func touch(_ tile: SlippyTile) {
        clock &+= 1
        lastUse[tile] = clock
    }

    /// 丢弃最久没用到的，直到回到 `target` 字节以内。
    private func evict(downTo target: Int) {
        guard cachedBytes > target else { return }
        let victims = cache.keys.sorted { (lastUse[$0] ?? 0) < (lastUse[$1] ?? 0) }
        for victim in victims {
            guard cachedBytes > target else { break }
            if let image = cache.removeValue(forKey: victim) {
                cachedBytes -= cost(of: image)
                lastUse.removeValue(forKey: victim)
            }
        }
    }

    private func cost(of image: CGImage) -> Int {
        max(image.bytesPerRow * image.height, 1)
    }
}
