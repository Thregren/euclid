import AppKit
import Observation
import SwiftUI
import TileKit

/// 画布对外汇报的视图状态。
@MainActor
@Observable
final class ViewportState {
    var zoomLevel: Double = 0
    var dataZoom: Int = 0
    var center = GeoCoordinate(longitude: 0, latitude: 0)
    var metersPerPoint: Double = 0
    var visibleTiles = 0
    var loadedTiles = 0
    var missingTiles = 0

    func apply(_ snapshot: ViewportSnapshot) {
        zoomLevel = snapshot.zoomLevel
        dataZoom = snapshot.dataZoom
        center = snapshot.center
        metersPerPoint = snapshot.metersPerPoint
        visibleTiles = snapshot.visibleTiles
    }

    func reset() {
        zoomLevel = 0
        dataZoom = 0
        center = GeoCoordinate(longitude: 0, latitude: 0)
        metersPerPoint = 0
        visibleTiles = 0
        loadedTiles = 0
        missingTiles = 0
    }
}

/// SwiftUI 与 AppKit 画布之间的命令通道。
@MainActor
@Observable
final class CanvasController {
    private weak var view: TileCanvasNSView?
    private var pendingDataset: TileDataset?
    private var pendingExtent: DatasetExtent?

    func attach(_ view: TileCanvasNSView) {
        self.view = view
        view.measurementStore = measurements
        if let pendingDataset {
            view.configure(dataset: pendingDataset, extent: pendingExtent)
        }
    }

    private weak var measurements: MeasurementStore?

    func bind(measurements: MeasurementStore) {
        self.measurements = measurements
        view?.measurementStore = measurements
    }

    func set(dataset: TileDataset?, extent: DatasetExtent?) {
        pendingDataset = dataset
        pendingExtent = extent
        view?.configure(dataset: dataset, extent: extent)
    }

    func updateExtent(_ extent: DatasetExtent?) {
        pendingExtent = extent
        view?.setExtent(extent)
    }

    func setTileGrid(_ isVisible: Bool) {
        view?.showTileGrid = isVisible
    }

    func refreshOverlay() { view?.refreshOverlay() }
    func goTo(_ coordinate: GeoCoordinate) { view?.goTo(coordinate) }
    func fit() { view?.fitToData() }
    func zoomIn() { view?.zoomIn() }
    func zoomOut() { view?.zoomOut() }
    func actualSize() { view?.zoomToActualSize() }
}

/// 应用状态。
@MainActor
@Observable
final class AppModel {
    /// 全局共享实例：AppDelegate 需要用它来响应「用本应用打开文件夹」。
    static let shared = AppModel()

    var datasets: [TileDataset] = []
    var selectedDatasetID: TileDataset.ID?
    var isScanning = false
    var statusMessage: String?
    var rootFolder: URL?
    var extent: DatasetExtent?
    var recentFolders: [URL] = []

    var showInspector = true
    var showTileGrid = false {
        didSet { canvas.setTileGrid(showTileGrid) }
    }

    let viewport = ViewportState()
    let canvas = CanvasController()
    let measurements = MeasurementStore()

    var selectedDataset: TileDataset? {
        datasets.first { $0.id == selectedDatasetID }
    }

    /// 扫描代号，用于丢弃过期的扫描结果。
    private var scanGeneration = 0

    /// 启动时待打开的数据集目录。真正的扫描延后到窗口出现之后，避免在 App 初始化阶段触发状态变化。
    private var initialURL: URL?

    init() {
        canvas.bind(measurements: measurements)
        recentFolders = Self.loadRecentFolders()
        if let saved = UserDefaults.standard.string(forKey: "lastRootFolder"),
           FileManager.default.fileExists(atPath: saved) {
            initialURL = URL(fileURLWithPath: saved)
        }
    }

