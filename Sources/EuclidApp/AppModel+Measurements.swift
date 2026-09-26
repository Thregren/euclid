import AppKit
import Foundation
import Observation
import SwiftUI
import TileKit
import UniformTypeIdentifiers

/// 测量的导出、存档与出图。
///
/// 从 `AppModel.swift`（状态中枢）拆出来的纯搬移：状态与图层、来源分别在另外两个文件里。

/// 测量结果的导出格式。
enum MeasurementExportFormat: String, CaseIterable, Identifiable {
    case geoJSON
    case kml
    case csv
    case excel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .geoJSON: return "GeoJSON"
        case .kml: return "KML"
        case .csv: return "CSV"
        case .excel: return "Excel"
        }
    }

    var fileExtension: String {
        switch self {
        case .geoJSON: return "geojson"
        case .kml: return "kml"
        case .csv: return "csv"
        case .excel: return "xlsx"
        }
    }

    /// Excel 是二进制格式，不能直接复制成文本。
    var isText: Bool { self != .excel }

    /// 可以复制到剪贴板的格式。
    static var textFormats: [MeasurementExportFormat] {
        allCases.filter(\.isText)
    }

    func render(_ measurements: [GeoMeasurement]) -> String {
        switch self {
        case .geoJSON: return MeasurementExporter.geoJSON(measurements)
        case .kml: return MeasurementExporter.kml(measurements)
        case .csv: return MeasurementExporter.csv(measurements)
        case .excel: return ""
        }
    }

    /// 导出用的字节内容。
    func data(_ measurements: [GeoMeasurement], datasetName: String? = nil) -> Data {
        switch self {
        case .excel:
            return MeasurementExporter.excel(measurements, datasetName: datasetName)
        default:
            return Data(render(measurements).utf8)
        }
    }
}

