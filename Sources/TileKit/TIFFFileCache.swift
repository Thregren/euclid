import Foundation

final class TIFFFileCache: @unchecked Sendable {
    static let shared = TIFFFileCache()

    /// 一份文件的「时间戳 + 大小」，用来发现文件被外部换掉了。
    private struct Entry {
        var file: TIFFFile
        var stamp: FileIdentity?
    }

    private let lock = NSLock()
    private var files: [String: Entry] = [:]
    private var order: [String] = []
    private let limit = 4
    /// 检查文件是否被改过的最短间隔：每块瓦片都 stat 一次太浪费，一秒一次足够。
    private var lastStampCheck: [String: Date] = [:]
    private let stampCheckInterval: TimeInterval = 1

    func file(for url: URL, forceIdentityCheck: Bool = false) -> TIFFFile? {
        let key = url.path(percentEncoded: false)
        let now = Date()

        lock.lock()
        // `lastStampCheck` 也在这个锁里 —— 它是个可变状态，多个解码线程同时进来时
        // 在锁外读写就是数据竞争（`Date` 不是原子的）。
        let shouldCheckStamp = forceIdentityCheck || now.timeIntervalSince(lastStampCheck[key] ?? .distantPast) >= stampCheckInterval
        if shouldCheckStamp { lastStampCheck[key] = now }
        let known = files[key]
        lock.unlock()

        if let known {
            // 没到该检查的间隔就直接用解析结果；到了就 stat 一次看看文件是不是被换过
            //（stat 放在锁外做，别让磁盘 IO 占着这份表的锁）。
            guard shouldCheckStamp else { return known.file }
            let stamp = Self.stamp(of: url)
            if known.stamp == stamp { return known.file }
            // 文件被换掉了：结构要重解析，已经解出来的块也不能再用（尺寸 / 分块都可能变了）。
            lock.lock()
            if files[key]?.stamp == known.stamp {
                files.removeValue(forKey: key)
                order.removeAll { $0 == key }
            }
            lock.unlock()
            TIFFChunkCache.shared.invalidate(path: key)
        }

        // Never label old IFD data with a replacement file's identity if it changed mid-parse.
        guard let identity = Self.stamp(of: url),
              let parsed = try? TIFFReader.parse(url: url),
              Self.stamp(of: url) == identity else { return nil }
        let entry = Entry(file: parsed, stamp: identity)
        lock.lock()
        if files[key] == nil {
            files[key] = entry
            order.append(key)
            while order.count > limit {
                let evicted = order.removeFirst()
                files.removeValue(forKey: evicted)
                lastStampCheck[evicted] = nil
            }
        }
        lock.unlock()
        return parsed
    }

    /// 丢弃某个文件的解析结果（文件被外部改动后用）。
    func invalidate(_ url: URL) {
        let key = url.path(percentEncoded: false)
        lock.lock()
        files.removeValue(forKey: key)
        lastStampCheck[key] = nil
        order.removeAll { $0 == key }
        lock.unlock()
        TIFFChunkCache.shared.invalidate(path: key)
    }

    private static func stamp(of url: URL) -> FileIdentity? { FileIdentity(url: url) }
}

/// 解码出错时的提示（同一类错误只报一次，别在日志里刷屏）。
enum TIFFDiagnostics {
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var reported = Set<String>()

        func insertIfNew(_ key: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return reported.insert(key).inserted
        }
    }

    private static let store = Store()

    static func record(error: Error, tile: SlippyTile, file: URL) {
        let key = "\(file.lastPathComponent):\(error)"
        guard store.insertIfNew(key) else { return }
        FileHandle.standardError.write(Data(
            "[tiff] \(file.lastPathComponent) 瓦片 \(tile)：\(error)\n".utf8
        ))
    }

    /// 记一条「不致命但值得知道」的情况（例如某个块解出来比声明的短，只能补零）。
    ///
    /// 这类问题以前是完全静默的：画面上只是那一块发黑，没人知道为什么。
    static func record(message: String, file: URL) {
        let key = "\(file.lastPathComponent):\(message)"
        guard store.insertIfNew(key) else { return }
        FileHandle.standardError.write(Data(
            "[tiff] \(file.lastPathComponent)：\(message)\n".utf8
        ))
    }
}
