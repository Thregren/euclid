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
        destination: CGRect
    ) throws {
        guard level.planarConfiguration == 1 else {
            throw TIFFError.unsupported("暂不支持分离平面（PlanarConfiguration = 2）的 TIFF")
        }
        guard level.compression.isSupported else {
            throw TIFFError.unsupported("暂不支持这种 TIFF 压缩方式：\(level.compression.description)")
        }
        guard let bits = level.bitsPerSampleUniform, [1, 2, 4, 8, 16].contains(bits) else {
            throw TIFFError.unsupported("暂不支持 \(level.bitsPerSample.first ?? 0) 位/样本的 TIFF")
        }
        guard [1, 3].contains(level.sampleFormat.first ?? 1) else {
            throw TIFFError.unsupported("暂不支持浮点样本的 TIFF")
        }
        guard level.predictor == 1 || level.predictor == 2 else {
            throw TIFFError.unsupported("暂不支持 Predictor = \(level.predictor) 的 TIFF")
        }
        if level.compression != .jpeg {
            switch level.photometric {
            case .rgb, .blackIsZero, .whiteIsZero:
                break
            case .palette:
                guard (level.colorMap?.count ?? 0) >= 3 * (1 << bits) else {
                    throw TIFFError.decodeFailed("调色板表不完整")
                }
            default:
                throw TIFFError.unsupported("暂不支持这种光度解释（\(level.photometric)）")
            }
        }
        guard level.chunkWidth > 0, level.chunkHeight > 0, !level.chunks.isEmpty else {
            throw TIFFError.decodeFailed("没有可读的数据块")
        }

        let reader = try TIFFSourceFile(url: file.url)
        defer { reader.close() }
        let store = ChunkStore(reader: reader, file: file, level: level)

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
}

/// 数据块的解码缓存：同一块会被相邻的若干目标像素反复取到。
private final class ChunkStore {
    private let reader: TIFFSourceFile
    private let file: TIFFFile
    private let level: TIFFImageFileDirectory
    private var cache: [Int: [UInt8]] = [:]
    private var order: [Int] = []
    private let limit = 24
    /// 上一次取到的块。相邻采样点几乎总是落在同一块里，
    /// 记一份就能把「每个采样点查一次字典」降到一次整数比较。
    private var lastIndex = -1
    private var lastPixels: [UInt8] = []

    init(reader: TIFFSourceFile, file: TIFFFile, level: TIFFImageFileDirectory) {
        self.reader = reader
        self.file = file
        self.level = level
    }

    /// 取某个源像素的 RGBA；越界返回 nil。
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

    private func chunkPixels(_ index: Int) throws -> [UInt8] {
        if let cached = cache[index] { return cached }
        let pixels = try decodeChunk(index)
        cache[index] = pixels
        order.append(index)
        while order.count > limit {
            cache.removeValue(forKey: order.removeFirst())
        }
        return pixels
    }

    /// 数据块里真正有内容的行数（最后一行/列可能不满）。
    private func rowsInChunk(_ index: Int) -> Int {
        let across = max(1, level.chunksAcross)
        let row = index / across
        let start = row * level.chunkHeight
        return max(1, min(level.chunkHeight, level.height - start))
    }

