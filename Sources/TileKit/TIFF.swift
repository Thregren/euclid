import Compression
import CoreGraphics
import Foundation
import ImageIO

/// TIFF 解析出来的文件结构，以及「按需解码某个区域」的能力。
///
/// 为什么自己读 TIFF：`ImageIO` 能把整张图解出来，但正射影像动辄上亿像素，
/// 整张大图进内存不现实；更要紧的是 `ImageIO` 不暴露 GeoTIFF 的地理标签
/// （ModelPixelScale / ModelTiepoint / GeoKeyDirectory），没有这些就摆不对位置。
/// 因此这里只读 IFD（目录结构）拿到尺寸、分块表与地理标签，
/// 再按屏幕需要的区域逐块解压、采样，内存占用与文件大小无关。
public struct TIFFFile: Sendable {
    public let url: URL
    let byteOrder: TIFFByteOrder
    let isBigTIFF: Bool
    /// 主图（分辨率最高的一级）。
    let main: TIFFImageFileDirectory
    /// 内建概览（SubIFD 或串在 IFD 链上的低分辨率级），按分辨率从小到大。
    let overviews: [TIFFImageFileDirectory]

    public var pixelWidth: Int { main.width }
    public var pixelHeight: Int { main.height }
    public var geo: TIFFGeoTags { main.geo }
    public var isTiled: Bool { main.isTiled }
    public var compressionDescription: String { main.compression.description }
    public var bitsPerSample: Int { main.bitsPerSample.first ?? 8 }
    public var hasAlpha: Bool { main.hasAlpha }

    /// 所有可用层级：概览 + 主图，分辨率升序。
    var levels: [TIFFImageFileDirectory] { overviews + [main] }
}

/// TIFF 字节序。
enum TIFFByteOrder: Sendable {
    case little
    case big
}

/// 压缩方式（标签 259）。
enum TIFFCompression: Equatable, Sendable {
    case none
    case lzw
    case deflate
    case packBits
    case jpeg
    case other(Int)

    init(code: Int) {
        switch code {
        case 1: self = .none
        case 5: self = .lzw
        case 6, 7: self = .jpeg
        case 8, 32946: self = .deflate
        case 32773: self = .packBits
        default: self = .other(code)
        }
    }

    var isSupported: Bool {
        if case .other = self { return false }
        return true
    }

    var description: String {
        switch self {
        case .none: return "未压缩"
        case .lzw: return "LZW"
        case .deflate: return "Deflate"
        case .packBits: return "PackBits"
        case .jpeg: return "JPEG"
        case .other(let code): return "未支持（\(code)）"
        }
    }
}

/// 光度解释（标签 262）。
enum TIFFPhotometricRaw: Equatable, Sendable {
    case whiteIsZero
    case blackIsZero
    case rgb
    case palette
    case ycbcr
    case other(Int)

    init(code: Int) {
        switch code {
        case 0: self = .whiteIsZero
        case 1: self = .blackIsZero
        case 2: self = .rgb
        case 3: self = .palette
        case 6: self = .ycbcr
        default: self = .other(code)
        }
    }
}

/// 一个数据块（tile 或 strip）在文件里的位置。
struct TIFFChunk: Sendable {
    var offset: Int
    var byteCount: Int
}

/// GeoTIFF 的地理标签原样保留，交给 `GeoTIFF` 解释。
public struct TIFFGeoTags: Sendable, Hashable {
    public var pixelScale: [Double]?
    public var tiePoints: [Double]?
    public var transformation: [Double]?
    public var keyDirectory: [UInt16]?
    public var doubleParameters: [Double]?
    public var asciiParameters: String?
    public var noData: String?

    public var isEmpty: Bool {
        pixelScale == nil && tiePoints == nil && transformation == nil && keyDirectory == nil
    }
}

