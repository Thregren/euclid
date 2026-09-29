import Compression
import CoreGraphics
import Foundation
import ImageIO

/// 把 TIFF 的像素按需解出来。
///
/// 只解「这一屏真正需要的那一小块」：分块（tile）与横条（strip）都按块解压，
/// 解完立刻采样到目标尺寸，因此内存占用与文件大小无关。
enum TIFFDecoder {
    /// 把影像的一个像素区域采样进 RGBA8 画布的指定矩形。
    ///
    /// - Parameters:
    ///   - source: 源图像素矩形（左上角为原点、y 向下）。允许越界，越界部分不画。
    ///   - canvas: RGBA8 缓冲区（预乘 alpha 由调用方决定，这里按「直通」写）。
    ///   - destination: 目标矩形（画布像素坐标，允许小数）；`source` 线性映射到这里。
    static func draw(
        file: TIFFFile,
        level: TIFFImageFileDirectory,
        source: CGRect,
        canvas: UnsafeMutablePointer<UInt8>,
        canvasWidth: Int,
        canvasHeight: Int,
        destination: CGRect,
        stretch: TIFFStretch? = nil
    ) throws {
        guard level.planarConfiguration == 1 || level.planarConfiguration == 2 else {
            throw TIFFError.unsupported("暂不支持 PlanarConfiguration = \(level.planarConfiguration) 的 TIFF")
        }
        guard level.compression.isSupported else {
            throw TIFFError.unsupported("暂不支持这种 TIFF 压缩方式：\(level.compression.description)")
        }
        if level.isFloatSamples {
            // 浮点样本按 32 / 64 位读写；其它位数（半精度）没有实际数据，直接说不支持。
            guard let bits = level.bitsPerSampleUniform, bits == 32 || bits == 64 else {
                throw TIFFError.unsupported("暂不支持 \(level.bitsPerSample.first ?? 0) 位的浮点样本")
            }
        } else if level.planarConfiguration == 1 {
            guard let bits = level.bitsPerSampleUniform,
                  [1, 2, 4, 8, 16, 32, 64].contains(bits) else {
                throw TIFFError.unsupported("暂不支持 \(level.bitsPerSample.first ?? 0) 位/样本的 TIFF")
            }
        }
        guard [1, 2, 3].contains(level.predictor) else {
            throw TIFFError.unsupported("暂不支持 Predictor = \(level.predictor) 的 TIFF")
        }
        if level.compression != .jpeg {
            switch level.photometric {
            case .rgb, .blackIsZero, .whiteIsZero:
                break
            case .palette:
                let paletteBits = max(1, min(16, level.bitsPerSample.first ?? 8))
                guard (level.colorMap?.count ?? 0) >= 3 * (1 << paletteBits) else {
                    throw TIFFError.decodeFailed("调色板表不完整")
                }
            default:
                throw TIFFError.unsupported("暂不支持这种光度解释（\(level.photometric)）")
            }
        }
        guard level.chunkWidth > 0, level.chunkHeight > 0, !level.chunks.isEmpty else {
            throw TIFFError.decodeFailed("没有可读的数据块")
        }
        // 再兜一道底：解析时已经校验过分块尺寸（`TIFFLimits`），
        // 但这里直接按它申请缓冲区，值得再确认一次（外部改过元数据 / 将来新增解析路径）。
        guard TIFFLimits.isSaneChunk(width: level.chunkWidth, height: level.chunkHeight) else {
            throw TIFFError.unsupported("分块尺寸不可信（\(level.chunkWidth) × \(level.chunkHeight)）")
        }

        // 句柄走池子（借用凭据交给 store 持有，直到这一屏解完才还回去），
        // 解出来的块走跨瓦片缓存 —— 相邻瓦片、连续缩放都吃同一份数据，
        // 一个块只解一次。
        let lease = try TIFFChunkCache.shared.acquireReader(url: file.url)
        let store = ChunkStore(lease: lease, file: file, level: level)

        let destinationWidth = max(1.0, destination.width)
        let destinationHeight = max(1.0, destination.height)
        let startX = Int(destination.minX.rounded())
        let startY = Int(destination.minY.rounded())
        let columns = Int(destinationWidth.rounded(.up))
        let rows = Int(destinationHeight.rounded(.up))

        // 一个目标像素对应多少源像素：据此决定采样点个数。
        // 缩得很小时只取少量采样点（否则第一屏要把整幅影像的每个像素都摸一遍），
        // 接近 1:1 时用单点，避免把清晰的影像抹平。
        let boxWidth = source.width / destinationWidth
        let boxHeight = source.height / destinationHeight
        let taps = max(boxWidth, boxHeight) <= 1.2
            ? 1
            : (max(boxWidth, boxHeight) <= 12 ? 2 : 3)

        // 浮点样本 / 分离平面走「按样本取值」那条路：先把值读出来，再按拉伸或
        // 类型值域映射成颜色。整数连续存放仍然走原来的 RGBA 热路径。
        if store.usesSamples {
            try drawSamples(
                store: store,
                source: source,
                boxWidth: boxWidth,
                boxHeight: boxHeight,
                taps: taps,
                canvas: canvas,
                canvasWidth: canvasWidth,
                canvasHeight: canvasHeight,
                destination: destination,
                stretch: stretch ?? TIFFDisplayRange.stretch(for: file)
            )
            return
        }

        for row in 0..<rows {
            let y = startY + row
            guard y >= 0, y < canvasHeight else { continue }
            // 目标像素中心反投到源像素坐标。
            let v = (Double(row) + 0.5) / destinationHeight
            let sourceY = source.minY + v * source.height
            for column in 0..<columns {
                let x = startX + column
                guard x >= 0, x < canvasWidth else { continue }
                let u = (Double(column) + 0.5) / destinationWidth
                let sourceX = source.minX + u * source.width

                var sumR = 0, sumG = 0, sumB = 0, sumA = 0, count = 0
                if taps == 1 {
                    if let pixel = try store.pixel(x: Int(sourceX.rounded(.down)), y: Int(sourceY.rounded(.down))) {
                        sumR = Int(pixel.0); sumG = Int(pixel.1); sumB = Int(pixel.2); sumA = Int(pixel.3)
                        count = 1
                    }
                } else {
                    for tapY in 0..<taps {
                        let sy = sourceY - boxHeight / 2 + boxHeight * (Double(tapY) + 0.5) / Double(taps)
                        for tapX in 0..<taps {
                            let sx = sourceX - boxWidth / 2 + boxWidth * (Double(tapX) + 0.5) / Double(taps)
                            guard let pixel = try store.pixel(x: Int(sx.rounded(.down)), y: Int(sy.rounded(.down))) else {
                                continue
                            }
                            sumR += Int(pixel.0); sumG += Int(pixel.1)
                            sumB += Int(pixel.2); sumA += Int(pixel.3)
                            count += 1
                        }
                    }
                }
                guard count > 0 else { continue }
                let offset = (y * canvasWidth + x) * 4
                canvas[offset] = UInt8((sumR + count / 2) / count)
                canvas[offset + 1] = UInt8((sumG + count / 2) / count)
                canvas[offset + 2] = UInt8((sumB + count / 2) / count)
                canvas[offset + 3] = UInt8((sumA + count / 2) / count)
            }
        }
    }

