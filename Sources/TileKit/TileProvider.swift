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

/// 瓦片图片供应者：LRU 内存缓存 + 并发解码 + 缺片负缓存。
public actor TileProvider {
    private let source: DirectoryTileSource
    private let memoryLimitBytes: Int
    private let limiter: AsyncLimiter

    private var cache: [SlippyTile: CGImage] = [:]
    private var recency: [SlippyTile] = []
    private var cachedBytes = 0
    private var inFlight: [SlippyTile: Task<CGImage?, Never>] = [:]
    private var missingTiles: Set<SlippyTile> = []

    public init(source: DirectoryTileSource, memoryLimitBytes: Int = 512 * 1024 * 1024, maxConcurrentDecodes: Int = 6) {
        self.source = source
        self.memoryLimitBytes = memoryLimitBytes
        self.limiter = AsyncLimiter(limit: maxConcurrentDecodes)
    }

    public var dataSource: DirectoryTileSource { source }

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
            let data = source.data(for: tile)
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
