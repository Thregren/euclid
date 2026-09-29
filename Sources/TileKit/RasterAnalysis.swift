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
        /// 相邻采样点的地面距离（米）。
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
        /// 每个采样格的地面面积（平方米）。
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

        let ground = reader.groundPixelSize() ?? 1
        let spacing = max(1e-6, ground * Double(grid.step))
        var values = [Float](repeating: .nan, count: grid.width * grid.height)
        for row in 0..<grid.height {
            for column in 0..<grid.width {
                guard let dzdx = derivativeX(grid, column: column, row: row, spacing: spacing),
                      let dzdy = derivativeY(grid, column: column, row: row, spacing: spacing) else {
                    continue
                }
                let radians = atan((dzdx * dzdx + dzdy * dzdy).squareRoot())
                values[row * grid.width + column] = Float(radians * 180 / .pi)
            }
        }
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

    /// 中心差分；边界或邻点缺失时退回单边差分，两边都缺就返回 nil。
    private static func derivativeX(
        _ grid: RasterSampleGrid,
        column: Int,
        row: Int,
        spacing: Double
    ) -> Double? {
        let center = grid[column, row]
        guard center.isFinite else { return nil }
        let before = grid[column - 1, row]
        let after = grid[column + 1, row]
        if before.isFinite, after.isFinite {
            return Double(after - before) / (2 * spacing)
        }
        if after.isFinite { return Double(after - center) / spacing }
        if before.isFinite { return Double(center - before) / spacing }
        return nil
    }

    private static func derivativeY(
        _ grid: RasterSampleGrid,
        column: Int,
        row: Int,
        spacing: Double
    ) -> Double? {
        let center = grid[column, row]
        guard center.isFinite else { return nil }
        let before = grid[column, row - 1]
        let after = grid[column, row + 1]
        if before.isFinite, after.isFinite {
            return Double(after - before) / (2 * spacing)
        }
        if after.isFinite { return Double(after - center) / spacing }
        if before.isFinite { return Double(center - before) / spacing }
        return nil
    }

    /// 把坡度网格着色成一张图（绿→黄→红，半透明叠加）。
    ///
    /// - Parameter maximum: 色标上限（度）；`nil` 时用数据自身最大值，全平则为 1。
    public static func image(of grid: SlopeGrid, maximum: Double? = nil) -> CGImage? {
        let stats = statistics(of: grid.values)
        let top = max(1e-3, maximum ?? (stats.isEmpty ? 1 : stats.maximum))
        var canvas = [UInt8](repeating: 0, count: grid.width * grid.height * 4)
        for index in 0..<grid.values.count {
            let value = grid.values[index]
            guard value.isFinite else { continue }
            let t = min(max(Double(value) / top, 0), 1)
            let color = terrainColor(t)
            // 坡度越陡越不透明，平地几乎透出底图。
            let alpha = UInt8(min(235, 60 + t * 175))
            write(&canvas, at: index, color, alpha: alpha)
        }
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
        guard polygon.count >= 3, baseElevation.isFinite else { return nil }
        let full = CGRect(x: 0, y: 0, width: Double(reader.pixelWidth), height: Double(reader.pixelHeight))
        var bounds = CGRect(origin: polygon[0], size: .zero)
        for point in polygon.dropFirst() {
            bounds = bounds.union(CGRect(origin: point, size: .zero))
        }
        let area = bounds.intersection(full)
        guard !area.isNull, area.width >= 1, area.height >= 1 else { return nil }
        guard let grid = reader.grid(rect: area, band: band, maxDimension: maxDimension) else { return nil }

        let ground = reader.groundPixelSize() ?? 1
        let cellArea = pow(max(1e-6, ground * Double(grid.step)), 2)
        var cut = 0.0
        var fill = 0.0
        var cells = 0
        var lowest = Double.greatestFiniteMagnitude
        var highest = -Double.greatestFiniteMagnitude
        var sum = 0.0
        var count = 0
        for row in 0..<grid.height {
            for column in 0..<grid.width {
                let value = grid[column, row]
                guard value.isFinite else { continue }
                guard contains(polygon, point: grid.pixelPoint(column: column, row: row)) else { continue }
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
        guard cells > 0 else { return nil }
        return VolumeResult(
            baseElevation: baseElevation,
            cellArea: cellArea,
            sampledCells: cells,
            sampledArea: Double(cells) * cellArea,
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
        var lowest = Double.greatestFiniteMagnitude
        var highest = -Double.greatestFiniteMagnitude
        var sum = 0.0
        var count = 0
        for value in values where value.isFinite {
            let number = Double(value)
            lowest = min(lowest, number)
            highest = max(highest, number)
            sum += number
            count += 1
        }
        guard count > 0 else {
            return Statistics(validCount: 0, minimum: .nan, maximum: .nan, mean: .nan)
        }
        return Statistics(
            validCount: count,
            minimum: lowest,
            maximum: highest,
            mean: sum / Double(count)
        )
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
/// 各自按同一输出尺寸抽稀采样，逐点相减 —— 第一份减第二份。
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

        guard let gridA = first.grid(rect: rectA, band: band, maxDimension: maxDimension),
              let gridB = second.grid(rect: rectB, band: band, maxDimension: maxDimension),
              gridA.width >= 1, gridA.height >= 1, gridB.width >= 1, gridB.height >= 1 else { return nil }

        let width = min(gridA.width, gridB.width)
        let height = min(gridA.height, gridB.height)
        guard width >= 1, height >= 1 else { return nil }

        var differences = [Float](repeating: .nan, count: width * height)
        var sum = 0.0
        var count = 0
        var lowest = Double.greatestFiniteMagnitude
        var highest = -Double.greatestFiniteMagnitude
        var absoluteMax = 0.0
        for row in 0..<height {
            let rowA = row * gridA.height / height
            let rowB = row * gridB.height / height
            for column in 0..<width {
                let columnA = column * gridA.width / width
                let columnB = column * gridB.width / width
                let a = gridA[columnA, rowA]
                let b = gridB[columnB, rowB]
                guard a.isFinite, b.isFinite else { continue }
                let difference = a - b
                differences[row * width + column] = difference
                let number = Double(difference)
                sum += number
                count += 1
                lowest = min(lowest, number)
                highest = max(highest, number)
                absoluteMax = max(absoluteMax, abs(number))
            }
        }
        guard count > 0 else { return nil }

        var canvas = [UInt8](repeating: 0, count: width * height * 4)
        let scale = absoluteMax > 0 ? absoluteMax : 1
        for index in 0..<differences.count {
            let value = differences[index]
            guard value.isFinite else { continue }
            let t = min(max(Double(value) / scale, -1), 1)
            let magnitude = abs(t)
            let color = t >= 0
                ? (230.0, 74.0, 54.0)      // 变高 / 变大
                : (46.0, 116.0, 230.0)     // 变低 / 变小
            let alpha = UInt8(min(235, 40 + magnitude * 195))
            DEMAnalysis.write(&canvas, at: index, color, alpha: alpha)
        }
        guard let image = RasterTileSource.makeImage(canvas: canvas, width: width, height: height) else {
            return nil
        }
        let georeference = DEMAnalysis.subGeoreference(
            first.georeference,
            originColumn: rectA.minX,
            originRow: rectA.minY,
            step: rectA.width / Double(width)
        )
        return Result(
            image: image,
            georeference: georeference,
            width: width,
            height: height,
            worldRect: common,
            comparedSamples: count,
            meanDifference: sum / Double(count),
            maximumDifference: highest,
            minimumDifference: lowest,
            absoluteMaximum: absoluteMax
        )
    }
}