    /// 浮点 / 分离平面的采样渲染。
    ///
    /// 与整数路径共用「目标像素中心反投源像素」的采样口径，只是每个采样点取的是
    /// 样本值而不是 RGBA；均值算完再统一映射，避免逐点量化带来的条纹。
    private static func drawSamples(
        store: ChunkStore,
        source: CGRect,
        boxWidth: Double,
        boxHeight: Double,
        taps: Int,
        canvas: UnsafeMutablePointer<UInt8>,
        canvasWidth: Int,
        canvasHeight: Int,
        destination: CGRect,
        stretch: TIFFStretch?
    ) throws {
        let destinationWidth = max(1.0, destination.width)
        let destinationHeight = max(1.0, destination.height)
        let startX = Int(destination.minX.rounded())
        let startY = Int(destination.minY.rounded())
        let columns = Int(destinationWidth.rounded(.up))
        let rows = Int(destinationHeight.rounded(.up))
        let color = store.rendersColor

        for row in 0..<rows {
            let y = startY + row
            guard y >= 0, y < canvasHeight else { continue }
            let v = (Double(row) + 0.5) / destinationHeight
            let sourceY = source.minY + v * source.height
            for column in 0..<columns {
                let x = startX + column
                guard x >= 0, x < canvasWidth else { continue }
                let u = (Double(column) + 0.5) / destinationWidth
                let sourceX = source.minX + u * source.width

                var totals: (Float, Float, Float) = (0, 0, 0)
                var count = 0
                func accumulate(_ values: (Float, Float, Float)) {
                    totals.0 += values.0
                    totals.1 += values.1
                    totals.2 += values.2
                    count += 1
                }
                if taps == 1 {
                    if let values = try store.sampleBands(
                        x: Int(sourceX.rounded(.down)),
                        y: Int(sourceY.rounded(.down)),
                        color: color
                    ) {
                        accumulate(values)
                    }
                } else {
                    for tapY in 0..<taps {
                        let sy = sourceY - boxHeight / 2 + boxHeight * (Double(tapY) + 0.5) / Double(taps)
                        for tapX in 0..<taps {
                            let sx = sourceX - boxWidth / 2 + boxWidth * (Double(tapX) + 0.5) / Double(taps)
                            if let values = try store.sampleBands(
                                x: Int(sx.rounded(.down)),
                                y: Int(sy.rounded(.down)),
                                color: color
                            ) {
                                accumulate(values)
                            }
                        }
                    }
                }
                guard count > 0 else { continue }
                let divisor = Float(count)
                let offset = (y * canvasWidth + x) * 4
                if color {
                    canvas[offset] = encode(totals.0 / divisor, store: store, stretch: stretch)
                    canvas[offset + 1] = encode(totals.1 / divisor, store: store, stretch: stretch)
                    canvas[offset + 2] = encode(totals.2 / divisor, store: store, stretch: stretch)
                    canvas[offset + 3] = 255
                } else {
                    guard let gray = encodeGray(totals.0 / divisor, store: store, stretch: stretch) else { continue }
                    canvas[offset] = gray
                    canvas[offset + 1] = gray
                    canvas[offset + 2] = gray
                    canvas[offset + 3] = 255
                }
            }
        }
    }

