import CoreGraphics
import Foundation

/// 一次取到的样本网格：矩形范围 + 真实样本值。
///
/// 与画面对应的关系是 `rect` / `step`：`values[row * width + column]` 取自
/// `rect.origin + (column * step, row * step)`。显示之外要的是数值本身
/// （高程、反射率……），所以这里不做任何颜色映射。
public struct RasterSampleGrid: Sendable {
    public let width: Int
    public let height: Int
    /// 采样覆盖的源像素矩形（左上角原点）。
    public let rect: CGRect
    /// 采样步长（1 = 原分辨率）。
    public let step: Int
    public let values: [Float]

    public init(width: Int, height: Int, rect: CGRect, step: Int, values: [Float]) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.rect = rect
        self.step = max(1, step)
        self.values = values
    }

    /// 越界返回 NaN（而不是崩）。
    public subscript(column: Int, row: Int) -> Float {
        guard column >= 0, row >= 0, column < width, row < height else { return .nan }
        let index = row * width + column
        guard index >= 0, index < values.count else { return .nan }
        return values[index]
    }

    /// 第 (column,row) 个采样点对应的源像素坐标（格中心）。
    public func pixelPoint(column: Int, row: Int) -> CGPoint {
        CGPoint(
            x: rect.minX + Double(column * step) + min(Double(step), max(0, rect.width - Double(column * step))) / 2,
            y: rect.minY + Double(row * step) + min(Double(step), max(0, rect.height - Double(row * step))) / 2
        )
    }

    /// 有效值（有限、不是 NaN）。
    public var validValues: [Float] {
        values.filter { $0.isFinite }
    }

    /// 有效值的范围；一个有效值都没有时返回 nil。
    public var range: ClosedRange<Float>? {
        var low = Float.greatestFiniteMagnitude
        var high = -Float.greatestFiniteMagnitude
        for value in values where value.isFinite {
            low = min(low, value)
            high = max(high, value)
        }
        guard low <= high else { return nil }
        return low...high
    }
}

/// 单幅栅格的「按样本取值」入口。
///
/// DEM 工具箱（点高程、剖面、坡度、土方）与两期差异叠加都走它 ——
/// 与显示路径共用同一份解压 / 预测还原实现（`TIFFRawChunks`），
/// 因此「图上看到的」和「算出来的」不会对不上。
///
/// 值类型 + 每次现取句柄：没有需要释放的资源，跨线程用也不会共享可变状态。
public struct RasterSampleReader: Sendable {
    public let fileURL: URL
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let bandCount: Int
    public let sampleBits: Int
    public let isFloat: Bool
    public let isGeoreferenced: Bool
    public let georeference: RasterGeoreference

    /// 解析文件头；读不出就返回 nil（不抛错，调用方按「这份数据不适合分析」处理）。
    public static func open(url: URL, forceReload: Bool = false) -> RasterSampleReader? {
        // Force an identity check, not a cold decode: unchanged files keep their shared chunks.
        guard let file = TIFFFileCache.shared.file(for: url, forceIdentityCheck: forceReload) else { return nil }
        let main = file.main
        guard main.width > 0, main.height > 0, main.chunkWidth > 0, main.chunkHeight > 0,
              !main.chunks.isEmpty, main.compression.isSupported,
              main.planarConfiguration == 1 || main.planarConfiguration == 2 else { return nil }
        let reference = RasterGeoreference.from(
            geo: file.geo,
            pixelWidth: main.width,
            pixelHeight: main.height
        )
        return RasterSampleReader(
            fileURL: url,
            pixelWidth: main.width,
            pixelHeight: main.height,
            bandCount: max(1, main.samplesPerPixel),
            sampleBits: main.bitsPerSample.first ?? 8,
            isFloat: main.isFloatSamples,
            isGeoreferenced: reference.isGeoreferenced,
            georeference: reference
        )
    }

    /// 像不像一份 DEM：单波段、浮点或 ≥16 位整数。
    public var isElevationLike: Bool {
        bandCount == 1 && (isFloat || sampleBits >= 16)
    }

    /// 中央像素横向的地面尺度。分析计算使用完整的局部地面向量和面积。
    public func groundPixelSize() -> Double? {
        RasterGroundGeometry(reference: georeference)
            .metric(column: Double(pixelWidth) / 2, row: Double(pixelHeight) / 2)?.columnLength
    }

