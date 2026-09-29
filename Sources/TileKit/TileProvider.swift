import CoreGraphics
import Foundation

/// 并发闸门，限制同时进行的解码数量。
///
/// 排队期间被取消（切数据集、图层被移除）要真的走人：既不再占名额，也不去取图。
/// 取消与放行都会 resume 等待者，所以等待者用一个小盒子记住「这次到底是哪种」，
/// 调用方据此决定要不要 `release` —— 多算一次少算一次都会把名额算歪。
actor AsyncLimiter {
    private final class Waiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var cancelled = false
        private var granted = false

        /// 入队。若在此之前就被取消，直接放行（名额不归它，`release` 那边会自己退回去）。
        func install(_ continuation: CheckedContinuation<Void, Never>) {
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func markCancelled() {
            lock.lock()
            cancelled = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }

        /// 把名额交给这个等待者；返回 false 表示它已被取消（名额还得留给别人）。
        func grant() -> Bool {
            lock.lock()
            if cancelled {
                lock.unlock()
                return false
            }
            granted = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
            return continuation != nil
        }

        var isGranted: Bool {
            lock.lock()
            defer { lock.unlock() }
            return granted
        }
    }

    private let limit: Int
    private var active = 0
    private var waiters: [Waiter] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// 等一个名额。返回 false 表示等待期间被取消：**没有**占住名额，不要再调 `release`。
    func acquire() async -> Bool {
        if Task.isCancelled { return false }
        if active < limit {
            active += 1
            return true
        }
        let waiter = Waiter()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(waiter)
                waiter.install(continuation)
            }
        } onCancel: {
            Task { await self.cancel(waiter) }
        }
        return waiter.isGranted
    }

    func release() {
        // 被取消的等待者可能还留在队列里（入队与取消的先后顺序不定），
        // 跳过它们，把名额交给下一个真正在等的人。
        while !waiters.isEmpty {
            if waiters.removeFirst().grant() { return }
        }
        active = max(0, active - 1)
    }

    private func cancel(_ waiter: Waiter) {
        if let index = waiters.firstIndex(where: { $0 === waiter }) {
            waiters.remove(at: index)
        }
        waiter.markCancelled()
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
    /// 每片的「最近使用序号」。命中时只改一个整数，淘汰时按序号排一次 ——
    /// 老写法每次命中都要在数组里线性查找一遍（缓存上千片时，每片瓦片上屏都要扫过整个队列）。
    private var lastUse: [SlippyTile: UInt64] = [:]
    private var clock: UInt64 = 0
    private var cachedBytes = 0
    private var inFlight: [SlippyTile: Task<CGImage?, Never>] = [:]
    private var missingTiles: Set<SlippyTile> = []
    /// 每次 `invalidate` 加一：用来丢掉「invalidate 之前发出、之后才回来」的取图结果。
    private var generation = 0

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

    /// 当前内存缓存占用的字节数与瓦片数（内存压力与调试输出用）。
    public var cacheStats: (tiles: Int, bytes: Int) { (cache.count, cachedBytes) }

    /// 把缓存压到给定字节以内：从最久没用到的开始丢（内存压力下由界面调用）。
    ///
    /// 只丢缓存、不动在途请求与「缺片」负缓存，因此正在看的这一屏不会被清掉。
    public func trimCache(keepingBytes limit: Int) {
        evict(downTo: max(0, limit))
    }

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
        let generation = self.generation
        let task = Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard await limiter.acquire() else { return nil }
            // 排到队时可能已经被取消（切数据集 / 图层被移除）：放回名额就走，别白解一张。
            if Task.isCancelled {
                await limiter.release()
                return nil
            }
            let image = await source.image(for: tile)
            await limiter.release()
            return image
        }
        inFlight[tile] = task

        let image = await task.value
        inFlight[tile] = nil
        // 期间被 invalidate（换了数据集、文件被外部改过）时，这一张属于上一份数据，
        // 不能写进新缓存 —— 否则新数据集的画面上会冒出旧数据集的瓦片。
        guard generation == self.generation else { return nil }
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
        generation &+= 1
        // 在途任务要真的取消：只丢引用的话它们还会跑完，
        // 既白占并发名额，也需要靠上面的 generation 兜住结果。
        for task in inFlight.values { task.cancel() }
        cache.removeAll()
        lastUse.removeAll()
        cachedBytes = 0
        missingTiles.removeAll()
        inFlight.removeAll()
    }

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
