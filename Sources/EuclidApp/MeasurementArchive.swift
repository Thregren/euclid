import Foundation
import TileKit

/// 测量结果的本地存档。
///
/// 按数据集目录分别保存，再次打开同一数据集时自动恢复；
/// 数据量很小（每条测量不过几百字节），因此用一个 JSON 文件装下全部数据集。
@MainActor
enum MeasurementArchive {
    private struct Entry: Codable {
        var updatedAt: Date
        var measurements: [GeoMeasurement]
    }

    private struct Contents: Codable {
        var entries: [String: Entry] = [:]
    }

    /// 最多保留的数据集数量，避免存档无限增长。
    private static let maximumEntries = 30

    private static var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base.appending(path: "Euclid", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "measurements.json")
    }

    private static func load() -> Contents {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return Contents() }
        return (try? JSONDecoder().decode(Contents.self, from: data)) ?? Contents()
    }

    private static func write(_ contents: Contents) {
        guard let fileURL, let data = try? JSONEncoder().encode(contents) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func measurements(for datasetPath: String) -> [GeoMeasurement] {
        load().entries[datasetPath]?.measurements ?? []
    }

    static func save(_ measurements: [GeoMeasurement], for datasetPath: String) {
        var contents = load()
        if measurements.isEmpty {
            contents.entries.removeValue(forKey: datasetPath)
        } else {
            contents.entries[datasetPath] = Entry(updatedAt: Date(), measurements: measurements)
        }
        if contents.entries.count > maximumEntries {
            let excess = contents.entries
                .sorted { $0.value.updatedAt > $1.value.updatedAt }
                .dropFirst(maximumEntries)
            for (key, _) in excess {
                contents.entries.removeValue(forKey: key)
            }
        }
        write(contents)
    }
}
