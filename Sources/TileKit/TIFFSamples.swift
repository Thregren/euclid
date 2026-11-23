import Foundation

/// 样本的数值类型（TIFF 标签 339 `SampleFormat`）。
///
/// 与「怎么显示」无关：这里只回答「这一级的样本是整数还是浮点、有没有符号」。
/// DEM / 多波段栅格走的是样本值这条路，颜色解释交给上层。
package enum TIFFSampleKind: Sendable {
    case unsigned
    case signed
    case float

    init(code: Int) {
        switch code {
        case 2: self = .signed
        case 3: self = .float
        default: self = .unsigned
        }
    }
}

/// 显示拉伸：把浮点 / 高动态范围的样本值映射到 0…255。
///
/// `low` 与 `high` 由上层按数据分布算出来（见 `TIFFDisplayRange`），
/// 解码器只负责按它做线性映射 —— 解码器不需要知道「什么算亮」。
package struct TIFFStretch: Sendable, Equatable {
    package var low: Float
    package var high: Float

    package init(low: Float, high: Float) {
        self.low = low
        self.high = high
    }

    /// 值 → 0…255；非有限值返回 nil（调用方按透明处理）。
    package func level(_ value: Float) -> UInt8? {
        guard value.isFinite else { return nil }
        let span = high - low
        guard span.isFinite, span > 0 else { return 0 }
        let t = (value - low) / span
        if t <= 0 { return 0 }
        if t >= 1 { return 255 }
        return UInt8((t * 255).rounded())
    }
}

extension TIFFImageFileDirectory {
    /// 主样本的数值类型（多波段时按第一个样本算，混合类型极少见）。
    var sampleKind: TIFFSampleKind {
        TIFFSampleKind(code: sampleFormat.first ?? 1)
    }

    var isFloatSamples: Bool { sampleKind == .float }

    /// 平面数：连续存放（1）只有 1 个平面，分离存放（2）每个样本一个平面。
    var planeCount: Int {
        planarConfiguration == 2 ? max(1, samplesPerPixel) : 1
    }

    /// 单个平面里的块数（分块图 = 横向块数 × 纵向块数）。
    var chunksPerPlane: Int {
        max(1, chunksAcross) * max(1, chunksDown)
    }

    /// 连续存放时块表就是「按行优先」；分离存放时块表是「平面优先」。
    func chunkIndex(plane: Int, indexInPlane: Int) -> Int? {
        guard plane >= 0, plane < planeCount, indexInPlane >= 0 else { return nil }
        guard indexInPlane < chunksPerPlane else { return nil }
        let (base, multiplicationOverflow) = (planarConfiguration == 2 ? plane : 0).multipliedReportingOverflow(by: chunksPerPlane)
        let (index, additionOverflow) = base.addingReportingOverflow(indexInPlane)
        guard !multiplicationOverflow, !additionOverflow, index >= 0, index < chunks.count else { return nil }
        return index
    }

    /// 某个块里真正有内容的行数（最后一行可能不满）。
    func rowsInChunk(indexInPlane: Int) -> Int {
        let across = max(1, chunksAcross)
        let row = indexInPlane / across
        let start = row * chunkHeight
        return max(1, min(chunkHeight, height - start))
    }

    /// 一个块里每行有多少个样本（分离平面时块里只有当前平面）。
    var samplesPerChunkRow: Int {
        max(1, chunkWidth) * (planarConfiguration == 2 ? 1 : max(1, samplesPerPixel))
    }

    /// 某个块「写进文件时」的完整字节数。
    ///
    /// 最后一列 / 最后一行的块在编码时仍按整块大小补齐（libtiff 就是这么写的），
    /// 所以解压缓冲区要按整块申请，否则压缩流比预期长会被判成损坏。
    var chunkCapacityBytes: Int {
        TIFFLimits.chunkBytes(width: chunkWidth, height: chunkHeight,
                              samples: planarConfiguration == 2 ? 1 : samplesPerPixel,
                              bits: bitsPerSample.first ?? 8) ?? 0
    }

    /// 某个块里「有图像内容」的字节数（最后一行可能不满）。
    func visibleCapacityBytes(indexInPlane: Int) -> Int {
        TIFFLimits.chunkBytes(width: chunkWidth, height: rowsInChunk(indexInPlane: indexInPlane),
                              samples: planarConfiguration == 2 ? 1 : samplesPerPixel,
                              bits: bitsPerSample.first ?? 8) ?? 0
    }
}

