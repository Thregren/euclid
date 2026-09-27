import Foundation

/// 跨瓦片的「解好的块」缓存 + 文件句柄池。
///
/// 为什么需要它：一块影像内部分块（常见 256² 或 512²）往往横跨好几块屏幕瓦片，
/// 而每次取瓦片都从零开始解 —— 同一块数据在相邻瓦片里被重复解压、重复申请缓冲。
/// 平移时这条重复路径正好落在最吃紧的地方（每个瓦片一次 LZW / Deflate 解压，
/// 上百 KB 起步），缩小时同一块更是被反复解。
///
/// 于是这里做两件事：
/// 1. 按「文件 + 层级 + 块号」记住**解好的 RGBA**，跨瓦片复用（按字节封顶，先进先出淘汰）；
/// 2. 按文件池化读句柄，省掉每块瓦片 open / close 一次系统调用。
///
/// 容量很小（默认 64 MB，约 256 块 256²），所以它只是个「热区快取」，
/// 不是把影像读进内存 —— 内存占用仍然与影像大小无关。
///
/// 淘汰策略用先进先出而不是严格 LRU：命中时不必改动队列，一次字典查找就够了，
/// 而这里的工作集（一屏用到的块）远小于容量，两者效果没有差别。
package final class TIFFChunkCache: @unchecked Sendable {
    package static let shared = TIFFChunkCache()

    /// 缓存键：同一份文件里，层级用 IFD 偏移区分，块用序号区分。
    ///
    /// 路径必须在键里：不同影像的 IFD 常常都从偏移 8 开始、块号也都从 0 开始，
    /// 而它们的内容毫无关系 —— 漏掉路径就会把 A 的像素画到 B 上。
    package struct Key: Hashable {
        package let path: String
        package let level: Int
        package let index: Int

        package init(path: String, level: Int, index: Int) {
            self.path = path
            self.level = level
            self.index = index
        }
    }

    /// 自检与调试用的计数。
    package struct Stats: Sendable {
        package var entries = 0
        package var bytes = 0
        package var readers = 0
        package var hits = 0
        package var misses = 0

        package var megabytes: Double { Double(bytes) / 1_048_576 }
    }

    /// 默认字节上限；自检会构造小容量的实例来验证淘汰。
    private let byteLimit: Int
    private let countLimit: Int
    /// 同时保留的读句柄个数（`TIFFFileCache` 也只留 4 份文件）。
    private let readerLimit: Int

    private let lock = NSLock()
    private var pixels: [Key: [UInt8]] = [:]
    private var order: [Key] = []
    private var bytes = 0
    private var hits = 0
    private var misses = 0

    /// 句柄池里的一条：`leases` 是正在用它的调用方数量。
    ///
    /// 关键点是**不能**在还有人在读的时候 `close` —— 那会让正在进行的读拿到
    /// 「坏文件描述符」。所以被淘汰的句柄只打标记（`evicted`），
    /// 等最后一个借用者归还时才真正关上（见 `releaseReader`）。
    private final class ReaderEntry {
        let reader: TIFFSourceFile
        var leases = 0
        var evicted = false

        init(reader: TIFFSourceFile) {
            self.reader = reader
        }
    }

    private var readers: [String: ReaderEntry] = [:]
    private var readerOrder: [String] = []

    package init(byteLimit: Int = 64 << 20, countLimit: Int = 512, readerLimit: Int = 4) {
        self.byteLimit = max(4096, byteLimit)
        self.countLimit = max(1, countLimit)
        self.readerLimit = max(1, readerLimit)
    }

    // MARK: - 块像素

    /// 取解好的块；没有就返回 nil（调用方去解，解完 `store`）。
    package func pixels(for key: Key) -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        guard let cached = pixels[key] else {
            misses += 1
            return nil
        }
        hits += 1
        return cached
    }

    /// 存一块解好的像素。
    package func store(pixels newPixels: [UInt8], for key: Key) {
        // 比整个缓存还大的一块（例如「整幅一条」的横条影像）直接不缓存：
        // 存进去只会把别的块全挤掉，自己还占着一整块的内存。
        guard !newPixels.isEmpty, newPixels.count <= byteLimit else { return }
        lock.lock()
        defer { lock.unlock() }
        guard pixels[key] == nil else { return }
        pixels[key] = newPixels
        order.append(key)
        bytes += newPixels.count
        while order.count > 1, bytes > byteLimit || order.count > countLimit {
            let oldest = order.removeFirst()
            if let dropped = pixels.removeValue(forKey: oldest) {
                bytes -= dropped.count
            }
        }
    }

    // MARK: - 读句柄

    /// 借一个读句柄；返回的凭据释放时自动归还（`deinit`）。
    package func acquireReader(url: URL) throws -> TIFFReaderLease {
        let path = url.path(percentEncoded: false)
        lock.lock()
        if let entry = readers[path] {
            entry.leases += 1
            touch(path)
            lock.unlock()
            return TIFFReaderLease(cache: self, path: path, reader: entry.reader)
        }
        lock.unlock()

        // 打开文件可能失败，放在锁外做（也避免持锁做系统调用）。
        let reader = try TIFFSourceFile(url: url)

        lock.lock()
        // 期间可能有别的线程也开了同一个文件：留一个，多出来的这次直接关掉。
        if let existing = readers[path] {
            existing.leases += 1
            touch(path)
            lock.unlock()
            reader.close()
            return TIFFReaderLease(cache: self, path: path, reader: existing.reader)
        }
        let entry = ReaderEntry(reader: reader)
        entry.leases = 1
        readers[path] = entry
        readerOrder.append(path)
        var doomed: [TIFFSourceFile] = []
        while readerOrder.count > readerLimit {
            let victim = readerOrder.removeFirst()
            guard let victimEntry = readers[victim] else { continue }
            victimEntry.evicted = true
            if victimEntry.leases == 0 {
                readers.removeValue(forKey: victim)
                doomed.append(victimEntry.reader)
            }
        }
        lock.unlock()
        for file in doomed { file.close() }
        return TIFFReaderLease(cache: self, path: path, reader: reader)
    }

    /// 借用者归还（只由 `TIFFReaderLease.deinit` 调用）。
    fileprivate func releaseReader(path: String) {
        var doomed: TIFFSourceFile?
        lock.lock()
        if let entry = readers[path] {
            entry.leases -= 1
            if entry.leases <= 0, entry.evicted {
                doomed = entry.reader
                readers.removeValue(forKey: path)
                readerOrder.removeAll { $0 == path }
            }
        }
        lock.unlock()
        doomed?.close()
    }

    private func touch(_ path: String) {
        // 调用方已持锁。
        if let position = readerOrder.firstIndex(of: path) {
            readerOrder.remove(at: position)
        }
        readerOrder.append(path)
    }

    // MARK: - 失效与收缩

    /// 丢掉某个文件的所有块与句柄（文件被换掉 / 数据集关闭时用）。
    package func invalidate(path: String) {
        var doomed: TIFFSourceFile?
        lock.lock()
        let keys = order.filter { $0.path == path }
        if !keys.isEmpty {
            order.removeAll { $0.path == path }
            for key in keys {
                if let dropped = pixels.removeValue(forKey: key) { bytes -= dropped.count }
            }
        }
        if let entry = readers[path] {
            entry.evicted = true
            if entry.leases == 0 {
                readers.removeValue(forKey: path)
                readerOrder.removeAll { $0 == path }
                doomed = entry.reader
            }
        }
        lock.unlock()
        doomed?.close()
    }

    /// 内存压力下按比例收缩（0…1 表示留多少）。
    package func trim(toFraction fraction: Double) {
        let target = Int(Double(byteLimit) * min(max(fraction, 0), 1))
        lock.lock()
        defer { lock.unlock() }
        while order.count > 1, bytes > target {
            let oldest = order.removeFirst()
            if let dropped = pixels.removeValue(forKey: oldest) { bytes -= dropped.count }
        }
    }

    // MARK: - 自检 / 调试

    package func stats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        var value = Stats()
        value.entries = pixels.count
        value.bytes = bytes
        value.readers = readers.count
        value.hits = hits
        value.misses = misses
        return value
    }

    package func resetStats() {
        lock.lock()
        defer { lock.unlock() }
        hits = 0
        misses = 0
    }

    /// 调试摘要（`EUCLID_DEBUG_MEMORY=1` 打印）。
    package func debugSummary() -> String {
        let value = stats()
        return String(
            format: "块缓存 %d 块/%.1f MB（命中 %d / 未中 %d）· 句柄 %d",
            value.entries, value.megabytes, value.hits, value.misses, value.readers
        )
    }
}