/// 一个 IFD（主图或某一级概览）里我们关心的字段。
struct TIFFImageFileDirectory: Sendable {
    /// 这一级 IFD 在文件里的偏移。解析出来的结构本身没有唯一编号，
    /// 而跨瓦片的块缓存需要一个稳定的键，偏移天然就满足（同一份文件里不会重复）。
    var offset = 0
    var width = 0
    var height = 0
    var samplesPerPixel = 1
    var bitsPerSample: [Int] = [8]
    var sampleFormat: [Int] = [1]
    var compression: TIFFCompression = .none
    var photometric: TIFFPhotometricRaw = .blackIsZero
    var planarConfiguration = 1
    var predictor = 1
    var colorMap: [UInt16]?
    var extraSamples: [Int] = []
    var jpegTables: Data?
    var isTiled = false
    /// 单个数据块的像素尺寸（分块图 = 瓦片尺寸；横条图 = 整行宽 × 条带高）。
    var chunkWidth = 0
    var chunkHeight = 0
    var chunks: [TIFFChunk] = []
    var geo = TIFFGeoTags()

    var bitsPerSampleUniform: Int? {
        let value = bitsPerSample.first ?? 8
        return bitsPerSample.allSatisfy { $0 == value } ? value : nil
    }

    var bytesPerSample: Int { max(1, (bitsPerSample.first ?? 8) / 8) }

    var hasAlpha: Bool { samplesPerPixel > (photometric == .rgb ? 3 : 1) }

    var chunksAcross: Int {
        guard chunkWidth > 0 else { return 0 }
        return (width + chunkWidth - 1) / chunkWidth
    }

    var chunksDown: Int {
        guard chunkHeight > 0 else { return 0 }
        return (height + chunkHeight - 1) / chunkHeight
    }

    /// 某一行的像素数（按采样数算）。
    func rowSampleCount(forChunk index: Int) -> Int {
        let row = index / max(1, chunksAcross)
        let start = row * chunkHeight
        let rows = max(1, min(chunkHeight, height - start))
        return rows * chunkWidth * samplesPerPixel
    }
}

/// 解析或解码时的错误。
public enum TIFFError: Error, CustomStringConvertible {
    case notTIFF
    case truncated
    case unsupported(String)
    case decodeFailed(String)

    public var description: String {
        switch self {
        case .notTIFF: return "不是 TIFF 文件"
        case .truncated: return "文件不完整"
        case .unsupported(let reason): return reason
        case .decodeFailed(let reason): return reason
        }
    }
}

/// 分块 / 条带尺寸的可信范围。
///
/// `TileWidth / TileHeight`（以及条带的 `RowsPerStrip`）完全由文件说了算，而解码时会按
/// 「宽 × 高 × 4」直接申请缓冲区 —— 一个损坏或恶意写出的 IFD（例如声称分块是 10⁶ × 10⁶）
/// 就能让应用去申请几个 T 的内存、被系统直接杀掉。这里给一个宽松但确定的上限：
/// 单块 2²⁶ 像素（RGBA 约 268 MB）足以覆盖合法的超大条带（例如宽 10 万 × 条带高 600），
/// 同时把「声明出来的天文数字」挡在门外。
package enum TIFFLimits {
    /// 单个分块 / 条带允许的最大像素数。
    package static let maximumChunkPixels = 1 << 26
    /// 允许的最大边长（宽松值，主要拦明显荒谬的数字）。
    package static let maximumChunkSide = 1_000_000
    /// 单个目录项允许声明的最大字节数。
    ///
    /// 条目里的 `count` 完全来自文件，而解析时会照着它去读一整块数据。一个损坏
    /// （或恶意写出）的 IFD 声称「这个条目有十亿个元素」，就能让应用按天文数字申请内存。
    /// 合法的地理标签、分块表与色彩表都远小于这个数（最大的常见项是 16 位调色板，384 KB），
    /// 因此 64 MB 既宽松又足够把「声明出来的天文数字」挡在门外。
    package static let maximumEntryBytes = 64 << 20
    package static let maximumSamplesPerPixel = 1024
    package static let maximumImageSide = Int(Int32.max)
    package static let maximumDirectories = 1024
    #if os(iOS)
    package static let maximumChunkBytes = 64 << 20
    package static let maximumMetadataBytes = 64 << 20
    #else
    package static let maximumChunkBytes = 256 << 20
    package static let maximumMetadataBytes = 256 << 20
    #endif

    package static func chunkBytes(width: Int, height: Int, samples: Int, bits: Int) -> Int? {
        guard isSaneChunk(width: width, height: height), samples > 0,
              samples <= maximumSamplesPerPixel, [1, 2, 4, 8, 16, 32, 64].contains(bits) else { return nil }
        let bytesPerSample = max(1, bits / 8)
        let pixels = width * height
        guard samples <= maximumChunkBytes / pixels / bytesPerSample else { return nil }
        return pixels * samples * bytesPerSample
    }

    package static func isSaneChunk(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        guard width <= maximumChunkSide, height <= maximumChunkSide else { return false }
        return height <= maximumChunkPixels / width
    }
}