/// 「解出某个块、某个平面的原始样本字节」——解压 + 还原预测，不做颜色解释。
///
/// 渲染成 RGBA 与「按样本取值」（DEM 工具、差异叠加）都走这一条路：
/// 解压与预测还原只有一份实现，两条路不会各自漂移。
enum TIFFRawChunks {
    /// 解一块（带跨瓦片缓存）。
    ///
    /// - Parameters:
    ///   - chunkIndex: **平面内**的块号。
    ///   - plane: 平面号；连续存放时恒为 0。
    static func bytes(
        file: TIFFFile,
        level: TIFFImageFileDirectory,
        reader: TIFFSourceFile,
        chunkIndex: Int,
        plane: Int
    ) throws -> [UInt8] {
        guard let globalIndex = level.chunkIndex(plane: plane, indexInPlane: chunkIndex) else {
            throw TIFFError.decodeFailed("块号超出范围（平面 \(plane) 第 \(chunkIndex) 块）")
        }
        let key = TIFFChunkCache.Key(
            path: file.url.path(percentEncoded: false),
            level: level.offset,
            index: globalIndex,
            payload: .samples
        )
        return try TIFFChunkCache.shared.loadPixels(for: key) {
            try decode(file: file, level: level, reader: reader, chunkIndex: chunkIndex, plane: plane)
        }
    }

    /// 真正解一块（无缓存）。
    static func decode(
        file: TIFFFile,
        level: TIFFImageFileDirectory,
        reader: TIFFSourceFile,
        chunkIndex: Int,
        plane: Int
    ) throws -> [UInt8] {
        let rows = level.rowsInChunk(indexInPlane: chunkIndex)
        let bytesPerSample = level.bytesPerSample
        // 按「整块」申请：最后一列 / 最后一行在文件里也是按整块补齐的。
        let capacity = level.chunkCapacityBytes
        try Task.checkCancellation()
        guard capacity > 0 else { throw TIFFError.unsupported("TIFF 解码块超过安全内存预算") }
        guard let globalIndex = level.chunkIndex(plane: plane, indexInPlane: chunkIndex) else {
            return [UInt8](repeating: 0, count: capacity)
        }
        let chunk = level.chunks[globalIndex]
        guard chunk.byteCount <= TIFFLimits.maximumChunkBytes else {
            throw TIFFError.unsupported("TIFF 压缩块超过安全内存预算")
        }
        guard chunk.byteCount > 0, let data = reader.read(offset: chunk.offset, count: chunk.byteCount) else {
            return [UInt8](repeating: 0, count: capacity)
        }
        let reported = "\(chunkIndex)（平面 \(plane)）"

        let reportShort: (String) -> (Int) -> Void = { [file] codec in
            { produced in
                TIFFDiagnostics.record(
                    message: "第 \(reported) 块的 \(codec) 数据比声明的短"
                        + "（解出 \(produced) / 期望 \(capacity) 字节），缺口已补零",
                    file: file.url
                )
            }
        }

        var raw: [UInt8]
        switch level.compression {
        case .none:
            raw = [UInt8](data)
            if raw.count < capacity {
                reportShort("未压缩")(raw.count)
                raw.append(contentsOf: [UInt8](repeating: 0, count: capacity - raw.count))
            }
        case .deflate:
            guard let inflated = TIFFCodec.inflate(data, capacity: capacity, onShort: reportShort("Deflate")) else {
                throw TIFFError.decodeFailed("Deflate 解压失败（第 \(reported) 块）")
            }
            raw = inflated
        case .lzw:
            guard let decoded = TIFFCodec.lzwDecode(data, capacity: capacity, onShort: reportShort("LZW")) else {
                throw TIFFError.decodeFailed("LZW 解码失败（第 \(reported) 块）")
            }
            raw = decoded
        case .packBits:
            guard let decoded = TIFFCodec.packBitsDecode(data, capacity: capacity, onShort: reportShort("PackBits")) else {
                throw TIFFError.decodeFailed("PackBits 解码失败（第 \(reported) 块）")
            }
            raw = decoded
        case .jpeg, .other:
            throw TIFFError.unsupported("暂不支持这种 TIFF 压缩方式：\(level.compression.description)")
        }

        undoPredictor(&raw, level: level, rows: rows, bytesPerSample: bytesPerSample, order: file.byteOrder)
        if raw.count < capacity { raw.append(contentsOf: [UInt8](repeating: 0, count: capacity - raw.count)) }
        return raw
    }

