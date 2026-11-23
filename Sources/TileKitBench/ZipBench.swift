import Foundation
import TileKit

private func milliseconds(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

private func logZip(_ message: String) {
    FileHandle.standardOutput.write(Data(("[zip-bench] " + message + "\n").utf8))
}

/// 只读真实 ZIP：索引构建、重开、跨行查找与经共享池并发解码。
func runZipBenchmark(url: URL) async {
    do {
        var start = DispatchTime.now().uptimeNanoseconds
        let archive = try ZipArchive(url: url)
        logZip(String(format: "open_ms=%.3f entries=%d directory_bytes=%llu rows=%d",
                      milliseconds(since: start), archive.entryCount,
                      archive.centralDirectorySize, archive.indexedRows.count))
        start = DispatchTime.now().uptimeNanoseconds
        let reopened = try ZipArchive(url: url)
        logZip(String(format: "reopen_ms=%.3f entries=%d", milliseconds(since: start), reopened.entryCount))
        let allRows = archive.indexedRows
        let count = min(32, allRows.count)
        let rows = count <= 1 ? allRows : (0..<count).map {
            allRows[Int((Double($0) * Double(allRows.count - 1) / Double(count - 1)).rounded())]
        }
        var names: [String] = []
        var rowTimes: [Double] = []
        for row in rows {
            start = DispatchTime.now().uptimeNanoseconds
            let entries = archive.entryNames(inRow: String(row))
            rowTimes.append(milliseconds(since: start))
            let middle = entries.count / 2
            names.append(contentsOf: entries.dropFirst(middle).prefix(4))
        }
        rowTimes.sort()
        guard !rowTimes.isEmpty, !names.isEmpty else { throw ZipArchive.ZipError.corrupt("没有可采样瓦片") }
        logZip(String(format: "row_lookup_p50_ms=%.3f p95_ms=%.3f samples=%d",
                      rowTimes[rowTimes.count / 2], rowTimes[Int(Double(rowTimes.count - 1) * 0.95)], names.count))
        await ZipArchivePool.shared.adopt(archive)
        start = DispatchTime.now().uptimeNanoseconds
        let results = await withTaskGroup(of: (Int, Bool).self) { group in
            for name in names {
                group.addTask {
                    guard let data = await ZipArchivePool.shared.rawData(name, in: url) else { return (0, false) }
                    return (data.count, ImageDecoder.decode(data) != nil)
                }
            }
            var bytes = 0, decoded = 0
            for await result in group { bytes += result.0; if result.1 { decoded += 1 } }
            return (bytes, decoded)
        }
        logZip(String(format: "batch_ms=%.3f decoded=%d/%d bytes=%d",
                      milliseconds(since: start), results.1, names.count, results.0))
        precondition(results.1 == names.count, "抽样瓦片读取/解码失败")
    } catch {
        logZip("failed=\(error)")
        exit(1)
    }
}
