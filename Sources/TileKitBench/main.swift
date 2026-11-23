import CoreGraphics
import Foundation
import TileKit

if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--zip" {
    await runZipBenchmark(url: URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(0)
}

if CommandLine.arguments.contains("--metal") {
    runMetalBenchmark()
    exit(0)
}
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--zip-stack" {
    do { try await runArchiveStackBenchmark(urls: CommandLine.arguments.dropFirst(2).map { URL(fileURLWithPath: $0) }) }
    catch { print("[stack-bench] failed=\(error)"); exit(1) }
    exit(0)
}

/// Release 基准只测算法，避免把磁盘缓存、窗口尺寸或网络波动混进结果。
func medianMilliseconds(_ operation: () -> Double) -> (time: Double, checksum: Double) {
    _ = operation()
    var times: [Double] = []
    var checksum = 0.0
    for _ in 0..<7 {
        let start = DispatchTime.now().uptimeNanoseconds
        checksum += operation()
        times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
    return (times.sorted()[times.count / 2], checksum)
}

func report(_ name: String, before: (time: Double, checksum: Double), after: (time: Double, checksum: Double)) {
    precondition(abs(before.checksum - after.checksum) <= max(1e-8, abs(before.checksum) * 1e-10))
    print(String(format: "%@: %.3f ms → %.3f ms（%.2f×），结果一致", name, before.time, after.time,
                 before.time / max(after.time, 0.000001)))
}

let values = (0..<1_048_576).map { index -> Float in
    index % 997 == 0 ? .nan : Float(index % 10007) * 0.125 - 300
}
report("百万样本统计", before: medianMilliseconds { RasterStatistics.scalar(values).mean },
       after: medianMilliseconds { DEMAnalysis.statistics(of: values).mean })

let grid = RasterSampleGrid(width: 512, height: 512, rect: CGRect(x: 0, y: 0, width: 512, height: 512),
                            step: 1, values: [])
let polygon = (0..<256).map { index -> CGPoint in
    let angle = Double(index) * 2 * .pi / 256
    let radius = index % 2 == 0 ? 240.0 : 180.0
    return CGPoint(x: 256 + cos(angle) * radius, y: 256 + sin(angle) * radius)
}
report("512² 网格 / 256 边多边形", before: medianMilliseconds {
    var count = 0
    for row in 0..<grid.height {
        for column in 0..<grid.width {
            if DEMAnalysis.contains(polygon, point: grid.pixelPoint(column: column, row: row)) { count += 1 }
        }
    }
    return Double(count)
}, after: medianMilliseconds {
    var count = 0
    for row in 0..<grid.height {
        for span in RasterPolygonScanlines.spans(polygon: polygon, grid: grid, row: row) { count += span.count }
    }
    return Double(count)
})
