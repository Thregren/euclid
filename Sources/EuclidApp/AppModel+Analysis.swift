import AppKit
import Foundation
import Observation
import SwiftUI
import TileKit

/// 栅格分析（DEM 工具箱 / 两期差异）的界面状态。
///
/// 单独一个模型：面板只读它、改它，分析结果（剖面采样、土方量、坡度统计）
/// 都落在这里；真正的重活由 `AppModel+Analysis.swift` 里的方法放到后台跑完再回填。
@MainActor
@Observable
final class RasterAnalysisModel {
    /// 指针处的样本读数。
    struct PointReading: Sendable, Equatable {
        var coordinate: GeoCoordinate
        var column: Double
        var row: Double
        var value: Float
    }

    /// 一条剖面。
    struct ProfileReading: Sendable {
        var measurementID: UUID?
        var title: String
        var samples: [(fraction: Double, value: Float)]
        var lengthMeters: Double
        var minimum: Float
        var maximum: Float
        var start: Float
        var end: Float
        /// 累计爬升 / 下降（米）。
        var gain: Double
        var loss: Double
    }

    /// 土方量的基准高程（米，可手填）。
    var baseElevationText = "0"
    var profile: ProfileReading?
    var volume: DEMAnalysis.VolumeResult?
    /// 最近一次算出的坡度统计。
    var slopeStatistics: DEMAnalysis.Statistics?
    /// 最近一次分析结果的一句话说明（差异图这类不需要留在面板上的）。
    var message: String?
    var isWorking = false

    /// 手填的基准高程；填得不对返回 nil。
    var baseElevation: Double? {
        let trimmed = baseElevationText.trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }
}

/// 坡度图要算哪一块。
enum RasterAnalysisScope: String, CaseIterable, Identifiable {
    /// 只算当前视野（快，适合边看边算）。
    case view
    /// 整幅影像（慢一些，但结果完整）。
    case whole

    var id: String { rawValue }

    var title: String {
        switch self {
        case .view: return "当前视野"
        case .whole: return "整幅影像"
        }
    }
}

/// 数值分析：点高程、剖面、坡度、土方量、两期差异。
///
/// 这一层只做「取值 + 出图 + 挂图层」，取值与出图都在 `TileKit` 的
/// `RasterSampleReader` / `DEMAnalysis` / `RasterDifference` 里 —— 界面这边不碰
/// TIFF 字节，也不自己算测地线。重活一律 `Task.detached` 下主线程。
extension AppModel {
    /// 用来做数值分析的影像：优先基准层（本地数据的那一份），否则退回当前选中的影像。
    var analysisRaster: RasterDataset? {
        if let anchor = anchorLayer, anchor.kind == .raster,
           let raster = rasters.first(where: { $0.id == anchor.sourceID }) {
            return raster
        }
        return selectedRaster
    }

    /// 分析用的读句柄。表头解析本身有缓存，这里只省掉重复查找。
    var analysisReader: RasterSampleReader? {
        guard let raster = analysisRaster else { return nil }
        if let cached = analysisReaderCache, cached.url == raster.fileURL { return cached.reader }
        guard let reader = RasterSampleReader.open(url: raster.fileURL) else { return nil }
        analysisReaderCache = (raster.fileURL, reader)
        return reader
    }

    /// 当前这份数据能不能做高程类分析（单波段浮点或 ≥16 位整数）。
    var supportsElevationAnalysis: Bool { analysisReader?.isElevationLike == true }

    /// 指针处的样本读数（点高程）。
    func analysisReading(at coordinate: GeoCoordinate) -> RasterAnalysisModel.PointReading? {
        guard let reader = analysisReader,
              let pixel = reader.georeference.pixel(for: coordinate),
              let value = reader.value(column: pixel.x, row: pixel.y) else { return nil }
        return RasterAnalysisModel.PointReading(
            coordinate: coordinate,
            column: pixel.x,
            row: pixel.y,
            value: value
        )
    }

    /// 指针处的高程读数（只在高程类影像上给值）。
    ///
    /// 指针坐标是 30 Hz 刷新的热路径，而读一个像素要走一遍分块解码；
    /// 因此按「整数像素」缓存：没跨到下一个源像素就不重读。
    func elevationReading(at coordinate: GeoCoordinate) -> Float? {
        guard let reader = analysisReader, reader.isElevationLike,
              let pixel = reader.georeference.pixel(for: coordinate) else {
            pointElevationCache = nil
            return nil
        }
        let column = Int(pixel.x.rounded(.down))
        let row = Int(pixel.y.rounded(.down))
        if let cache = pointElevationCache, cache.column == column, cache.row == row {
            return cache.value
        }
        let value = reader.value(column: pixel.x, row: pixel.y)
        pointElevationCache = (column, row, value)
        return value
    }

