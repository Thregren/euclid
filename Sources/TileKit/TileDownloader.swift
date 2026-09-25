import Foundation

// MARK: - 取图

/// 一次瓦片请求。
public struct TileRequest: Hashable, Sendable {
    public var url: URL
    public var headers: [String: String]

    public init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }
}

public struct TileFetchResult: Sendable {
    public var data: Data
    public var statusCode: Int

    public init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }
}

public enum TileFetchError: Error, LocalizedError, Equatable {
    case httpStatus(Int)
    case emptyBody
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "服务返回 HTTP \(code)"
        case .emptyBody: return "返回内容为空"
        case .transport(let message): return "网络错误：\(message)"
        }
    }

    /// 404 / 410 说明这一格本来就没有，重试没有意义。
    public var isMissing: Bool {
        if case .httpStatus(let code) = self { return code == 404 || code == 410 }
        return false
    }

    /// 限流与临时故障值得重试。
    public var isRetryable: Bool {
        switch self {
        case .httpStatus(let code):
            return code == 408 || code == 425 || code == 429 || (500...599).contains(code)
        case .emptyBody, .transport:
            return true
        }
    }
}

/// 取图通道。抽成协议是为了让自检可以注入假实现，不依赖网络。
public protocol TileFetching: Sendable {
    func fetch(_ request: TileRequest) async throws -> TileFetchResult
}

/// 基于 URLSession 的默认取图通道。
public struct URLSessionTileFetcher: TileFetching {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 20, session: URLSession = .shared) {
        self.timeout = timeout
        self.session = session
    }

    public func fetch(_ request: TileRequest) async throws -> TileFetchResult {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.timeoutInterval = timeout
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard (200..<300).contains(status) else { throw TileFetchError.httpStatus(status) }
            guard !data.isEmpty else { throw TileFetchError.emptyBody }
            return TileFetchResult(data: data, statusCode: status)
        } catch let error as TileFetchError {
            throw error
        } catch {
            throw TileFetchError.transport(error.localizedDescription)
        }
    }
}

// MARK: - 下载

public struct TileDownloadOptions: Sendable {
    public var urlTemplate: String
    public var subdomains: [String]
    public var key: String?
    /// 数据源的坐标基准（影响落盘清单与提示；瓦片编号由计划决定）。
    public var datum: Datum
    public var fileExtension: String
    /// 落盘布局：默认 `<z>/<x>/<y>.<ext>`，与 WebODM 输出一致，下载完可以直接用本程序打开。
    public var layout: TileLayout
    public var outputDirectory: URL
    public var overwriteExisting: Bool
    /// 同时在途的请求数。
    public var concurrency: Int
    /// 每秒最多发起的请求数，用来对数据源客气一点。
    public var requestsPerSecond: Double
    public var retryLimit: Int
    public var headers: [String: String]
    /// 写进落盘清单的来源信息。
    public var sourceName: String
    public var attribution: String
    public var terms: String
    public var writesManifest: Bool

    public init(
        urlTemplate: String,
        outputDirectory: URL,
        fileExtension: String = "png",
        subdomains: [String] = [],
        key: String? = nil,
        datum: Datum = .wgs84,
        layout: TileLayout = .webODM,
        overwriteExisting: Bool = false,
        concurrency: Int = 6,
        requestsPerSecond: Double = 8,
        retryLimit: Int = 3,
        headers: [String: String] = [:],
        sourceName: String = "",
        attribution: String = "",
        terms: String = "",
        writesManifest: Bool = true
    ) {
        self.urlTemplate = urlTemplate
        self.outputDirectory = outputDirectory
        self.fileExtension = fileExtension
        self.subdomains = subdomains
        self.key = key
        self.datum = datum
        self.layout = layout
        self.overwriteExisting = overwriteExisting
        self.concurrency = max(1, concurrency)
        self.requestsPerSecond = max(0, requestsPerSecond)
        self.retryLimit = max(0, retryLimit)
        self.headers = headers
        self.sourceName = sourceName
        self.attribution = attribution
        self.terms = terms
        self.writesManifest = writesManifest
    }