    /// 样本值 → 8 位通道。浮点走拉伸，整数按类型值域归一化。
    private static func encode(_ value: Float, store: ChunkStore, stretch: TIFFStretch?) -> UInt8 {
        if let stretch { return stretch.level(value) ?? 0 }
        return TIFFSampleAccess.normalize(value, level: store.level, band: 0)
    }

    /// 单波段：NaN / 非有限值不画（留空），其余按灰度。
    private static func encodeGray(_ value: Float, store: ChunkStore, stretch: TIFFStretch?) -> UInt8? {
        guard value.isFinite else { return nil }
        if let stretch { return stretch.level(value) ?? 0 }
        return TIFFSampleAccess.normalize(value, level: store.level, band: 0)
    }
}

/// 数据块的解码缓存：同一块会被相邻的若干目标像素反复取到。
///
/// 两个口径共用同一份解压 / 预测还原实现（`TIFFRawChunks`）：
/// 整数连续存放走 RGBA 热路径，浮点与分离平面走「按样本取值」。
private final class ChunkStore {
    /// 借用凭据（而不是句柄本身）：只要这个 store 还活着，池子就不会关掉它的句柄。
    private let lease: TIFFReaderLease
    private var reader: TIFFSourceFile { lease.reader }
    private let file: TIFFFile
    let level: TIFFImageFileDirectory
    private let path: String
    /// 上一次取到的块。相邻采样点几乎总是落在同一块里，
    /// 记一份就能把「每个采样点查一次字典」降到一次整数比较。
    private var lastIndex = -1
    private var lastPixels: [UInt8] = []
    /// 分离平面：最近用过的几块「平面内的原始样本」。
    private var planeChunks: [Int: [UInt8]] = [:]
    private var planeOrder: [Int] = []

    /// 这一级要不要走「按样本取值」的路。
    var usesSamples: Bool {
        level.planarConfiguration == 2 || level.isFloatSamples
    }