// MARK: - 文件读取

/// 按偏移读字节的小工具（解码时反复用到，所以保留一个句柄）。
package final class TIFFSourceFile: @unchecked Sendable {
    private let handle: FileHandle
    private let closeLock = NSLock()
    private var isClosed = false
    let byteCount: Int

    package init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        var status = stat()
        guard fstat(handle.fileDescriptor, &status) == 0, let size = Int(exactly: status.st_size), size >= 0 else {
            try? handle.close()
            throw TIFFError.truncated
        }
        byteCount = size
    }

    /// 按偏移读一段字节；读不满或出错返回 nil。
    ///
    /// 用 `pread` 而不是「seek + read」：句柄的读写位置是所有线程共享的，
    /// 而这里被多个解码线程同时用（拖动时一块几十 MB 的条带会把别的读全堵住）。
    /// `pread` 不依赖句柄状态，因此不需要加锁排队。
    package func read(offset: Int, count: Int) -> Data? {
        guard !Task.isCancelled, offset >= 0, count > 0, offset < byteCount,
              count <= max(TIFFLimits.maximumEntryBytes, TIFFLimits.maximumChunkBytes) else { return nil }
        // Bound the allocation before reading. Truncated image chunks may still be diagnosed downstream.
        let count = min(count, byteCount - offset)
        var data = Data(count: count)
        var total = 0
        let descriptor = handle.fileDescriptor
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while total < count, !Task.isCancelled {
                let read = pread(descriptor, base.advanced(by: total), count - total, off_t(offset + total))
                if read <= 0 { break }
                total += read
            }
        }
        guard total > 0 else { return nil }
        return total == count ? data : data.prefix(total)
    }

    package func close() {
        // 只关一次：重复 `close` 会把文件描述符号还给系统，
        // 而那个号码可能已经被别的 `open` 拿去用了（等于关掉别人的文件）。
        closeLock.lock()
        let shouldClose = !isClosed
        isClosed = true
        closeLock.unlock()
        if shouldClose { try? handle.close() }
    }
}

// MARK: - 解析