    /// 按 Predictor 标签还原差分编码。
    static func undoPredictor(
        _ raw: inout [UInt8],
        level: TIFFImageFileDirectory,
        rows: Int,
        bytesPerSample: Int,
        order: TIFFByteOrder
    ) {
        switch level.predictor {
        case 2:
            TIFFCodec.undoHorizontalPredictor(
                &raw,
                width: level.chunkWidth,
                rows: rows,
                samplesPerPixel: level.planarConfiguration == 2 ? 1 : max(1, level.samplesPerPixel),
                bitsPerSample: level.bitsPerSample.first ?? 8,
                order: order
            )
        case 3:
            undoFloatPredictor(
                &raw,
                width: level.chunkWidth,
                rows: rows,
                samplesPerPixel: level.planarConfiguration == 2 ? 1 : max(1, level.samplesPerPixel),
                bytesPerSample: bytesPerSample,
                order: order
            )
        default:
            break
        }
    }

    /// Predictor = 3（浮点行差分）。
    ///
    /// libtiff 的 `fpAcc` 分两步，顺序不能反：
    /// 1. **先按字节平面重排**（编码时做的逆操作）：一条记录里每个样本按字节拆开，
    ///    小端文件把最高位那一片排在最前，大端文件把最低位那一片排在最前；
    /// 2. **再做按字节累加**，而且跨的是重排后相邻的**字节**（含平面交界处），
    ///    不是相邻样本的同位置字节 —— 这一点最容易想当然写错。
    ///
    /// 累加只在一条记录内部进行（跨行不累加），所以这里按行走。
    static func undoFloatPredictor(
        _ raw: inout [UInt8],
        width: Int,
        rows: Int,
        samplesPerPixel: Int,
        bytesPerSample: Int,
        order: TIFFByteOrder
    ) {
        guard width > 0, rows > 0, bytesPerSample > 0 else { return }
        let rowSamples = width * max(1, samplesPerPixel)
        let rowBytes = rowSamples * bytesPerSample
        guard rowBytes > 0 else { return }
        let available = raw.count
        // 一行的临时缓冲，行内复用（不每行新申请）。
        var scratch = [UInt8](repeating: 0, count: rowBytes)
        let littleEndian = order == .little
        raw.withUnsafeMutableBufferPointer { buffer in
            scratch.withUnsafeMutableBufferPointer { copy in
                guard let source = buffer.baseAddress, let destination = copy.baseAddress else { return }
                for row in 0..<rows {
                    let base = row * rowBytes
                    guard base >= 0, base + rowBytes <= available else { return }
                    // 第一步：字节累加（记录内相邻字节，含平面交界）。
                    var index = base + 1
                    let end = base + rowBytes
                    while index < end {
                        source[index] = source[index] &+ source[index - 1]
                        index += 1
                    }
                    // 第二步：还原字节平面。平面 j 里存的是样本的第 `plane` 个字节。
                    destination.update(from: source + base, count: rowBytes)
                    for sample in 0..<rowSamples {
                        for byte in 0..<bytesPerSample {
                            // 小端：平面先后 = 高位字节 → 低位字节；大端反过来。
                            let plane = littleEndian ? bytesPerSample - 1 - byte : byte
                            source[base + sample * bytesPerSample + byte] = destination[plane * rowSamples + sample]
                        }
                    }
                }
            }
        }
    }
}