    /// 样本路径下这一级是不是彩色（三波段以上、光度学说是 RGB）。
    var rendersColor: Bool {
        level.photometric == .rgb && level.samplesPerPixel >= 3
    }

    init(lease: TIFFReaderLease, file: TIFFFile, level: TIFFImageFileDirectory) {
        self.lease = lease
        self.file = file
        self.level = level
        self.path = file.url.path(percentEncoded: false)
    }

    /// 取某个源像素的 RGBA（连续存放的整数样本）；越界返回 nil。
    func pixel(x: Int, y: Int) throws -> (UInt8, UInt8, UInt8, UInt8)? {
        guard x >= 0, y >= 0, x < level.width, y < level.height else { return nil }
        let across = max(1, level.chunksAcross)
        let column = x / level.chunkWidth
        let row = y / level.chunkHeight
        let index = row * across + column
        guard index >= 0, index < level.chunks.count else { return nil }
        let pixels: [UInt8]
        if index == lastIndex {
            pixels = lastPixels
        } else {
            pixels = try chunkPixels(index)
            lastIndex = index
            lastPixels = pixels
        }
        let innerX = x % level.chunkWidth
        let innerY = y % level.chunkHeight
        let offset = (innerY * level.chunkWidth + innerX) * 4
        guard offset + 3 < pixels.count else { return nil }
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
    }

    /// 取某个源像素的样本值（浮点 / 分离平面走它）。
    ///
    /// 彩色时返回 RGB 三个样本；单波段时把同一个值填满三个分量。
    func sampleBands(x: Int, y: Int, color: Bool) throws -> (Float, Float, Float)? {
        guard x >= 0, y >= 0, x < level.width, y < level.height,
              level.chunkWidth > 0, level.chunkHeight > 0 else { return nil }
        let across = max(1, level.chunksAcross)
        let innerX = x % level.chunkWidth
        let innerY = y % level.chunkHeight
        let indexInPlane = (y / level.chunkHeight) * across + (x / level.chunkWidth)
        if level.planarConfiguration == 2 {
            let planes = color ? min(3, level.planeCount) : 1
            var values = (Float(0), Float(0), Float(0))
            for plane in 0..<planes {
                guard let bytes = try planeBytes(plane: plane, index: indexInPlane),
                      let value = TIFFSampleAccess.value(
                          bytes: bytes,
                          level: level,
                          x: innerX,
                          y: innerY,
                          band: 0,
                          order: file.byteOrder
                      ) else { return nil }
                if plane == 0 { values.0 = value }
                else if plane == 1 { values.1 = value }
                else { values.2 = value }
            }
            if planes == 1 { values.1 = values.0; values.2 = values.0 }
            return values
        }
        guard let bytes = try planeBytes(plane: 0, index: indexInPlane) else { return nil }
        func value(_ band: Int) -> Float? {
            TIFFSampleAccess.value(
                bytes: bytes,
                level: level,
                x: innerX,
                y: innerY,
                band: band,
                order: file.byteOrder
            )
        }
        guard let first = value(0) else { return nil }
        if color {
            guard let green = value(1), let blue = value(2) else { return (first, first, first) }
            return (first, green, blue)
        }
        return (first, first, first)
    }

    /// RGBA 热路径（连续存放的整数样本）。
    private func chunkPixels(_ index: Int) throws -> [UInt8] {
        // 跨瓦片缓存：这一块在别的瓦片 / 上一次缩放里已经解过就直接拿。
        let key = TIFFChunkCache.Key(path: path, level: level.offset, index: index)
        if let cached = TIFFChunkCache.shared.pixels(for: key) { return cached }
        let rows = level.rowsInChunk(indexInPlane: index)
        var pixels: [UInt8]
        if level.compression == .jpeg, let data = chunkData(globalIndex: index) {
            pixels = try jpegPixels(data, rows: rows)
        } else {
            let raw = try TIFFRawChunks.bytes(
                file: file,
                level: level,
                reader: reader,
                chunkIndex: index,
                plane: 0
            )
            pixels = TIFFCodec.rgba(from: raw, level: level, rows: rows, order: file.byteOrder)
        }
        TIFFChunkCache.shared.store(pixels: pixels, for: key)
        return pixels
    }