/// TIFF 目录结构解析。
public enum TIFFReader {
    /// 读取文件结构（不碰像素数据）。
    public static func parse(url: URL) throws -> TIFFFile {
        try Task.checkCancellation()
        let reader = try TIFFSourceFile(url: url)
        defer { reader.close() }
        guard let header = reader.read(offset: 0, count: 16), header.count >= 8 else {
            throw TIFFError.truncated
        }
        let order: TIFFByteOrder
        if header[header.startIndex] == 0x49, header[header.startIndex + 1] == 0x49 {
            order = .little
        } else if header[header.startIndex] == 0x4D, header[header.startIndex + 1] == 0x4D {
            order = .big
        } else {
            throw TIFFError.notTIFF
        }

        let magic = header.u16(at: 2, order: order)
        let isBigTIFF: Bool
        let firstIFD: Int
        switch magic {
        case 42:
            isBigTIFF = false
            firstIFD = Int(header.u32(at: 4, order: order))
        case 43:
            isBigTIFF = true
            guard header.count >= 16, header.u16(at: 4, order: order) == 8 else {
                throw TIFFError.unsupported("BigTIFF 的偏移宽度不是 8 字节")
            }
            guard let offset = Int(exactly: header.u64(at: 8, order: order)) else { throw TIFFError.truncated }
            firstIFD = offset
        default:
            throw TIFFError.notTIFF
        }
        guard firstIFD > 0 else { throw TIFFError.truncated }

        var main: TIFFImageFileDirectory?
        var overviews: [TIFFImageFileDirectory] = []
        var pending = [firstIFD]
        var visited = Set<Int>()
        var metadataBudget = TIFFLimits.maximumMetadataBytes
        while let offset = pending.popLast() {
            try Task.checkCancellation()
            guard offset > 0, !visited.contains(offset) else { continue }
            guard visited.count < TIFFLimits.maximumDirectories else {
                throw TIFFError.unsupported("TIFF 目录数量超过安全上限")
            }
            visited.insert(offset)
            let parsed = try parseIFD(reader: reader, order: order, isBigTIFF: isBigTIFF,
                                      offset: offset, metadataBudget: &metadataBudget)
            if main == nil {
                main = parsed.directory
            } else if parsed.directory.width > 0 {
                // IFD 链上后出现的目录是 GDAL 风格的内建概览。
                overviews.append(parsed.directory)
            }
            if parsed.next > 0 { pending.append(parsed.next) }
            for sub in parsed.subDirectories where sub > 0 { pending.append(sub) }
        }
        guard let directory = main else { throw TIFFError.truncated }
        return TIFFFile(
            url: url,
            byteOrder: order,
            isBigTIFF: isBigTIFF,
            main: directory,
            overviews: overviews.sorted { $0.width < $1.width }
        )
    }

    private struct ParsedIFD {
        var directory: TIFFImageFileDirectory
        var next: Int
        var subDirectories: [Int]
    }

    private struct Entry {
        var tag: Int
        var type: Int
        var count: Int
        /// 值不足一个偏移宽度时内联在目录项里。
        var inlineBytes: [UInt8]
        var valueOffset: Int
        var byteSize: Int
    }