    public var defaultHeaders: [String: String] {
        TileRequestDefaults.headers(headers)
    }
}

public struct TileDownloadProgress: Sendable, Equatable {
    public var completed: Int
    public var total: Int
    public var downloaded: Int
    public var skipped: Int
    public var missing: Int
    public var failed: Int
    public var bytes: Int
    public var zoom: Int
    public var tilesPerSecond: Double

    public init(
        completed: Int = 0,
        total: Int = 0,
        downloaded: Int = 0,
        skipped: Int = 0,
        missing: Int = 0,
        failed: Int = 0,
        bytes: Int = 0,
        zoom: Int = 0,
        tilesPerSecond: Double = 0
    ) {
        self.completed = completed
        self.total = total
        self.downloaded = downloaded
        self.skipped = skipped
        self.missing = missing
        self.failed = failed
        self.bytes = bytes
        self.zoom = zoom
        self.tilesPerSecond = tilesPerSecond
    }

    public var fraction: Double {
        total > 0 ? Double(completed) / Double(total) : 0
    }

    public var remainingTiles: Int { max(0, total - completed) }

    public var estimatedRemaining: TimeInterval? {
        guard tilesPerSecond > 0.01, remainingTiles > 0 else { return nil }
        return Double(remainingTiles) / tilesPerSecond
    }
}

public struct TileDownloadSummary: Sendable {
    public var downloaded: Int
    public var skipped: Int
    public var missing: Int
    public var failed: Int
    public var bytes: Int
    public var elapsed: TimeInterval
    public var cancelled: Bool
    /// 失败样例（最多 20 条），便于判断是密钥、限流还是模板问题。
    public var failures: [String]
}

public enum TileDownloadError: Error, LocalizedError, Equatable {
    case emptyTemplate
    case invalidTemplate(String)
    case unknownPlaceholder(String)
    case missingKey
    case invalidBounds
    case invalidZoomRange
    case emptyPlan
    case tooManyTiles(Int)
    case cannotCreateDirectory(String)

    public var errorDescription: String? {
        switch self {
        case .emptyTemplate: return "URL 模板为空"
        case .invalidTemplate(let text): return "URL 模板无法解析：\(text)"
        case .unknownPlaceholder(let text): return "URL 模板里有无法识别的占位符：\(text)"
        case .missingKey: return "这个数据源需要密钥（模板里有 {key}）"
        case .invalidBounds: return "经纬度范围无效（需要西 < 东、南 < 北）"
        case .invalidZoomRange: return "层级范围无效"
        case .emptyPlan: return "该范围在所选层级下没有任何瓦片"
        case .tooManyTiles(let count): return "瓦片数量太多（\(count) 张），请缩小范围或降低层级"
        case .cannotCreateDirectory(let path): return "无法创建输出目录：\(path)"
        }
    }
}

/// 瓦片下载器：按计划逐层抓取并写入本地目录。
public struct TileDownloader: Sendable {
    /// 单次任务的上限，避免误操作把磁盘和对方服务器都拖垮。
    public static let defaultTileLimit = 2_000_000

    private let fetcher: any TileFetching
    private let tileLimit: Int

    public init(
        fetcher: any TileFetching = URLSessionTileFetcher(),
        tileLimit: Int = TileDownloader.defaultTileLimit
    ) {
        self.fetcher = fetcher
        self.tileLimit = tileLimit
    }

    private enum Outcome: Sendable {
        case downloaded(Int)
        case skipped
        case missing
        case failed(String)
    }

