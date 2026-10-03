import Foundation

/// 只读 ZIP 归档读取器（存储 / deflate 两种方式，支持 ZIP64）。
///
/// 为什么瓦片要放进 zip：exFAT 的簇是 256 KB，一张 16 KB 的瓦片散着放也要占满一个簇，
/// 一千六百万张就是几个 TB。打包成 zip 之后按实际大小占用，而且**不用解压**就能直接读。
///
/// 设计上有三条是冲着「大瓦片包」去的：
///
/// 1. **不把中央目录整个读进内存**：一个 z18 的分卷能有一百多万条记录、中央目录上百 MB。
///    这里只流式扫一遍，记下「每个行号（名字的第一段）对应的字节范围」；
///    查某一格时再单独解析那一行的记录（几十 KB）。
/// 2. **索引按行缓存**：解析过的行做个小 LRU（默认 8 行），一屏用到的行数远小于它。
/// 3. **每次读取只 seek + 读一条**，并核对长度与 CRC：正在下载、只写了一半的分卷
///    不会被当成有效数据（会抛错，调用方按缺片处理）。
public final class ZipArchive: @unchecked Sendable {
    /// 中央目录里的一条记录。
    public struct Entry: Sendable, Hashable {
        public let name: String
        public let method: UInt16
        public let compressedSize: UInt64
        public let uncompressedSize: UInt64
        public let crc32: UInt32
        public let localHeaderOffset: UInt64
    }

    public enum ZipError: Error, CustomStringConvertible {
        case notAZip
        case truncated(String)
        case unsupported(String)
        case corrupt(String)

        public var description: String {
            switch self {
            case .notAZip: return "不是 ZIP 文件（找不到中央目录）"
            case .truncated(let what): return "ZIP 被截断：\(what)"
            case .unsupported(let what): return "不支持的 ZIP 特性：\(what)"
            case .corrupt(let what): return "ZIP 内容损坏：\(what)"
            }
        }
    }

    public let url: URL
    /// 单条记录解压后的上限：瓦片也就几十 KB，超过这个数一定是畸形文件或选错了文件。
    public static let maximumEntryBytes = 64 << 20
    /// 解析中央目录时的读缓冲大小。
    private static let chunkSize = 1 << 21

    private let handle: FileHandle
    private let lock = NSLock()
    /// 文件长度。读数据前用它兜一道，畸形索引里的超大长度就不会变成巨量内存申请。
    private var fileSize: UInt64 = 0
    /// 行号（名字里第一段）→ 该行所有记录在中央目录里占据的字节范围。
    private var rowSpans: [String: (start: UInt64, end: UInt64)] = [:]
    /// 已解析的行 → （完整名字 → 记录）。
    private var rowTables: [String: [String: Entry]] = [:]
    private var rowOrder: [String] = []
    /// 解析过的行做个小 LRU。
    ///
    /// 一屏通常只落在十几行上（z17 一条行里三千多个条目，一张行表约 400 KB），
    /// 12 行既能把整屏盖住，内存也压在几 MB 量级。
    private static let rowCacheLimit = 12

    public private(set) var entryCount = 0
    public private(set) var centralDirectorySize: UInt64 = 0
    public private(set) var isZip64 = false