/// 读句柄的借用凭据：`deinit` 时归还，保证「还有人用就不关句柄」。
package final class TIFFReaderLease: @unchecked Sendable {
    package let reader: TIFFSourceFile
    private let cache: TIFFChunkCache
    private let path: String

    init(cache: TIFFChunkCache, path: String, reader: TIFFSourceFile) {
        self.cache = cache
        self.path = path
        self.reader = reader
    }

    deinit {
        cache.releaseReader(path: path)
    }
}

/// 块缓存 / 句柄池的公开入口。
///
/// 应用侧只需要这三件事：数据集关掉时丢掉它的缓存、内存紧张时收缩、
/// 调试时打印一行摘要。缓存本身（`TIFFChunkCache`）不必对外暴露。
public enum RasterCache {
    /// 丢掉某个文件的全部块缓存并关闭它的读句柄（数据集从图层里移除时调用）。
    public static func discard(fileURL: URL) {
        TIFFChunkCache.shared.invalidate(path: fileURL.path(percentEncoded: false))
    }

    /// 内存压力下按比例收缩（0…1 表示留多少）。
    public static func trim(toFraction fraction: Double) {
        TIFFChunkCache.shared.trim(toFraction: fraction)
    }

    /// 一行摘要（`EUCLID_DEBUG_MEMORY=1` 打印，也方便排错时看一眼）。
    public static func debugSummary() -> String {
        TIFFChunkCache.shared.debugSummary()
    }
}