extension AppModel {
    /// 复制全部测量结果到剪贴板。
    func copyMeasurements(as format: MeasurementExportFormat = .geoJSON) {
        guard !measurements.measurements.isEmpty, format.isText else { return }
        let text = format.render(measurements.measurements)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        setStatus("已复制 \(measurements.measurements.count) 条测量结果（\(format.title)）")
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
            let payload = format.data(measurements.measurements, datasetName: selectedSourceName)
            try payload.write(to: url, options: .atomic)
            setStatus("已导出 \(measurements.measurements.count) 条测量结果到 \(url.lastPathComponent)")
        } catch {
            setStatus("导出失败：\(error.localizedDescription)", autoClearAfter: 8)
        }
    }

    /// 复制一段文本到剪贴板。
    func copyToClipboard(_ text: String, message: String? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if let message { setStatus(message) }
    }

    func goToCoordinate(longitude: Double, latitude: Double) {
        let clampedLatitude = min(max(latitude, -89.9), 89.9)
        canvas.goTo(GeoCoordinate(longitude: longitude, latitude: clampedLatitude))
    }

    /// 复制指针所在坐标（检查器按钮与「工具」菜单共用，快捷键 ⌥⌘C）。
    func copyCursorCoordinate() {
        guard let cursor = measurements.cursorInfo else {
            setStatus("把指针移到地图上再复制坐标")
            return
        }
        copyToClipboard(
            CoordinateText.decimal(cursor.coordinate, precision: 7),
            message: "已复制坐标"
        )
    }

    /// 把指针位置记成一个点（快捷键 P）。与「点坐标」工具共用同一份测量数据。
    func dropPointAtCursor() {
        guard hasMapContent else { return }
        guard let measurement = canvas.dropPointAtCursor(),
              let coordinate = measurement.points.first else {
            setStatus("把指针移到地图上，再按 P 记下这个点", autoClearAfter: 5)
            return
        }
        setStatus("已记下 \(CoordinateText.decimal(coordinate, precision: 6))（可在检查器里改名或调样式）")
    }

    func clearMeasurements() {
        measurements.clearAll()
        canvas.refreshOverlay()
    }

    // MARK: - 测量的显式存档

    /// 把当前测量另存为一个文件：可以交给别人、换机器接着用，或者当作「彻底保存」的备份。
    func saveMeasurementsToFile() {
        guard !measurements.measurements.isEmpty else {
            setStatus("现在还没有测量可以保存")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(selectedSourceName ?? "测量")-测量.json"
        panel.allowedContentTypes = [.json]
        panel.isExtensionHidden = false
        panel.message = "保存 \(measurements.measurements.count) 条测量（JSON，可再次载入编辑）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writeMeasurements(to: url)
    }

    /// 写到一个具体文件（面板与调试脚本共用同一条路径）。
    @discardableResult
    func writeMeasurements(to url: URL) -> Bool {
        guard let data = MeasurementArchive.encode(measurements.measurements) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            setStatus("已保存 \(measurements.measurements.count) 条测量到 \(url.lastPathComponent)")
            return true
        } catch {
            setStatus("保存失败：\(error.localizedDescription)", autoClearAfter: 8)
            return false
        }
    }

    /// 从文件里追加测量（不清掉现有的，便于把几次外业的点拼在一起）。
    func loadMeasurementsFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "选择之前保存的测量文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard loadMeasurements(from: url) == nil else { return }
    }

    /// 从具体文件追加测量；返回读到的条数，失败返回 nil。
    @discardableResult
    func loadMeasurements(from url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url),
              let loaded = MeasurementArchive.decode(data) else {
            setStatus("这个文件里没有可识别的测量", autoClearAfter: 6)
            return nil
        }
        guard !loaded.isEmpty else {
            setStatus("这个文件里没有测量", autoClearAfter: 6)
            return nil
        }
        measurements.merge(loaded)
        canvas.refreshOverlay()
        setStatus("已载入 \(loaded.count) 条测量（追加到现有 \(measurements.measurements.count - loaded.count) 条之后）")
        return loaded.count
    }

    /// 在访达里显示自动存档文件（每次改动都会写进去，按数据集 / 影像分开存）。
    func revealMeasurementArchive() {
        guard let url = MeasurementArchive.archiveFileURL,
              FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            setStatus("自动存档还没有生成（先量一条试试）")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - 出图

    /// 快捷导出目录：默认 `~/图片/尺规`，也可以在「导出为图片…」里换。
    private static let quickExportFolderKey = "quickExportFolder"

    private var quickExportDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: Self.quickExportFolderKey) {
            return URL(fileURLWithPath: path)
        }
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return pictures.appending(path: "尺规", directoryHint: .isDirectory)
    }

    /// 快速导出当前视图：不弹面板，直接按时间戳存进快捷导出目录（含测量标注）。
    func quickExportView() {
        guard hasMapContent else {
            setStatus("当前没有可导出的画面")
            return
        }
        guard let data = viewImageData() else {
            setStatus("导出失败：画面还没渲染好", autoClearAfter: 8)
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(basemapName)-\(formatter.string(from: Date())).png"
        let directory = quickExportDirectory
        let url = directory.appending(path: name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            setStatus("已快速导出：\(directory.lastPathComponent)/\(name)", autoClearAfter: 8)
        } catch {
            setStatus("导出失败：\(error.localizedDescription)", autoClearAfter: 8)
        }
    }

    /// 在访达里显示快捷导出目录。
    func revealQuickExportFolder() {
        let directory = quickExportDirectory
        if FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } else {
            setStatus("还没有快速导出过（⌘E 试一次）")
        }
    }

    /// 导出当前视图：画面（瓦片 + 测量标注）加一条信息栏，
    /// 里面是数据源、中心坐标、层级与比例尺，直接贴进报告就能看懂。
    func exportViewAsImage() {
        guard let info = viewImageInfo else {
            setStatus("当前没有可导出的画面")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(basemapName)-视图.png"
        panel.allowedContentTypes = [.png]
        panel.isExtensionHidden = false
        panel.message = "导出当前视图（下方带数据源、中心坐标与比例尺信息栏）"
        let measurementsToggle = NSButton(
            checkboxWithTitle: "包含测量标注", target: nil, action: nil
        )
        measurementsToggle.state = .on
        panel.accessoryView = measurementsToggle
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let includesMeasurements = measurementsToggle.state == .on
        guard let data = viewImageData(info: info, includingMeasurements: includesMeasurements) else {
            setStatus("导出失败：画面还没渲染好", autoClearAfter: 8)
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            setStatus("已导出当前视图到 \(url.lastPathComponent)")
        } catch {
            setStatus("导出失败：\(error.localizedDescription)", autoClearAfter: 8)
        }
    }

    /// 把当前视图放进剪贴板，直接粘到聊天窗口或文档里。
    func copyViewToClipboard() {
        guard let info = viewImageInfo,
              let data = viewImageData(info: info, includingMeasurements: true),
              let image = NSImage(data: data) else {
            setStatus("当前没有可复制的画面")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        setStatus("已复制当前视图（\(image.size.width)×\(image.size.height) 点）")
    }

    private func viewImageData(info: ViewExporter.Info, includingMeasurements: Bool) -> Data? {
        guard let map = canvas.mapImage(includingMeasurements: includingMeasurements),
              let composed = ViewExporter.compose(
                map: map,
                scale: canvas.backingScale,
                info: info
              ) else { return nil }
        return ViewExporter.pngData(composed)
    }

    /// 出图用的数据（调试脚本与菜单共用同一条路径）。
    func viewImageData(includingMeasurements: Bool = true) -> Data? {
        guard let info = viewImageInfo else { return nil }
        return viewImageData(info: info, includingMeasurements: includingMeasurements)
    }

    /// 信息栏内容：现在看的是什么、中心在哪、多大比例、量了几条。
    private var viewImageInfo: ViewExporter.Info? {
        guard hasMapContent else { return nil }
        let hasLocal = selectedSourceName != nil
        let online = onlineBasemap
        var subtitleParts: [String] = []
        if hasLocal, let online {
            subtitleParts.append("叠加 \(online.name)")
        }
        if let online, !online.attribution.isEmpty {
            subtitleParts.append(online.attribution)
        }
        return ViewExporter.Info(
            title: selectedSourceName ?? online?.name ?? basemapName,
            subtitle: subtitleParts.isEmpty ? nil : subtitleParts.joined(separator: " · "),
            center: viewport.center,
            zoom: viewport.dataZoom,
            metersPerPoint: viewport.metersPerPoint,
            measurementCount: measurements.measurements.count
        )
    }
}