    private static func parseIFD(
        reader: TIFFSourceFile,
        order: TIFFByteOrder,
        isBigTIFF: Bool,
        offset: Int,
        metadataBudget: inout Int
    ) throws -> ParsedIFD {
        let countSize = isBigTIFF ? 8 : 2
        let entrySize = isBigTIFF ? 20 : 12
        let inlineSize = isBigTIFF ? 8 : 4

        guard let header = reader.read(offset: offset, count: countSize), header.count == countSize else {
            throw TIFFError.truncated
        }
        // `Int(_:)` 对超出范围的值是直接 trap（BigTIFF 的 64 位条目数轻易就能越界），
        // 所以先走一遍可失败转换，再判范围。
        let rawEntryCount = isBigTIFF
            ? header.u64(at: 0, order: order)
            : UInt64(header.u16(at: 0, order: order))
        guard let entryCount = Int(exactly: rawEntryCount) else { throw TIFFError.truncated }
        guard entryCount > 0, entryCount < 4096 else { throw TIFFError.truncated }
        let blockSize = entryCount * entrySize + (isBigTIFF ? 8 : 4)
        guard offset <= reader.byteCount - countSize,
              let block = reader.read(offset: offset + countSize, count: blockSize), block.count == blockSize else {
            throw TIFFError.truncated
        }

        var entries: [Int: Entry] = [:]
        entries.reserveCapacity(entryCount)
        for index in 0..<entryCount {
            if index % 128 == 0 { try Task.checkCancellation() }
            let base = index * entrySize
            let tag = Int(block.u16(at: base, order: order))
            let type = Int(block.u16(at: base + 2, order: order))
            let rawCount = isBigTIFF
                ? block.u64(at: base + 4, order: order)
                : UInt64(block.u32(at: base + 4, order: order))
            let count = Int(exactly: rawCount) ?? Int.max
            let valueStart = base + (isBigTIFF ? 12 : 8)
            guard let byteSize = entryByteSize(type: type, count: count) else {
                throw TIFFError.unsupported("目录项 \(tag) 声明了不可信的数据长度（\(count) 个元素）")
            }
            // Include expanded numeric arrays in the cumulative budget, not just their on-disk bytes.
            let cost = byteSize + count * 2 * MemoryLayout<Int>.stride
            guard cost <= metadataBudget else { throw TIFFError.unsupported("TIFF 元数据超过安全预算") }
            metadataBudget -= cost
            var inline: [UInt8] = []
            for i in 0..<inlineSize where valueStart + i < block.count {
                inline.append(block[block.startIndex + valueStart + i])
            }
            let rawOffset = isBigTIFF
                ? block.u64(at: valueStart, order: order)
                : UInt64(block.u32(at: valueStart, order: order))
            var offsetValue = -1
            if byteSize > inlineSize {
                guard let value = Int(exactly: rawOffset), value >= 0, value <= reader.byteCount,
                      byteSize <= reader.byteCount - value else { throw TIFFError.truncated }
                offsetValue = value
            }
            entries[tag] = Entry(
                tag: tag,
                type: type,
                count: count,
                inlineBytes: inline,
                valueOffset: byteSize <= inlineSize ? -1 : offsetValue,
                byteSize: byteSize
            )
        }

        // 注意：`block` 是从「条目数」之后开始读的，所以下一个 IFD 的偏移就在所有条目之后。
        let nextOffset = entryCount * entrySize
        let rawNext = isBigTIFF
            ? block.u64(at: nextOffset, order: order)
            : UInt64(block.u32(at: nextOffset, order: order))
        guard let next = Int(exactly: rawNext) else {
            throw TIFFError.unsupported("目录链的偏移超出可表示范围")
        }

        func entry(_ tag: Int) -> Entry? { entries[tag] }
        func ints(_ tag: Int) throws -> [Int] {
            guard let entry = entry(tag) else { return [] }
            return try integerValues(of: entry, reader: reader, order: order)
        }
        func int(_ tag: Int) throws -> Int? {
            guard entry(tag)?.count ?? 1 == 1 else { throw TIFFError.unsupported("TIFF 标量标签长度无效") }
            return try ints(tag).first
        }
        func shorts(_ tag: Int) throws -> [UInt16]? {
            guard entry(tag) != nil else { return nil }
            return try ints(tag).map {
                guard let value = UInt16(exactly: $0) else { throw TIFFError.unsupported("TIFF 短整数标签越界") }
                return value
            }
        }
        func doubles(_ tag: Int) throws -> [Double]? {
            guard let entry = entry(tag) else { return nil }
            let result = values(of: entry, reader: reader, order: order)
            guard result.allSatisfy(\.isFinite) else { throw TIFFError.unsupported("TIFF 地理标签包含非有限数值") }
            return result
        }
        func ascii(_ tag: Int) -> String? {
            guard let entry = entry(tag) else { return nil }
            let bytes = rawBytes(of: entry, reader: reader)
            let text = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            return text.isEmpty ? nil : text
        }

        var directory = TIFFImageFileDirectory()
        directory.offset = offset
        directory.width = try int(256) ?? 0
        directory.height = try int(257) ?? 0
        guard (1...TIFFLimits.maximumImageSide).contains(directory.width),
              (1...TIFFLimits.maximumImageSide).contains(directory.height) else { throw TIFFError.truncated }
        directory.samplesPerPixel = try int(277) ?? 1
        guard (1...TIFFLimits.maximumSamplesPerPixel).contains(directory.samplesPerPixel) else {
            throw TIFFError.unsupported("TIFF 通道数超过安全上限")
        }
        let bits = try ints(258)
        guard bits.allSatisfy({ [1, 2, 4, 8, 16, 32, 64].contains($0) }) else {
            throw TIFFError.unsupported("TIFF 样本位数无效")
        }
        directory.bitsPerSample = bits.count == directory.samplesPerPixel
            ? bits
            : Array(repeating: bits.first ?? 8, count: directory.samplesPerPixel)
        let formats = try ints(339)
        directory.sampleFormat = formats.count == directory.samplesPerPixel
            ? formats
            : Array(repeating: formats.first ?? 1, count: directory.samplesPerPixel)
        directory.compression = TIFFCompression(code: try int(259) ?? 1)
        directory.photometric = TIFFPhotometricRaw(code: try int(262) ?? 1)
        directory.planarConfiguration = try int(284) ?? 1
        directory.predictor = try int(317) ?? 1
        directory.colorMap = try shorts(320)
        directory.extraSamples = try ints(338)
        if let tables = entry(347) {
            let bytes = rawBytes(of: tables, reader: reader)
            if !bytes.isEmpty { directory.jpegTables = Data(bytes) }
        }
        directory.geo = TIFFGeoTags(
            pixelScale: try doubles(33550),
            tiePoints: try doubles(33922),
            transformation: try doubles(34264),
            keyDirectory: try shorts(34735),
            doubleParameters: try doubles(34736),
            asciiParameters: ascii(34737),
            noData: ascii(42113)
        )

        // 分块（tiled）与横条（stripped）二选一。
        let tileWidth = try int(322)
        let tileHeight = try int(323)
        let tileOffsets = try ints(324)
        let tileCounts = try ints(325)
        if let tileWidth, let tileHeight, !tileOffsets.isEmpty {
            // 分块尺寸先过一遍可信范围：后面解码会按它申请缓冲区（见 TIFFLimits）。
            guard TIFFLimits.isSaneChunk(width: tileWidth, height: tileHeight) else {
                throw TIFFError.unsupported("分块尺寸不可信（\(tileWidth) × \(tileHeight)）")
            }
            directory.isTiled = true
            directory.chunkWidth = tileWidth
            directory.chunkHeight = tileHeight
            directory.chunks = zip(tileOffsets, tileCounts.isEmpty ? tileOffsets.map { _ in 0 } : tileCounts)
                .map { TIFFChunk(offset: $0.0, byteCount: $0.1) }
        } else {
            let stripOffsets = try ints(273)
            let stripCounts = try ints(279)
            let rowsPerStrip = try int(278) ?? directory.height
            directory.isTiled = false
            directory.chunkWidth = directory.width
            // `RowsPerStrip` 常用 0xFFFFFFFF 表示「整幅一条」，也可能写成一个荒谬的大数：
            // 条带不可能比影像本身还高，夹到影像高度既符合语义、又挡住超大分配。
            let stripHeight = min(max(1, rowsPerStrip), directory.height)
            guard TIFFLimits.isSaneChunk(width: directory.width, height: stripHeight) else {
                throw TIFFError.unsupported("条带尺寸不可信（\(directory.width) × \(stripHeight)）")
            }
            directory.chunkHeight = stripHeight
            directory.chunks = zip(stripOffsets, stripCounts.isEmpty ? stripOffsets.map { _ in 0 } : stripCounts)
                .map { TIFFChunk(offset: $0.0, byteCount: $0.1) }
        }

        guard directory.planarConfiguration == 1 || directory.planarConfiguration == 2,
              TIFFLimits.chunkBytes(width: directory.chunkWidth, height: directory.chunkHeight,
                                    samples: directory.planarConfiguration == 2 ? 1 : directory.samplesPerPixel,
                                    bits: directory.bitsPerSample.max() ?? 8) != nil,
              TIFFLimits.chunkBytes(width: directory.chunkWidth, height: directory.chunkHeight, samples: 4, bits: 8) != nil else {
            throw TIFFError.unsupported("TIFF 解码块超过安全内存预算")
        }
        for chunk in directory.chunks {
            guard chunk.offset >= 0, chunk.byteCount >= 0, chunk.byteCount <= TIFFLimits.maximumChunkBytes,
                  chunk.offset <= reader.byteCount, chunk.byteCount <= reader.byteCount - chunk.offset else {
                throw TIFFError.truncated
            }
        }
        return ParsedIFD(
            directory: directory,
            next: next,
            subDirectories: try ints(330)
        )
    }

