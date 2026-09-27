import Foundation
import TileKit

/// 测量结果的本地存档。
///
/// 按数据集目录分别保存，再次打开同一数据集时自动恢复；
/// 数据量很小（每条测量不过几百字节），因此用一个 JSON 文件装下全部数据集。
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

    /// 最多保留的数据集数量，避免存档无限增长。
    private static let maximumEntries = 30
    /// 写盘失败只报一次：自动存档每 0.8 秒就会来一次，别把状态栏和日志刷满。
    private var hasReportedWriteFailure = false
    /// 有待告诉用户的提示（存档文件读不出来之类），由界面取走一次。
    private var pendingNotice: String?

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

    private func load() -> Contents {
        guard let url = Self.fileURL, let data = try? Data(contentsOf: url) else { return Contents() }
        if let contents = try? JSONDecoder().decode(Contents.self, from: data) { return contents }
        // 文件在、但解不开：留一份现场再当作空存档，并在状态栏说明。
        // 以前这里是「悄悄当成没有存档」，用户会以为自己的测量丢了。
        if pendingNotice == nil {
            let stamp = Self.timestamp()
            let backup = url.deletingLastPathComponent().appending(path: "measurements.corrupt-\(stamp).json")
            if (try? FileManager.default.copyItem(at: url, to: backup)) != nil {
                pendingNotice = "自动存档读不出来，已备份成 \(backup.lastPathComponent)；本次按空存档启动"
            } else {
                pendingNotice = "自动存档读不出来（备份也没写成），本次按空存档启动"
            }
        }
        return Contents()
    }

    /// 取走一次待显示的提示（没有就返回 nil）。
    func takeNotice() -> String? {
        defer { pendingNotice = nil }
        return pendingNotice
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// 写盘。失败时返回一句给人看的话（同一个会话里只说一次），成功返回 nil。
    private static func write(_ contents: Contents) -> String? {
        guard let fileURL else { return "找不到应用支持目录，自动存档没写成" }
        do {
            let data = try JSONEncoder().encode(contents)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            return nil
        } catch {
            return "自动存档写盘失败：\(error.localizedDescription)"
        }
    }

    func measurements(for datasetPath: String) -> [GeoMeasurement] {
        load().entries[datasetPath]?.measurements ?? []
    }

    /// 存一份。返回 nil 表示成功；否则是给状态栏看的一句失败说明（同一次运行里只报一次）。
    @discardableResult
    func save(_ measurements: [GeoMeasurement], for datasetPath: String) -> String? {
        var contents = load()
        if measurements.isEmpty {
            contents.entries.removeValue(forKey: datasetPath)
        } else {
            contents.entries[datasetPath] = Entry(updatedAt: Date(), measurements: measurements)
        }
        if contents.entries.count > Self.maximumEntries {
            let excess = contents.entries
                .sorted { $0.value.updatedAt > $1.value.updatedAt }
                .dropFirst(Self.maximumEntries)
            for (key, _) in excess {
                contents.entries.removeValue(forKey: key)
            }
        }
        guard let failure = Self.write(contents) else { return nil }
        // 有「存档读不出来」这类提示时优先报它（写失败的那条下一次再说）。
        if let notice = pendingNotice {
            pendingNotice = nil
            return notice
        }
        guard !hasReportedWriteFailure else { return nil }
        hasReportedWriteFailure = true
        return failure
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

    /// 自动存档文件所在位置（「在访达中显示」用）。
    nonisolated static var archiveFileURL: URL? { fileURL }
}
