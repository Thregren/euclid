import CoreGraphics
import Foundation

/// 单幅栅格的数值分析：坡度、土方量、两期差异。
///
/// 与「显示」这条路分开：这里只回答「数值是多少」，产出的 `CGImage` 也只是给人看的着色结果。
/// 取值全部走 `RasterSampleReader`（与铺图共用同一份解压 / 预测还原实现），
/// 因此图上看到的和算出来的不会对不上。
///
/// 这些类型都是值类型、没有共享可变状态，可以整段丢到后台线程跑（`@unchecked Sendable`
/// 只用在真正含不可变 CoreGraphics 对象的结果上）。重活（采样 + 出图）都由调用方放后台。
public enum DEMAnalysis {
    /// 坡度栅格（单位：度）。
    public struct SlopeGrid: Sendable {
        public let width: Int
        public let height: Int
        /// 采样覆盖的源像素矩形。
        public let rect: CGRect
        /// 采样步长（源像素）。
        public let step: Int
        /// 中央采样点的横向地面距离（米）；计算使用各位置的完整横纵地面向量。
        public let spacingMeters: Double
        /// 每点的坡度（度）；取不到的地方是 NaN。
        public let values: [Float]
        /// 与这份坡度图对应的地理参考（一个像素 = `step` 个源像素）。
        public let georeference: RasterGeoreference
    }

    /// 一组数值的统计（忽略 NaN）。
    public struct Statistics: Sendable {
        public let validCount: Int
        public let minimum: Double
        public let maximum: Double
        public let mean: Double

        public var isEmpty: Bool { validCount == 0 }
    }

    /// 土方量结果。
    public struct VolumeResult: Sendable {
        public let baseElevation: Double
        /// 有效采样格的平均地面面积（平方米）；积分使用每格的局部面积。
        public let cellArea: Double
        /// 参与计算的采样格数。
        public let sampledCells: Int
        /// 采样覆盖的平面面积（平方米）。
        public let sampledArea: Double
        /// 挖方：高于基准的部分需要削掉，取正。
        public let cutVolume: Double
        /// 填方：低于基准的部分需要补上，取正。
        public let fillVolume: Double
        public let elevation: Statistics

        /// 净方量（填方 − 挖方）：正数表示净填，负数表示净挖。
        public var netVolume: Double { fillVolume - cutVolume }
        public var totalVolume: Double { fillVolume + cutVolume }
    }

    // MARK: - 坡度

    /// 算一片坡度。
    ///
    /// - Parameters:
    ///   - rect: 源像素矩形（`nil` = 整幅）。
    ///   - maxDimension: 输出网格最长边上限，超了按整数步长抽稀。
    public static func slope(
        reader: RasterSampleReader,
        rect: CGRect? = nil,
        maxDimension: Int = 1024,
        band: Int = 0
    ) -> SlopeGrid? {
        let full = CGRect(x: 0, y: 0, width: Double(reader.pixelWidth), height: Double(reader.pixelHeight))
        let area = (rect ?? full).intersection(full)
        guard !area.isNull, area.width >= 2, area.height >= 2 else { return nil }
        guard let grid = reader.grid(rect: area, band: band, maxDimension: maxDimension),
              grid.width >= 2, grid.height >= 2 else { return nil }

        let geometry = RasterGroundGeometry(reference: reader.georeference)
        guard let centerMetric = geometry.metric(column: grid.rect.midX, row: grid.rect.midY) else { return nil }
        let spacing = centerMetric.columnLength * Double(grid.step)
        func metric(_ column: Int, _ row: Int) -> RasterGroundMetric? {
            let point = grid.pixelPoint(column: column, row: row)
            return geometry.metric(column: point.x, row: point.y)?.scaled(by: Double(grid.step))
        }
        let values: [Float]?
        if geometry.constantAlongRows {
            var metrics: [RasterGroundMetric] = []
            metrics.reserveCapacity(grid.height)
            for row in 0..<grid.height {
                guard !Task.isCancelled, let value = metric(0, row) else { return nil }
                metrics.append(value)
            }
            values = RasterCompute.slope(values: grid.values, width: grid.width, height: grid.height, rowMetrics: metrics)
        } else {
            values = RasterCompute.slope(values: grid.values, width: grid.width, height: grid.height, metric: metric)
        }
        guard let values else { return nil }
        return SlopeGrid(
            width: grid.width,
            height: grid.height,
            rect: grid.rect,
            step: grid.step,
            spacingMeters: spacing,
            values: values,
            georeference: subGeoreference(
                reader.georeference,
                originColumn: grid.rect.minX,
                originRow: grid.rect.minY,
                step: Double(grid.step)
            )
        )
    }

