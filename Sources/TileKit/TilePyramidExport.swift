import CoreGraphics
import Foundation
import ImageIO

/// 生成的瓦片用什么格式存。
public enum TileImageFormat: String, Sendable, CaseIterable, Identifiable {
    /// JPEG：默认。正射影像用它体积小得多（约为 PNG 的 1/8）。
    case jpeg
    case png

    public var id: String { rawValue }
    public var fileExtension: String { self == .jpeg ? "jpg" : "png" }
    public var displayName: String { self == .jpeg ? "JPEG" : "PNG" }

    /// JPEG 没有 alpha：透明区域需要先合成到某个底色上。
    var flattensTransparency: Bool { self == .jpeg }
}

/// 生成瓦片的参数。
public struct TilePyramidOptions: Sendable {
    public var tileSize: Int
    public var format: TileImageFormat
    /// JPEG 质量（0…1），PNG 忽略。
    public var compressionQuality: Double
    /// 已经存在的瓦片是否重新生成；默认跳过，便于中断后续跑。
    public var overwriteExisting: Bool
    /// 同时进行的解码 / 编码任务数。
    public var concurrency: Int

    public init(
        tileSize: Int = 512,
        format: TileImageFormat = .jpeg,
        compressionQuality: Double = 0.85,
        overwriteExisting: Bool = false,
        concurrency: Int = 4
    ) {
        self.tileSize = max(16, tileSize)
        self.format = format
        self.compressionQuality = min(max(compressionQuality, 0.1), 1)
        self.overwriteExisting = overwriteExisting
        self.concurrency = max(1, concurrency)
    }
}

/// 一次生成任务的计划：每级的行列范围（只存范围，不逐个存瓦片）。
public struct TilePyramidPlan: Sendable {
    public var zoomRange: ClosedRange<Int>
    public var ranges: [TileRange]
    public var tileSize: Int
    public var format: TileImageFormat
    public var outputDirectory: URL

    public var totalTileCount: Int { ranges.reduce(0) { $0 + $1.count } }

    /// 粗略体积估算，只用来给使用者一个量级概念。
    public var estimatedBytes: Int {
        let perTile = format == .jpeg ? 48 * 1024 : 140 * 1024
        return totalTileCount * perTile
    }
}

/// 进度。
public struct TilePyramidProgress: Sendable {
    public var completed: Int
    public var total: Int
    public var written: Int
    public var skipped: Int
    public var failed: Int
    public var bytes: Int
    public var zoom: Int

    public init(
        completed: Int = 0, total: Int = 0, written: Int = 0,
        skipped: Int = 0, failed: Int = 0, bytes: Int = 0, zoom: Int = 0
    ) {
        self.completed = completed
        self.total = total
        self.written = written
        self.skipped = skipped
        self.failed = failed
        self.bytes = bytes
        self.zoom = zoom
    }

    public var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
}

/// 结果。
public struct TilePyramidSummary: Sendable {
    public var written: Int
    public var skipped: Int
    public var failed: Int
    public var bytes: Int
    public var elapsed: Double
    public var cancelled: Bool
    public var outputDirectory: URL

    public init(
        written: Int = 0, skipped: Int = 0, failed: Int = 0, bytes: Int = 0,
        elapsed: Double = 0, cancelled: Bool = false, outputDirectory: URL
    ) {
        self.written = written
        self.skipped = skipped
        self.failed = failed
        self.bytes = bytes
        self.elapsed = elapsed
        self.cancelled = cancelled
        self.outputDirectory = outputDirectory
    }
}

public enum TilePyramidError: Error, CustomStringConvertible {
    case emptyRange
    case tooManyTiles(Int)
    case cannotCreateDirectory(String)
    case cannotWrite(String)

    public var description: String {
        switch self {
        case .emptyRange: return "层级范围里没有任何瓦片"
        case .tooManyTiles(let count): return "瓦片太多（\(count) 张），请缩小层级范围或范围"
        case .cannotCreateDirectory(let path): return "建不了输出目录：\(path)"
        case .cannotWrite(let path): return "写不了文件：\(path)"
        }
    }
}

/// 单次生成的安全上限：再多就该先调小范围，而不是让磁盘和 CPU 空转。
public let tilePyramidTileLimit = 1_000_000

/// 把单幅影像切成各级瓦片：`<输出目录>/<z>/<x>/<y>.<ext>`。
///
/// 复用与浏览完全相同的那条取图链路（`RasterTileSource` → 按区域解压采样），
/// 因此「生成的瓦片」和「直接看 GeoTIFF」看到的是同一份像素：
/// 不存在另一套重采样实现，也就不会出现「切出来和原图对不上」的问题。
public struct TilePyramidExporter: Sendable {
    public init() {}