/// 从一个「原始样本字节块」里读出某个像素、某个波段的数值。
///
/// 纯函数、不持有内存：调用方拿到块字节后，按需取多少个点都行。
enum TIFFSampleAccess {
    /// 块内坐标 `(x, y)`、波段 `band` 的样本值；越界返回 nil。
    ///
    /// - Note: 分离平面（PlanarConfiguration = 2）时块里只有 `band` 这一个平面，
    ///   `band` 参数只用来选「第几个字节位置」，与平面无关。
    static func value(
        bytes: [UInt8],
        level: TIFFImageFileDirectory,
        x: Int,
        y: Int,
        band: Int,
        order: TIFFByteOrder
    ) -> Float? {
        guard x >= 0, y >= 0, x < level.chunkWidth, y < level.chunkHeight else { return nil }
        let index = max(0, min(band, level.bitsPerSample.count - 1))
        let bits = level.bitsPerSample[index]
        guard bits == 8 || bits == 16 || bits == 32 || bits == 64 else { return nil }
        let bytesPerSample = bits / 8
        let samplesPerRow = level.planarConfiguration == 2 ? 1 : max(1, level.samplesPerPixel)
        let offset = (y * level.chunkWidth + x) * samplesPerRow * bytesPerSample + band * bytesPerSample
        guard offset >= 0, offset + bytesPerSample <= bytes.count else { return nil }
        let kind = TIFFSampleKind(code: level.sampleFormat[index])
        switch kind {
        case .float:
            switch bits {
            case 32:
                let raw = bytes.u32(at: offset, order: order)
                let value = Float(bitPattern: raw)
                return value.isFinite ? value : nil
            case 64:
                let raw = bytes.u64(at: offset, order: order)
                let value = Double(bitPattern: raw)
                return value.isFinite ? Float(value) : nil
            default:
                return nil
            }
        case .unsigned:
            switch bits {
            case 8: return Float(bytes[offset])
            case 16: return Float(bytes.u16(at: offset, order: order))
            case 32: return Float(bytes.u32(at: offset, order: order))
            default: return Float(bytes.u64(at: offset, order: order))
            }
        case .signed:
            switch bits {
            case 8: return Float(Int8(bitPattern: bytes[offset]))
            case 16: return Float(Int16(bitPattern: bytes.u16(at: offset, order: order)))
            case 32: return Float(Int32(bitPattern: bytes.u32(at: offset, order: order)))
            default: return Float(Int64(bitPattern: bytes.u64(at: offset, order: order)))
            }
        }
    }

    /// 样本值 → 0…255。没有拉伸（拉伸只对浮点有效）时按类型值域归一化：
    /// 无符号取满量程，有符号以零点居中，浮点按 0…1 兜底。
    static func normalize(_ value: Float, level: TIFFImageFileDirectory, band: Int) -> UInt8 {
        guard value.isFinite else { return 0 }
        let count = max(1, level.bitsPerSample.count)
        let index = max(0, min(band, count - 1))
        let bits = level.bitsPerSample[index]
        return normalize(value, bits: bits, kind: TIFFSampleKind(code: level.sampleFormat[index]))
    }

    /// 归一化的纯函数形式（只吃位数与类型）：自检直接喂参数即可。
    package static func normalize(_ value: Float, bits: Int, kind: TIFFSampleKind) -> UInt8 {
        guard value.isFinite, bits >= 1, bits <= 64 else { return 0 }
        let upper = pow(2.0, Double(bits)) - 1
        guard upper > 0 else { return 0 }
        let value = Double(value)
        let t: Double
        switch kind {
        case .float:
            t = value
        case .unsigned:
            t = value / upper
        case .signed:
            let half = pow(2.0, Double(bits - 1))
            t = (value + half) / upper
        }
        if !t.isFinite || t <= 0 { return 0 }
        if t >= 1 { return 255 }
        return UInt8((t * 255).rounded())
    }
}

/// 自检入口：把几处只吃原生参数的纯函数暴露给同包的检查程序。
///
/// `TIFFImageFileDirectory` 这类结构是模块内部的，自检没必要为了测两个纯函数
/// 就把整条元数据 API 放开；这里只转出「喂字节 / 喂数字」的那两个。
package enum TIFFSampleChecks {
    /// Predictor 3（浮点行差分）的还原。
    package static func undoFloatPredictor(
        _ raw: inout [UInt8],
        width: Int,
        rows: Int,
        samplesPerPixel: Int = 1,
        bytesPerSample: Int = 4,
        littleEndian: Bool = true
    ) {
        TIFFRawChunks.undoFloatPredictor(
            &raw,
            width: width,
            rows: rows,
            samplesPerPixel: samplesPerPixel,
            bytesPerSample: bytesPerSample,
            order: littleEndian ? .little : .big
        )
    }

    /// 样本值 → 0…255 的归一化（按位数与类型）。
    package static func normalize(_ value: Float, bits: Int, kind: TIFFSampleKind) -> UInt8 {
        TIFFSampleAccess.normalize(value, bits: bits, kind: kind)
    }

}

