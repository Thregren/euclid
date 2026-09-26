import AppKit
import Foundation
import Observation
import SwiftUI
import TileKit
import UniformTypeIdentifiers

/// 数据源与底图：打开 / 扫描 / 选中来源、装配基准层与在线层、范围解析与汇报。
///
/// 同样是从 `AppModel.swift` 拆出来的纯搬移。其中「当前装配到画布上的来源」这几个字段
/// 要在图层扩展里一起维护（`appliedLocalDatasetID` 等），因此没有写成 private ——
/// Swift 的 `private` 是文件级的，拆文件之后跨文件就看不到了。
extension AppModel {
    /// 当前在线底图；用本地数据时为 nil。
    var onlineBasemap: OnlineBasemap? {
        guard usesOnlineBasemap else { return nil }
        return OnlineBasemap(template: download.currentTemplate, key: download.key, datum: download.datum)
    }

    /// 界面上是否有可看的内容（本地数据集或在线底图）。
    var hasMapContent: Bool { selectedSourceName != nil || onlineBasemap != nil }

    /// 正在忙什么；nil 表示空闲。用于画布上的进度指示（HIG：加载时别只留空白）。
    var loadingMessage: String? {
        if isScanning { return "正在扫描目录…" }
        if isResolvingExtent { return "正在读取数据范围…" }
        return nil
    }

    /// 当前底图的显示名。
    var basemapName: String {
        onlineBasemap?.name ?? selectedSourceName ?? "未打开"
    }

    /// 按当前选择刷新画布。
    func applyBasemap() {
        applyOnlineLayer(force: true)
    }

    /// 重建「基准本地层」：只替换标记为 anchor 的那一层，用户另外添加的图层保持不动。
    func applyLocalLayer(force: Bool = false) {
        guard force || selectedSourceID != appliedLocalDatasetID else { return }
        appliedLocalDatasetID = selectedSourceID
        let previousOpacity = anchorLayer?.opacity ?? 1
        let previousVisibility = anchorLayer?.isVisible ?? true
        // 同一份数据在画布上只留一份：「加一层本地数据」加过的那份，在它成为当前数据之后
        // 由基准层代表，别在列表里留两个一模一样、点起来还各是各的图层。
        layers.removeAll { $0.isAnchor || $0.sourceID == selectedSourceID }
        var newLayer: MapLayer?
        if let raster = selectedRaster {
            newLayer = makeLayer(raster: raster)
        } else if let dataset = selectedDataset {
            newLayer = makeLayer(dataset: dataset)
        }
        if var layer = newLayer {
            // 这一层就是「当前数据」，也就是基准层（测量、存档与相机尺度以它为准）。
            layer.isAnchor = true
            layer.opacity = previousOpacity
            layer.isVisible = previousVisibility
            layers.insert(layer, at: 0)   // 本地影像放最下层，参考底图叠在它上面
        }
        pushLayers()
    }

    /// 重建「在线底图层」：签名没变就不动。
    func applyOnlineLayer(force: Bool = false) {
        let basemap = onlineBasemap
        let signature = basemap.map {
            // 基准要进签名：只改基准（模板与密钥都没动）时也得重装图层，否则偏移不会生效。
            "\($0.template.id)|\($0.template.urlTemplate)|\($0.key)|\($0.datum.rawValue)"
        }
        guard force || signature != appliedOnlineSignature else { return }
        appliedOnlineSignature = signature

        let previousOpacity = onlineLayer?.opacity ?? 1
        let previousVisibility = onlineLayer?.isVisible ?? true
        layers.removeAll { $0.kind == .online && $0.sourceID == Self.onlineLayerID }

        guard let basemap, basemap.invalidReason == nil else {
            if let reason = basemap?.invalidReason {
                setStatus(reason, autoClearAfter: 6)
            }
            pushLayers()
            return
        }
        var layer = makeLayer(basemap: basemap)
        layer.opacity = previousOpacity
        layer.isVisible = previousVisibility
        layers.append(layer)
        normalizeAnchor()
        pushLayers()

        var message = "底图：\(basemap.name)"
        if !basemap.attribution.isEmpty { message += " · \(basemap.attribution)" }
        // 偏移基准要说清方向与量级：使用者一眼就能判断基准选得对不对。
        if basemap.datum != .wgs84 {
            message += " · " + basemap.offsetHint(at: viewport.center)
        }
        setStatus(message, autoClearAfter: 5)
    }