    /// 规划：按影像覆盖范围算出每一级要写哪些行列。
    public static func plan(
        for raster: RasterDataset,
        zoomRange: ClosedRange<Int>,
        options: TilePyramidOptions,
        outputDirectory: URL
    ) -> TilePyramidPlan? {
        let bounds = GeoBounds(normalizedRect: raster.worldRect)
        guard bounds.isValid,
              let downloadPlan = try? TileDownloadPlan(bounds: bounds, zoomRange: zoomRange) else {
            return nil
        }
        return TilePyramidPlan(
            zoomRange: zoomRange,
            ranges: downloadPlan.ranges,
            tileSize: options.tileSize,
            format: options.format,
            outputDirectory: outputDirectory
        )
    }

    /// 影像适合生成的层级范围（上限 = 一个影像像素对一个瓦片像素的那一级）。
    public static func suggestedZoomRange(for raster: RasterDataset) -> ClosedRange<Int> {
        let upper = max(0, min(30, Int(raster.maximumDataZoom.rounded())))
        let lower = max(0, upper - 3)
        return lower...upper
    }

    /// 执行生成。可以随时取消（`Task` 取消后返回已写出的结果）。
    public func run(
        raster: RasterDataset,
        plan: TilePyramidPlan,
        options: TilePyramidOptions,
        onProgress: (@Sendable (TilePyramidProgress) -> Void)? = nil
    ) async throws -> TilePyramidSummary {
        let total = plan.totalTileCount
        guard total > 0 else { throw TilePyramidError.emptyRange }
        guard total <= tilePyramidTileLimit else { throw TilePyramidError.tooManyTiles(total) }

        let manager = FileManager.default
        do {
            try manager.createDirectory(at: plan.outputDirectory, withIntermediateDirectories: true)
        } catch {
            throw TilePyramidError.cannotCreateDirectory(plan.outputDirectory.path(percentEncoded: false))
        }

        // 注意用**参数里的瓦片尺寸**重建来源：`raster.source` 用的是影像默认边长（512），
        // 拿它渲染会让「选 256」这个选项失效。
        let source = RasterTileSource(
            fileURL: raster.fileURL,
            pixelWidth: raster.pixelWidth,
            pixelHeight: raster.pixelHeight,
            georeference: raster.georeference,
            worldRect: raster.worldRect,
            tileSize: options.tileSize
        )
        let started = Date()
        let limiter = AsyncLimiter(limit: options.concurrency)
        let counter = TilePyramidCounter(total: total)
        let outputDirectory = plan.outputDirectory
        let overlay = options

        var cancelled = false
        var firstFailure: String?

        await withTaskGroup(of: TilePyramidOutcome.self) { group in
            var completed = 0
            var written = 0, skipped = 0, failed = 0, bytes = 0
            var lastZoom = plan.zoomRange.lowerBound

            func record(_ outcome: TilePyramidOutcome) async {
                completed += 1
                switch outcome {
                case .written(let size, let zoom):
                    written += 1; bytes += size; lastZoom = zoom
                case .skipped(let zoom):
                    skipped += 1; lastZoom = zoom
                case .empty(let zoom):
                    lastZoom = zoom
                case .failed(let message, let zoom):
                    failed += 1; lastZoom = zoom
                    if firstFailure == nil { firstFailure = message }
                }
                await counter.set(TilePyramidProgress(
                    completed: completed, total: total, written: written,
                    skipped: skipped, failed: failed, bytes: bytes, zoom: lastZoom
                ))
                onProgress?(await counter.snapshot())
            }

            var inFlight = 0
            loop: for range in plan.ranges {
                for column in range.columns.lowerBound...range.columns.upperBound {
                    for row in range.rows.lowerBound...range.rows.upperBound {
                        if Task.isCancelled { cancelled = true; break loop }
                        if inFlight >= overlay.concurrency * 2, let outcome = await group.next() {
                            inFlight -= 1
                            await record(outcome)
                        }
                        let tile = SlippyTile(zoom: range.zoom, x: column, y: row)
                        group.addTask {
                            await limiter.acquire()
                            let outcome = await Self.render(
                                tile: tile,
                                source: source,
                                options: overlay,
                                outputDirectory: outputDirectory
                            )
                            await limiter.release()
                            return outcome
                        }
                        inFlight += 1
                    }
                }
            }
            while let outcome = await group.next() {
                await record(outcome)
            }
        }

        let final = await counter.snapshot()
        if let firstFailure {
            throw TilePyramidError.cannotWrite(firstFailure)
        }
        writeManifest(raster: raster, plan: plan, options: options, summary: final)
        return TilePyramidSummary(
            written: final.written,
            skipped: final.skipped,
            failed: final.failed,
            bytes: final.bytes,
            elapsed: Date().timeIntervalSince(started),
            cancelled: cancelled,
            outputDirectory: plan.outputDirectory
        )
    }