    private static func loadRecentFolders() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: "recentFolders") ?? []
        return paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// 打开启动时记录的数据集（由界面在首个窗口出现后调用）。
    func activateInitialDataset() {
        guard let url = initialURL else { return }
        initialURL = nil
        rootFolder = url
        scan(url)
    }


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

    func open(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue else {
            statusMessage = "请选择文件夹，而不是文件"
            return
        }
        rootFolder = url
        let path = url.path(percentEncoded: false)
        UserDefaults.standard.set(path, forKey: "lastRootFolder")
        recentFolders.removeAll { $0.path(percentEncoded: false) == path }
        recentFolders.insert(url, at: 0)
        if recentFolders.count > 8 {
            recentFolders = Array(recentFolders.prefix(8))
        }
        UserDefaults.standard.set(recentFolders.map { $0.path(percentEncoded: false) }, forKey: "recentFolders")
        scan(url)
    }

    private func scan(_ url: URL) {
        scanGeneration += 1
        let generation = scanGeneration
        AppModel.trace("scan start \(url.path(percentEncoded: false))")
        isScanning = true
        statusMessage = nil
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                DatasetLocator.discover(at: url)
            }.value
            AppModel.trace("scan finished datasets=\(found.count)")
            guard generation == self.scanGeneration else { return }
            isScanning = false
            datasets = found
            if found.isEmpty {
                statusMessage = "在 \(url.lastPathComponent) 中没有找到形如 <z>/<x>/<y> 的瓦片目录"
                selectDataset(nil)
            } else {
                selectDataset(found[0].id)
            }
        }
    }

    func selectDataset(_ id: TileDataset.ID?) {
        AppModel.trace("select \(id ?? "nil")")
        selectedDatasetID = id
        extent = nil
        guard let dataset = datasets.first(where: { $0.id == id }) else {
            canvas.set(dataset: nil, extent: nil)
            viewport.reset()
            return
        }
        canvas.set(dataset: dataset, extent: nil)
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DatasetLocator.extent(of: dataset)
            }.value
            guard selectedDatasetID == dataset.id else { return }
            AppModel.trace("extent done \(String(describing: result?.tileCount))")
            extent = result
            canvas.updateExtent(result)
            if let result, DebugFixtures.isEnabled {
                DebugFixtures.populateMeasurements(in: result, store: measurements)
                canvas.refreshOverlay()
            }
        }
    }

    static func trace(_ message: String) {
        guard ProcessInfo.processInfo.environment["EUCLID_TRACE"] != nil else { return }
        FileHandle.standardError.write(Data(("[trace] " + message + "\n").utf8))
    }
}

/// 测量结果的导出格式。
enum MeasurementExportFormat: String, CaseIterable, Identifiable {
    case geoJSON
    case kml
    case csv

    var id: String { rawValue }

    var title: String {
        switch self {
        case .geoJSON: return "GeoJSON"
        case .kml: return "KML"
        case .csv: return "CSV"
        }
    }

    var fileExtension: String {
        switch self {
        case .geoJSON: return "geojson"
        case .kml: return "kml"
        case .csv: return "csv"
        }
    }

    func render(_ measurements: [GeoMeasurement]) -> String {
        switch self {
        case .geoJSON: return MeasurementExporter.geoJSON(measurements)
        case .kml: return MeasurementExporter.kml(measurements)
        case .csv: return MeasurementExporter.csv(measurements)
        }
    }
}

extension AppModel {
    /// 复制全部测量结果到剪贴板。
    func copyMeasurements(as format: MeasurementExportFormat = .geoJSON) {
        guard !measurements.measurements.isEmpty else { return }
        let text = format.render(measurements.measurements)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "已复制 \(measurements.measurements.count) 条测量结果（\(format.title)）"
    }

    /// 导出测量结果到文件。
    func exportMeasurements(as format: MeasurementExportFormat) {
        guard !measurements.measurements.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "测量结果.\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = "导出 \(measurements.measurements.count) 条测量结果"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try format.render(measurements.measurements).write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "已导出到 \(url.lastPathComponent)"
        } catch {
            statusMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    /// 复制一段文本到剪贴板。
    func copyToClipboard(_ text: String, message: String? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if let message { statusMessage = message }
    }

    func goToCoordinate(longitude: Double, latitude: Double) {
        let clampedLatitude = min(max(latitude, -89.9), 89.9)
        canvas.goTo(GeoCoordinate(longitude: longitude, latitude: clampedLatitude))
    }

    func clearMeasurements() {
        measurements.clearAll()
        canvas.refreshOverlay()
    }
}