    public func run(
        plan: TileDownloadPlan,
        options: TileDownloadOptions,
        onProgress: (@Sendable (TileDownloadProgress) -> Void)? = nil
    ) async throws -> TileDownloadSummary {
        let total = plan.totalTileCount
        guard total > 0 else { throw TileDownloadError.emptyPlan }
        guard total <= tileLimit else { throw TileDownloadError.tooManyTiles(total) }

        do {
            try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
        } catch {
            throw TileDownloadError.cannotCreateDirectory(options.outputDirectory.path(percentEncoded: false))
        }

        let pacer = RequestPacer(requestsPerSecond: options.requestsPerSecond)
        let headers = options.defaultHeaders
        let started = Date()
        var downloaded = 0, skipped = 0, missing = 0, failed = 0, bytes = 0
        var failures: [String] = []
        var completed = 0
        var cancelled = false
        var lastReport = Date.distantPast

        func report(zoom: Int, force: Bool = false) {
            guard let onProgress else { return }
            let now = Date()
            guard force || now.timeIntervalSince(lastReport) >= 0.1 else { return }
            lastReport = now
            let elapsed = max(now.timeIntervalSince(started), 0.001)
            onProgress(TileDownloadProgress(
                completed: completed,
                total: total,
                downloaded: downloaded,
                skipped: skipped,
                missing: missing,
                failed: failed,
                bytes: bytes,
                zoom: zoom,
                tilesPerSecond: Double(completed) / elapsed
            ))
        }

        report(zoom: plan.zoomRange.lowerBound, force: true)

        for range in plan.ranges {
            if Task.isCancelled {
                cancelled = true
                break
            }
            let tiles = plan.tiles(for: range)
            let options = options
            let fetcher = fetcher

            try await withThrowingTaskGroup(of: Outcome.self) { group in
                var index = 0
                var inFlight = 0

                while index < tiles.count || inFlight > 0 {
                    if Task.isCancelled {
                        cancelled = true
                        group.cancelAll()
                        break
                    }
                    while inFlight < options.concurrency, index < tiles.count {
                        let tile = tiles[index]
                        index += 1
                        inFlight += 1
                        group.addTask {
                            await Self.fetchTile(
                                tile,
                                options: options,
                                headers: headers,
                                fetcher: fetcher,
                                pacer: pacer
                            )
                        }
                    }
                    guard let outcome = try await group.next() else { break }
                    inFlight -= 1
                    completed += 1
                    switch outcome {
                    case .downloaded(let size):
                        downloaded += 1
                        bytes += size
                    case .skipped:
                        skipped += 1
                    case .missing:
                        missing += 1
                    case .failed(let message):
                        failed += 1
                        if failures.count < 20 { failures.append(message) }
                    }
                    report(zoom: range.zoom)
                }
            }
            report(zoom: range.zoom, force: true)
        }

        let elapsed = Date().timeIntervalSince(started)
        let summary = TileDownloadSummary(
            downloaded: downloaded,
            skipped: skipped,
            missing: missing,
            failed: failed,
            bytes: bytes,
            elapsed: elapsed,
            cancelled: cancelled,
            failures: failures
        )
        if options.writesManifest {
            writeManifest(plan: plan, options: options, summary: summary)
        }
        return summary
    }

    /// 取一张瓦片并落盘：404 直接算缺片，可重试的错误按指数退避重试。
    private static func fetchTile(
        _ tile: SlippyTile,
        options: TileDownloadOptions,
        headers: [String: String],
        fetcher: any TileFetching,
        pacer: RequestPacer
    ) async -> Outcome {
        let manager = FileManager.default
        let destination = options.outputDirectory.appending(
            path: options.layout.relativePath(for: tile, fileExtension: options.fileExtension)
        )
        if !options.overwriteExisting, manager.fileExists(atPath: destination.path(percentEncoded: false)) {
            return .skipped
        }

        let url: URL
        do {
            url = try TileURLTemplate.url(
                for: tile,
                template: options.urlTemplate,
                subdomains: options.subdomains,
                key: options.key
            )
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return .failed("\(tile)：\(reason)")
        }

        var attempt = 0
        while true {
            if Task.isCancelled { return .failed("\(tile)：已取消") }
            await pacer.waitForTurn()
            do {
                let result = try await fetcher.fetch(TileRequest(url: url, headers: headers))
                do {
                    try manager.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try result.data.write(to: destination, options: .atomic)
                } catch {
                    return .failed("\(tile)：写入失败 \(error.localizedDescription)")
                }
                return .downloaded(result.data.count)
            } catch let error as TileFetchError {
                if error.isMissing { return .missing }
                guard error.isRetryable, attempt < options.retryLimit else {
                    return .failed("\(tile)：\(error.errorDescription ?? "取图失败")")
                }
                attempt += 1
                try? await Task.sleep(for: .seconds(Self.backoff(attempt: attempt)))
            } catch {
                return .failed("\(tile)：\(error.localizedDescription)")
            }
        }
    }