    private static func size(ofType type: Int) -> Int {
        switch type {
        case 1, 2, 6, 7: return 1
        case 3, 8: return 2
        case 4, 9, 11, 13: return 4
        case 5, 10, 12, 16, 17, 18: return 8
        default: return 1
        }
    }

    /// 目录项声明的数据长度；溢出或超出可信上限时返回 nil。
    ///
    /// 这一层是「文件说了算的数字」与「内存分配」之间唯一的闸门：`count` 来自文件，
    /// 而下游会照 `byteSize` 申请缓冲区（见 `rawBytes(of:)`）。
    private static func entryByteSize(type: Int, count: Int) -> Int? {
        guard count >= 0 else { return nil }
        let (bytes, overflow) = size(ofType: type).multipliedReportingOverflow(by: count)
        guard !overflow, bytes <= TIFFLimits.maximumEntryBytes else { return nil }
        return bytes
    }

    /// Integer tags retain their exact representation; routing offsets through Double loses precision.
    private static func integerValues(of entry: Entry, reader: TIFFSourceFile, order: TIFFByteOrder) throws -> [Int] {
        guard [1, 3, 4, 6, 8, 9, 13, 16, 17, 18].contains(entry.type) else {
            throw TIFFError.unsupported("TIFF 整数标签 \(entry.tag) 的类型无效")
        }
        let bytes = rawBytes(of: entry, reader: reader)
        guard bytes.count == entry.byteSize else { throw TIFFError.truncated }
        let step = size(ofType: entry.type)
        var result: [Int] = []
        result.reserveCapacity(entry.count)
        for offset in stride(from: 0, to: entry.byteSize, by: step) {
            if offset % 16384 == 0 { try Task.checkCancellation() }
            let value: Int?
            switch entry.type {
            case 1: value = Int(bytes[offset])
            case 6: value = Int(Int8(bitPattern: bytes[offset]))
            case 3: value = Int(bytes.u16(at: offset, order: order))
            case 8: value = Int(Int16(bitPattern: bytes.u16(at: offset, order: order)))
            case 4, 13: value = Int(bytes.u32(at: offset, order: order))
            case 9: value = Int(Int32(bitPattern: bytes.u32(at: offset, order: order)))
            case 16, 18: value = Int(exactly: bytes.u64(at: offset, order: order))
            default: value = Int(exactly: Int64(bitPattern: bytes.u64(at: offset, order: order)))
            }
            guard let value else { throw TIFFError.unsupported("TIFF 整数标签超出可表示范围") }
            result.append(value)
        }
        return result
    }

