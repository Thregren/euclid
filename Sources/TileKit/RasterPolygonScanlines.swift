import CoreGraphics

/// 与 DEMAnalysis.contains 相同的奇偶填充规则，按扫描行批量确定有效列。
/// 每行只遍历一次多边形边；随后在连续列区间内做数值计算。
package enum RasterPolygonScanlines {
    package static func spans(polygon: [CGPoint], grid: RasterSampleGrid, row: Int) -> [Range<Int>] {
        guard polygon.count >= 3, grid.width > 0 else { return [] }
        let y = grid.pixelPoint(column: 0, row: row).y
        var crossings: [Double] = []
        crossings.reserveCapacity(polygon.count)
        var previous = polygon[polygon.count - 1]
        for point in polygon {
            if (point.y > y) != (previous.y > y) {
                let t = (y - point.y) / (previous.y - point.y)
                let x = point.x + t * (previous.x - point.x)
                if x.isFinite { crossings.append(x) }
            }
            previous = point
        }
        crossings.sort()
        func firstColumn(atOrAfter x: Double) -> Int {
            var lower = 0
            var upper = grid.width
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if grid.pixelPoint(column: middle, row: row).x < x { lower = middle + 1 }
                else { upper = middle }
            }
            return lower
        }
        var spans: [Range<Int>] = []
        var index = 0
        while index + 1 < crossings.count {
            let lower = firstColumn(atOrAfter: crossings[index])
            let upper = firstColumn(atOrAfter: crossings[index + 1])
            if lower < upper { spans.append(lower..<upper) }
            index += 2
        }
        return spans
    }
}