    static func backoff(attempt: Int) -> Double {
        min(0.5 * pow(2, Double(max(0, attempt - 1))), 8)
    }

    /// 把来源、范围、层级与条款写到输出目录，方便日后查证这批瓦片从哪来。
    private func writeManifest(
        plan: TileDownloadPlan,
        options: TileDownloadOptions,
        summary: TileDownloadSummary
    ) {
        let manifest = DownloadManifest(
            sourceName: options.sourceName,
            urlTemplate: options.urlTemplate,
            attribution: options.attribution,
            terms: options.terms,
            datum: plan.datum,
            bounds: plan.bounds,
            zoomRange: plan.zoomRange,
            fileExtension: options.fileExtension,
            layout: options.layout,
            tileCount: plan.totalTileCount,
            downloaded: summary.downloaded,
            skipped: summary.skipped,
            missing: summary.missing,
            failed: summary.failed,
            cancelled: summary.cancelled,
            downloadedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let root = options.outputDirectory
        if let data = try? encoder.encode(manifest) {
            try? data.write(to: root.appending(path: "source.json"), options: .atomic)
        }

        var lines = ["# 数据来源", ""]
        if !manifest.sourceName.isEmpty { lines.append("- 数据源：\(manifest.sourceName)") }
        if !manifest.attribution.isEmpty { lines.append("- 版权/归属：\(manifest.attribution)") }
        lines.append("- 范围：\(plan.bounds.displayText)")
        lines.append("- 层级：z\(plan.zoomRange.lowerBound)–z\(plan.zoomRange.upperBound)")
        if plan.datum != .wgs84 {
            lines.append("- 坐标基准：\(plan.datum.title)（瓦片编号按该基准）")
        }
        lines.append("- 瓦片：计划 \(plan.totalTileCount) 张，落地 \(summary.downloaded) 张，"
            + "跳过 \(summary.skipped)，缺片 \(summary.missing)，失败 \(summary.failed)")
        if !manifest.terms.isEmpty {
            lines.append("")
            lines.append("## 使用条款提醒")
            lines.append(manifest.terms)
        }
        try? Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: root.appending(path: "attribution.txt"), options: .atomic)
    }
}

/// 落盘清单，和瓦片放在同一个目录里。
public struct DownloadManifest: Codable, Sendable {
    public var sourceName: String
    public var urlTemplate: String
    public var attribution: String
    public var terms: String
    /// 旧清单里可能没有这一项。
    public var datum: Datum?
    public var bounds: GeoBounds
    public var zoomRange: ClosedRange<Int>
    public var fileExtension: String
    public var layout: TileLayout
    public var tileCount: Int
    public var downloaded: Int
    public var skipped: Int
    public var missing: Int
    public var failed: Int
    public var cancelled: Bool
    public var downloadedAt: Date
}

/// 请求节流：保证相邻两次请求之间至少间隔 `1 / requestsPerSecond` 秒。
actor RequestPacer {
    private let minimumInterval: Double
    private var nextAllowed = Date.distantPast

    init(requestsPerSecond: Double) {
        minimumInterval = requestsPerSecond > 0 ? 1 / requestsPerSecond : 0
    }

    func waitForTurn() async {
        guard minimumInterval > 0 else { return }
        let now = Date()
        let start = max(now, nextAllowed)
        nextAllowed = start.addingTimeInterval(minimumInterval)
        let delay = start.timeIntervalSince(now)
        if delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
        }
    }
}
