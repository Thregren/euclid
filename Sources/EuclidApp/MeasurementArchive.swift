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

    // MARK: - 手工存档（另存为 / 从文件载入）

    /// 把一组测量编成可读的 JSON（另存到用户挑的文件里）。
    static func encode(_ measurements: [GeoMeasurement]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(measurements)
    }

    /// 从 JSON 里读回测量；格式不对时返回 nil。
    static func decode(_ data: Data) -> [GeoMeasurement]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let list = try? decoder.decode([GeoMeasurement].self, from: data) { return list }
        // 兼容旧写法：整份存档文件的格式。
        if let contents = try? decoder.decode(Contents.self, from: data) {
            return contents.entries.values.flatMap(\.measurements)
        }
        return nil
    }

    /// 自动存档文件所在位置（「在访达中显示」用）。
    static var archiveFileURL: URL? { fileURL }
}