    // MARK: - 剖面

    /// 用当前选中的测量当路径生成剖面。
    ///
    /// 折线沿每个顶点走（不是起点连终点），圆沿圆周走一圈；点 / 标注没有路径，直接拒绝。
    func buildProfileFromSelection() {
        guard let reader = analysisReader else {
            status("先打开一份影像，再算剖面")
            return
        }
        guard let measurement = measurements.selectedMeasurement ?? measurements.measurements.last else {
            status("先用「测距」画一条线，或在列表里选中一条折线")
            return
        }
        let ring = profilePath(of: measurement)
        guard ring.count >= 2 else {
            status("\(measurement.kind.displayName)没有可采样的路径，请用「测距」或「测面积」")
            return
        }
        guard let path = pixels(of: ring, reader: reader) else {
            status("这条线的端点不在影像范围内")
            return
        }
        // 只有起点落在图上时，采样会从第一个可见点开始 —— 剖面图和「画出来的线」要对得上。
        guard path.count >= 2 else {
            status("这条线落在影像范围内的部分太短")
            return
        }
        analysis.isWorking = true
        let length = pathLength(of: ring)
        Task {
            let samples = await Task.detached(priority: .userInitiated) {
                reader.profile(along: path, count: 320)
            }.value
            analysis.isWorking = false
            guard samples.count >= 2 else {
                status("这条线上没有可读的数值")
                return
            }
            analysis.profile = Self.makeProfile(
                measurement: measurement,
                samples: samples,
                lengthMeters: length
            )
            status("剖面已更新：\(samples.count) 个采样点")
        }
    }

    /// 剖面要走的路径（世界坐标）。
    private func profilePath(of measurement: GeoMeasurement) -> [GeoCoordinate] {
        switch measurement.kind {
        case .distance, .area:
            return measurement.points
        case .circle:
            guard let center = measurement.circleCenter,
                  let radius = measurement.circleRadius, radius > 0 else { return [] }
            // 闭合一圈：末尾再回到起点，剖面首尾才对得上。
            let ring = Geodesy.circleRing(center: center, radius: radius, samples: 72)
            return ring + (ring.first.map { [$0] } ?? [])
        case .point, .annotation:
            return []
        }
    }

    /// 世界坐标 → 影像像素坐标；有任何一个顶点不在影像上就整体放弃（宁可不画，不画错的）。
    private func pixels(of ring: [GeoCoordinate], reader: RasterSampleReader) -> [CGPoint]? {
        var result: [CGPoint] = []
        result.reserveCapacity(ring.count)
        for coordinate in ring {
            guard let pixel = reader.georeference.pixel(for: coordinate),
                  pixel.x.isFinite, pixel.y.isFinite else { return nil }
            result.append(pixel)
        }
        return result
    }

    private func pathLength(of ring: [GeoCoordinate]) -> Double {
        guard ring.count >= 2 else { return 0 }
        var total = 0.0
        for index in 0..<(ring.count - 1) {
            total += Geodesy.distance(from: ring[index], to: ring[index + 1])
        }
        return total
    }

    private static func makeProfile(
        measurement: GeoMeasurement,
        samples: [(fraction: Double, value: Float)],
        lengthMeters: Double
    ) -> RasterAnalysisModel.ProfileReading {
        var minimum = Float.greatestFiniteMagnitude
        var maximum = -Float.greatestFiniteMagnitude
        var gain = 0.0
        var loss = 0.0
        var previous: Float?
        for sample in samples where sample.value.isFinite {
            minimum = min(minimum, sample.value)
            maximum = max(maximum, sample.value)
            if let previous {
                let delta = Double(sample.value - previous)
                if delta > 0 { gain += delta } else { loss -= delta }
            }
            previous = sample.value
        }
        let valid = samples.filter { $0.value.isFinite }
        return RasterAnalysisModel.ProfileReading(
            measurementID: measurement.id,
            title: measurement.exportName,
            samples: samples,
            lengthMeters: lengthMeters,
            minimum: valid.isEmpty ? .nan : minimum,
            maximum: valid.isEmpty ? .nan : maximum,
            start: valid.first?.value ?? .nan,
            end: valid.last?.value ?? .nan,
            gain: gain,
            loss: loss
        )
    }

