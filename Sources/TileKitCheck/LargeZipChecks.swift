import Foundation
import TileKit

@MainActor
func runLargeZipChecks() async {
    section("大 ZIP：跨缓冲索引、同行合并与并行读取")
    let root = FileManager.default.temporaryDirectory.appending(path: "euclid-large-zip-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suffix = String(repeating: "x", count: 110)
        let payload = Data([1, 3, 5, 7, 9])
        var entries: [(name: String, data: Data)] = (0..<18_000).map {
            ("700/\($0)-\(suffix).jpg", payload)
        }
        entries.append(("701/1.png", payload))
        entries.append(("700/last.jpg", payload)) // 同一行在中央目录中不连续
        entries.append(("plain.txt", payload))
        entries.append(("目录/1.png", payload))
        let url = root.appending(path: "large.zip")
        let bytes = try ZIP.stored(entries, compress: false)
        try bytes.write(to: url)
        let archive = try ZipArchive(url: url)
        expect(archive.centralDirectorySize > 2 << 20 && archive.entryCount == entries.count,
               "超过扫描缓冲的中央目录应完整建立索引")
        expect(archive.indexedRows == [700, 701], "数字行索引不混入普通文件和非数字目录")
        expect(archive.entry(named: "plain.txt") != nil && archive.entry(named: "目录/1.png") != nil,
               "无斜杠与 UTF-8 路径仍可查询")
        let targets = (0..<24).map { entries[$0 * 701].name }
        let matched = await withTaskGroup(of: Bool.self) { group in
            for name in targets {
                group.addTask {
                    guard let entry = archive.entry(named: name) else { return false }
                    return (try? archive.data(for: entry)) == payload
                }
            }
            var matched = true
            for await result in group { matched = matched && result }
            return matched
        }
        expect(matched, "24 个同行并发读取应逐字节一致")
        // 普通文件所在的空前缀跨度只含该文件；非数字目录也独立解析。
        expect(archive.parsedRowCount == 3, "同一行并发 miss 只解析一次（含前面两张独立行表）")
        expect(archive.entryNames(inRow: "700").count == 18_001,
               "非连续出现的同一行不能遗漏后面的记录")
        let reopened = try ZipArchive(url: url)
        expect(reopened.entryCount == entries.count && reopened.entry(named: "700/last.jpg") != nil,
               "落盘索引重开仍包含末尾非连续行")
        let pool = ZipArchivePool()
        let results = await withTaskGroup(of: Bool.self) { group in
            for name in targets {
                group.addTask { await pool.rawData(name, in: url) == payload }
            }
            var matched = true
            for await result in group { matched = matched && result }
            return matched
        }
        expect(results, "共享池并发打开与读取应完整返回")
        await pool.forget(url)
        expect(await pool.rawData("700/last.jpg", in: url) == payload,
               "释放归档后可重新打开")
        let cancelled = Task { () -> Data? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await pool.rawData("700/last.jpg", in: url)
        }
        expect(await cancelled.value == nil, "已取消请求不读取 ZIP 条目")
        var forged = bytes
        let eocd = forged.count - 22
        forged[eocd + 10] = 1
        forged[eocd + 11] = 0
        let brokenURL = root.appending(path: "wrong-count.zip")
        try forged.write(to: brokenURL)
        expect((try? ZipArchive(url: brokenURL)) == nil, "首次索引校验 EOCD 条目数")
    } catch {
        expect(false, "大 ZIP 回归执行失败：\(error)")
    }
}
