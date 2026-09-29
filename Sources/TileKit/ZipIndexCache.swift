import Foundation

/// zip「行索引」的落盘缓存。
///
/// 打开一个 zip 分卷时，`ZipArchive` 要流式扫一遍中央目录，记下每个行号（名字第一段，
/// 也就是瓦片的 z/x）对应的字节范围。一个 z18 分卷有一百多万条记录、中央目录上百 MB，
/// 扫一遍本机实测一二百毫秒；而索引本身只有几 KB。福建省那份数据一次要开好几个分卷，
/// 每次启动都重扫一遍纯属白等。
///
/// 缓存键 = 文件路径 + 文件大小 + 修改时间：
/// - 大小 / 修改时间一变（分卷还在下载、或者被替换过）就直接不命中，不会读到过期索引；
/// - 内容一样但路径变了（复制过去一份）会重建索引，代价只是一次扫描，不会出错。
///
/// 目录在 `~/Library/Caches/Euclid/zip-index/`，是**可随时删掉的纯缓存**，
/// 放不下就按修改时间淘汰（上限 128 个文件）。
package enum ZipIndexCache {
    package struct Payload {
        package var rowSpans: [String: (start: UInt64, end: UInt64)]
        package var entryCount: Int
        package var centralDirectorySize: UInt64
        package var isZip64: Bool
    }

    /// 最多留多少个索引文件。一份索引几 KB，128 个也就几百 KB。
    private static let maximumFiles = 128
    /// 单个索引文件的大小上限：真到了这个量级说明不是索引而是别的什么东西，直接不读。
    private static let maximumFileBytes = 8 << 20
    private static let magic = "EuclidZipIndex1"

    /// 索引目录。拿不到目录（无权限等）时返回 nil，调用方就退回「每次重扫」。
    private static var directory: URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base.appending(path: "Euclid/zip-index", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - 读

    package static func load(for url: URL, fileSize: UInt64) -> Payload? {
        guard let file = fileURL(for: url, fileSize: fileSize),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              data.count <= maximumFileBytes else { return nil }
        return parse(data)
    }

    // MARK: - 写

    package static func save(
        rowSpans: [String: (start: UInt64, end: UInt64)],
        entryCount: Int,
        centralDirectorySize: UInt64,
        isZip64: Bool,
        for url: URL,
        fileSize: UInt64
    ) {
        guard let directory, let file = fileURL(for: url, fileSize: fileSize) else { return }
        var text = "\(magic)\t\(fileSize)\t\(entryCount)\t\(centralDirectorySize)\t\(isZip64 ? 1 : 0)\n"
        // 行名里可能出现制表符 / 换行（畸形包），转义掉再写，读回来原样还原。
        text.reserveCapacity(rowSpans.count * 24)
        for (row, span) in rowSpans {
            text += "\(escape(row))\t\(span.start)\t\(span.end)\n"
        }
        guard let data = text.data(using: .utf8), data.count <= maximumFileBytes else { return }
        // 原子写：写一半的文件会被下一次读当成解析失败（而不是读到半截索引）。
        try? data.write(to: file, options: .atomic)
        prune(in: directory, keeping: maximumFiles)
    }

    // MARK: - 解析

    private static func parse(_ data: Data) -> Payload? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var rowSpans: [String: (start: UInt64, end: UInt64)] = [:]
        var header: [Substring]?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            if header == nil {
                guard fields.count == 5, fields[0] == Substring(magic) else { return nil }
                header = fields
                continue
            }
            guard fields.count == 3,
                  let start = UInt64(fields[1]), let end = UInt64(fields[2]), end >= start else {
                return nil
            }
            rowSpans[unescape(String(fields[0]))] = (start, end)
        }
        guard let header,
              let entryCount = Int(header[2]),
              let centralDirectorySize = UInt64(header[3]),
              entryCount >= 0 else { return nil }
        // 空索引（没有一行）也算无效：那多半是写坏了，别让它把数据变成「什么都没有」。
        guard !rowSpans.isEmpty else { return nil }
        return Payload(
            rowSpans: rowSpans,
            entryCount: entryCount,
            centralDirectorySize: centralDirectorySize,
            isZip64: header[4] == "1"
        )
    }

    // MARK: - 文件与名字

    /// 缓存文件名 = 路径哈希 + 大小 + 修改时间。
    ///
    /// 三者都进文件名（而不是只放在文件内容里）是为了让「分卷还在长大」这件事
    /// 自然变成「换了一个缓存文件」，不需要任何失效逻辑。
    private static func fileURL(for url: URL, fileSize: UInt64) -> URL? {
        guard let directory else { return nil }
        let path = url.path(percentEncoded: false)
        var key = "\(fnv1a(path))-\(fileSize)-\(modifiedStamp(of: url))"
        if key.count > 120 { key = String(key.prefix(120)) }
        return directory.appending(path: "\(key).idx")
    }

    private static func modifiedStamp(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        guard let date = values?.contentModificationDate else { return 0 }
        return Int64(date.timeIntervalSince1970)
    }

    /// FNV-1a（64 位）：只用来给路径生成一个稳定的短名字，不承担任何安全职责。
    private static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }

    private static func escape(_ row: String) -> String {
        row
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func unescape(_ row: String) -> String {
        var result = ""
        var iterator = row.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            switch iterator.next() {
            case "t": result.append("\t")
            case "n": result.append("\n")
            case "\\": result.append("\\")
            case let other?: result.append(other)
            case nil: result.append("\\")
            }
        }
        return result
    }

    /// 只留最近的 `keeping` 个索引文件（按修改时间）。失败就跳过 —— 缓存清理不值得报错。
    private static func prune(in directory: URL, keeping: Int) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ), entries.count > keeping else { return }
        let files = entries.compactMap { url -> (URL, Date)? in
            guard url.pathExtension == "idx",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }
        let doomed = files.sorted { $0.1 < $1.1 }.prefix(files.count - keeping)
        for (url, _) in doomed { try? FileManager.default.removeItem(at: url) }
    }
}
