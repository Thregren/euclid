import AppKit
import Foundation
import Observation
import SwiftUI
import TileKit
import UniformTypeIdentifiers

/// 当前标签页的图层操作、基准层管理与图层工厂。
extension AppModel {
    /// 各层瓦片缓存的上限，按物理内存分档。
    ///
    /// 一张 512² 的瓦片解码后约 1 MB，所以「512 MB」大致是五百来片（三四个屏幕的活动范围）。
    /// 以前写死 512 MB（在线 256 MB），两三层叠加在 8 GB 机器上压力偏大；
    /// 现在按内存分三档：内存小的少缓存、内存大的多缓存。
    enum TileCacheBudget {
        static func bytes(for kind: MapLayer.Kind) -> Int {
            let gigabytes = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
            let megabytes: Int
            switch gigabytes {
            case ..<9: megabytes = kind == .online ? 96 : 192
            case ..<17: megabytes = kind == .online ? 192 : 384
            default: megabytes = kind == .online ? 256 : 768
            }
            return megabytes * 1_048_576
        }
    }
    // MARK: - 图层操作

    /// 改某一层的不透明度。
    func setOpacity(of id: String?, to value: Double) {
        guard let id, let index = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[index].opacity = min(max(value, 0), 1)
        pushLayers()
    }

    /// 只改选中态（拖动排序、拖放落点这类操作走它，别顺手把当前数据也换了）。
    func selectLayer(_ id: String) {
        selectedLayerID = id
    }

    /// ⌫ / ⌦ 删除选中的图层（画布统一监听键盘，见 `TileCanvasNSView.installFinishMonitor`）。
    ///
    /// 只在图层面板开着时生效：面板收起来的时候用户看不到列表，一按退格删掉点什么会很意外。
    /// 返回是否真的删了（没删就把按键还给系统，别吞掉）。
    func deleteSelectedLayerFromKeyboard() -> Bool {
        guard showLayers, let id = selectedLayer?.id else { return false }
        let name = layers.first { $0.id == id }?.name ?? "图层"
        removeLayer(id)
        setStatus("已移除图层：\(name)", autoClearAfter: 5)
        return true
    }

    /// 把某一层**设为当前数据**：本地数据要重建基准层、重算数据范围、恢复这份数据自己的测量存档，
    /// 因此走 `selectSource`，只改一个 id 是不够的。
    ///
    /// 点图层行、⋯ 菜单里的「设为基准层」都走这里 —— 检查器里原先还有个「可用数据」列表能切，
    /// 那份已经删掉了，这里就是唯一的路。在线层没有基准的概念，只把它选中。
    func activateLayer(_ id: String) {
        selectedLayerID = id
        guard let layer = layers.first(where: { $0.id == id }),
              !layer.isAnchor, layer.kind != .online else { return }
        selectSource(layer.sourceID)
    }

    /// 移除当前选中层（没有选中时移除最上面那层）。
    func removeSelectedLayer() {
        guard let id = selectedLayer?.id else { return }
        removeLayer(id)
        selectedLayerID = layers.last?.id
    }

    func canMoveSelectedLayer(up: Bool) -> Bool {
        guard let id = selectedLayer?.id, let index = layers.firstIndex(where: { $0.id == id }) else { return false }
        return layers.indices.contains(up ? index + 1 : index - 1)
    }

    func moveSelectedLayer(up: Bool) {
        guard let id = selectedLayer?.id, canMoveSelectedLayer(up: up) else { return }
        moveLayer(id, up: up)
    }

    /// 把某一层设为基准层（测量、存档与相机尺度以它为准）。
    func setAnchorLayer(_ id: String) {
        guard let layer = layers.first(where: { $0.id == id }), layer.kind != .online else { return }
        activateLayer(id)
        setStatus("基准层已改为：\(layer.name)", autoClearAfter: 5)
    }

    /// 给某一层改名（图层行的右键菜单里用）。
    func renameLayer(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = layers.firstIndex(where: { $0.id == id }) else { return }
        guard layers[index].name != trimmed else { return }
        layers[index].name = trimmed
        pushLayers()
        setStatus("图层已改名为：\(trimmed)", autoClearAfter: 5)
    }

