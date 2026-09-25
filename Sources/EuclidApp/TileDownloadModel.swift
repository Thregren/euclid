import AppKit
import Foundation
import Observation
import TileKit

/// 在线瓦片下载的界面状态。
///
/// 下载任务本身在 `TileKit` 里（`TileDownloader`），这里只负责收集参数、
/// 把进度搬回主线程、以及在结束后给主窗口一个交代。
@MainActor
@Observable
final class TileDownloadModel {
    var sourceID: String = TileSourceTemplate.presets[0].id {
        didSet {
            applyPresetIfNeeded()
            onSourceChanged?()
        }
    }
    var template: String = "" {
        didSet { inferFileExtension() }
    }
    var subdomains: [String] = []
    var fileExtension: String = "png"
    var sourceName: String = ""
    var attribution: String = ""
    var terms: String = ""
    var key: String = ""

    var bounds = GeoBounds(west: -180, south: -85, east: 180, north: 85)
    var minimumZoom = 12
    var maximumZoom = 16
    var outputDirectory: URL?
    var overwriteExisting = false
    var concurrency = 6
    var requestsPerSecond = 24.0
    /// 输出目录里除了瓦片还写一份来源与条款说明。
    var writesManifest = true

    var isRunning = false
    var progress: TileDownloadProgress?
    var summary: TileDownloadSummary?
    var errorMessage: String?
    var lastOutputDirectory: URL?

    /// 主窗口用来显示状态栏提示。
    var onStatus: ((String) -> Void)?
    /// 数据源（预设）变化时通知主窗口，正在看在线底图时好跟着切换。
    var onSourceChanged: (() -> Void)?

    private var task: Task<Void, Never>?
    private var didPrepare = false

    init() {
        // `sourceID` 的初始值不会触发 didSet，这里补一次，保证面板一打开就带着预设模板。
        applyPresetIfNeeded()
    }

    var maximumZoomLimit: Int {
        max(0, min(TileSourceTemplate.preset(id: sourceID)?.maximumZoom ?? 22, 30))
    }

    var needsKey: Bool { template.contains("{key}") }

    /// 当前参数对应的瓦片源模板：在线浏览与下载共用同一套参数。
    var currentTemplate: TileSourceTemplate {
        TileSourceTemplate(
            id: sourceID,
            name: sourceName.isEmpty ? "自定义模板" : sourceName,
            urlTemplate: template,
            subdomains: subdomains,
            fileExtension: fileExtension,
            maximumZoom: maximumZoomLimit,
            tileSize: 256,
            attribution: attribution,
            terms: terms
        )
    }

    // MARK: - 参数装配

    /// 打开面板时把范围与层级预填成当前视图。
    func prepare(currentBounds: GeoBounds?, datasetBounds: GeoBounds?, currentZoom: Int) {
        let fallback = currentBounds ?? datasetBounds
        if let fallback, fallback.isValid {
            bounds = fallback
        }
        if !didPrepare {
            didPrepare = true
            let limit = maximumZoomLimit
            minimumZoom = min(max(0, currentZoom), limit)
            maximumZoom = min(minimumZoom + 3, limit)
            if max(minimumZoom, maximumZoom) <= minimumZoom {
                minimumZoom = max(0, min(limit, currentZoom) - 1)
            }
            outputDirectory = Self.restoredOutputDirectory()
        }
    }

    private func applyPresetIfNeeded() {
        guard let preset = TileSourceTemplate.preset(id: sourceID) else { return }
        template = preset.urlTemplate
        subdomains = preset.subdomains
        fileExtension = preset.fileExtension
        sourceName = preset.name
        attribution = preset.attribution
        terms = preset.terms
        maximumZoom = min(maximumZoom, max(preset.maximumZoom, 1))
        minimumZoom = min(minimumZoom, maximumZoom)
    }

    /// 模板里带扩展名时跟着它走，免得存成 `.png` 的文件其实是 JPEG。
    private func inferFileExtension() {
        let lower = template.lowercased()
        for candidate in ["jpeg", "jpg", "png", "webp"] where lower.contains(".\(candidate)") {
            fileExtension = candidate == "jpeg" ? "jpg" : candidate
            return
        }
    }

    func useCurrentView(_ currentBounds: GeoBounds?) {
        guard let currentBounds, currentBounds.isValid else { return }
        bounds = currentBounds
    }

    /// 把当前范围复制到剪贴板（`西,南,东,北`，可直接贴进 GIS 工具或再贴回来）。
    func copyBounds() {
        let text = String(format: "%.6f,%.6f,%.6f,%.6f", bounds.west, bounds.south, bounds.east, bounds.north)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        onStatus?("已复制范围：\(text)")
    }