    public init(url: URL) throws {
        self.url = url
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ZipError.notAZip
        }
        self.handle = handle
        do {
            try readCentralDirectory()
        } catch {
            try? handle.close()
            throw error
        }
    }

    deinit {
        try? handle.close()
    }

    // MARK: - 查询

    /// 按完整名字查一条记录（例如 `45224/215425.jpg`）。
    public func entry(named name: String) -> Entry? {
        table(forRow: Self.rowPrefix(of: name))[name]
    }

    /// 读出并校验一条记录的内容。
    public func data(for entry: Entry) throws -> Data {
        try Self.read(entry: entry, handle: handle, fileSize: fileSize)
    }

    /// 读一条记录的内容。句柄与文件长度由调用方给：轻量取样（`sampleEntry`）没有索引，
    /// 只有一个临时句柄，走的是同一段读法 —— 长度与 CRC 的校验口径也就只有一处。
    static func read(entry: Entry, handle: FileHandle, fileSize: UInt64) throws -> Data {
        guard entry.method != 0xFFFF else {
            throw ZipError.unsupported("加密记录：\(entry.name)")
        }
        guard entry.uncompressedSize <= UInt64(Self.maximumEntryBytes) else {
            throw ZipError.unsupported("单条记录解压后 \(entry.uncompressedSize) 字节")
        }
        // 这里不加锁：读走 `pread`（无句柄状态），`fileSize` 在 init 之后只读，
        // 解压与 CRC 都是纯函数。持锁读一整条记录会把同包其他行全挡住 ——
        // 一个 64 MB 的条目就是一次几百毫秒的停顿。

        // 本地文件头：长度字段可能与中央目录不同（数据描述符），
        // 所以**只**用它算数据的起点，长度与 CRC 一律以中央目录为准。
        let header = read(handle: handle, at: entry.localHeaderOffset, count: 30)
        guard header.count == 30, header.u32(0) == 0x0403_4B50 else {
            throw ZipError.corrupt("本地文件头签名不对：\(entry.name)")
        }
        let nameLength = UInt64(header.u16(26))
        let extraLength = UInt64(header.u16(28))
        let dataOffset = entry.localHeaderOffset + 30 + nameLength + extraLength
        // 长度一律以中央目录为准，但先拿文件长度兜一道：畸形（或只写了一半）的索引里
        // 那个「压缩后大小」可以是任意值，照着它去分配缓冲会直接把内存吃掉。
        guard entry.compressedSize <= UInt64(Self.maximumEntryBytes),
              dataOffset <= fileSize,
              entry.compressedSize <= fileSize - dataOffset else {
            throw ZipError.corrupt("记录超出文件范围：\(entry.name)")
        }

        let packed = read(handle: handle, at: dataOffset, count: Int(entry.compressedSize))
        guard UInt64(packed.count) == entry.compressedSize else {
            throw ZipError.truncated("\(entry.name) 的数据不完整")
        }

        let payload: Data
        switch entry.method {
        case 0:
            payload = packed
        case 8:
            guard let inflated = ZIP.inflate(packed, capacity: Int(entry.uncompressedSize)) else {
                throw ZipError.corrupt("deflate 解不开：\(entry.name)")
            }
            payload = inflated
        default:
            throw ZipError.unsupported("压缩方式 \(entry.method)：\(entry.name)")
        }
        guard UInt64(payload.count) == entry.uncompressedSize else {
            throw ZipError.corrupt("长度对不上：\(entry.name)")
        }
        guard ZIP.crc32(payload) == entry.crc32 else {
            throw ZipError.corrupt("CRC 对不上：\(entry.name)")
        }
        return payload
    }

    /// 轻量取样：只读中央目录**开头**的一小块，取一条读得出来的记录。
    ///
    /// 用于「只看一眼」的活，比如量一下瓦片边长。一个年度合并包的中央目录上 GB，
    /// 为了量边长把它整个扫一遍纯属白读；而中央目录开头的几十条记录里随便一条都是真瓦片。
    /// 返回 nil 表示开头这段没有读得出来的记录（截断、空包、畸形包），
    /// 调用方该退回「老老实实建索引」那条路 —— 轻量取样只是省事，不改变判据。
    public static func sampleEntry(
        at url: URL,
        limit: Int = 8
    ) throws -> (entry: Entry, data: Data)? {
        guard limit > 0 else { return nil }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ZipError.notAZip
        }
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let directory = try locateCentralDirectory(handle: handle, fileSize: size)
        guard directory.size > 0 else { return nil }
        // 一条记录连名字一般几十字节，64 KB 足够罩住开头一小把；不够就少取几条。
        let budget = Int(min(UInt64(64 << 10), directory.size))
        let head = read(handle: handle, at: directory.offset, count: budget)

        var offset = 0
        var taken = 0
        while taken < limit, offset + 46 <= head.count, head.u32(offset) == 0x0201_4B50 {
            let nameLength = Int(head.u16(offset + 28))
            let extraLength = Int(head.u16(offset + 30))
            let commentLength = Int(head.u16(offset + 32))
            let recordLength = 46 + nameLength + extraLength + commentLength
            guard recordLength >= 46, offset + recordLength <= head.count else { break }
            let base = head.startIndex + offset
            let name = String(decoding: head[(base + 46)..<(base + 46 + nameLength)], as: UTF8.self)
            let extra = Data(head[(base + 46 + nameLength)..<(base + 46 + nameLength + extraLength)])
            let entry = makeEntry(name: name, record: head, offset: offset, extra: extra)
            offset += recordLength
            taken += 1
            if let data = try? read(entry: entry, handle: handle, fileSize: size) {
                return (entry, data)
            }
        }
        return nil
    }

    /// 某一行的全部条目名（升序）。探测覆盖范围用。
    public func entryNames(inRow row: String) -> [String] {
        return table(forRow: row).keys.sorted()
    }

    /// 索引里出现过的行号（升序，数字行号）。
    public var indexedRows: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return rowSpans.keys.compactMap(Int.init).sorted()
    }

    // MARK: - 中央目录

    /// 中央目录的落点：位置、长度、条目数，以及它是不是 ZIP64 记的。
    struct CentralDirectory {
        var offset: UInt64
        var size: UInt64
        var entries: UInt64
        var isZip64: Bool
    }

    /// 从文件末尾的 EOCD（必要时再往前找 ZIP64 结束记录）读出中央目录的落点。
    ///
    /// 只读文件尾部的一小块，所以「只想看一眼」的取样不必建全量索引。
    static func locateCentralDirectory(
        handle: FileHandle,
        fileSize size: UInt64
    ) throws -> CentralDirectory {
        guard size >= 22 else { throw ZipError.notAZip }
        // 中央目录结束记录（EOCD）在文件末尾 22 字节 + 最多 65535 字节注释之内。
        let tailLength = Int(min(size, 22 + 65_535))
        let tail = read(handle: handle, at: size - UInt64(tailLength), count: tailLength)
        guard let eocd = lastIndex(of: 0x0605_4B50, in: tail), tail.count >= eocd + 22 else {
            throw ZipError.notAZip
        }

        var entries = UInt64(tail.u16(eocd + 10))
        var directorySize = UInt64(tail.u32(eocd + 12))
        var directoryOffset = UInt64(tail.u32(eocd + 16))
        var isZip64 = false

        // ZIP64：固定字段被填满（0xFFFF / 0xFFFFFFFF）时，真值放在 ZIP64 结束记录里，
        // 它的位置由紧挨 EOCD 前面的定位器给出。
        let needsZip64 = entries == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF
        if needsZip64 {
            guard eocd >= 20, tail.u32(eocd - 20) == 0x0706_4B50 else {
                throw ZipError.corrupt("缺少 ZIP64 定位器")
            }
            let record = read(handle: handle, at: tail.u64(eocd - 20 + 8), count: 56)
            guard record.count == 56, record.u32(0) == 0x0606_4B50 else {
                throw ZipError.corrupt("ZIP64 结束记录签名不对")
            }
            entries = record.u64(32)
            directorySize = record.u64(40)
            directoryOffset = record.u64(48)
            isZip64 = true
        }
        guard directoryOffset <= size, directorySize <= size - directoryOffset else {
            throw ZipError.truncated("中央目录越过了文件末尾")
        }
        return CentralDirectory(
            offset: directoryOffset,
            size: directorySize,
            entries: entries,
            isZip64: isZip64
        )
    }

    private func readCentralDirectory() throws {
        let size = try handle.seekToEnd()
        fileSize = size
        guard size >= 22 else { throw ZipError.notAZip }
        // 先看有没有上次留下的索引：命中的话连中央目录都不用扫（一个 z18 分卷上百万条
        // 记录，扫一遍要一二百毫秒，而索引落盘只要几 KB）。
        if let cached = ZipIndexCache.load(for: url, fileSize: size) {
            rowSpans = cached.rowSpans
            entryCount = cached.entryCount
            centralDirectorySize = cached.centralDirectorySize
            isZip64 = cached.isZip64
            return
        }
        let directory = try Self.locateCentralDirectory(handle: handle, fileSize: size)
        entryCount = Int(directory.entries)
        centralDirectorySize = directory.size
        isZip64 = directory.isZip64
        try indexRows(directoryOffset: directory.offset, directorySize: directory.size)
        // 扫完了就把索引存一份：下次打开同一份数据（同一路径、同一大小与修改时间）
        // 直接命中，不用再逐个分卷扫一遍中央目录。还在下载中的分卷大小会变，自然不会命中旧索引。
        ZipIndexCache.save(
            rowSpans: rowSpans,
            entryCount: entryCount,
            centralDirectorySize: centralDirectorySize,
            isZip64: isZip64,
            for: url,
            fileSize: size
        )
    }

    /// 流式扫一遍中央目录，只记「行 → 字节范围」，不保留记录本身。
    private func indexRows(directoryOffset: UInt64, directorySize: UInt64) throws {
        try forEachRecord(from: directoryOffset, to: directoryOffset + directorySize) { name, _, start, length in
            let row = Self.rowPrefix(of: name)
            if let span = rowSpans[row] {
                rowSpans[row] = (min(span.start, start), max(span.end, start + UInt64(length)))
            } else {
                rowSpans[row] = (start, start + UInt64(length))
            }
        }
    }

    /// 解析某一行的全部记录（带缓存）。
    ///
    /// 两处讲究：
    /// 1. **失败不写缓存**。读盘出错或中央目录当场损坏时，如果把空表记进 LRU，
    ///    这一行就永久变成「没有瓦片」——画面一直缺那一块，重启才好。
    ///    一次瞬时失败（外置盘掉线、分卷还在下载）不该有这种后果。
    /// 2. **解析在锁外做**。一行可能有几千条记录、几十到几百 KB，持锁解析会把
    ///    同一个包里其他行的读全挡住，正好落在拖动取图的热路径上。
    private func table(forRow row: String) -> [String: Entry] {
        lock.lock()
        if let cached = rowTables[row] {
            lock.unlock()
            return cached
        }
        guard let span = rowSpans[row] else {
            lock.unlock()
            return [:]
        }
        lock.unlock()

        var table: [String: Entry] = [:]
        let prefix = row.isEmpty ? "" : row + "/"
        do {
            try forEachRecord(from: span.start, to: span.end) { name, entry, _, _ in
                guard name.hasPrefix(prefix) else { return }
                table[name] = entry
            }
        } catch {
            return [:]
        }

        lock.lock()
        // 期间可能有别的线程把同一行填好了：用它那份，别覆盖。
        if let cached = rowTables[row] {
            lock.unlock()
            return cached
        }
        rowTables[row] = table
        rowOrder.append(row)
        while rowOrder.count > Self.rowCacheLimit {
            rowTables[rowOrder.removeFirst()] = nil
        }
        lock.unlock()
        return table
    }

    /// 流式遍历一段中央目录：每次回调给出名字、记录与它在文件里的位置。
    private func forEachRecord(
        from start: UInt64,
        to end: UInt64,
        _ body: (_ name: String, _ entry: Entry, _ recordStart: UInt64, _ recordLength: Int) -> Void
    ) throws {
        var buffer = Data()
        var bufferFileOffset = start
        var cursor = start
        var offset = 0

        /// 保证缓冲里从 `offset` 起至少有 `count` 字节。
        func ensure(_ count: Int) -> Bool {
            while buffer.count - offset < count, cursor < end {
                let want = Int(min(UInt64(Self.chunkSize), end - cursor))
                buffer.append(read(at: cursor, count: want))
                cursor += UInt64(want)
            }
            return buffer.count - offset >= count
        }

        while ensure(46) {
            guard buffer.u32(offset) == 0x0201_4B50 else {
                throw ZipError.corrupt("中央目录记录签名不对（文件偏移 \(bufferFileOffset + UInt64(offset))）")
            }
            let nameLength = Int(buffer.u16(offset + 28))
            let extraLength = Int(buffer.u16(offset + 30))
            let commentLength = Int(buffer.u16(offset + 32))
            let recordLength = 46 + nameLength + extraLength + commentLength
            guard ensure(recordLength) else {
                throw ZipError.truncated("中央目录记录不完整")
            }

            let base = buffer.startIndex + offset
            let name = String(decoding: buffer[(base + 46)..<(base + 46 + nameLength)], as: UTF8.self)
            let extra = Data(buffer[(base + 46 + nameLength)..<(base + 46 + nameLength + extraLength)])
            let entry = Self.makeEntry(name: name, record: buffer, offset: offset, extra: extra)
            body(name, entry, bufferFileOffset + UInt64(offset), recordLength)

            offset += recordLength
            // 攒够一块就把已经用掉的部分丢掉，避免整个中央目录都留在内存里。
            if offset >= Self.chunkSize {
                buffer = Data(buffer[(buffer.startIndex + offset)...])
                bufferFileOffset += UInt64(offset)
                offset = 0
            }
        }
    }

    private static func makeEntry(name: String, record: Data, offset: Int, extra: Data) -> Entry {
        let flags = record.u16(offset + 8)
        var method = record.u16(offset + 10)
        if flags & 0x1 != 0 { method = 0xFFFF }  // 加密：调用方一律当不支持
        let compressed = UInt64(record.u32(offset + 20))
        let uncompressed = UInt64(record.u32(offset + 24))
        let crc = record.u32(offset + 16)
        var sizes: (uncompressed: UInt64, compressed: UInt64, offset: UInt64) = (
            uncompressed, compressed, UInt64(record.u32(offset + 42))
        )

        // ZIP64 扩展字段：只补齐那些在固定字段里被写成「满值」的项，顺序固定
        // （原始长度、压缩长度、本地头偏移、分卷号）。
        if uncompressed == 0xFFFF_FFFF || compressed == 0xFFFF_FFFF || sizes.offset == 0xFFFF_FFFF {
            var cursor = 0
            while cursor + 4 <= extra.count {
                let id = extra.u16(cursor)
                let size = Int(extra.u16(cursor + 2))
                let body = cursor + 4
                guard body + size <= extra.count else { break }
                if id == 0x0001 {
                    var at = body
                    if uncompressed == 0xFFFF_FFFF, at + 8 <= body + size {
                        sizes.uncompressed = extra.u64(at); at += 8
                    }
                    if compressed == 0xFFFF_FFFF, at + 8 <= body + size {
                        sizes.compressed = extra.u64(at); at += 8
                    }
                    if sizes.offset == 0xFFFF_FFFF, at + 8 <= body + size {
                        sizes.offset = extra.u64(at)
                    }
                    break
                }
                cursor = body + size
            }
        }

        return Entry(
            name: name,
            method: method,
            compressedSize: sizes.compressed,
            uncompressedSize: sizes.uncompressed,
            crc32: crc,
            localHeaderOffset: sizes.offset
        )
    }

    // MARK: - 工具

    /// 按绝对偏移读一段；读不满或出错就返回读到的那部分（调用方各自校验长度）。
    ///
    /// 走 `pread`（不依赖句柄的读写位置）：这样多线程同时查同一个包的不同行时
    /// 不必互相排队，`lock` 也就只需要保护索引缓存，不再覆盖磁盘 IO。
    private func read(at offset: UInt64, count: Int) -> Data {
        Self.read(handle: handle, at: offset, count: count)
    }

    /// 与上同，只是句柄由调用方给（轻量取样用临时句柄，没有索引可用）。
    private static func read(handle: FileHandle, at offset: UInt64, count: Int) -> Data {
        guard count > 0, offset <= UInt64(Int64.max), offset <= UInt64(Int.max - count) else { return Data() }
        var data = Data(count: count)
        var total = 0
        let descriptor = handle.fileDescriptor
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while total < count {
                let read = pread(descriptor, base.advanced(by: total), count - total, off_t(offset) + off_t(total))
                if read <= 0 { break }
                total += read
            }
        }
        guard total > 0 else { return Data() }
        return total == count ? data : data.prefix(total)
    }

    /// 名字里的第一段（`45224/215425.jpg` → `45224`）。
    static func rowPrefix(of name: String) -> String {
        guard let slash = name.firstIndex(of: "/") else { return "" }
        return String(name[name.startIndex..<slash])
    }

    private static func lastIndex(of signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        var index = data.count - 4
        while index >= 0 {
            if data.u32(index) == signature { return index }
            index -= 1
        }
        return nil
    }
}

/// 小端读取（ZIP 的所有整数字段都是小端）。偏移一律相对 `startIndex`，
/// 因为 `Data` 的切片可能保留非零起点。
extension Data {
    func u16(_ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        let start = startIndex + offset
        return UInt16(self[start]) | (UInt16(self[start + 1]) << 8)
    }

    func u32(_ offset: Int) -> UInt32 {
        UInt32(u16(offset)) | (UInt32(u16(offset + 2)) << 16)
    }

    func u64(_ offset: Int) -> UInt64 {
        UInt64(u32(offset)) | (UInt64(u32(offset + 4)) << 32)
    }
}