    /// 把坡度网格着色成一张图（绿→黄→红，半透明叠加）。
    ///
    /// - Parameter maximum: 色标上限（度）；`nil` 时用数据自身最大值，全平则为 1。
    public static func image(of grid: SlopeGrid, maximum: Double? = nil) -> CGImage? {
        let stats = statistics(of: grid.values)
        let top = max(1e-3, maximum ?? (stats.isEmpty ? 1 : stats.maximum))
        guard let canvas = RasterCompute.color(values: grid.values, scale: top, difference: false) else { return nil }
        return RasterTileSource.makeImage(canvas: canvas, width: grid.width, height: grid.height)
    }

    /// 一片坡度图的统计。
    public static func statistics(of grid: SlopeGrid) -> Statistics {
        statistics(of: grid.values)
    }

    // MARK: - 土方量

    /// 以一条多边形（源像素坐标）为范围、以给定基准高程算挖填方量。
    ///
    /// 高程低于基准的需要**填**，高于基准的需要**挖**；两者都取正数。
    public static func volume(
        reader: RasterSampleReader,
        polygon: [CGPoint],
        baseElevation: Double,
        maxDimension: Int = 2048,
        band: Int = 0
    ) -> VolumeResult? {
        guard polygon.count >= 3, baseElevation.isFinite,
              polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let full = CGRect(x: 0, y: 0, width: Double(reader.pixelWidth), height: Double(reader.pixelHeight))
        var bounds = CGRect(origin: polygon[0], size: .zero)
        for point in polygon.dropFirst() {
            bounds = bounds.union(CGRect(origin: point, size: .zero))
        }
        let area = bounds.intersection(full)
        guard !area.isNull, area.width >= 1, area.height >= 1 else { return nil }
        guard let grid = reader.grid(rect: area, band: band, maxDimension: maxDimension) else { return nil }

        let geometry = RasterGroundGeometry(reference: reader.georeference)
        guard geometry.metric(column: grid.rect.midX, row: grid.rect.midY) != nil else { return nil }
        var sampledArea = 0.0
        var cut = 0.0
        var fill = 0.0
        var cells = 0
        var lowest = Double.greatestFiniteMagnitude
        var highest = -Double.greatestFiniteMagnitude
        var sum = 0.0
        var count = 0
        for row in 0..<grid.height {
            if Task.isCancelled { return nil }
            let rowPoint = grid.pixelPoint(column: 0, row: row)
            let rowMetric = geometry.constantAlongRows ? geometry.metric(column: rowPoint.x, row: rowPoint.y) : nil
            for span in RasterPolygonScanlines.spans(polygon: polygon, grid: grid, row: row) {
                for column in span {
                    let value = grid[column, row]
                    guard value.isFinite else { continue }
                    let point = grid.pixelPoint(column: column, row: row)
                    guard let metric = rowMetric ?? geometry.metric(column: point.x, row: point.y) else { return nil }
                    // The last downsampled cell may cover fewer than step × step source pixels.
                    let cellWidth = min(Double(grid.step), grid.rect.maxX - (grid.rect.minX + Double(column * grid.step)))
                    let cellHeight = min(Double(grid.step), grid.rect.maxY - (grid.rect.minY + Double(row * grid.step)))
                    let cellArea = metric.area * cellWidth * cellHeight
                    guard cellArea.isFinite, cellArea > 0 else { return nil }
                    sampledArea += cellArea
                    let height = Double(value)
                    cells += 1
                    sum += height
                    count += 1
                    lowest = min(lowest, height)
                    highest = max(highest, height)
                    let delta = height - baseElevation
                    if delta >= 0 { cut += delta * cellArea } else { fill += -delta * cellArea }
                }
            }
        }
        guard cells > 0 else { return nil }
        return VolumeResult(
            baseElevation: baseElevation,
            cellArea: sampledArea / Double(cells),
            sampledCells: cells,
            sampledArea: sampledArea,
            cutVolume: cut,
            fillVolume: fill,
            elevation: Statistics(
                validCount: count,
                minimum: lowest,
                maximum: highest,
                mean: count > 0 ? sum / Double(count) : .nan
            )
        )
    }