    /// 取「平面内某一块」的原始样本字节（带本地小缓存 + 跨瓦片缓存）。
    private func planeBytes(plane: Int, index: Int) throws -> [UInt8]? {
        let key = plane &* 1_000_003 &+ index
        if let cached = planeChunks[key] { return cached }
        let bytes = try TIFFRawChunks.bytes(
            file: file,
            level: level,
            reader: reader,
            chunkIndex: index,
            plane: plane
        )
        planeChunks[key] = bytes
        planeOrder.append(key)
        let limit = max(4, level.planeCount * 3)
        while planeOrder.count > limit {
            let oldest = planeOrder.removeFirst()
            planeChunks.removeValue(forKey: oldest)
        }
        return bytes
    }

    private func chunkData(globalIndex: Int) -> Data? {
        guard globalIndex >= 0, globalIndex < level.chunks.count else { return nil }
        let chunk = level.chunks[globalIndex]
        guard chunk.byteCount > 0 else { return nil }
        return reader.read(offset: chunk.offset, count: chunk.byteCount)
    }

    /// JPEG 压缩的块：交给 ImageIO 解，再转成 RGBA8。
    private func jpegPixels(_ data: Data, rows: Int) throws -> [UInt8] {
        var payload = data
        // 老式 JPEG-in-TIFF 把量化表/哈夫曼表放在 JPEGTables 里，块本身不带表头。
        if let tables = level.jpegTables, !payload.starts(with: [0xFF, 0xD8]) {
            var merged = tables
            if merged.last == 0 { merged.removeLast() }
            merged.append(payload)
            payload = merged
        }
        guard let source = CGImageSourceCreateWithData(payload as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw TIFFError.decodeFailed("JPEG 块解不开")
        }
        let width = level.chunkWidth
        let height = level.chunkHeight
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: raw.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw TIFFError.decodeFailed("JPEG 块转换失败") }
        _ = rows
        return buffer
    }
}

