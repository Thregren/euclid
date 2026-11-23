import Foundation
import TileKit

/// 测量结果的本地存档。
///
/// 按数据集目录分别保存，再次打开同一数据集时自动恢复；
/// 每个数据集独立 JSON，原子写入并保留三代备份；旧版合并存档继续可读。
///
/// 这里刻意做成 `actor`：自动存档是「读整份 → 合并 → 编码 → 写盘」，原先跑在主线程上，
/// 十来条测量看不出来，几百上千条就是每次改完一下可感的顿挫。放到 actor 上以后
/// 主 actor 只把快照交过来，顺带也让同一个文件的读-改-写天然串行（不会互相覆盖）。
actor MeasurementArchive {
    /// 存档只有一个文件，用单例串行化所有读写。
    static let shared = MeasurementArchive()

    private struct Entry: Codable {
        var updatedAt: Date
        var measurements: [GeoMeasurement]
    }

    private struct Contents: Codable {
        var entries: [String: Entry] = [:]
    }

    /// 每份数据独立保存，兼容读取旧版合并存档。
    private let repository: MeasurementRepository? = fileURL.map { MeasurementRepository(legacyURL: $0) }

    /// 调试 / 自检把存档指到别处用的覆盖路径（`EUCLID_DEBUG_ARCHIVE_PATH=/tmp/...`）。
    ///
    /// macOS 上 `HOME=/tmp/x` 并不会改变 `applicationSupportDirectory`，所以想「不碰用户存档」
    /// 地验证读写只能显式指定路径。读一次留成常量（环境字典每读一次都要重拼，见 `TileKitTrace`）。
    nonisolated static let overrideFileURL: URL? = {
        guard let raw = ProcessInfo.processInfo.environment["EUCLID_DEBUG_ARCHIVE_PATH"],
              !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: raw)
    }()

    /// 用户真正的自动存档位置（**不看调试覆盖**）。
    ///
    /// 自检脚本要断言的正是「这个文件没被动过」，因此必须有一条不受覆盖影响的路。
    nonisolated static var userArchiveFileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base
            .appending(path: "Euclid", directoryHint: .isDirectory)
            .appending(path: "measurements.json")
    }

    /// 实际读写用的位置（不建目录：读的时候目录不存在就当没有存档）。
    nonisolated static var fileURL: URL? { overrideFileURL ?? userArchiveFileURL }

    func takeNotice() async -> String? { await repository?.takeNotice() }

    func measurements(for datasetPath: String) async -> [GeoMeasurement] {
        await repository?.measurements(for: datasetPath) ?? []
    }

    func measurementsIfPresent(for datasetPath: String) async -> [GeoMeasurement]? {
        await repository?.measurementsIfPresent(for: datasetPath)
    }

    @discardableResult
    func save(_ measurements: [GeoMeasurement], for datasetPath: String) async -> String? {
        guard let repository else { return "找不到应用支持目录，自动存档没写成" }
        do {
            try await repository.save(measurements, for: datasetPath)
            return nil
        } catch {
            return "自动存档写盘失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 手工存档（另存为 / 从文件载入）

    /// 把一组测量编成可读的 JSON（另存到用户挑的文件里）。
    nonisolated static func encode(_ measurements: [GeoMeasurement]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(measurements)
    }

    /// 从 JSON 里读回测量；格式不对时返回 nil。
    nonisolated static func decode(_ data: Data) -> [GeoMeasurement]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let list = try? decoder.decode([GeoMeasurement].self, from: data) { return list }
        // 兼容旧写法：整份存档文件的格式。
        if let contents = try? decoder.decode(Contents.self, from: data) {
            return contents.entries.values.flatMap(\.measurements)
        }
        return nil
    }

    nonisolated static func readFile(_ url: URL) async -> [GeoMeasurement]? {
        await runCancellableAppWork {
            let limit = 64 * 1024 * 1024
            guard let identity = FileIdentity(url: url), identity.bytes >= 0, identity.bytes <= limit,
                  !Task.isCancelled, let file = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? file.close() }
            guard let data = try? file.read(upToCount: limit + 1), data.count <= limit, !Task.isCancelled else { return nil }
            return decode(data)
        }
    }

    /// 自动存档文件所在位置（「在访达中显示」用）。
    nonisolated static var archiveFileURL: URL? { fileURL?.deletingPathExtension().appendingPathExtension("datasets") }
}
