import Foundation

package enum DiskCacheMaintenance {
    package static func prune(directory: URL, suffix: String, maximumFiles: Int = .max, maximumBytes: Int = .max) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        var files: [(URL, Date, Int)] = []
        for url in entries where url.pathExtension == suffix {
            guard let value = try? url.resourceValues(forKeys: keys), value.isRegularFile == true else { continue }
            files.append((url, value.contentModificationDate ?? .distantPast, value.fileSize ?? 0))
        }
        files.sort { $0.1 > $1.1 }
        var bytes = 0
        for (index, file) in files.enumerated() {
            if index >= maximumFiles || file.2 > maximumBytes - bytes { try? FileManager.default.removeItem(at: file.0) }
            else { bytes += file.2 }
        }
    }
}
