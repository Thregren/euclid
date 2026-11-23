import Foundation
import TileKit

func runMetalBenchmark() {
    guard RasterCompute.metalAvailable else { print("Metal unavailable; CPU fallback active"); return }
    for width in [512, 1024, 2048] {
        let count = width * width
        let values = (0..<count).map { index -> Float in index % 997 == 0 ? .nan : Float(sin(Double(index) / 120) * 80) }
        let other = values.map { $0 - 0.25 }
        let cpuSlope = medianMilliseconds { Double(RasterCompute.slope(values: values, width: width, height: width, spacing: 0.5, backend: .cpu)![count / 2]) }
        let metalSlope = medianMilliseconds { Double(RasterCompute.slope(values: values, width: width, height: width, spacing: 0.5, backend: .metal)![count / 2]) }
        let cpuColor = medianMilliseconds { Double(RasterCompute.color(values: values, scale: 100, difference: false, backend: .cpu)![count / 2]) }
        let metalColor = medianMilliseconds { Double(RasterCompute.color(values: values, scale: 100, difference: false, backend: .metal)![count / 2]) }
        let cpuDifference = medianMilliseconds { Double(RasterCompute.differences(first: values, firstWidth: width, firstHeight: width, second: other, secondWidth: width, secondHeight: width, width: width, height: width, backend: .cpu)![count / 2]) }
        let metalDifference = medianMilliseconds { Double(RasterCompute.differences(first: values, firstWidth: width, firstHeight: width, second: other, secondWidth: width, secondHeight: width, width: width, height: width, backend: .metal)![count / 2]) }
        print(String(format: "[metal-bench] %d² slope_cpu_ms=%.3f slope_gpu_ms=%.3f color_cpu_ms=%.3f color_gpu_ms=%.3f difference_cpu_ms=%.3f difference_gpu_ms=%.3f", width, cpuSlope.time, metalSlope.time, cpuColor.time, metalColor.time, cpuDifference.time, metalDifference.time))
    }
    print("[metal-bench] warm pipelines; includes buffer preparation, submit, completion and readback; numerical tolerance is checked separately")
}

func runArchiveStackBenchmark(urls: [URL]) async throws {
    var samples: [(URL, String)] = []
    for url in urls {
        let archive = try ZipArchive(url: url)
        guard let row = archive.indexedRows.dropFirst(archive.indexedRows.count / 2).first else { continue }
        let names = archive.entryNames(inRow: String(row))
        if let name = names.dropFirst(names.count / 2).first { samples.append((url, name)) }
    }
    for limit in [4, 16] {
        let pool = ZipArchivePool(maximumArchives: limit)
        let start = DispatchTime.now().uptimeNanoseconds
        var decoded = 0
        for _ in 0..<3 {
            for (url, name) in samples {
                if let data = await pool.rawData(name, in: url), ImageDecoder.decode(data) != nil { decoded += 1 }
            }
        }
        let stats = await pool.statistics
        let time = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print(String(format: "[stack-bench] capacity=%d sources=%d cycles=3 batch_ms=%.3f opens=%d row_bytes=%d decoded=%d", limit, samples.count, time, stats.opens, stats.rowBytes, decoded))
        precondition(decoded == samples.count * 3)
    }
    print("[stack-bench] same reader and warm filesystem/index cache; compares archive-pool capacity, not physical cold I/O")
}
