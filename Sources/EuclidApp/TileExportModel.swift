import AppKit
import Foundation
import Observation
import TileKit

/// 「从单幅影像生成瓦片」面板的状态。
///
/// 真正的活在 `TileKit/TilePyramidExport.swift` 里；这里只管收参数、把进度搬回主线程、
/// 结束后给主窗口一个交代（能不能直接打开这个数据集）。
@MainActor
@Observable
final class TileExportModel {
    /// 影像文件；面板打开时默认取当前正在看的那一份。
    var sourceURL: URL?
    private(set) var raster: RasterDataset?
    private(set) var sourceError: String?
    var outputDirectory: URL?

    var minimumZoom = 16
    var maximumZoom = 19
    /// 512（默认，与本地影像 1:1 显示一致）或 256（在线底图那套通用约定）。
    var tileSize = 512
    var format: TileImageFormat = .jpeg
    /// JPEG 质量，0…1。
    var quality = 0.85
    var overwriteExisting = false

    var isRunning = false
    var progress: TilePyramidProgress?
    private(set) var summary: TilePyramidSummary?
    var errorMessage: String?

    var onStatus: ((String) -> Void)?

    private var task: Task<Void, Never>?

    var tileSizeOptions: [Int] { [512, 256] }

    var zoomRange: ClosedRange<Int> {
        min(minimumZoom, maximumZoom)...max(minimumZoom, maximumZoom)
    }

    var maximumZoomLimit: Int {
        guard let raster else { return 24 }
        return max(0, min(30, Int(raster.maximumDataZoom.rounded(.up))))
    }

    var options: TilePyramidOptions {
        TilePyramidOptions(
            tileSize: tileSize,
            format: format,
            compressionQuality: quality,
            overwriteExisting: overwriteExisting
        )
    }

    var plan: TilePyramidPlan? {
        guard let raster, let outputDirectory else { return nil }
        return TilePyramidExporter.plan(
            for: raster,
            zoomRange: zoomRange,
            options: options,
            outputDirectory: outputDirectory
        )
    }

    var tileCount: Int { plan?.totalTileCount ?? 0 }
    var estimatedBytes: Int { plan?.estimatedBytes ?? 0 }

    var canStart: Bool {
        !isRunning && raster != nil && outputDirectory != nil && tileCount > 0
    }

    var blockingReason: String? {
        if raster == nil { return sourceError ?? "请先选择一幅影像（GeoTIFF / TIFF）" }
        if outputDirectory == nil { return "请选择输出目录" }
        if plan == nil { return "这个层级范围里没有瓦片，请调大最大层级" }
        if tileCount > 500_000 { return "瓦片太多（\(tileCount) 张），请缩小层级范围" }
        return nil
    }

    // MARK: - 参数装配

    /// 打开面板时按当前影像与当前视图预填一次。
    func prepare(source: RasterDataset?, outputDirectory currentOutput: URL?, currentZoom: Int) {
        if raster == nil, let source {
            raster = source
            sourceURL = source.fileURL
            applySuggestedZooms(currentZoom: currentZoom)
        }
        if outputDirectory == nil {
            outputDirectory = currentOutput ?? Self.restoredOutputDirectory()
                ?? source?.fileURL.deletingLastPathComponent().appending(path: "\(source?.name ?? "tiles")-tiles")
        }
    }

    /// 换成另一幅影像。
    func loadSource(_ url: URL) {
        sourceURL = url
        sourceError = nil
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                try? RasterLoader.load(url: url)
            }.value
            guard let loaded else {
                raster = nil
                sourceError = "读不出这个影像（\(url.lastPathComponent)）"
                return
            }
            raster = loaded
            applySuggestedZooms(currentZoom: nil)
            if outputDirectory == nil {
                outputDirectory = url.deletingLastPathComponent().appending(path: "\(loaded.name)-tiles")
            }
        }
    }

    private func applySuggestedZooms(currentZoom: Int?) {
        guard let raster else { return }
        let suggested = TilePyramidExporter.suggestedZoomRange(for: raster)
        maximumZoom = suggested.upperBound
        minimumZoom = min(suggested.lowerBound, max(0, currentZoom ?? suggested.lowerBound))
        if let currentZoom, currentZoom <= suggested.upperBound, currentZoom >= suggested.lowerBound {
            minimumZoom = currentZoom
        }
    }

    func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.tiff, .image]
        panel.message = "选择要切瓦片的影像（GeoTIFF / TIFF / 图片）"
        panel.prompt = "选择"
        if let sourceURL { panel.directoryURL = sourceURL.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadSource(url)
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择瓦片输出目录（生成后可以直接用本程序打开）"
        panel.prompt = "选择"
        if let outputDirectory { panel.directoryURL = outputDirectory }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputDirectory = url
        Self.remember(outputDirectory: url)
    }

    // MARK: - 生成

    func start() {
        guard canStart, let raster, let plan, let outputDirectory else { return }
        isRunning = true
        summary = nil
        errorMessage = nil
        progress = TilePyramidProgress(
            completed: 0, total: plan.totalTileCount, written: 0,
            skipped: 0, failed: 0, bytes: 0, zoom: plan.zoomRange.lowerBound
        )
        Self.remember(outputDirectory: outputDirectory)
        onStatus?("开始生成瓦片：\(plan.totalTileCount) 张…")

        let options = self.options
        task = Task {
            do {
                let result = try await TilePyramidExporter().run(
                    raster: raster, plan: plan, options: options
                ) { update in
                    Task { @MainActor in self.progress = update }
                }
                self.isRunning = false
                self.task = nil
                self.summary = result
                let name = outputDirectory.lastPathComponent
                if result.cancelled {
                    onStatus?("已停止生成：已写出 \(result.written) 张 → \(name)")
                } else {
                    onStatus?("已生成 \(result.written) 张瓦片 → \(name)")
                }
            } catch {
                self.isRunning = false
                self.task = nil
                let message = (error as? TilePyramidError)?.description ?? error.localizedDescription
                self.errorMessage = message
                self.onStatus?("生成失败：\(message)")
            }
        }
    }

    func cancel() {
        task?.cancel()
        onStatus?("正在停止…")
    }

    /// 生成完直接把结果打开看。
    func openResult(using app: AppModel) {
        guard let directory = summary?.outputDirectory ?? outputDirectory else { return }
        app.open(directory)
    }

    var outputPreviewURL: URL? { summary?.outputDirectory ?? outputDirectory }

    // MARK: - 记忆

    private static let outputDirectoryKey = "lastTileExportDirectory"

    static func restoredOutputDirectory() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: outputDirectoryKey) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func remember(outputDirectory: URL) {
        UserDefaults.standard.set(
            outputDirectory.path(percentEncoded: false),
            forKey: outputDirectoryKey
        )
    }
}