    /// 从剪贴板读取范围，支持逗号/空格/换行分隔的四段数字。
    func pasteBounds() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        let numbers = text
            .split(whereSeparator: { !$0.isNumber && $0 != "." && $0 != "-" })
            .compactMap { Double($0) }
        guard numbers.count >= 4 else {
            onStatus?("剪贴板里没有可识别的范围（需要 西,南,东,北 四段数字）")
            return
        }
        let candidate = GeoBounds(west: numbers[0], south: numbers[1], east: numbers[2], north: numbers[3])
        guard candidate.isValid else {
            onStatus?("剪贴板里的范围无效（需要西 < 东、南 < 北）")
            return
        }
        bounds = candidate
        onStatus?("已填入剪贴板范围")
    }

    /// 把计划里的瓦片清单复制成 `z,x,y` 文本，便于交给别的工具核对。
    func copyTileList(limit: Int = 200_000) {
        guard let plan else { return }
        guard plan.totalTileCount <= limit else {
            onStatus?("瓦片太多（\(plan.totalTileCount) 张），清单就不复制了")
            return
        }
        var lines = ["z,x,y"]
        for tile in plan.allTiles() {
            lines.append("\(tile.zoom),\(tile.x),\(tile.y)")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        onStatus?("已复制 \(plan.totalTileCount) 行瓦片清单")
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择瓦片保存目录（下载完可以直接用本程序打开）"
        if let outputDirectory, outputDirectory.hasDirectoryPath {
            panel.directoryURL = outputDirectory
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputDirectory = url
        didPrepare = true
        Self.remember(outputDirectory: url)
    }

    // MARK: - 计划

    var zoomRange: ClosedRange<Int> {
        min(minimumZoom, maximumZoom)...max(minimumZoom, maximumZoom)
    }

    /// 当前参数下的下载计划；参数不合法时给出原因。
    var planResult: Result<TileDownloadPlan, TileDownloadError> {
        do {
            return .success(try TileDownloadPlan(bounds: bounds, zoomRange: zoomRange))
        } catch let error as TileDownloadError {
            return .failure(error)
        } catch {
            return .failure(.invalidBounds)
        }
    }

    var plan: TileDownloadPlan? {
        if case .success(let plan) = planResult { return plan }
        return nil
    }

    var tileCount: Int { plan?.totalTileCount ?? 0 }

    /// 粗略体积估计，只用于让使用者对磁盘占用心里有数。
    var estimatedBytes: Int {
        let perTile: Int
        switch fileExtension.lowercased() {
        case "jpg", "jpeg": perTile = 28 * 1024
        case "webp": perTile = 24 * 1024
        default: perTile = 70 * 1024
        }
        return tileCount * perTile
    }

    var canStart: Bool {
        !isRunning
            && !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && outputDirectory != nil
            && !(needsKey && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && tileCount > 0
            && tileCount <= TileDownloader.defaultTileLimit
    }

    var blockingReason: String? {
        if isRunning { return "正在下载…" }
        if template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请先填写 URL 模板" }
        if needsKey, key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "这个数据源需要密钥" }
        if outputDirectory == nil { return "请选择输出目录" }
        if case .failure(let error) = planResult { return error.errorDescription }
        if tileCount > TileDownloader.defaultTileLimit {
            return "瓦片太多（\(tileCount) 张），请缩小范围或降低层级"
        }
        return nil
    }

    // MARK: - 下载

    func start() {
        guard canStart, let outputDirectory else { return }
        guard case .success(let plan) = planResult else { return }

        let options = TileDownloadOptions(
            urlTemplate: template,
            outputDirectory: outputDirectory,
            fileExtension: fileExtension,
            subdomains: subdomains,
            key: key.isEmpty ? nil : key,
            overwriteExisting: overwriteExisting,
            concurrency: concurrency,
            requestsPerSecond: requestsPerSecond,
            sourceName: sourceName,
            attribution: attribution,
            terms: terms,
            writesManifest: writesManifest
        )

        isRunning = true
        summary = nil
        errorMessage = nil
        progress = TileDownloadProgress(
            completed: 0,
            total: plan.totalTileCount,
            downloaded: 0,
            skipped: 0,
            missing: 0,
            failed: 0,
            bytes: 0,
            zoom: plan.zoomRange.lowerBound,
            tilesPerSecond: 0
        )
        Self.remember(outputDirectory: outputDirectory)
        onStatus?("开始下载 \(plan.totalTileCount) 张瓦片…")

        // 这个 Task 在主 actor 上创建，因此内部状态改动仍在主线程；
        // `run` 本身是非隔离的异步方法，取图与写盘都在后台执行。
        task = Task {
            let downloader = TileDownloader()
            do {
                let result = try await downloader.run(plan: plan, options: options) { update in
                    Task { @MainActor in
                        self.progress = update
                    }
                }
                self.finish(with: result, directory: outputDirectory)
            } catch {
                self.isRunning = false
                self.task = nil
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.errorMessage = message
                self.onStatus?("下载失败：\(message)")
            }
        }
    }

    func cancel() {
        task?.cancel()
        onStatus?("正在停止下载…")
    }

    private func finish(with summary: TileDownloadSummary, directory: URL) {
        isRunning = false
        task = nil
        self.summary = summary
        lastOutputDirectory = directory

        if summary.cancelled {
            onStatus?("已停止下载：落地 \(summary.downloaded) 张，跳过 \(summary.skipped) 张")
        } else if summary.failed > 0 {
            onStatus?("下载完成（\(summary.failed) 张失败）：落地 \(summary.downloaded) 张")
        } else {
            onStatus?("下载完成：\(summary.downloaded) 张瓦片 → \(directory.lastPathComponent)")
        }
    }

    // MARK: - 记忆

    private static let outputDirectoryKey = "lastDownloadDirectory"

    static func restoredOutputDirectory() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: outputDirectoryKey),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func remember(outputDirectory: URL) {
        UserDefaults.standard.set(
            outputDirectory.path(percentEncoded: false),
            forKey: outputDirectoryKey
        )
    }
}
