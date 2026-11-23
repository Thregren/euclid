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
    case dxf
    case shapefile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .geoJSON: return "GeoJSON"
        case .kml: return "KML"
        case .csv: return "CSV"
        case .excel: return "Excel"
        case .dxf: return "DXF（CAD）"
        case .shapefile: return "Shapefile"
        }
    }

    var fileExtension: String {
        switch self {
        case .geoJSON: return "geojson"
        case .kml: return "kml"
        case .csv: return "csv"
        case .excel: return "xlsx"
        case .dxf: return "dxf"
        case .shapefile: return "shp"
        }
    }

    /// 能直接复制成文本的格式（Excel 是二进制，Shapefile 是多文件）。
    var isText: Bool {
        switch self {
        case .excel, .shapefile: return false
        default: return true
        }
    }

    /// 导出会写出多个文件（Shapefile 有 .shp/.shx/.dbf/.prj/.cpg）。
    var isMultiFile: Bool { self == .shapefile }

    /// 可以复制到剪贴板的格式。
    static var textFormats: [MeasurementExportFormat] {
        allCases.filter(\.isText)
    }

    func render(_ measurements: [GeoMeasurement]) -> String {
        switch self {
        case .geoJSON: return MeasurementExporter.geoJSON(measurements)
        case .kml: return MeasurementExporter.kml(measurements)
        case .csv: return MeasurementExporter.csv(measurements)
        case .dxf: return MeasurementCADExporter.dxf(measurements)
        case .excel, .shapefile: return ""
        }
    }

    /// 导出用的字节内容。
    ///
    /// - Throws: Excel 超过 ZIP32 上限时抛 `ZIPError.tooLarge`。文本格式不会抛。
    ///   多文件格式（Shapefile）返回空 `Data`，请走 `files(_:baseName:datasetName:)`。
    func data(_ measurements: [GeoMeasurement], datasetName: String? = nil) throws -> Data {
        switch self {
        case .excel:
            return try MeasurementExporter.excel(measurements, datasetName: datasetName)
        case .shapefile:
            return Data()
        default:
            return Data(render(measurements).utf8)
        }
    }

    /// 一次导出会写出的全部文件（文件名 + 内容）。
    ///
    /// 单文件格式就是「一个以 baseName 命名的文件」；Shapefile 则是
    /// `baseName_point.shp` 这样的一整套，调用方负责写到目标目录。
    func files(
        _ measurements: [GeoMeasurement],
        baseName: String,
        datasetName: String? = nil
    ) throws -> [(name: String, data: Data)] {
        switch self {
        case .shapefile:
            return MeasurementCADExporter.shapefile(measurements, baseName: baseName)
                .map { (name: $0.name, data: $0.data) }
        default:
            return [(name: "\(baseName).\(fileExtension)",
                     data: try data(measurements, datasetName: datasetName))]
        }
    }
}