/// 压缩与颜色转换的纯函数部分。
/// 压缩与颜色转换的纯函数部分。
///
/// `package` 是为了让同包的自检程序（`TileKitCheck`）能直接喂损坏数据进来 ——
/// 「截断的块不许崩」这类断言只能在编解码器这一层做。
package enum TIFFCodec {
    /// TIFF 的 Deflate 解压。
    ///
    /// 规范里 TIFF 的 Deflate 是 zlib 包装（RFC 1950：2 字节头 + 裸 deflate + 4 字节 Adler-32），
    /// 而系统 `Compression` 框架的 `COMPRESSION_ZLIB` **只吃裸 deflate**
    /// （它自己编码出来的就是裸流；把标准 zlib 流丢给它一律报错）。
    /// 所以这里先剥掉 zlib 外壳，剥不动或者解不出再按裸流试一次。
    static func inflate(
        _ data: Data,
        capacity: Int,
        onShort: ((Int) -> Void)? = nil
    ) -> [UInt8]? {
        guard capacity > 0, !data.isEmpty else { return nil }
        if data.count > 6, isZlibWrapped(data) {
            let body = Data(data.dropFirst(2).dropLast(4))
            if let decoded = rawInflate(body, capacity: capacity, onShort: onShort) { return decoded }
        }
        return rawInflate(data, capacity: capacity, onShort: onShort)
    }

    /// 是不是标准 zlib 包装（CMF/FLG 校验 + 没有预置字典）。
    private static func isZlibWrapped(_ data: Data) -> Bool {
        let cmf = data[data.startIndex]
        let flg = data[data.startIndex + 1]
        guard cmf & 0x0F == 8 else { return false }
        guard (Int(cmf) * 256 + Int(flg)) % 31 == 0 else { return false }
        guard flg & 0x20 == 0 else { return false }
        return true
    }

    private static func rawInflate(
        _ data: Data,
        capacity: Int,
        onShort: ((Int) -> Void)? = nil
    ) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            data.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress,
                      let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_decode_buffer(
                    destinationBase, capacity,
                    sourceBase, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        if written == 0, TileKitTrace.tiff {
            FileHandle.standardError.write(Data(
                "[tiff-probe] inflate 失败：读到 \(data.count) 字节，期望容量 \(capacity)，头 4 字节 "
                    .appending(data.prefix(4).map { String(format: "%02x", $0) }.joined())
                    .appending("\n").utf8
            ))
            return nil
        }
        guard written > 0 else { return nil }
        if written != capacity, TileKitTrace.raster {
            let line = "[tiff] 解压只得到 \(written) / 期望 \(capacity) 字节（输入 \(data.count)）\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        if written < capacity {
            onShort?(written)
            for index in written..<capacity { output[index] = 0 }
        }
        return output
    }

    /// PackBits（TIFF 6.0 的 RLE）。
    package static func packBitsDecode(
        _ data: Data,
        capacity: Int,
        onShort: ((Int) -> Void)? = nil
    ) -> [UInt8]? {
        let bytes = [UInt8](data)
        var output: [UInt8] = []
        output.reserveCapacity(capacity)
        var index = 0
        while index < bytes.count, output.count < capacity {
            let header = Int(Int8(bitPattern: bytes[index]))
            index += 1
            if header >= 0 {
                let count = header + 1
                guard index + count <= bytes.count else { break }
                output.append(contentsOf: bytes[index..<(index + count)])
                index += count
            } else if header != -128 {
                let count = 1 - header
                guard index < bytes.count else { break }
                let value = bytes[index]
                index += 1
                output.append(contentsOf: repeatElement(value, count: count))
            }
        }
        guard !output.isEmpty else { return nil }
        if output.count < capacity {
            onShort?(output.count)
            output.append(contentsOf: [UInt8](repeating: 0, count: capacity - output.count))
        }
        return Array(output.prefix(capacity))
    }

    /// TIFF 的 LZW。
    ///
    /// 位宽增长的时机（「提前一位」）各家写法偶有出入，所以两种规则都试一遍：
    /// 先按规范（提前一位）解，长度不对再按不提前解；哪个正好填满就采用哪个。
    ///
    /// `onShort` 只在「两种规则都填不满、只好补零交差」时回调一次（参数是真正解出的字节数）：
    /// 这种块以前是完全静默的，画面上只是那一块发黑，没人知道为什么。
    package static func lzwDecode(
        _ data: Data,
        capacity: Int,
        onShort: ((Int) -> Void)? = nil
    ) -> [UInt8]? {
        // 最多解两遍。老写法在「两种规则都不对」时会把第一遍再算一次。
        let first = lzwDecode(data, capacity: capacity, earlyChange: true)
        if let first, first.count == capacity { return first }
        let second = lzwDecode(data, capacity: capacity, earlyChange: false)
        if let second, second.count == capacity { return second }
        // 两种规则都没正好填满（截断 / 损坏的块）：按「解出多少算多少」补齐到容量再交出去。
        // 调用方是**按块尺寸索引像素**的，返回一个短数组会让它越界。
        guard let decoded = first ?? second else { return nil }
        onShort?(decoded.count)
        if decoded.count >= capacity { return Array(decoded.prefix(capacity)) }
        return decoded + [UInt8](repeating: 0, count: capacity - decoded.count)
    }

    private static func lzwDecode(_ data: Data, capacity: Int, earlyChange: Bool) -> [UInt8]? {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty, capacity > 0 else { return nil }

        var output: [UInt8] = []
        output.reserveCapacity(capacity)
        // 扁平字典：每个码一条「前缀码 + 末字节」，整块共用三个数组。
        // 老写法是 `[[UInt8]]`，每解一块要新建四千多个小数组，分配抖动全落在
        // 解压这条热路径上（拖动时每张瓦片都要走一遍）。
        var prefix = [Int](repeating: -1, count: 4096)
        var suffix = [UInt8](repeating: 0, count: 4096)
        var next = 258
        /// 展开一个码用的暂存（复用：不再一个码分配一次）。
        var scratch: [UInt8] = []
        scratch.reserveCapacity(1024)
        func resetDictionary() {
            for code in 0..<256 {
                prefix[code] = -1
                suffix[code] = UInt8(code)
            }
            prefix[256] = -1   // 256：清除
            prefix[257] = -1   // 257：结束
            next = 258
        }
        resetDictionary()

        /// 沿前缀链把一个码展开进 `scratch`；码不在字典里就返回 false。
        func expand(_ code: Int) -> Bool {
            scratch.removeAll(keepingCapacity: true)
            var current = code
            var steps = 0
            while current >= 0 {
                guard current < next, current < 4096 else { return false }
                scratch.append(suffix[current])
                current = prefix[current]
                steps += 1
                if steps > 4096 { return false }   // 损坏数据里的环，兜底
            }
            scratch.reverse()
            return true
        }

        var codeWidth = 9
        var bitBuffer = 0
        var bitCount = 0
        var index = 0

        func nextCode() -> Int? {
            while bitCount < codeWidth {
                guard index < bytes.count else { return nil }
                bitBuffer = (bitBuffer << 8) | Int(bytes[index])
                index += 1
                bitCount += 8
            }
            let code = (bitBuffer >> (bitCount - codeWidth)) & ((1 << codeWidth) - 1)
            bitCount -= codeWidth
            return code
        }

        var previous = -1
        while let code = nextCode() {
            if code == 256 {
                resetDictionary()
                codeWidth = 9
                previous = -1
                continue
            }
            if code == 257 { break }

            // KwKwK：这个码就是「正在生成的下一个词条」，即上一串再加它的首字节。
            let isNewCode = code >= next
            guard !isNewCode || (code == next && previous >= 0) else { return nil }
            guard expand(isNewCode ? previous : code) else { return nil }
            let firstByte = scratch.first ?? 0
            output.append(contentsOf: scratch)
            if isNewCode { output.append(firstByte) }

            if previous >= 0, next < 4096 {
                prefix[next] = previous
                suffix[next] = firstByte
                next += 1
            }
            previous = code

            let threshold = earlyChange ? (1 << codeWidth) - 1 : (1 << codeWidth)
            if next >= threshold, codeWidth < 12 {
                codeWidth += 1
            }
            if output.count >= capacity { break }
        }
        guard !output.isEmpty else { return nil }
        return output.count > capacity ? Array(output.prefix(capacity)) : output
    }

    /// 还原水平差分预测（Predictor = 2）。
    static func undoHorizontalPredictor(
        _ raw: inout [UInt8],
        width: Int,
        rows: Int,
        samplesPerPixel: Int,
        bitsPerSample: Int,
        order: TIFFByteOrder
    ) {
        guard width > 0, rows > 0 else { return }
        switch bitsPerSample {
        case 8:
            let stride = samplesPerPixel
            for row in 0..<rows {
                let base = row * width * stride
                for column in 1..<width {
                    let offset = base + column * stride
                    for sample in 0..<stride {
                        let target = offset + sample
                        guard target < raw.count else { return }
                        raw[target] = raw[target] &+ raw[target - stride]
                    }
                }
            }
        case 16:
            for row in 0..<rows {
                let base = row * width * samplesPerPixel * 2
                for column in 1..<width {
                    let offset = base + column * samplesPerPixel * 2
                    for sample in 0..<samplesPerPixel {
                        let target = offset + sample * 2
                        guard target + 1 < raw.count else { return }
                        let previous = offset - samplesPerPixel * 2
                        let value = raw.u16(at: target, order: order)
                            &+ raw.u16(at: previous, order: order)
                        if order == .little {
                            raw[target] = UInt8(value & 0xFF)
                            raw[target + 1] = UInt8(value >> 8)
                        } else {
                            raw[target] = UInt8(value >> 8)
                            raw[target + 1] = UInt8(value & 0xFF)
                        }
                    }
                }
            }
        default:
            // 1/2/4 位的预测极少见，不做处理。
            break
        }
    }

    /// 原始样本 → RGBA8。
    static func rgba(
        from raw: [UInt8],
        level: TIFFImageFileDirectory,
        rows: Int,
        order: TIFFByteOrder
    ) -> [UInt8] {
        let width = level.chunkWidth
        let height = level.chunkHeight
        var output = [UInt8](repeating: 0, count: width * height * 4)
        let samplesPerPixel = level.samplesPerPixel
        let bits = level.bitsPerSample.first ?? 8
        let gray = level.photometric == .blackIsZero || level.photometric == .whiteIsZero
        let invert = level.photometric == .whiteIsZero
        let palette = level.photometric == .palette ? level.colorMap : nil
        let hasAlpha = level.hasAlpha
        let alphaIsPremultiplied = level.extraSamples.first == 1
        let usableRows = min(rows, height)

        raw.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                for y in 0..<usableRows {
                    for x in 0..<width {
                        let target = (y * width + x) * 4
                        var red = 0, green = 0, blue = 0, alpha = 255
                        if bits == 8, samplesPerPixel >= 1, !hasAlpha {
                            let base = (y * width + x) * samplesPerPixel
                            if base < raw.count {
                                if let palette {
                                    let index = Int(source[base])
                                    red = Int(palette[index]) / 257
                                    green = Int(palette[(1 << bits) + index]) / 257
                                    blue = Int(palette[2 * (1 << bits) + index]) / 257
                                } else if gray || samplesPerPixel < 3 {
                                    red = Int(source[base]); green = red; blue = red
                                } else {
                                    red = Int(source[base])
                                    green = base + 1 < raw.count ? Int(source[base + 1]) : 0
                                    blue = base + 2 < raw.count ? Int(source[base + 2]) : 0
                                }
                            }
                        } else {
                            func sample(_ index: Int) -> Int {
                                if bits == 1 || bits == 2 || bits == 4 {
                                    let bitIndex = (y * width + x) * samplesPerPixel * bits + index * bits
                                    // 打包位样本：块数据可能比声明的容量短（损坏 / 截断），
                                    // 这里的下标必须自己挡一下，否则就是数组越界。
                                    let byteIndex = bitIndex / 8
                                    guard byteIndex >= 0, byteIndex < raw.count else { return 0 }
                                    let byte = source[byteIndex]
                                    let shift = 8 - bits - (bitIndex % 8)
                                    let mask = (1 << bits) - 1
                                    let value = (Int(byte) >> shift) & mask
                                    // 归一化到 8 位。
                                    return value * 255 / mask
                                }
                                // 8 / 16 / 32 / 64 位（含浮点、有符号）统一按样本值读，
                                // 再按类型值域归一化 —— 这条口径与 DEM 工具那边完全一致。
                                guard let value = TIFFSampleAccess.value(
                                    bytes: raw,
                                    level: level,
                                    x: x,
                                    y: y,
                                    band: index,
                                    order: order
                                ) else { return 0 }
                                return Int(TIFFSampleAccess.normalize(value, level: level, band: index))
                            }
                            if let palette {
                                let index = sample(0)
                                let entries = 1 << bits
                                if index < entries {
                                    red = Int(palette[index]) / 257
                                    green = Int(palette[entries + index]) / 257
                                    blue = Int(palette[2 * entries + index]) / 257
                                }
                            } else if gray || samplesPerPixel < 3 {
                                red = sample(0); green = red; blue = red
                            } else {
                                red = sample(0); green = sample(1); blue = sample(2)
                            }
                            if hasAlpha {
                                let alphaSample = samplesPerPixel > (gray || samplesPerPixel < 3 ? 1 : 3)
                                    ? samplesPerPixel - 1
                                    : samplesPerPixel - 1
                                alpha = sample(alphaSample)
                            }
                        }
                        if invert {
                            red = 255 - red; green = 255 - green; blue = 255 - blue
                        }
                        destination[target] = UInt8(clamping: red)
                        destination[target + 1] = UInt8(clamping: green)
                        destination[target + 2] = UInt8(clamping: blue)
                        destination[target + 3] = UInt8(clamping: alpha)
                        if hasAlpha, !alphaIsPremultiplied, alpha < 255 {
                            // CGImage 用预乘 alpha，这里按直通样本预乘一次。
                            destination[target] = UInt8(clamping: red * alpha / 255)
                            destination[target + 1] = UInt8(clamping: green * alpha / 255)
                            destination[target + 2] = UInt8(clamping: blue * alpha / 255)
                        }
                    }
                }
            }
        }
        return output
    }
}