    /// 取出一个目录项的值（统一成 Double）。
    private static func values(of entry: Entry, reader: TIFFSourceFile, order: TIFFByteOrder) -> [Double] {
        let bytes = rawBytes(of: entry, reader: reader)
        switch entry.type {
        case 1, 7: return bytes.map { Double($0) }
        case 2: return bytes.map { Double($0) }
        case 3: return stride(from: 0, to: entry.count * 2, by: 2).map { Double(bytes.u16(at: $0, order: order)) }
        case 4, 13: return stride(from: 0, to: entry.count * 4, by: 4).map { Double(bytes.u32(at: $0, order: order)) }
        case 5:
            return stride(from: 0, to: entry.count * 8, by: 8).map { index in
                let numerator = Double(bytes.u32(at: index, order: order))
                let denominator = Double(bytes.u32(at: index + 4, order: order))
                return denominator == 0 ? 0 : numerator / denominator
            }
        case 8: return stride(from: 0, to: entry.count * 2, by: 2).map { Double(Int16(bitPattern: bytes.u16(at: $0, order: order))) }
        case 9: return stride(from: 0, to: entry.count * 4, by: 4).map { Double(Int32(bitPattern: bytes.u32(at: $0, order: order))) }
        case 11: return stride(from: 0, to: entry.count * 4, by: 4).map { Double(Float(bitPattern: bytes.u32(at: $0, order: order))) }
        case 12: return stride(from: 0, to: entry.count * 8, by: 8).map { Double(bitPattern: bytes.u64(at: $0, order: order)) }
        case 16, 18: return stride(from: 0, to: entry.count * 8, by: 8).map { Double(bytes.u64(at: $0, order: order)) }
        case 17: return stride(from: 0, to: entry.count * 8, by: 8).map { Double(Int64(bitPattern: bytes.u64(at: $0, order: order))) }
        default: return []
        }
    }

