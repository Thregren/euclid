import CoreGraphics
import Foundation

/// 并发闸门，限制同时进行的解码数量。
actor AsyncLimiter {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// 瓦片图片供应者：LRU 内存缓存 + 并发取图/解码 + 缺片负缓存。
///
/// 来源可以是本地目录，也可以是在线服务（见 `TileImageSource`）；
/// 对上层来说只有「拿到图 / 这片没有」两种结果。
public actor TileProvider {
    private let source: any TileImageSource
    private let memoryLimitBytes: Int
    private let limiter: AsyncLimiter

    private var cache: [SlippyTile: CGImage] = [:]
    private var recency: [SlippyTile] = []
    private var cachedBytes = 0
    private var inFlight: [SlippyTile: Task<CGImage?, Never>] = [:]
    private var missingTiles: Set<SlippyTile> = []

    public init(
        source: any TileImageSource,
        memoryLimitBytes: Int = 512 * 1024 * 1024,
        maxConcurrentDecodes: Int = 8
    ) {
        self.source = source
        self.memoryLimitBytes = memoryLimitBytes
        self.limiter = AsyncLimiter(limit: maxConcurrentDecodes)
    }

    /// 来源能提供的层级范围，供相机夹取缩放用。
    public var availableZoomRange: ClosedRange<Int> { source.availableZoomRange }

    /// 当前内存缓存里的瓦片数（状态栏 / 自检用）。
    public var cachedTileCount: Int { cache.count }

    /// 取瓦片图片；不存在时返回 nil。
    public func image(for tile: SlippyTile) async -> CGImage? {
        if let image = cache[tile] {
            touch(tile)
            return image
        }
        if missingTiles.contains(tile) { return nil }
        if let task = inFlight[tile] { return await task.value }

        let source = self.source
        let limiter = self.limiter
        let task = Task.detached(priority: .userInitiated) { () -> CGImage? in
            await limiter.acquire()
            let data = await source.data(for: tile)
            let image = data.flatMap { ImageDecoder.decode($0) }
            await limiter.release()
            return image
        }
        inFlight[tile] = task

        let image = await task.value
        inFlight[tile] = nil
        if let image {
            store(image, for: tile)
        } else {
            if missingTiles.count > 50_000 { missingTiles.removeAll(keepingCapacity: true) }
            missingTiles.insert(tile)
        }
        return image
    }

    /// 预取一批瓦片（通常是当前视野外面一圈），填进内存缓存让接下来的平移更顺。
    ///
    /// 命中缓存或已确认缺片的直接跳过；失败不抛出，也不影响调用方。
    public func prefetch(_ tiles: [SlippyTile]) async {
        for tile in tiles {
            if Task.isCancelled { return }
            if cache[tile] != nil || missingTiles.contains(tile) { continue }
            _ = await image(for: tile)
        }
    }

    /// 清空缓存与负缓存（切换数据源、外部改动过磁盘文件时用）。
    public func invalidate() {
        cache.removeAll()
        recency.removeAll()
        cachedBytes = 0
        missingTiles.removeAll()
        inFlight.removeAll()
    }

    // MARK: - 缓存

    private func store(_ image: CGImage, for tile: SlippyTile) {
        if let existing = cache[tile] {
            cachedBytes -= cost(of: existing)
            recency.removeAll { $0 == tile }
        }
        cache[tile] = image
        recency.append(tile)
        cachedBytes += cost(of: image)
        evictIfNeeded()
    }

    private func touch(_ tile: SlippyTile) {
        guard let index = recency.firstIndex(of: tile), index != recency.count - 1 else { return }
        recency.remove(at: index)
        recency.append(tile)
    }

    private func evictIfNeeded() {
        while cachedBytes > memoryLimitBytes, let oldest = recency.first {
            recency.removeFirst()
            if let image = cache.removeValue(forKey: oldest) {
                cachedBytes -= cost(of: image)
            }
        }
    }

    private func cost(of image: CGImage) -> Int {
        max(image.bytesPerRow * image.height, 1)
    }
}
