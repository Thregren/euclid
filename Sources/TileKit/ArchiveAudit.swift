import Foundation

public struct ArchiveAuditReport: Codable, Sendable {
    public var source: String
    public var declaredEntries = 0
    public var checked = 0
    public var decodedImages = 0
    public var bytes: UInt64 = 0
    public var failureCount = 0
    public var failures: [String] = []
    public var full = false
    public var complete = false
    public var nextOffset: UInt64?
    public var identity: FileIdentity?
}

public enum ArchiveAudit {
    /// Sample checks do not claim full archive integrity. Full checks are streamable and resumable.
    public static func run(url: URL, full: Bool = false, sampleCount: Int = 128, checkpoint: URL? = nil,
                           maximumRecords: Int? = nil) throws -> ArchiveAuditReport {
        guard let identity = FileIdentity(url: url) else { throw CocoaError(.fileReadNoSuchFile) }
        let archive = try ZipArchive(url: url)
        var report = ArchiveAuditReport(source: url.canonicalFilePath)
        report.declaredEntries = archive.entryCount; report.identity = identity; report.full = full
        if full, let checkpoint, FileManager.default.fileExists(atPath: checkpoint.path) {
            let previous = try JSONDecoder().decode(ArchiveAuditReport.self, from: Data(contentsOf: checkpoint))
            guard previous.full, previous.identity == identity, previous.source == report.source else { throw MBTilesError.invalid("归档已变化或检查点属于其他文件，不能继续旧检查点") }
            if previous.complete { return previous }
            report = previous
        }
        func save() throws {
            guard let checkpoint else { return }
            guard checkpoint.canonicalFilePath != url.canonicalFilePath else { throw CocoaError(.fileWriteInvalidFileName) }
            try FileManager.default.createDirectory(at: checkpoint.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(report).write(to: checkpoint, options: .atomic)
        }
        func inspect(_ entry: ZipArchive.Entry) {
            do {
                let bytes = try archive.data(for: entry)
                report.bytes += UInt64(bytes.count)
                let ext = URL(fileURLWithPath: entry.name).pathExtension.lowercased()
                if ["png", "jpg", "jpeg", "webp"].contains(ext) {
                    guard ImageDecoder.decode(bytes) != nil else { throw ZipArchive.ZipError.corrupt("图片解码失败：\(entry.name)") }
                    report.decodedImages += 1
                }
            } catch {
                report.failureCount += 1
                if report.failures.count < 1000 { report.failures.append("\(entry.name): \(error)") }
            }
            report.checked += 1
        }
        if full {
            var processed = 0, stopped = false
            do {
                try archive.visitEntries(startingAt: report.nextOffset) { entry, next in
                    try Task.checkCancellation()
                    if let maximumRecords, processed >= maximumRecords { stopped = true; return false }
                    inspect(entry); report.nextOffset = next; processed += 1
                    if processed % 128 == 0 { try save() }
                    return true
                }
                report.complete = !stopped
            } catch { try save(); throw error }
        } else {
            let rows = archive.indexedRows
            let limit = min(max(1, sampleCount), max(1, rows.count))
            var selected: [String] = []
            if rows.isEmpty {
                try archive.visitEntries { entry, _ in selected.append(entry.name); return selected.count < sampleCount }
            } else {
                for index in 0..<limit {
                    let row = rows[limit == 1 ? 0 : index * (rows.count - 1) / (limit - 1)]
                    let names = archive.entryNames(inRow: String(row))
                    if !names.isEmpty { selected.append(names[names.count / 2]) }
                }
            }
            for name in selected { try Task.checkCancellation(); if let entry = archive.entry(named: name) { inspect(entry) } }
        }
        try save()
        return report
    }
}
