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

// MARK: - 文件读取

/// 按偏移读字节的小工具（解码时反复用到，所以保留一个句柄）。
final class TIFFSourceFile: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    let byteCount: Int

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size]) as? Int
        byteCount = size ?? 0
    }

    func read(offset: Int, count: Int) -> Data? {
        guard offset >= 0, count > 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return nil }
        return try? handle.read(upToCount: count)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle.close()
    }
}

// MARK: - 解析

/// TIFF 目录结构解析。
public enum TIFFReader {
    /// 读取文件结构（不碰像素数据）。
    public static func parse(url: URL) throws -> TIFFFile {
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
            firstIFD = Int(header.u64(at: 8, order: order))
        default:
            throw TIFFError.notTIFF
        }
        guard firstIFD > 0 else { throw TIFFError.truncated }

        var main: TIFFImageFileDirectory?
        var overviews: [TIFFImageFileDirectory] = []
        var pending = [firstIFD]
        var visited = Set<Int>()
        while let offset = pending.popLast() {
            guard offset > 0, !visited.contains(offset) else { continue }
            visited.insert(offset)
            let parsed = try parseIFD(reader: reader, order: order, isBigTIFF: isBigTIFF, offset: offset)
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
        offset: Int
    ) throws -> ParsedIFD {
        let countSize = isBigTIFF ? 8 : 2
        let entrySize = isBigTIFF ? 20 : 12
        let inlineSize = isBigTIFF ? 8 : 4

        guard let header = reader.read(offset: offset, count: countSize), header.count == countSize else {
            throw TIFFError.truncated
        }
        let entryCount = Int(isBigTIFF ? header.u64(at: 0, order: order) : UInt64(header.u16(at: 0, order: order)))
        guard entryCount > 0, entryCount < 4096 else { throw TIFFError.truncated }
        guard let block = reader.read(offset: offset + countSize, count: entryCount * entrySize + (isBigTIFF ? 8 : 4)) else {
            throw TIFFError.truncated
        }

        var entries: [Int: Entry] = [:]
        entries.reserveCapacity(entryCount)
        for index in 0..<entryCount {
            let base = index * entrySize
            let tag = Int(block.u16(at: base, order: order))
            let type = Int(block.u16(at: base + 2, order: order))
            let count = Int(isBigTIFF ? block.u64(at: base + 4, order: order) : UInt64(block.u32(at: base + 4, order: order)))
            let valueStart = base + (isBigTIFF ? 12 : 8)
            let byteSize = size(ofType: type) * count
            var inline: [UInt8] = []
            for i in 0..<inlineSize where valueStart + i < block.count {
                inline.append(block[block.startIndex + valueStart + i])
            }
            let offsetValue = Int(isBigTIFF ? block.u64(at: valueStart, order: order) : UInt64(block.u32(at: valueStart, order: order)))
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
        let next = Int(isBigTIFF
            ? block.u64(at: nextOffset, order: order)
            : UInt64(block.u32(at: nextOffset, order: order)))

        func entry(_ tag: Int) -> Entry? { entries[tag] }
        func ints(_ tag: Int) -> [Int] {
            guard let entry = entry(tag) else { return [] }
            return values(of: entry, reader: reader, order: order).map { Int($0) }
        }
        func int(_ tag: Int) -> Int? { ints(tag).first }
        func doubles(_ tag: Int) -> [Double]? {
            guard let entry = entry(tag) else { return nil }
            return values(of: entry, reader: reader, order: order)
        }
        func ascii(_ tag: Int) -> String? {
            guard let entry = entry(tag) else { return nil }
            let bytes = rawBytes(of: entry, reader: reader)
            let text = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            return text.isEmpty ? nil : text
        }

        var directory = TIFFImageFileDirectory()
        directory.width = int(256) ?? 0
        directory.height = int(257) ?? 0
        guard directory.width > 0, directory.height > 0 else { throw TIFFError.truncated }
        directory.samplesPerPixel = max(1, int(277) ?? 1)
        let bits = ints(258)
        directory.bitsPerSample = bits.count == directory.samplesPerPixel
            ? bits
            : Array(repeating: bits.first ?? 8, count: directory.samplesPerPixel)
        let formats = ints(339)
        directory.sampleFormat = formats.count == directory.samplesPerPixel
            ? formats
            : Array(repeating: formats.first ?? 1, count: directory.samplesPerPixel)
        directory.compression = TIFFCompression(code: int(259) ?? 1)
        directory.photometric = TIFFPhotometricRaw(code: int(262) ?? 1)
        directory.planarConfiguration = int(284) ?? 1
        directory.predictor = int(317) ?? 1
        directory.colorMap = entry(320).map { values(of: $0, reader: reader, order: order).map { UInt16($0) } }
        directory.extraSamples = ints(338)
        if let tables = entry(347) {
            let bytes = rawBytes(of: tables, reader: reader)
            if !bytes.isEmpty { directory.jpegTables = Data(bytes) }
        }
        directory.geo = TIFFGeoTags(
            pixelScale: doubles(33550),
            tiePoints: doubles(33922),
            transformation: doubles(34264),
            keyDirectory: entry(34735).map { values(of: $0, reader: reader, order: order).map { UInt16($0) } },
            doubleParameters: doubles(34736),
            asciiParameters: ascii(34737),
            noData: ascii(42113)
        )

        // 分块（tiled）与横条（stripped）二选一。
        let tileWidth = int(322)
        let tileHeight = int(323)
        let tileOffsets = ints(324)
        let tileCounts = ints(325)
        if let tileWidth, let tileHeight, !tileOffsets.isEmpty {
            directory.isTiled = true
            directory.chunkWidth = tileWidth
            directory.chunkHeight = tileHeight
            directory.chunks = zip(tileOffsets, tileCounts.isEmpty ? tileOffsets.map { _ in 0 } : tileCounts)
                .map { TIFFChunk(offset: $0.0, byteCount: $0.1) }
        } else {
            let stripOffsets = ints(273)
            let stripCounts = ints(279)
            let rowsPerStrip = int(278) ?? directory.height
            directory.isTiled = false
            directory.chunkWidth = directory.width
            directory.chunkHeight = max(1, rowsPerStrip)
            directory.chunks = zip(stripOffsets, stripCounts.isEmpty ? stripOffsets.map { _ in 0 } : stripCounts)
                .map { TIFFChunk(offset: $0.0, byteCount: $0.1) }
        }

        return ParsedIFD(
            directory: directory,
            next: next,
            subDirectories: ints(330)
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