    // MARK: - 单块瓦片

    /// 一块瓦片的几种结局。
    enum TilePyramidOutcome: Sendable {
        case written(bytes: Int, zoom: Int)
        /// 影像没覆盖到（边缘的空格子），或已经存在而选择跳过。
        case skipped(zoom: Int)
        /// 整块都是透明的数据空洞，不写文件。
        case empty(zoom: Int)
        case failed(message: String, zoom: Int)
    }

    private static func render(
        tile: SlippyTile,
        source: RasterTileSource,
        options: TilePyramidOptions,
        outputDirectory: URL
    ) async -> TilePyramidOutcome {
        let manager = FileManager.default
        let url = outputDirectory
            .appending(path: String(tile.zoom))
            .appending(path: String(tile.x))
            .appending(path: "\(tile.y).\(options.format.fileExtension)")
        if !options.overwriteExisting, manager.fileExists(atPath: url.path(percentEncoded: false)) {
            return .skipped(zoom: tile.zoom)
        }
        guard let image = await source.image(for: tile) else {
            return .skipped(zoom: tile.zoom)
        }
        if isBlank(image) { return .empty(zoom: tile.zoom) }
        guard let data = encode(image, options: options) else {
            return .failed(message: url.path(percentEncoded: false), zoom: tile.zoom)
        }
        do {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return .written(bytes: data.count, zoom: tile.zoom)
        } catch {
            return .failed(message: url.path(percentEncoded: false), zoom: tile.zoom)
        }
    }

    /// 整块透明（数据空洞）的瓦片不写文件：稀疏覆盖的数据集不该被一堆空文件撑大。
    private static func isBlank(_ image: CGImage) -> Bool {
        guard image.bitsPerPixel == 32,
              image.alphaInfo == .premultipliedLast || image.alphaInfo == .last,
              let data = image.dataProvider?.data else { return false }
        let bytes = CFDataGetBytePtr(data)
        let count = CFDataGetLength(data)
        var index = 3
        var opaqueSeen = false
        while index < count {
            if bytes?[index] != 0 { opaqueSeen = true; break }
            index += 4
        }
        return !opaqueSeen
    }

    /// 编码成 JPEG / PNG。JPEG 没有 alpha，先按白底合成一次。
    private static func encode(_ image: CGImage, options: TilePyramidOptions) -> Data? {
        var source = image
        if options.format.flattensTransparency, image.alphaInfo != .none {
            let width = image.width, height = image.height
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: nil, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                  ) else { return nil }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let flattened = context.makeImage() else { return nil }
            source = flattened
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            (options.format == .jpeg ? "public.jpeg" : "public.png") as CFString,
            1,
            nil
        ) else { return nil }
        var properties: [CFString: Any] = [:]
        if options.format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = options.compressionQuality
        }
        CGImageDestinationAddImage(destination, source, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// 输出目录里留一份来源说明，和下载的瓦片一致。
    private func writeManifest(
        raster: RasterDataset,
        plan: TilePyramidPlan,
        options: TilePyramidOptions,
        summary: TilePyramidProgress
    ) {
        var lines = [
            "# 从单幅影像生成的瓦片",
            "",
            "- 来源文件：\(raster.fileURL.lastPathComponent)",
            "- 影像尺寸：\(raster.pixelWidth) × \(raster.pixelHeight) 像素",
            "- 坐标基准：\(raster.crsName)",
            "- 层级：z\(plan.zoomRange.lowerBound)–z\(plan.zoomRange.upperBound)",
            "- 瓦片：\(options.tileSize) × \(options.tileSize) 像素，\(plan.format.displayName)"
                + (plan.format == .jpeg ? String(format: "（质量 %.0f）", options.compressionQuality * 100) : ""),
            "- 已写出：\(summary.written) 张，跳过：\(summary.skipped)，空白：\(summary.completed - summary.written - summary.skipped - summary.failed) 张",
        ]
        let url = plan.outputDirectory.appending(path: "attribution.txt")
        try? lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

/// 进度计数（多任务并发更新）。
private actor TilePyramidCounter {
    private let total: Int
    private var completed = 0
    private var written = 0
    private var skipped = 0
    private var failed = 0
    private var bytes = 0
    private var zoom = 0

    init(total: Int) { self.total = total }

    /// 直接写入一份快照（并发任务按完成顺序更新）。
    func set(_ progress: TilePyramidProgress) {
        completed = progress.completed
        written = progress.written
        skipped = progress.skipped
        failed = progress.failed
        bytes = progress.bytes
        zoom = progress.zoom
    }

    func snapshot() -> TilePyramidProgress {
        TilePyramidProgress(
            completed: completed, total: total, written: written,
            skipped: skipped, failed: failed, bytes: bytes, zoom: zoom
        )
    }
}