    /// 单个样本值（最近邻）；越界或读不出返回 nil。
    public func value(column: Double, row: Double, band: Int = 0) -> Float? {
        guard column.isFinite, row.isFinite, column >= 0, row >= 0,
              column < Double(pixelWidth), row < Double(pixelHeight) else { return nil }
        let x = Int(column.rounded(.down))
        let y = Int(row.rounded(.down))
        guard x >= 0, y >= 0, x < pixelWidth, y < pixelHeight else { return nil }
        return withLevel { file, level -> Float? in
            guard let bytes = try? chunkBytes(file: file, level: level, x: x, y: y, band: band) else {
                return nil
            }
            return TIFFSampleAccess.value(
                bytes: bytes.0,
                level: level,
                x: bytes.1,
                y: bytes.2,
                band: level.planarConfiguration == 2 ? 0 : band,
                order: file.byteOrder
            )
        }
    }

    /// 取一个矩形范围的样本网格。
    ///
    /// - Parameter maxDimension: 输出网格最长边的上限；超了就按整数步长抽稀。
    /// - Returns: 网格（`step > 1` 表示抽稀过），取不到返回 nil。
    public func grid(rect: CGRect, band: Int = 0, maxDimension: Int = 1024) -> RasterSampleGrid? {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.maxX.isFinite, rect.maxY.isFinite, rect.width > 0, rect.height > 0 else { return nil }
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: Double(pixelWidth), height: Double(pixelHeight)))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        let limit = max(2, min(4096, maxDimension))
        let x0 = max(0, Int(clipped.minX.rounded(.down)))
        let y0 = max(0, Int(clipped.minY.rounded(.down)))
        let x1 = min(pixelWidth, Int(clipped.maxX.rounded(.up)))
        let y1 = min(pixelHeight, Int(clipped.maxY.rounded(.up)))
        guard x1 > x0, y1 > y0 else { return nil }
        let step = max(1, Int((Double(max(x1 - x0, y1 - y0)) / Double(limit)).rounded(.up)))
        let width = (x1 - x0 + step - 1) / step
        let height = (y1 - y0 + step - 1) / step
        guard width > 0, height > 0, width * height <= limit * limit * 2 else { return nil }

        var values = [Float](repeating: .nan, count: width * height)
        let drawn: Bool = withLevel { file, level -> Bool? in
            guard let lease = try? TIFFChunkCache.shared.acquireReader(url: fileURL) else { return false }
            let across = max(1, level.chunksAcross)
            let chunkWidth = max(1, level.chunkWidth)
            let chunkHeight = max(1, level.chunkHeight)
            let plane = level.planarConfiguration == 2 ? band : 0
            let bandIndex = level.planarConfiguration == 2 ? 0 : band
            var cachedRow = -1
            var rowChunks: [Int: [UInt8]] = [:]
            var failedChunks: Set<Int> = []
            for outRow in 0..<height {
                if Task.isCancelled { return nil }
                let y = y0 + outRow * step
                guard y < level.height else { break }
                let chunkRow = y / chunkHeight
                if chunkRow != cachedRow {
                    cachedRow = chunkRow
                    rowChunks.removeAll(keepingCapacity: true)
                    failedChunks.removeAll(keepingCapacity: true)
                }
                var cachedColumn = -1
                var cachedBytes: [UInt8]?
                for outColumn in 0..<width {
                    let x = x0 + outColumn * step
                    guard x < level.width else { break }
                    let column = x / chunkWidth
                    if column != cachedColumn {
                        if rowChunks[column] == nil, !failedChunks.contains(column) {
                            let index = chunkRow * across + column
                            if let bytes = try? TIFFRawChunks.bytes(
                                file: file, level: level, reader: lease.reader, chunkIndex: index, plane: plane
                            ) {
                                rowChunks[column] = bytes
                            } else { failedChunks.insert(column) }
                        }
                        cachedColumn = column
                        cachedBytes = rowChunks[column]
                    }
                    guard let bytes = cachedBytes,
                          let value = TIFFSampleAccess.value(
                              bytes: bytes,
                              level: level,
                              x: x % chunkWidth,
                              y: y % chunkHeight,
                              band: bandIndex,
                              order: file.byteOrder
                          ) else { continue }
                    values[outRow * width + outColumn] = value
                }
            }
            return true
        } ?? false
        guard drawn else { return nil }
        return RasterSampleGrid(
            width: width,
            height: height,
            rect: CGRect(x: Double(x0), y: Double(y0), width: Double(x1 - x0), height: Double(y1 - y0)),
            step: step,
            values: values
        )
    }

    /// Samples a shared georeferenced output grid at pixel centres. Bilinear interpolation
    /// uses source pixel centres too; a missing contributing sample remains missing.
    package func resampledValues(georeference output: RasterGeoreference, width: Int, height: Int,
                                 band: Int = 0) -> [Float]? {
        guard isGeoreferenced, output.isGeoreferenced, width > 0, height > 0,
              width <= 4096, height <= 4096, band >= 0, band < bandCount else { return nil }
        return withLevel { file, level in
            guard let lease = try? TIFFChunkCache.shared.acquireReader(url: fileURL) else { return nil }
            let chunkWidth = max(1, level.chunkWidth), chunkHeight = max(1, level.chunkHeight)
            let across = max(1, level.chunksAcross)
            let plane = level.planarConfiguration == 2 ? band : 0
            let bandIndex = level.planarConfiguration == 2 ? 0 : band
            // A small local cache avoids taking the shared cache lock four times per pixel.
            // It is byte bounded even when an oblique output row crosses many source chunks.
            var chunks: [Int: [UInt8]] = [:]
            var lastChunk: (index: Int, bytes: [UInt8])?
            var cacheBytes = 0
            var failed: Set<Int> = []
            let localBudget = min(16 << 20, TileResourcePolicy.rasterChunkCacheBytes)
            func value(_ x: Int, _ y: Int) -> Float? {
                let index = (y / chunkHeight) * across + x / chunkWidth
                if failed.contains(index) { return nil }
                var bytes = lastChunk?.index == index ? lastChunk?.bytes : chunks[index]
                if bytes == nil {
                    bytes = try? TIFFRawChunks.bytes(file: file, level: level, reader: lease.reader,
                                                    chunkIndex: index, plane: plane)
                    guard let loaded = bytes else { failed.insert(index); return nil }
                    if loaded.count <= localBudget {
                        if cacheBytes + loaded.count > localBudget { chunks.removeAll(keepingCapacity: true); cacheBytes = 0 }
                        chunks[index] = loaded
                        cacheBytes += loaded.count
                    }
                }
                guard let bytes else { return nil }
                // Retain the current chunk even if it exceeds the small dictionary budget.
                // Otherwise an uncached wide strip could be decompressed for every sample.
                lastChunk = (index, bytes)
                return TIFFSampleAccess.value(bytes: bytes, level: level, x: x % chunkWidth, y: y % chunkHeight,
                                              band: bandIndex, order: file.byteOrder)
            }
            var values = [Float](repeating: .nan, count: width * height)
            for row in 0..<height {
                if Task.isCancelled { return nil }
                failed.removeAll(keepingCapacity: true)
                for column in 0..<width {
                    let source: CGPoint?
                    if output.crs == georeference.crs {
                        let point = output.crsPoint(column: Double(column) + 0.5, row: Double(row) + 0.5)
                        source = georeference.pixelPoint(x: point.x, y: point.y)
                    } else if let coordinate = output.coordinate(column: Double(column) + 0.5, row: Double(row) + 0.5) {
                        source = georeference.pixel(for: coordinate)
                    } else { source = nil }
                    guard let source, source.x.isFinite, source.y.isFinite,
                          source.x >= 0, source.y >= 0,
                          source.x < Double(level.width), source.y < Double(level.height) else { continue }
                    let x = min(max(source.x - 0.5, 0), Double(level.width - 1))
                    let y = min(max(source.y - 0.5, 0), Double(level.height - 1))
                    let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
                    let x1 = min(x0 + 1, level.width - 1), y1 = min(y0 + 1, level.height - 1)
                    let dx = x - Double(x0), dy = y - Double(y0)
                    let samples = [(x0, y0, (1 - dx) * (1 - dy)), (x1, y0, dx * (1 - dy)),
                                   (x0, y1, (1 - dx) * dy), (x1, y1, dx * dy)]
                    var total = 0.0
                    var valid = true
                    for (x, y, weight) in samples where weight > 1e-12 {
                        guard let sample = value(x, y), sample.isFinite else { valid = false; break }
                        total += Double(sample) * weight
                    }
                    if valid, total.isFinite { values[row * width + column] = Float(total) }
                }
            }
            return values
        }
    }

    /// 采样一条直线（剖面用）：从 `start` 到 `end` 均匀取 `count` 个点。
    public func profile(
        from start: CGPoint,
        to end: CGPoint,
        count: Int = 256,
        band: Int = 0
    ) -> [(fraction: Double, value: Float)] {
        profile(along: [start, end], count: count, band: band)
    }

    /// 采样一条折线（剖面用）：按各段长度分配采样点，首尾点必然落在折线两端。
    ///
    /// 沿着用户画出来的折线走（而不是「起点连终点」），测一条绕行的路线时才不会抄近道。
    public func profile(
        along polyline: [CGPoint],
        count: Int = 256,
        band: Int = 0
    ) -> [(fraction: Double, value: Float)] {
        let samples = max(2, min(4096, count))
        guard polyline.count >= 2 else { return [] }
        var cumulative: [Double] = [0]
        for index in 0..<(polyline.count - 1) {
            let dx = polyline[index + 1].x - polyline[index].x
            let dy = polyline[index + 1].y - polyline[index].y
            cumulative.append(cumulative[index] + (dx * dx + dy * dy).squareRoot())
        }
        let total = cumulative[cumulative.count - 1]
        guard total.isFinite, total > 0 else { return [] }
        return withLevel { file, level -> [(fraction: Double, value: Float)]? in
            guard let lease = try? TIFFChunkCache.shared.acquireReader(url: fileURL) else { return [] }
            let across = max(1, level.chunksAcross)
            let chunkWidth = max(1, level.chunkWidth)
            let chunkHeight = max(1, level.chunkHeight)
            let plane = level.planarConfiguration == 2 ? band : 0
            let bandIndex = level.planarConfiguration == 2 ? 0 : band
            var lastIndex = -1
            var lastBytes: [UInt8] = []
            var output: [(Double, Float)] = []
            output.reserveCapacity(samples)
            var segment = 0
            for index in 0..<samples {
                if Task.isCancelled { return nil }
                let t = Double(index) / Double(samples - 1)
                let target = t * total
                while segment < cumulative.count - 2, cumulative[segment + 1] < target {
                    segment += 1
                }
                let startDistance = cumulative[segment]
                let segmentLength = max(1e-12, cumulative[segment + 1] - startDistance)
                let local = min(max((target - startDistance) / segmentLength, 0), 1)
                let a = polyline[segment]
                let b = polyline[segment + 1]
                let x = a.x + (b.x - a.x) * local
                let y = a.y + (b.y - a.y) * local
                guard x.isFinite, y.isFinite, x >= 0, y >= 0,
                      x < Double(level.width), y < Double(level.height) else { continue }
                let xi = Int(x.rounded(.down))
                let yi = Int(y.rounded(.down))
                guard xi >= 0, yi >= 0, xi < level.width, yi < level.height else { continue }
                let chunkIndex = (yi / chunkHeight) * across + (xi / chunkWidth)
                if chunkIndex != lastIndex {
                    lastIndex = chunkIndex
                    lastBytes = (try? TIFFRawChunks.bytes(
                        file: file,
                        level: level,
                        reader: lease.reader,
                        chunkIndex: chunkIndex,
                        plane: plane
                    )) ?? []
                }
                guard let value = TIFFSampleAccess.value(
                    bytes: lastBytes,
                    level: level,
                    x: xi % chunkWidth,
                    y: yi % chunkHeight,
                    band: bandIndex,
                    order: file.byteOrder
                ) else { continue }
                output.append((t, value))
            }
            return output
        } ?? []
    }

    /// 合到主图这一级上做一次（所有取值路径共用）。
    private func withLevel<T>(_ body: (TIFFFile, TIFFImageFileDirectory) -> T?) -> T? {
        guard let file = TIFFFileCache.shared.file(for: fileURL) else { return nil }
        return body(file, file.main)
    }

    /// 取某个像素所在的块字节，返回（字节、块内 x、块内 y）。
    private func chunkBytes(
        file: TIFFFile,
        level: TIFFImageFileDirectory,
        x: Int,
        y: Int,
        band: Int
    ) throws -> ([UInt8], Int, Int) {
        let across = max(1, level.chunksAcross)
        let chunkWidth = max(1, level.chunkWidth)
        let chunkHeight = max(1, level.chunkHeight)
        let index = (y / chunkHeight) * across + (x / chunkWidth)
        let plane = level.planarConfiguration == 2 ? band : 0
        let lease = try TIFFChunkCache.shared.acquireReader(url: fileURL)
        let bytes = try TIFFRawChunks.bytes(
            file: file,
            level: level,
            reader: lease.reader,
            chunkIndex: index,
            plane: plane
        )
        return (bytes, x % chunkWidth, y % chunkHeight)
    }
}