    /// 射线法判定点在多边形内（含边界近似处理）。
    public static func contains(_ polygon: [CGPoint], point: CGPoint) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[j]
            if (a.y > point.y) != (b.y > point.y) {
                let t = (point.y - a.y) / (b.y - a.y)
                if point.x < a.x + t * (b.x - a.x) { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    // MARK: - 公共

    /// 一组数值的统计（忽略 NaN / 无穷）。
    public static func statistics(of values: [Float]) -> Statistics {
        RasterStatistics.compute(values)
    }

    /// 源像素矩形 → 与「抽稀后的一格」对应的地理参考。
    static func subGeoreference(
        _ base: RasterGeoreference,
        originColumn: Double,
        originRow: Double,
        step: Double
    ) -> RasterGeoreference {
        let origin = base.crsPoint(column: originColumn, row: originRow)
        let factor = max(1e-9, step)
        return RasterGeoreference(
            placement: base.placement,
            crs: base.crs,
            originX: origin.x,
            originY: origin.y,
            pixelSizeX: base.pixelSizeX * factor,
            pixelSizeY: base.pixelSizeY * factor,
            rotationX: base.rotationX * factor,
            rotationY: base.rotationY * factor
        )
    }

    /// 绿 → 黄 → 红 的地形色带。
    static func terrainColor(_ t: Double) -> (Double, Double, Double) {
        let stops: [(Double, Double, Double)] = [
            (56, 142, 60),
            (255, 213, 79),
            (211, 47, 47),
        ]
        let clamped = min(max(t, 0), 1)
        let scaled = clamped * Double(stops.count - 1)
        let index = min(Int(scaled), stops.count - 2)
        let local = scaled - Double(index)
        let a = stops[index]
        let b = stops[index + 1]
        return (
            a.0 + (b.0 - a.0) * local,
            a.1 + (b.1 - a.1) * local,
            a.2 + (b.2 - a.2) * local
        )
    }

    /// 往 RGBA8（预乘）缓冲区写一个像素。
    static func write(
        _ canvas: inout [UInt8],
        at index: Int,
        _ color: (Double, Double, Double),
        alpha: UInt8
    ) {
        let offset = index * 4
        guard offset >= 0, offset + 3 < canvas.count else { return }
        let a = Double(alpha) / 255
        canvas[offset] = UInt8((min(max(color.0, 0), 255) * a).rounded())
        canvas[offset + 1] = UInt8((min(max(color.1, 0), 255) * a).rounded())
        canvas[offset + 2] = UInt8((min(max(color.2, 0), 255) * a).rounded())
        canvas[offset + 3] = alpha
    }
}

/// 两期影像的差异。
///
/// 做法：先求两份影像的世界范围交集（只能比共同覆盖的那一块），
/// 在同一地理网格的像素中心分别反投影采样，逐点相减 —— 第一份减第二份。
/// 蓝色表示变低 / 变小，红色表示变高 / 变大，越接近 0 越透明。
public enum RasterDifference {
    public struct Result: @unchecked Sendable {
        public let image: CGImage
        public let georeference: RasterGeoreference
        public let width: Int
        public let height: Int
        public let worldRect: CGRect
        public let comparedSamples: Int
        public let meanDifference: Double
        public let maximumDifference: Double
        public let minimumDifference: Double
        public let absoluteMaximum: Double
    }

    /// 计算差异图；两份影像没有共同覆盖、或认不出地理参考时返回 nil。
    public static func compute(
        first: RasterSampleReader,
        second: RasterSampleReader,
        maxDimension: Int = 1024,
        band: Int = 0
    ) -> Result? {
        guard first.isGeoreferenced, second.isGeoreferenced else { return nil }
        // Identical source grids already share a geographic coordinate system. Preserve
        // their native cells instead of introducing interpolation or bounding-box corners.
        if first.georeference == second.georeference {
            let commonPixels = CGRect(x: 0, y: 0, width: min(first.pixelWidth, second.pixelWidth),
                                      height: min(first.pixelHeight, second.pixelHeight))
            guard let a = first.grid(rect: commonPixels, band: band, maxDimension: maxDimension),
                  let b = second.grid(rect: commonPixels, band: band, maxDimension: maxDimension),
                  a.width == b.width, a.height == b.height else { return nil }
            let output = DEMAnalysis.subGeoreference(first.georeference, originColumn: 0, originRow: 0,
                                                    step: Double(a.step))
            return result(first: a.values, second: b.values, width: a.width, height: a.height,
                          georeference: output,
                          worldRect: first.georeference.worldRect(pixelWidth: Int(commonPixels.width),
                                                                   pixelHeight: Int(commonPixels.height)))
        }
        let worldA = first.georeference.worldRect(pixelWidth: first.pixelWidth, pixelHeight: first.pixelHeight)
        let worldB = second.georeference.worldRect(pixelWidth: second.pixelWidth, pixelHeight: second.pixelHeight)
        let common = worldA.intersection(worldB)
        guard !common.isNull, common.width > 1e-9, common.height > 1e-9 else { return nil }

        guard let rectARaw = RasterTileSource.pixelRect(ofTileWorld: common, georeference: first.georeference),
              let rectBRaw = RasterTileSource.pixelRect(ofTileWorld: common, georeference: second.georeference) else {
            return nil
        }
        let boundsA = CGRect(x: 0, y: 0, width: Double(first.pixelWidth), height: Double(first.pixelHeight))
        let boundsB = CGRect(x: 0, y: 0, width: Double(second.pixelWidth), height: Double(second.pixelHeight))
        let rectA = rectARaw.intersection(boundsA)
        let rectB = rectBRaw.intersection(boundsB)
        guard !rectA.isNull, !rectB.isNull, rectA.width >= 1, rectA.height >= 1,
              rectB.width >= 1, rectB.height >= 1 else { return nil }

        let limit = Double(max(2, min(4096, maxDimension)))
        // Select a bounded output grid, no finer than the coarser source bounding rectangle.
        let rawWidth = min(rectA.width, rectB.width)
        let rawHeight = min(rectA.height, rectB.height)
        let reduction = max(1, max(rawWidth, rawHeight) / limit)
        let width = max(1, Int(ceil(rawWidth / reduction)))
        let height = max(1, Int(ceil(rawHeight / reduction)))
        let circumference = 2 * Double.pi * Projection.wgs84SemiMajorAxis
        let georeference = RasterGeoreference(
            placement: .georeferenced, crs: .webMercator,
            originX: (common.minX - 0.5) * circumference,
            originY: (0.5 - common.minY) * circumference,
            pixelSizeX: common.width * circumference / Double(width),
            pixelSizeY: -common.height * circumference / Double(height))
        guard let samplesA = first.resampledValues(georeference: georeference, width: width, height: height, band: band),
              let samplesB = second.resampledValues(georeference: georeference, width: width, height: height, band: band) else { return nil }
        return result(first: samplesA, second: samplesB, width: width, height: height,
                      georeference: georeference, worldRect: common)
    }

    private static func result(first: [Float], second: [Float], width: Int, height: Int,
                               georeference: RasterGeoreference, worldRect: CGRect) -> Result? {
        guard let differences = RasterCompute.differences(first: first, firstWidth: width, firstHeight: height,
                                                          second: second, secondWidth: width, secondHeight: height,
                                                          width: width, height: height) else { return nil }
        let statistics = RasterStatistics.compute(differences)
        let count = statistics.validCount
        guard count > 0 else { return nil }
        let lowest = statistics.minimum, highest = statistics.maximum
        let absoluteMax = max(abs(lowest), abs(highest))
        guard let canvas = RasterCompute.color(values: differences, scale: absoluteMax > 0 ? absoluteMax : 1, difference: true) else { return nil }
        guard let image = RasterTileSource.makeImage(canvas: canvas, width: width, height: height) else {
            return nil
        }
        return Result(
            image: image,
            georeference: georeference,
            width: width,
            height: height,
            worldRect: worldRect,
            comparedSamples: count,
            meanDifference: statistics.mean,
            maximumDifference: highest,
            minimumDifference: lowest,
            absoluteMaximum: absoluteMax
        )
    }
}