extension AppModel {
    /// 面积文本：按界面设置的单位格式化（`automatic` 时按数量级自动挑）。
    ///
    /// 测量界面里所有显示面积的地方都走它，保证同一块地在哪儿看都是同一个数字。
    /// 存档与导出不受影响，永远是平方米（见 `MeasurementArchive` / `MeasurementExporter`）。
    func areaText(_ squareMeters: Double) -> String {
        MeasureFormat.area(squareMeters, unit: areaUnit)
    }

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
        panel.nameFieldStringValue = format.isMultiFile ? "测量结果" : "测量结果.\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = format.isMultiFile
            ? "导出 \(measurements.measurements.count) 条测量结果（会写出 .shp/.shx/.dbf/.prj/.cpg 一组文件）"
            : "导出 \(measurements.measurements.count) 条测量结果"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // 拼接与编码放在后台：Excel 要拼 XML 再打 ZIP、CSV/GeoJSON 也是几十万字符的拼装，
        // 在主线程上做就是「点了导出，窗口先卡一下」；写盘（几 MB）也一并放后台。
        let snapshot = measurements.measurements
        let datasetName = selectedSourceName
        let directory = url.deletingLastPathComponent()
        let baseName = url.deletingPathExtension().lastPathComponent
        setStatus("正在导出 \(snapshot.count) 条测量…", autoClearAfter: 0)
        Task {
            let outcome: Result<Int, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let files = try format.files(snapshot, baseName: baseName, datasetName: datasetName)
                    for file in files {
                        try file.data.write(
                            to: directory.appendingPathComponent(file.name),
                            options: .atomic
                        )
                    }
                    return .success(files.count)
                } catch {
                    return .failure(error)
                }
            }.value
            switch outcome {
            case .success(let count):
                let where_ = directory.lastPathComponent
                setStatus(count > 1
                    ? "已导出 \(snapshot.count) 条测量结果（\(count) 个文件）到「\(where_)」"
                    : "已导出 \(snapshot.count) 条测量结果到 \(url.lastPathComponent)")
            case .failure(let error):
                setStatus("导出失败：\(error.localizedDescription)", autoClearAfter: 8)
            }
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
        Task { _ = await writeMeasurements(to: url) }
    }

    /// 写到一个具体文件（面板与调试脚本共用同一条路径）。
    @discardableResult
    func writeMeasurements(to url: URL) async -> Bool {
        // 编码与写盘都在后台：几百上千条测量的 JSON 编码不该占着主线程。
        let snapshot = measurements.measurements
        let failure: String? = await Task.detached(priority: .userInitiated) {
            guard let data = MeasurementArchive.encode(snapshot) else { return "编码失败" }
            do {
                try data.write(to: url, options: .atomic)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let failure {
            setStatus("保存失败：\(failure)", autoClearAfter: 8)
            return false
        }
        setStatus("已保存 \(snapshot.count) 条测量到 \(url.lastPathComponent)")
        return true
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
        Task { _ = await loadMeasurements(from: url) }
    }

    /// 从具体文件追加测量；返回读到的条数，失败返回 nil。
    @discardableResult
    func loadMeasurements(
        from url: URL,
        reader: @escaping @Sendable (URL) async -> [GeoMeasurement]? = MeasurementArchive.readFile
    ) async -> Int? {
        let targetTab = activeWorkspaceTabID
        let targetOwner = measurementOwnerPath
        let targetGeneration = sourceGeneration
        // 读盘 + 解码同样放后台（文件可能几 MB）。
        let loaded = await reader(url)
        guard !Task.isCancelled, activeWorkspaceTabID == targetTab,
              measurementOwnerPath == targetOwner, sourceGeneration == targetGeneration else {
            setStatus("导入已取消：原标签页或数据源已切换", autoClearAfter: 6)
            return nil
        }
        guard let loaded else {
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
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(basemapName)-\(formatter.string(from: Date())).png"
        let directory = quickExportDirectory
        let url = directory.appending(path: name)
        setStatus("正在出图…", autoClearAfter: 0)
        Task {
            guard let data = await viewImageData() else {
                setStatus("导出失败：画面还没渲染好", autoClearAfter: 8)
                return
            }
            // 写盘（几 MB）也放后台：主 actor 上的 Task 仍然是主线程，写盘会卡住界面。
            let failure: String? = await Task.detached(priority: .userInitiated) {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let failure {
                setStatus("导出失败：\(failure)", autoClearAfter: 8)
            } else {
                setStatus("已快速导出：\(directory.lastPathComponent)/\(name)", autoClearAfter: 8)
            }
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
        setStatus("正在出图…", autoClearAfter: 0)
        Task {
            guard let data = await viewImageData(info: info, includingMeasurements: includesMeasurements) else {
                setStatus("导出失败：画面还没渲染好", autoClearAfter: 8)
                return
            }
            let failure: String? = await Task.detached(priority: .userInitiated) {
                do {
                    try data.write(to: url, options: .atomic)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let failure {
                setStatus("导出失败：\(failure)", autoClearAfter: 8)
            } else {
                setStatus("已导出当前视图到 \(url.lastPathComponent)")
            }
        }
    }

    /// 把当前视图放进剪贴板，直接粘到聊天窗口或文档里。
    func copyViewToClipboard() {
        guard let info = viewImageInfo else {
            setStatus("当前没有可复制的画面")
            return
        }
        Task {
            guard let data = await viewImageData(info: info, includingMeasurements: true),
                  let image = NSImage(data: data) else {
                setStatus("当前没有可复制的画面")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            setStatus("已复制当前视图（\(image.size.width)×\(image.size.height) 点）")
        }
    }

    /// 导出当前视图为 PDF：画面是位图，信息栏 / 标题 / 坐标 / 比例尺是矢量。
    ///
    /// 与 PNG 那条路径共用同一个「画布快照 → 后台合成」链路，因此同样不卡界面。
    func exportViewAsPDF() {
        guard let info = viewImageInfo else {
            setStatus("当前没有可导出的画面")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(basemapName)-视图.pdf"
        panel.allowedContentTypes = [.pdf]
        panel.isExtensionHidden = false
        panel.message = "导出当前视图为 PDF（含测量标注，文字与比例尺为矢量）"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        setStatus("正在出图…", autoClearAfter: 0)
        Task {
            guard let snapshot = canvas.mapSnapshot() else {
                setStatus("导出失败：画面还没渲染好", autoClearAfter: 8)
                return
            }
            let data = await Task.detached(priority: .userInitiated) {
                ViewExporter.pdfData(snapshot, info: info)
            }.value
            guard let data else {
                setStatus("导出失败：画面还没渲染好", autoClearAfter: 8)
                return
            }
            let failure: String? = await Task.detached(priority: .userInitiated) {
                do {
                    try data.write(to: url, options: .atomic)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let failure {
                setStatus("导出失败：\(failure)", autoClearAfter: 8)
            } else {
                setStatus("已导出 PDF 到 \(url.lastPathComponent)")
            }
        }
    }

    /// 合成当前画面并编码成 PNG。
    ///
    /// 主线程只做一件事：把图层树抽成值类型快照（只读遍历，微秒级）。
    /// 光栅化、信息栏合成、PNG 编码（Retina 上一屏几十到一百多毫秒）整段在后台做，
    /// 出图期间界面照常响应。
    private func viewImageData(info: ViewExporter.Info, includingMeasurements: Bool) async -> Data? {
        guard let snapshot = canvas.mapSnapshot(includingMeasurements: includingMeasurements) else {
            return nil
        }
        return await Task.detached(priority: .userInitiated) {
            ViewExporter.pngData(snapshot, info: info)
        }.value
    }

    /// 出图用的数据（调试脚本与菜单共用同一条路径）。
    func viewImageData(includingMeasurements: Bool = true) async -> Data? {
        guard let info = viewImageInfo else { return nil }
        return await viewImageData(info: info, includingMeasurements: includingMeasurements)
    }

    /// 信息栏内容：现在看的是什么、中心在哪、多大比例、量了几条。
    /// （内部而非 private：巡检图集导出在另一个文件里也要用同一份信息栏内容。）
    var viewImageInfo: ViewExporter.Info? {
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

    // MARK: - 矢量叠加层（GeoJSON / KML）

    /// 导入 GeoJSON / KML 作为矢量叠加层。
    ///
    /// 解析成「测量」之后就和手画的图形完全同权：同样的样式、同样的存档、同样的导出、
    /// 同样的画布渲染 —— 叠在影像上面就能对照检查。
    func importVectorOverlay() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "选择 GeoJSON（.json / .geojson）或 KML 文件"
        panel.prompt = "导入"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task { await importVectorOverlays(from: urls) }
    }

    @discardableResult
    func importVectorOverlays(
        from urls: [URL],
        reader: @escaping @Sendable (URL) async -> Result<[GeoMeasurement], Error> = { url in
            await runCancellableAppWork { Result { try VectorImporter.measurements(from: url) } }
        }
    ) async -> Int? {
        let targetTab = activeWorkspaceTabID
        let targetOwner = measurementOwnerPath
        let targetGeneration = sourceGeneration
        setStatus("正在导入矢量…", autoClearAfter: 0)
        var imported: [GeoMeasurement] = []
        var failures: [String] = []
        for url in urls {
            let result = await reader(url)
            guard !Task.isCancelled, activeWorkspaceTabID == targetTab,
                  measurementOwnerPath == targetOwner, sourceGeneration == targetGeneration else {
                setStatus("导入已取消：原标签页或数据源已切换", autoClearAfter: 6)
                return nil
            }
            switch result {
            case .success(let measurements): imported.append(contentsOf: measurements)
            case .failure(let error):
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                failures.append("\(url.lastPathComponent)：\(reason)")
            }
        }
        guard !imported.isEmpty else {
            setStatus("导入失败：\(failures.first ?? "没有可识别的图形")", autoClearAfter: 8)
            return nil
        }
        measurements.merge(imported)
        canvas.refreshOverlay()
        if let rect = measurements.measurements.map(\.worldRect).compactMap({ $0 }).reduce(nil, { partial, rect in
            partial.map { $0.union(rect) } ?? rect
        }) {
            canvas.fit(to: rect)
        }
        var message = "已导入 \(imported.count) 个图形"
        if !failures.isEmpty { message += "（\(failures.count) 个文件失败：\(failures[0])）" }
        setStatus(message, autoClearAfter: 8)
        return imported.count
    }
}
