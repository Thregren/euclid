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

    /// 画布上是否已经有本地数据（瓦片数据集或单幅影像）。
    ///
    /// 这是「打开」的分岔点：已经有本地内容时，新打开的东西**叠加**成一层，
    /// 而不是被设为基准层、把老的那份顶掉（老图层、测量与视野都保持不动）。
    /// 要换「当前数据」走 `activateLayer`（点图层面板里那一行）。
    var hasLocalLayer: Bool { layers.contains { $0.kind != .online } }

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
        // 换数据集时把旧分卷的归档放掉，别让它们继续占着池子里的名额。
        releaseUnusedZipArchives()
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
                // 配置不全（最典型的是没填密钥）时**不作自动消失**：用户点了底图却什么都没发生，
                // 这句说明得一直留在状态栏，直到他填好密钥或切走。
                setStatus(reason, autoClearAfter: 0)
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
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "打开"
        panel.message = "选择瓦片目录（可以是单个数据集，也可以包含多个数据集；支持 zip 分卷包）"
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

    /// 一次拖入多个路径：第一个当「打开」（会写进最近记录），其余的一律**叠加成新图层**。
    ///
    /// 拖进来的东西可能混着目录、zip 分卷与单幅影像，因此这里按和 `openWithoutRemembering`
    /// 完全相同的规则分流：画布上已经有数据时，每个后面的路径都只加一层，
    /// 老图层、当前数据、测量与视野全都不动。谁都顶替不掉谁。
    func open(_ urls: [URL]) {
        guard let first = urls.first else { return }
        open(first)
        for url in urls.dropFirst() {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.canonicalFilePath, isDirectory: &isDirectory) else {
                setStatus("找不到这个路径：\(url.lastPathComponent)", autoClearAfter: 6)
                continue
            }
            if isDirectory.boolValue || url.pathExtension.lowercased() == "mbtiles" {
                addDatasetLayer(at: url)
            } else if url.pathExtension.lowercased() == "zip" {
                addDatasetLayer(at: DatasetLocator.datasetRoot(containing: url), preferring: url)
            } else {
                addRasterLayer(at: url)
            }
        }
    }

    // MARK: - 叠加（已经开着数据时，把新打开的东西加为新图层）

    /// 把一层本地数据**叠**到现有图层上，返回是否真的加了一层。
    ///
    /// 「同一份数据在画布上只留一层」是既有约定（见 `applyLocalLayer`）：重复打开同一份
    /// 数据、或从 ＋ 菜单里点一份已经在画布上的数据，都不该再叠出第二个一模一样的图层。
    ///
    /// 这里不碰基准层身份 —— 它只由「设为当前数据」（`activateLayer`）决定。
    @discardableResult
    func stackLayer(_ layer: MapLayer) -> Bool {
        let hadLocalLayer = hasLocalLayer
        if layers.contains(where: { $0.kind != .online && $0.sourceID == layer.sourceID }) {
            setStatus("「\(layer.name)」已经在画布上了", autoClearAfter: 6)
            return false
        }
        var layer = layer
        if layer.kind != .online { layer.isAnchor = false }
        addLayer(layer, announce: false)
        setStatus(
            hadLocalLayer ? "已叠加图层：\(layer.name)（原图层保留）" : "已添加图层：\(layer.name)",
            autoClearAfter: 6
        )
        return true
    }

    /// 把一份单幅影像叠成图层（已经开着数据时走这条，见 `openWithoutRemembering`）。
    ///
    /// 与 `openRaster` 的区别是**什么都不换**：不进加载态、不动基准层与测量，
    /// 读完文件头挂一层就完事 —— 用户在看的还是原来那份数据。
    func addRasterLayer(at url: URL) {
        let tabID = activeWorkspaceTabID
        Task {
            let raster = await Task.detached(priority: .userInitiated) {
                try? RasterLoader.load(url: url)
            }.value
            // 读文件头的这几百毫秒里用户可能已经切到别的标签页了：这份结果就不属于当前画面了。
            guard activeWorkspaceTabID == tabID else { return }
            guard let raster else {
                setStatus("叠加失败：读不出 \(url.lastPathComponent)", autoClearAfter: 8)
                return
            }
            rasters.removeAll { $0.id == raster.id }
            rasters.insert(raster, at: 0)
            stackLayer(makeLayer(raster: raster))
        }
    }

    /// 把一份瓦片数据集叠成图层（已经开着数据时走这条，见 `openWithoutRemembering`）。
    ///
    /// 扫出来的数据并进「已打开的数据」列表（＋ 菜单里仍可各自加一层），
    /// 但只把其中一份挂上画布：拖进来的是某个分卷时优先选包含它的那份，
    /// 否则就是扫到的第一份 —— 与「第一次打开这个目录」选的完全是同一份。
    func addDatasetLayer(at url: URL, preferring preferred: URL? = nil) {
        let tabID = activeWorkspaceTabID
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                DatasetLocator.discover(at: url)
            }.value
            guard activeWorkspaceTabID == tabID else { return }
            guard !found.isEmpty else {
                setStatus("在 \(url.lastPathComponent) 中没有找到瓦片目录（<z>/<x>/<y>）或 zip 分卷包", autoClearAfter: 0)
                return
            }
            // 新扫到的并进列表，老的那些原样留着（＋ 菜单里还能把它们各自加一层）。
            datasets = DatasetLocator.merging(datasets, with: found)

            // 拖进来的是某个分卷时，加的是包含它的那份数据（与第一次打开时选的是同一份）。
            let match = preferred.flatMap { DatasetLocator.dataset(containingVolume: $0, in: found) }
            let dataset = match ?? found[0]
            addDatasetLayer(dataset)
        }
    }

    /// 把一份**已经发现过**的数据集叠成图层（＋ 菜单里点的那条路）。
    func addDatasetLayer(_ dataset: TileDataset) {
        var layer = makeLayer(dataset: dataset)
        // 这份数据的范围还不知道（`extent` 是当前数据那一份的）：先留空，
        // 别拿当前数据的范围冒充它。算出来再填。
        layer.fitRect = nil
        guard stackLayer(layer) else { return }
        resolveFitRect(of: layer.id, dataset: dataset)
    }

    /// 给叠加进来的数据集补上它自己的适配范围。
    ///
    /// 只更新这一层，**不动相机**：用户在看的还是原来那份数据
    /// （「适配窗口」也仍然以基准层为准）。范围要扫完目录才知道，因此放后台。
    private func resolveFitRect(of layerID: String, dataset: TileDataset) {
        let tabID = activeWorkspaceTabID
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DatasetLocator.extent(of: dataset)
            }.value
            guard activeWorkspaceTabID == tabID else { return }
            // 图层可能已经被用户删掉了（或者换了数据集）：那就没有要更新的东西。
            guard let index = layers.firstIndex(where: { $0.id == layerID }) else { return }
            guard let result else {
                setStatus("「\(dataset.name)」的数据范围读不出来，已按默认层级显示", autoClearAfter: 8)
                return
            }
            layers[index].fitRect = result.worldRect
            pushLayers()
            // 新数据要是在视野之外，画面上一点变化都没有，用户会以为没打开成功 —— 补一句怎么过去。
            if let visible = canvas.visibleWorldRect, visible.intersection(result.worldRect).isNull {
                setStatus(
                    "已叠加图层：\(dataset.name)（不在当前视野，点图层面板里那一行可切过去）",
                    autoClearAfter: 12
                )
            }
        }
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

    /// 「打开」的唯一分岔口。
    ///
    /// 画布上还没有本地数据时，这份数据就是**当前数据**（成为基准层，相机按它适配）；
    /// 已经有数据在看时，它**叠加**成一层新图层 —— 老图层、`selectedSourceID`、
    /// 测量存档与相机视野一律不动（用户说的「叠加为新图册，而不是把老图层顶掉」）。
    private func openWithoutRemembering(_ url: URL, isDirectory: Bool) {
        let stacking = hasLocalLayer
        if !isDirectory {
            if url.pathExtension.lowercased() == "mbtiles" {
                if stacking { addDatasetLayer(at: url) }
                else { rootFolder = DatasetLocator.canonicalURL(url); scan(url) }
                return
            }
            // 拖进来一个 zip 分卷：当成「打开它所在的那份数据」。
            if url.pathExtension.lowercased() == "zip" {
                let root = DatasetLocator.datasetRoot(containing: url)
                if stacking {
                    addDatasetLayer(at: root, preferring: url)
                } else {
                    rootFolder = DatasetLocator.canonicalURL(root)
                    scan(root, preferring: url)
                }
                return
            }
            // 文件：按单幅影像打开（GeoTIFF / TIFF / 普通图片）。
            if stacking {
                addRasterLayer(at: url)
            } else {
                openRaster(url)
            }
            return
        }
        if stacking {
            addDatasetLayer(at: url)
        } else {
            rootFolder = DatasetLocator.canonicalURL(url)
            scan(url)
        }
    }

    /// 记住最近打开过的目录或文件。
    private func remember(_ url: URL) {
        // 最近列表里存的是规范路径：拖放给的目录 URL 常常带尾斜杠，
        // 不规范化同一份数据会在列表里出现两行、点哪行都看不出区别。
        let url = DatasetLocator.canonicalURL(url)
        let path = url.canonicalFilePath
        UserDefaults.standard.set(path, forKey: "lastRootFolder")
        recentFolders.removeAll { $0.canonicalFilePath == path }
        recentFolders.insert(url, at: 0)
        if recentFolders.count > 8 {
            recentFolders = Array(recentFolders.prefix(8))
        }
        UserDefaults.standard.set(recentFolders.map(\.canonicalFilePath), forKey: "recentFolders")
    }

    /// 清空「最近打开」列表（检查器里那个「清空」按钮）。
    ///
    /// `lastRootFolder` 一并清掉：它记的是「上次打开的目录」，只清列表的话，下次启动还是会
    /// 自动打开上一份数据，看起来就像没清干净。清的是偏好，不动任何数据文件。
    func clearRecentFolders() {
        let defaults = UserDefaults.standard
        guard !recentFolders.isEmpty || defaults.string(forKey: "lastRootFolder") != nil else {
            setStatus("最近记录本来就是空的", autoClearAfter: 4)
            return
        }
        recentFolders.removeAll()
        defaults.removeObject(forKey: "recentFolders")
        defaults.removeObject(forKey: "lastRootFolder")
        // 启动时已经排队、还没执行的那次「自动打开上次目录」也要撤掉。
        initialURL = nil
        setStatus("已清空最近记录", autoClearAfter: 4)
    }

    /// 读单幅影像：只读文件头（IFD），因此再大的图也是秒开。
    func openRaster(_ url: URL) {
        cancelAnalysis()
        cancelSourceLoading()
        let generation = sourceGeneration
        isResolvingExtent = true
        setStatus("正在读取影像…", autoClearAfter: 0)
        sourceTask = Task {
            let result: Result<RasterDataset, Error> = await runCancellableAppWork {
                do { return .success(try RasterLoader.load(url: url)) } catch { return .failure(error) }
            }
            // 这中间用户又打开了别的数据：这份结果已经过期，直接丢掉（连状态栏都不改）。
            guard generation == self.sourceGeneration else { return }
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

    private func scan(_ url: URL, preferring preferred: URL? = nil) {
        cancelAnalysis()
        cancelSourceLoading()
        let generation = sourceGeneration
        AppModel.trace("scan start \(url.path(percentEncoded: false))")
        isScanning = true
        setStatus("正在扫描目录…", autoClearAfter: 0)
        sourceTask = Task {
            let found = await runCancellableAppWork {
                DatasetLocator.discover(at: url)
            }
            AppModel.trace("scan finished datasets=\(found.count)")
            guard generation == self.sourceGeneration else { return }
            isScanning = false
            datasets = found
            if found.isEmpty {
                setStatus("在 \(url.lastPathComponent) 中没有找到瓦片目录（<z>/<x>/<y>）或 zip 分卷包", autoClearAfter: 0)
                selectSource(nil)
            } else {
                // 拖具体某个分卷进来时，优先选中包含它的那份数据。
                let match = preferred.flatMap { DatasetLocator.dataset(containingVolume: $0, in: found) }
                selectSource((match ?? found[0]).id)
            }
        }
    }

    /// 选中一个本地来源：瓦片数据集或单幅影像。
    func selectSource(_ id: String?) {
        cancelAnalysis()
        cancelSourceLoading()
        let generation = sourceGeneration
        AppModel.trace("select \(id ?? "nil")")
        changeMeasurementDocument(to: measurementPath(for: id))
        selectedSourceID = id
        extent = nil

        // 单幅影像：尺寸、坐标系与覆盖范围都在读文件头时就算好了，不需要异步扫描。
        if let raster = rasters.first(where: { $0.id == id }) {
            isResolvingExtent = false
            extent = raster.extent
            applyLocalLayer(force: true)
            applyOnlineLayer()
            reportRaster(raster)
            if DebugFixtures.isEnabled {
                DebugFixtures.populateMeasurements(in: raster.extent, store: measurements)
                canvas.refreshOverlay()
            }
            DebugZoomScript.runIfRequested(canvas: canvas)
            DebugFullscreenScript.runIfRequested(canvas: canvas)
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
        // 数据范围要扫完目录才知道，这期间画布先不铺图（在错误位置铺一屏空占位只会闪）。
        setStatus("正在读取数据范围…", autoClearAfter: 0)
        isResolvingExtent = true
        sourceTask = Task {
            let result = await runCancellableAppWork {
                DatasetLocator.extent(of: dataset)
            }
            // 代号与选中项都对得上才落地：少一个都可能把旧范围盖到新选的数据上。
            guard generation == self.sourceGeneration, selectedSourceID == dataset.id else { return }
            isResolvingExtent = false
            AppModel.trace("extent done \(String(describing: result?.tileCount))")
            extent = result
            if let result, let index = layers.firstIndex(where: { $0.isAnchor }) {
                layers[index].fitRect = result.worldRect
            }
            canvas.updateExtent(result)
            if result == nil {
                setStatus("未能确定数据范围，已按默认层级显示", autoClearAfter: 6)
            } else if let info = dataset.zipInfo {
                // zip 分卷读起来和散文件没区别，交代一句让使用者知道没在偷偷解压。
                setStatus(
                    "\(info.fileCount == 1 ? "zip 整包" : "zip 分卷 \(info.fileCount) 个包")"
                        + " · \(dataset.grid.title) · 不解压直读",
                    autoClearAfter: 8
                )
            } else {
                setStatus(nil)
            }
            if let result, DebugFixtures.isEnabled {
                DebugFixtures.populateMeasurements(in: result, store: measurements)
                canvas.refreshOverlay()
            }
            DebugZoomScript.runIfRequested(canvas: canvas)
            DebugFullscreenScript.runIfRequested(canvas: canvas)
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