    private func decodeChunk(_ index: Int) throws -> [UInt8] {
        let rows = rowsInChunk(index)
        let transparent = [UInt8](repeating: 0, count: level.chunkWidth * level.chunkHeight * 4)
        let chunk = level.chunks[index]
        guard chunk.byteCount > 0, let data = reader.read(offset: chunk.offset, count: chunk.byteCount) else {
            return transparent
        }

        if level.compression == .jpeg {
            return try jpegPixels(data, rows: rows)
        }

        let samplesPerPixel = level.samplesPerPixel
        let bytesPerSample = level.bytesPerSample
        let rowBytes = level.chunkWidth * samplesPerPixel * bytesPerSample
        let capacity = level.chunkHeight * rowBytes

        var raw: [UInt8]
        switch level.compression {
        case .none:
            raw = [UInt8](data)
            if raw.count < capacity { raw.append(contentsOf: [UInt8](repeating: 0, count: capacity - raw.count)) }
        case .deflate:
            guard let inflated = TIFFCodec.inflate(data, capacity: capacity) else {
                throw TIFFError.decodeFailed("Deflate 解压失败（第 \(index) 块）")
            }
            raw = inflated
        case .lzw:
            guard let decoded = TIFFCodec.lzwDecode(data, capacity: capacity) else {
                throw TIFFError.decodeFailed("LZW 解码失败（第 \(index) 块）")
            }
            raw = decoded
        case .packBits:
            guard let decoded = TIFFCodec.packBitsDecode(data, capacity: capacity) else {
                throw TIFFError.decodeFailed("PackBits 解码失败（第 \(index) 块）")
            }
            raw = decoded
        case .jpeg, .other:
            throw TIFFError.unsupported("暂不支持这种 TIFF 压缩方式：\(level.compression.description)")
        }

        if level.predictor == 2 {
            TIFFCodec.undoHorizontalPredictor(
                &raw,
                width: level.chunkWidth,
                rows: rows,
                samplesPerPixel: samplesPerPixel,
                bitsPerSample: level.bitsPerSample.first ?? 8,
                order: file.byteOrder
            )
        }
        return TIFFCodec.rgba(
            from: raw,
            level: level,
            rows: rows,
            order: file.byteOrder
        )
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
enum TIFFCodec {
    /// TIFF 的 Deflate 解压。
    ///
    /// 规范里 TIFF 的 Deflate 是 zlib 包装（RFC 1950：2 字节头 + 裸 deflate + 4 字节 Adler-32），
    /// 而系统 `Compression` 框架的 `COMPRESSION_ZLIB` **只吃裸 deflate**
    /// （它自己编码出来的就是裸流；把标准 zlib 流丢给它一律报错）。
    /// 所以这里先剥掉 zlib 外壳，剥不动或者解不出再按裸流试一次。
    static func inflate(_ data: Data, capacity: Int) -> [UInt8]? {
        guard capacity > 0, !data.isEmpty else { return nil }
        if data.count > 6, isZlibWrapped(data) {
            let body = Data(data.dropFirst(2).dropLast(4))
            if let decoded = rawInflate(body, capacity: capacity) { return decoded }
        }
        return rawInflate(data, capacity: capacity)
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

    private static func rawInflate(_ data: Data, capacity: Int) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            data.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    sourceBase, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        if written == 0, ProcessInfo.processInfo.environment["EUCLID_TIFF_TRACE"] != nil {
            FileHandle.standardError.write(Data(
                "[tiff-probe] inflate 失败：读到 \(data.count) 字节，期望容量 \(capacity)，头 4 字节 "
                    .appending(data.prefix(4).map { String(format: "%02x", $0) }.joined())
                    .appending("\n").utf8
            ))
            return nil
        }
        guard written > 0 else { return nil }
        if written != capacity, ProcessInfo.processInfo.environment["EUCLID_RASTER_TRACE"] != nil {
            let line = "[tiff] 解压只得到 \(written) / 期望 \(capacity) 字节（输入 \(data.count)）\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        if written < capacity {
            for index in written..<capacity { output[index] = 0 }
        }
        return output
    }

    /// PackBits（TIFF 6.0 的 RLE）。
    static func packBitsDecode(_ data: Data, capacity: Int) -> [UInt8]? {
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
            output.append(contentsOf: [UInt8](repeating: 0, count: capacity - output.count))
        }
        return Array(output.prefix(capacity))
    }

    /// TIFF 的 LZW。
    ///
    /// 位宽增长的时机（「提前一位」）各家写法偶有出入，所以两种规则都试一遍：
    /// 先按规范（提前一位）解，长度不对再按不提前解；哪个正好填满就采用哪个。
    static func lzwDecode(_ data: Data, capacity: Int) -> [UInt8]? {
        if let decoded = lzwDecode(data, capacity: capacity, earlyChange: true), decoded.count == capacity {
            return decoded
        }
        if let decoded = lzwDecode(data, capacity: capacity, earlyChange: false), decoded.count == capacity {
            return decoded
        }
        return lzwDecode(data, capacity: capacity, earlyChange: true)
    }

    private static func lzwDecode(_ data: Data, capacity: Int, earlyChange: Bool) -> [UInt8]? {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty, capacity > 0 else { return nil }

        var output: [UInt8] = []
        output.reserveCapacity(capacity)
        var dictionary: [[UInt8]] = []
        func resetDictionary() {
            dictionary = (0..<256).map { [UInt8($0)] }
            dictionary.append([])   // 256：清除
            dictionary.append([])   // 257：结束
        }
        resetDictionary()

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

        var previous: [UInt8]?
        while let code = nextCode() {
            if code == 256 {
                resetDictionary()
                codeWidth = 9
                previous = nil
                continue
            }
            if code == 257 { break }

            let entry: [UInt8]
            if code < dictionary.count, !dictionary[code].isEmpty {
                entry = dictionary[code]
            } else if let previous, !previous.isEmpty {
                entry = previous + [previous[0]]
            } else {
                return nil
            }
            output.append(contentsOf: entry)
            if let previous, !previous.isEmpty {
                dictionary.append(previous + [entry[0]])
            }
            previous = entry

            let threshold = earlyChange ? (1 << codeWidth) - 1 : (1 << codeWidth)
            if dictionary.count >= threshold, codeWidth < 12 {
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
                            let base = (y * width + x) * samplesPerPixel * (bits / 8)
                            func sample(_ index: Int) -> Int {
                                let offset = base + index * (bits / 8)
                                switch bits {
                                case 16:
                                    return Int(source.u16(at: offset, order: order)) >> 8
                                case 1, 2, 4:
                                    let bitIndex = (y * width + x) * samplesPerPixel * bits + index * bits
                                    let byte = source[bitIndex / 8]
                                    let shift = 8 - bits - (bitIndex % 8)
                                    let mask = (1 << bits) - 1
                                    let value = (Int(byte) >> shift) & mask
                                    // 归一化到 8 位。
                                    return value * 255 / mask
                                default:
                                    return offset < raw.count ? Int(source[offset]) : 0
                                }
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