    // MARK: - 坡度

    /// 把坡度算成一张叠加层加进图层列表。
    func addSlopeLayer(scope: RasterAnalysisScope) {
        guard let reader = analysisReader, let raster = analysisRaster else {
            status("先打开一份影像，再算坡度")
            return
        }
        let rect: CGRect?
        switch scope {
        case .whole:
            rect = nil
        case .view:
            guard let world = canvas.visibleWorldRect,
                  let pixels = reader.georeference.pixelRect(ofWorldRect: world) else {
                status("当前视野不在影像范围内")
                return
            }
            rect = pixels
        }
        analysis.isWorking = true
        setStatus("正在计算坡度…", autoClearAfter: 0)
        let target = raster
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                () -> (CGImage, DEMAnalysis.Statistics, RasterGeoreference, Int, Int)? in
                guard let grid = DEMAnalysis.slope(reader: reader, rect: rect, maxDimension: 1024),
                      let image = DEMAnalysis.image(of: grid) else { return nil }
                return (image, DEMAnalysis.statistics(of: grid), grid.georeference, grid.width, grid.height)
            }.value
            analysis.isWorking = false
            guard let result else {
                status("这一块算不出坡度（范围太小，或数据没有高程）")
                return
            }
            let (image, statistics, georeference, width, height) = result
            analysis.slopeStatistics = statistics
            let source = ImageTileSource(
                image: image,
                georeference: georeference,
                pixelWidth: width,
                pixelHeight: height
            )
            addLayer(makeLayer(
                analysisSource: source,
                name: "坡度 · \(scope.title)",
                sourceID: "analysis|slope|\(target.id)|\(scope.rawValue)",
                detail: String(
                    format: "坡度 %@ · 平均 %.1f° · 最大 %.1f°",
                    scope.title, statistics.mean, statistics.maximum
                )
            ))
            status("坡度图已叠加（平均 \(String(format: "%.1f", statistics.mean))°）")
        }
    }

    // MARK: - 土方量

    /// 用当前选中的测量（面 / 圆）当范围算土方量。
    func calculateVolumeFromSelection() {
        guard let reader = analysisReader else {
            status("先打开一份影像，再算土方量")
            return
        }
        guard let measurement = measurements.selectedMeasurement,
              let ring = volumeRing(of: measurement), ring.count >= 3 else {
            status("先画一块面积或用「画圆」，再在列表里选中它")
            return
        }
        guard let polygon = pixels(of: ring, reader: reader) else {
            status("这块范围不在影像上")
            return
        }
        runVolume(reader: reader, polygon: polygon, title: measurement.exportName)
    }

    /// 进入「在视图上框选范围」算土方量。
    func pickVolumeBoundsFromView() {
        guard analysisReader != nil else {
            status("先打开一份影像，再算土方量")
            return
        }
        showAnalysisSheet = false
        canvas.boundsPickCancel = { [weak self] in
            guard let self else { return }
            self.canvas.boundsPickCancel = nil
            self.showAnalysisSheet = true
        }
        canvas.boundsPicker = { [weak self] bounds in
            guard let self else { return }
            self.canvas.boundsPickCancel = nil
            self.canvas.boundsPicker = nil
            self.showAnalysisSheet = true
            self.calculateVolume(over: bounds)
        }
        setStatus("在画布上拖出一个矩形，松手即按这个范围算土方量（Esc 取消）", autoClearAfter: 8)
    }

    /// 用一块经纬度范围算土方量（框选回来的范围走这里）。
    func calculateVolume(over bounds: GeoBounds) {
        guard let reader = analysisReader else { return }
        let corners = [
            GeoCoordinate(longitude: bounds.west, latitude: bounds.north),
            GeoCoordinate(longitude: bounds.east, latitude: bounds.north),
            GeoCoordinate(longitude: bounds.east, latitude: bounds.south),
            GeoCoordinate(longitude: bounds.west, latitude: bounds.south),
        ]
        guard let polygon = pixels(of: corners, reader: reader) else {
            status("这块范围不在影像上")
            return
        }
        runVolume(reader: reader, polygon: polygon, title: "框选范围")
    }

    private func volumeRing(of measurement: GeoMeasurement) -> [GeoCoordinate]? {
        switch measurement.kind {
        case .area:
            return measurement.points
        case .circle:
            guard let center = measurement.circleCenter,
                  let radius = measurement.circleRadius, radius > 0 else { return nil }
            return Geodesy.circleRing(center: center, radius: radius, samples: 72)
        case .point, .distance, .annotation:
            return nil
        }
    }

    private func runVolume(reader: RasterSampleReader, polygon: [CGPoint], title: String) {
        guard let base = analysis.baseElevation else {
            status("基准高程填一个数字（例如 12.5）")
            return
        }
        analysis.isWorking = true
        setStatus("正在计算土方量…", autoClearAfter: 0)
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DEMAnalysis.volume(reader: reader, polygon: polygon, baseElevation: base)
            }.value
            analysis.isWorking = false
            guard let result else {
                status("这块范围里没有可读的高程")
                return
            }
            analysis.volume = result
            status("土方量（\(title)）：挖 \(Self.volumeText(result.cutVolume)) · 填 \(Self.volumeText(result.fillVolume))")
        }
    }

    static func volumeText(_ cubicMeters: Double) -> String {
        let magnitude = abs(cubicMeters)
        if magnitude >= 1_000_000 {
            return String(format: "%.2f 百万 m³", cubicMeters / 1_000_000)
        }
        if magnitude >= 10_000 {
            return String(format: "%.2f 万 m³", cubicMeters / 10_000)
        }
        return String(format: "%.1f m³", cubicMeters)
    }

    // MARK: - 两期差异

    /// 可以作为「另一期」来对比的影像层（基准影像之外的影像层）。
    var comparableRasterLayers: [MapLayer] {
        let baseReader = analysisReader
        return layers.filter { layer in
            guard layer.kind == .raster,
                  layer.source is RasterTileSource || layer.source is ImageTileSource else { return false }
            guard let reader = RasterSampleReader.open(url: URL(fileURLWithPath: layer.sourceID)) else {
                return false
            }
            guard let baseReader else { return true }
            return reader.fileURL != baseReader.fileURL
        }
    }

    /// 以基准影像减另一层影像，把结果作为叠加层加上去。
    func addDifferenceLayer(against layerID: String) {
        guard let base = analysisReader else {
            status("先打开一份影像作为第一期")
            return
        }
        guard let other = layers.first(where: { $0.id == layerID }),
              let otherReader = RasterSampleReader.open(url: URL(fileURLWithPath: other.sourceID)) else {
            status("这一层不是可比较的影像")
            return
        }
        analysis.isWorking = true
        setStatus("正在计算两期差异…", autoClearAfter: 0)
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                RasterDifference.compute(first: base, second: otherReader)
            }.value
            analysis.isWorking = false
            guard let result else {
                status("两份影像没有共同覆盖范围，或认不出地理参考")
                return
            }
            let source = ImageTileSource(
                image: result.image,
                georeference: result.georeference,
                pixelWidth: result.width,
                pixelHeight: result.height
            )
            addLayer(makeLayer(
                analysisSource: source,
                name: "差异 · \(other.name)",
                sourceID: "analysis|difference|\(other.sourceID)",
                detail: String(
                    format: "差异 %@（蓝 = 变低 %.2f，红 = 变高 %.2f）",
                    other.name, result.minimumDifference, result.maximumDifference
                )
            ))
            let summary = String(
                format: "差异图已叠加：平均 %+.2f，最大 +%.2f，最小 %.2f（%d 个采样点）",
                result.meanDifference, result.maximumDifference,
                result.minimumDifference, result.comparedSamples
            )
            analysis.message = summary
            setStatus(summary, autoClearAfter: 8)
        }
    }

    // MARK: - 工具

    /// 由「内存影像」造一层（坡度图 / 差异图这类即时算出来的结果）。
    func makeLayer(
        analysisSource source: ImageTileSource,
        name: String,
        sourceID: String,
        detail: String
    ) -> MapLayer {
        MapLayer(
            id: UUID().uuidString,
            sourceID: sourceID,
            kind: .raster,
            name: name,
            source: source,
            sourceKey: "\(sourceID)#\(source.worldRect)",
            tileSize: source.tileSize,
            zoomRange: source.zoomRange,
            followsDisplayScale: false,
            maximumDataZoom: source.maximumDataZoom,
            memoryLimitBytes: TileCacheBudget.bytes(for: .raster),
            maxConcurrentRequests: 8,
            fitRect: source.worldRect,
            isAnchor: false,
            detail: detail
        )
    }

    private func status(_ message: String) {
        setStatus(message, autoClearAfter: 8)
    }
}