    /// 显示 / 隐藏某一层。
    func setVisible(_ visible: Bool, of id: String) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[index].isVisible = visible
        pushLayers()
    }

    /// 移除某一层。基准层被移除时清掉当前选中项。
    func removeLayer(_ id: String) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        let removed = layers.remove(at: index)
        // 卷帘对比的分界层没了就自动关掉，免得留一条指向空层的分隔线。
        if swipePivotLayerID == id { swipePivotLayerID = nil }
        if selectedLayerID == id { selectedLayerID = layers.last?.id }
        if removed.isAnchor {
            cancelAnalysis()
            cancelSourceLoading()
            changeMeasurementDocument(to: nil)
            selectedSourceID = nil
            appliedLocalDatasetID = nil
            extent = nil
        }
        if removed.kind == .online, layers.last(where: { $0.kind == .online }) == nil {
            usesOnlineBasemap = false
        }
        // 这一层是单幅影像、并且没有别的图层还在用同一个文件时，
        // 把它解出来的块缓存与读句柄一起还回去（复制图层共享同一个文件，所以要看一圈）。
        if removed.kind == .raster, let raster = removed.source as? RasterTileSource {
            let stillUsed = layers.contains { ($0.source as? RasterTileSource)?.fileURL == raster.fileURL }
            if !stillUsed { RasterCache.discard(fileURL: raster.fileURL) }
        }
        activeWorkspaceTab.normalizeAnchor()
        if removed.isAnchor { changeMeasurementDocument(to: measurementPath(for: selectedSourceID)) }
        pushLayers()
        releaseUnusedZipArchives()
    }

    /// 调整叠放次序（列表末尾在最上面）。
    func moveLayer(_ id: String, up: Bool) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        let target = up ? index + 1 : index - 1
        guard layers.indices.contains(target) else { return }
        layers.swapAt(index, target)
        activeWorkspaceTab.normalizeAnchor()
        pushLayers()
    }

    /// 复制一层（叠在原层上面）。
    func duplicateLayer(_ id: String) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        var copy = layers[index]
        copy.id = UUID().uuidString
        copy.isAnchor = false
        layers.insert(copy, at: index + 1)
        selectedLayerID = copy.id
        activeWorkspaceTab.normalizeAnchor()
        pushLayers()
        setStatus("已复制图层：\(copy.name)", autoClearAfter: 5)
    }

    // MARK: - 图层面板的顺序

    /// 图层在面板里自上而下的顺序。
    ///
    /// 画师习惯：**最上面那层排在第一行**（Pixelmator / Photoshop 都如此），
    /// 而模型里存的是「下 → 上」，两者正好相反。这份换算只在这里做，
    /// 面板显示与拖动排序都走它，免得各处各翻一次。
    var panelOrder: [MapLayer] { layers.reversed() }

    /// 把某一层拖到面板的某一行：`row` 是插入位置，取 `0…layers.count`，
    /// `0` 表示放到第一行之前（也就是最上层），`layers.count` 表示放到最后一行之后（最底层）。
    func moveLayer(_ id: String, toPanelRow row: Int) {
        guard let from = layers.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(row, 0), layers.count)
        // 面板行号自上而下，模型下标自下而上：先把行号翻成「移除之前」的插入下标，
        // 移除之后再把落在后面的下标补回来。
        var target = layers.count - clamped
        let layer = layers.remove(at: from)
        if target > from { target -= 1 }
        layers.insert(layer, at: min(max(target, 0), layers.count))
        activeWorkspaceTab.normalizeAnchor()
        pushLayers()
    }

    /// 全部显示 / 全部隐藏。
    func setAllLayersVisible(_ visible: Bool) {
        for index in layers.indices { layers[index].isVisible = visible }
        pushLayers()
    }

    /// 直接加一层（＋ 菜单的「添加本地数据 / 在线底图」与「打开时叠加」都用它）。
    ///
    /// - Parameter announce: 是否自己写状态栏。叠加那条路会说更贴切的话
    ///   （「已叠加图层：…（原图层保留）」），由调用方写，因此传 `false`。
    func addLayer(_ layer: MapLayer, announce: Bool = true) {
        var layer = layer
        // 本地数据加成一层时：实在没有基准层（比如只开了在线底图）才让它顺带当基准层，
        // 否则一律是普通图层 —— 否则会出现两个「基准」，点它也切不过去。
        if layer.kind != .online, !layers.contains(where: \.isAnchor) {
            layer.isAnchor = true
        }
        layers.append(layer)
        selectedLayerID = layer.id
        activeWorkspaceTab.normalizeAnchor()
        pushLayers()
        if announce { setStatus("已添加图层：\(layer.name)", autoClearAfter: 5) }
    }

    /// 图层改动后同步当前标签页的画布和自动标题。
    func pushLayers() {
        canvas.updateWorkspaceLayers()
        refreshActiveWorkspaceTabTitle()
    }

    /// 把不再被任何图层使用的 zip 归档从池子里放掉。
    ///
    /// 归档池只留 4 个分卷，用完会自己淘汰；但「换数据集」「删图层」这种一次性丢一片的场景，
    /// 主动过一遍能让新数据立刻拿到名额、也尽早把大分卷的文件句柄还回去。
    /// 池子是 actor，调用点在主线程上，因此这里发一个后台任务去做，不占着界面。
    /// （跨文件要用，所以不是 `private`。）
    func releaseUnusedZipArchives() {
        var inUse: Set<String> = []
        for layer in layers {
            guard let source = layer.source as? ZipTileSource else { continue }
            for volumes in source.parts.values {
                for volume in volumes { inUse.insert(volume.url.path(percentEncoded: false)) }
            }
        }
        let rasterPaths = Set(layers.compactMap { ($0.source as? RasterTileSource)?.fileURL.canonicalFilePath })
        Task.detached(priority: .utility) {
            await ZipArchivePool.shared.forgetAll(except: inUse)
            await RasterOverviewCache.shared.cancelGeneration(except: rasterPaths)
        }
    }

    /// 由本地来源造一层。
    func makeLayer(dataset: TileDataset) -> MapLayer {
        MapLayer(
            id: UUID().uuidString,
            sourceID: dataset.id,
            kind: .dataset,
            name: dataset.name,
            source: dataset.source,
            sourceKey: "dataset|\(dataset.id)|\(dataset.layout.tileSize)|\(dataset.grid.kind.rawValue)",
            tileSize: dataset.layout.tileSize,
            zoomRange: dataset.zoomRange,
            grid: dataset.grid,
            followsDisplayScale: false,
            maximumDataZoom: Double(dataset.zoomRange.upperBound),
            memoryLimitBytes: TileCacheBudget.bytes(for: .dataset),
            maxConcurrentRequests: 8,
            fitRect: extent?.worldRect,
            // 基准层的身份由调用方决定（见 `applyLocalLayer` / `addLayer`）：
            // 「加一层本地数据」不该顺手把它标成基准层，否则会出现两个「基准」。
            isAnchor: false,
            detail: Self.detail(of: dataset)
        )
    }

    /// 数据集在图层行 / 检查器里的副标题。
    static func detail(of dataset: TileDataset) -> String {
        var parts = ["z\(dataset.zoomRange.lowerBound)–z\(dataset.zoomRange.upperBound) · \(dataset.layout.tileSize)px"]
        if let info = dataset.zipInfo {
            // 一年合并成一个大包时磁盘上只有一个文件，写「分卷」会让人以为该有多个。
            parts.append(info.fileCount == 1 ? "zip 整包" : "zip 分卷")
        }
        if dataset.grid.kind != .webMercator { parts.append(dataset.grid.shortTitle) }
        return parts.joined(separator: " · ")
    }

    /// 由单幅影像造一层。
    func makeLayer(raster: RasterDataset) -> MapLayer {
        MapLayer(
            id: UUID().uuidString,
            sourceID: raster.id,
            kind: .raster,
            name: raster.name,
            source: raster.source,
            sourceKey: "raster|\(raster.id)",
            tileSize: raster.tileSize,
            zoomRange: raster.zoomRange,
            followsDisplayScale: false,
            maximumDataZoom: raster.maximumDataZoom,
            memoryLimitBytes: TileCacheBudget.bytes(for: .raster),
            maxConcurrentRequests: 8,
            fitRect: raster.worldRect,
            isAnchor: false,
            detail: "\(raster.pixelSizeText) · \(raster.isGeoreferenced ? raster.crsName : "未配准")"
        )
    }

    /// 由在线底图配置造一层。
    func makeLayer(basemap: OnlineBasemap) -> MapLayer {
        MapLayer(
            id: UUID().uuidString,
            sourceID: Self.onlineLayerID,
            kind: .online,
            name: basemap.name,
            source: basemap.makeSource(),
            sourceKey: "\(basemap.template.id)|\(basemap.template.urlTemplate)|\(basemap.key)|\(basemap.datum.rawValue)",
            tileSize: basemap.tileSize,
            zoomRange: basemap.zoomRange,
            followsDisplayScale: true,
            maximumDataZoom: Double(basemap.zoomRange.upperBound),
            memoryLimitBytes: TileCacheBudget.bytes(for: .online),
            maxConcurrentRequests: 24,
            fitRect: extent?.worldRect,
            isAnchor: false,
            detail: "在线 · z0–z\(basemap.zoomRange.upperBound)\(basemap.datum == .wgs84 ? "" : " · \(basemap.datum.shortTitle)")"
        )
    }

}