    var selectedDataset: TileDataset? {
        datasets.first { $0.id == selectedSourceID }
    }

    /// 当前选中的单幅影像。
    var selectedRaster: RasterDataset? {
        rasters.first { $0.id == selectedSourceID }
    }

    /// 当前本地来源的名字（瓦片数据集或单幅影像）。
    var selectedSourceName: String? {
        selectedDataset?.name ?? selectedRaster?.name
    }

    /// 当前本地来源的目录 / 文件路径（测量存档与「最近打开」用）。
    var selectedSourcePath: String? {
        selectedDataset?.rootURL.path(percentEncoded: false)
            ?? selectedRaster?.fileURL.path(percentEncoded: false)
    }



    // MARK: - 打开与扫描

    // MARK: - 打开

    func promptForFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "打开"
        panel.message = "选择瓦片目录（可以是单个数据集，也可以包含多个数据集）"
        if let rootFolder {
            panel.directoryURL = rootFolder
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    /// 打开「从影像生成瓦片」面板：已经打开单幅影像时带上它，否则进去再选。
    func promptForTileExport() {
        showTileExportSheet = true
    }

    /// 打开单幅影像（GeoTIFF / TIFF，也收普通图片：读不出地理参考就按未配准显示）。
    func promptForRaster() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "打开"
        panel.message = "选择单幅影像（GeoTIFF / TIFF / PNG 等）"
        panel.allowedContentTypes = [.tiff, .image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else {
            setStatus("找不到这个路径：\(url.lastPathComponent)")
            return
        }
        remember(url)
        openWithoutRemembering(url, isDirectory: isDirectory.boolValue)
    }

    /// 打开一份数据但**不写进「最近打开」**（调试用：无人值守截图时不改用户的偏好）。
    func openForDebugging(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else {
            setStatus("找不到这个路径：\(url.lastPathComponent)")
            return
        }
        openWithoutRemembering(url, isDirectory: isDirectory.boolValue)
    }

    private func openWithoutRemembering(_ url: URL, isDirectory: Bool) {
        guard isDirectory else {
            // 文件：按单幅影像打开（GeoTIFF / TIFF / 普通图片）。
            openRaster(url)
            return
        }
        rootFolder = url
        scan(url)
    }

    /// 记住最近打开过的目录或文件。
    private func remember(_ url: URL) {
        let path = url.path(percentEncoded: false)
        UserDefaults.standard.set(path, forKey: "lastRootFolder")
        recentFolders.removeAll { $0.path(percentEncoded: false) == path }
        recentFolders.insert(url, at: 0)
        if recentFolders.count > 8 {
            recentFolders = Array(recentFolders.prefix(8))
        }
        UserDefaults.standard.set(recentFolders.map { $0.path(percentEncoded: false) }, forKey: "recentFolders")
    }

    /// 读单幅影像：只读文件头（IFD），因此再大的图也是秒开。
    func openRaster(_ url: URL) {
        isResolvingExtent = true
        setStatus("正在读取影像…", autoClearAfter: 0)
        Task {
            let result: Result<RasterDataset, Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(try RasterLoader.load(url: url)) } catch { return .failure(error) }
            }.value
            isResolvingExtent = false
            AppModel.trace("raster loaded \(url.lastPathComponent)")
            switch result {
            case .success(let raster):
                rasters.removeAll { $0.id == raster.id }
                rasters.insert(raster, at: 0)
                selectSource(raster.id)
            case .failure(let error):
                setStatus("打开影像失败：\((error as? TIFFError)?.description ?? error.localizedDescription)", autoClearAfter: 8)
            }
        }
    }

    private func scan(_ url: URL) {
        scanGeneration += 1
        let generation = scanGeneration
        AppModel.trace("scan start \(url.path(percentEncoded: false))")
        isScanning = true
        setStatus("正在扫描目录…", autoClearAfter: 0)
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                DatasetLocator.discover(at: url)
            }.value
            AppModel.trace("scan finished datasets=\(found.count)")
            guard generation == self.scanGeneration else { return }
            isScanning = false
            datasets = found
            if found.isEmpty {
                setStatus("在 \(url.lastPathComponent) 中没有找到形如 <z>/<x>/<y> 的瓦片目录", autoClearAfter: 0)
                selectSource(nil)
            } else {
                selectSource(found[0].id)
            }
        }
    }

    /// 选中一个本地来源：瓦片数据集或单幅影像。
    func selectSource(_ id: String?) {
        AppModel.trace("select \(id ?? "nil")")
        selectedSourceID = id
        extent = nil

        // 单幅影像：尺寸、坐标系与覆盖范围都在读文件头时就算好了，不需要异步扫描。
        if let raster = rasters.first(where: { $0.id == id }) {
            isResolvingExtent = false
            extent = raster.extent
            applyLocalLayer(force: true)
            applyOnlineLayer()
            measurements.restore(MeasurementArchive.measurements(for: raster.id))
            canvas.refreshOverlay()
            reportRaster(raster)
            if DebugFixtures.isEnabled {
                DebugFixtures.populateMeasurements(in: raster.extent, store: measurements)
                canvas.refreshOverlay()
            }
            DebugZoomScript.runIfRequested(canvas: canvas)
            return
        }

        guard let dataset = datasets.first(where: { $0.id == id }) else {
            isResolvingExtent = false
            applyLocalLayer(force: true)
            applyOnlineLayer()
            viewport.reset()
            return
        }
        // 选数据集就重装本地图层；在线底图是否叠加由 `usesOnlineBasemap` 决定，互不影响。
        applyLocalLayer(force: true)
        applyOnlineLayer()
        measurements.restore(MeasurementArchive.measurements(for: dataset.rootURL.path(percentEncoded: false)))
        canvas.refreshOverlay()
        // 数据范围要扫完目录才知道，这期间画布先不铺图（在错误位置铺一屏空占位只会闪）。
        setStatus("正在读取数据范围…", autoClearAfter: 0)
        isResolvingExtent = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DatasetLocator.extent(of: dataset)
            }.value
            guard selectedSourceID == dataset.id else { return }
            isResolvingExtent = false
            AppModel.trace("extent done \(String(describing: result?.tileCount))")
            extent = result
            if let result, let index = layers.firstIndex(where: { $0.isAnchor }) {
                layers[index].fitRect = result.worldRect
            }
            canvas.updateExtent(result)
            if result == nil {
                setStatus("未能确定数据范围，已按默认层级显示", autoClearAfter: 6)
            } else {
                setStatus(nil)
            }
            if let result, DebugFixtures.isEnabled {
                DebugFixtures.populateMeasurements(in: result, store: measurements)
                canvas.refreshOverlay()
            }
            DebugZoomScript.runIfRequested(canvas: canvas)
        }
    }

    /// 打开单幅影像后在状态栏交代一句：看了什么、多大、多清晰、是否配准。
    private func reportRaster(_ raster: RasterDataset) {
        if let note = raster.placementNote {
            setStatus("\(raster.name)：未配准（\(note)），已按 1 像素 = 1 米摆放", autoClearAfter: 8)
            return
        }
        var parts = ["\(raster.pixelSizeText)", raster.crsName]
        if let gsd = raster.groundSampleDistance {
            parts.append(gsd >= 1
                ? String(format: "%.2f 米/像素", gsd)
                : String(format: "%.1f 厘米/像素", gsd * 100))
        }
        setStatus("单幅影像 \(raster.name)：\(parts.joined(separator: " · "))", autoClearAfter: 6)
    }

    static func trace(_ message: String) {
        guard ProcessInfo.processInfo.environment["EUCLID_TRACE"] != nil else { return }
        FileHandle.standardError.write(Data(("[trace] " + message + "\n").utf8))
    }
}