/// 浮点影像的显示拉伸范围（低 / 高分位）。
///
/// 浮点正射影像（DEM、反射率）的值域常常被少量极端值拉得很开，
/// 直接用 min…max 会整幅发灰。这里在最粗的一级上稀疏采样，取 2%…98% 分位。
///
/// 结果按「路径 + 层级 + 文件大小」记在缓存里：拖动时每个瓦片都要问一次，
/// 不能每次都重算。
package final class TIFFDisplayRange: @unchecked Sendable {
    package static let shared = TIFFDisplayRange()

    private struct Key: Hashable {
        var path: String
        var level: Int
        var byteCount: Int
    }

    private let lock = NSLock()
    private var ranges: [Key: TIFFStretch] = [:]
    private var order: [Key] = []
    private let limit = 16

    /// 取（或算）某一级的显示拉伸；`root` 用来算缓存键。
    package static func stretch(for file: TIFFFile) -> TIFFStretch? {
        shared.stretch(for: file)
    }

    private func stretch(for file: TIFFFile) -> TIFFStretch? {
        let level = coarsestLevel(of: file)
        guard level.width > 0, level.height > 0 else { return nil }
        let key = Key(
            path: file.url.path(percentEncoded: false),
            level: level.offset,
            byteCount: file.pixelWidth * file.pixelHeight
        )
        lock.lock()
        if let cached = ranges[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let computed = compute(file: file, level: level) else { return nil }
        lock.lock()
        if ranges[key] == nil {
            ranges[key] = computed
            order.append(key)
            while order.count > limit, let oldest = order.first {
                order.removeFirst()
                ranges.removeValue(forKey: oldest)
            }
        }
        lock.unlock()
        return computed
    }

    /// 丢掉某个文件的拉伸缓存（文件被换掉时）。
    package static func invalidate(path: String) {
        shared.invalidate(path: path)
    }

    private func invalidate(path: String) {
        lock.lock()
        defer { lock.unlock() }
        let doomed = order.filter { $0.path == path }
        guard !doomed.isEmpty else { return }
        order.removeAll { $0.path == path }
        for key in doomed { ranges.removeValue(forKey: key) }
    }

    private func coarsestLevel(of file: TIFFFile) -> TIFFImageFileDirectory {
        // `levels` 是「概览 + 主图」升序，第一个就是最粗的一级。
        file.levels.first { $0.width > 0 && $0.height > 0 } ?? file.main
    }

    /// 在最粗一级上稀疏采样，取 2%…98% 分位。
    private func compute(file: TIFFFile, level: TIFFImageFileDirectory) -> TIFFStretch? {
        // 打包位样本（1/2/4 位）不走这条路：它们的值域本来就规整，按位归一化即可。
        guard let bits = level.bitsPerSampleUniform, bits == 8 || bits == 16 || bits == 32 || bits == 64
        else { return nil }
        let taps = 96
        let stepX = max(1, level.width / taps)
        let stepY = max(1, level.height / taps)
        let chunkWidth = max(1, level.chunkWidth)
        let chunkHeight = max(1, level.chunkHeight)
        let across = max(1, level.chunksAcross)
        var samples: [Float] = []
        samples.reserveCapacity((level.width / stepX + 1) * (level.height / stepY + 1))
        do {
            let lease = try TIFFChunkCache.shared.acquireReader(url: file.url)
            var cacheRow = -1
            var cacheColumns: [Int: [UInt8]] = [:]
            var y = 0
            while y < level.height {
                let chunkRow = y / chunkHeight
                if chunkRow != cacheRow {
                    cacheRow = chunkRow
                    cacheColumns = [:]
                }
                var x = 0
                while x < level.width {
                    let column = x / chunkWidth
                    if cacheColumns[column] == nil {
                        let index = chunkRow * across + column
                        cacheColumns[column] = try? TIFFRawChunks.bytes(
                            file: file,
                            level: level,
                            reader: lease.reader,
                            chunkIndex: index,
                            plane: 0
                        )
                    }
                    if let bytes = cacheColumns[column],
                       let value = TIFFSampleAccess.value(
                           bytes: bytes,
                           level: level,
                           x: x % chunkWidth,
                           y: y % chunkHeight,
                           band: 0,
                           order: file.byteOrder
                       ) {
                        samples.append(value)
                    }
                    x += stepX
                }
                y += stepY
            }
        } catch {
            return nil
        }
        guard samples.count >= 8 else {
            return samples.first.map { TIFFStretch(low: $0, high: $0 + 1) }
        }
        samples.sort()
        let low = samples[min(samples.count - 1, samples.count / 50)]
        let high = samples[min(samples.count - 1, samples.count - 1 - samples.count / 50)]
        if high - low <= .ulpOfOne {
            return TIFFStretch(low: low, high: low + 1)
        }
        return TIFFStretch(low: low, high: high)
    }
}