    private static func rawBytes(of entry: Entry, reader: TIFFSourceFile) -> [UInt8] {
        if entry.valueOffset < 0 {
            return Array(entry.inlineBytes.prefix(entry.byteSize))
        }
        guard let data = reader.read(offset: entry.valueOffset, count: entry.byteSize) else { return [] }
        return [UInt8](data)
    }
}

// MARK: - 字节序读取

extension Data {
    func u16(at index: Int, order: TIFFByteOrder) -> UInt16 {
        guard index >= 0, index + 2 <= count else { return 0 }
        let base = index + startIndex
        let low = UInt16(self[base])
        let high = UInt16(self[base + 1])
        return order == .little ? low | (high << 8) : (low << 8) | high
    }

    func u32(at index: Int, order: TIFFByteOrder) -> UInt32 {
        guard index >= 0, index + 4 <= count else { return 0 }
        let b0 = UInt32(self[index + startIndex])
        let b1 = UInt32(self[index + startIndex + 1])
        let b2 = UInt32(self[index + startIndex + 2])
        let b3 = UInt32(self[index + startIndex + 3])
        return order == .little
            ? b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
            : (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    func u64(at index: Int, order: TIFFByteOrder) -> UInt64 {
        guard index >= 0, index + 8 <= count else { return 0 }
        let low = UInt64(u32(at: index, order: order))
        let high = UInt64(u32(at: index + 4, order: order))
        return order == .little ? low | (high << 32) : (low << 32) | high
    }
}

extension Array where Element == UInt8 {
    func u16(at index: Int, order: TIFFByteOrder) -> UInt16 {
        guard index >= 0, index + 2 <= count else { return 0 }
        return order == .little
            ? UInt16(self[index]) | (UInt16(self[index + 1]) << 8)
            : (UInt16(self[index]) << 8) | UInt16(self[index + 1])
    }

    func u32(at index: Int, order: TIFFByteOrder) -> UInt32 {
        guard index >= 0, index + 4 <= count else { return 0 }
        let b0 = UInt32(self[index]), b1 = UInt32(self[index + 1])
        let b2 = UInt32(self[index + 2]), b3 = UInt32(self[index + 3])
        return order == .little
            ? b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
            : (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    func u64(at index: Int, order: TIFFByteOrder) -> UInt64 {
        let low = UInt64(u32(at: index, order: order))
        let high = UInt64(u32(at: index + 4, order: order))
        return order == .little ? low | (high << 32) : (low << 32) | high
    }
}

extension UnsafeBufferPointer where Element == UInt8 {
    func u16(at index: Int, order: TIFFByteOrder) -> UInt16 {
        guard index >= 0, index + 2 <= count else { return 0 }
        return order == .little
            ? UInt16(self[index]) | (UInt16(self[index + 1]) << 8)
            : (UInt16(self[index]) << 8) | UInt16(self[index + 1])
    }

    func u32(at index: Int, order: TIFFByteOrder) -> UInt32 {
        guard index >= 0, index + 4 <= count else { return 0 }
        let b0 = UInt32(self[index]), b1 = UInt32(self[index + 1])
        let b2 = UInt32(self[index + 2]), b3 = UInt32(self[index + 3])
        return order == .little
            ? b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
            : (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}
