import SwiftUI
import TileKit

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if model.hasMapContent {
                CursorCoordinateSection()
                MeasurementSection()
                layersSection
                datasetSection
                if let extent = model.extent {
                    extentSection(extent)
                }
                viewSection
            } else {
                Section {
                    ContentUnavailableView(
                        "未选择数据集",
                        systemImage: "square.stack.3d.up.slash",
                        description: Text("打开一个瓦片目录，或在侧栏切到在线底图，这里会显示坐标、测量结果与数据源信息。")
                    )
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(.background)
    }

    // MARK: - 数据集信息

    /// 图层信息：本地影像与在线底图各自的不透明度与来源。
    @ViewBuilder
    private var layersSection: some View {
        Section("图层") {
            ForEach(model.layers) { layer in
                LabeledContent(layer.name) {
                    Text("\(percent(layer.opacity))\(layer.isVisible ? "" : " · 已隐藏")\(layer.isAnchor ? " · 基准" : "")")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let basemap = model.onlineBasemap {
                LabeledContent("底图层级", value: "z0 – z\(basemap.zoomRange.upperBound)")
                LabeledContent("坐标基准", value: basemap.datum.title)
                if basemap.datum != .wgs84 {
                    LabeledContent("对齐偏移", value: basemap.offsetText(at: model.viewport.center))
                }
                if !basemap.attribution.isEmpty {
                    LabeledContent("版权", value: basemap.attribution)
                }
                if !basemap.terms.isEmpty {
                    Text(basemap.terms)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    @ViewBuilder
    private var datasetSection: some View {
        if let dataset = model.selectedDataset {
            Section("数据集") {
                LabeledContent("名称") {
                    Text(dataset.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent("层级", value: "z\(dataset.zoomRange.lowerBound) – z\(dataset.zoomRange.upperBound)")
                LabeledContent("瓦片尺寸", value: "\(dataset.layout.tileSize) × \(dataset.layout.tileSize) px")
                LabeledContent("目录结构", value: directoryDescription(dataset.layout))
                LabeledContent("行号基准", value: dataset.layout.rowOrigin == .north ? "XYZ（北起源）" : "TMS（南起源）")
                LabeledContent("坐标基准", value: "WGS84 / Web Mercator")
            }
        } else if let raster = model.selectedRaster {
            Section("单幅影像") {
                LabeledContent("名称") {
                    Text(raster.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent("像素尺寸", value: "\(raster.pixelSizeText) px")
                LabeledContent("坐标基准", value: raster.crsName)
                if let gsd = raster.groundSampleDistance {
                    LabeledContent("地面分辨率", value: gsd >= 1
                        ? String(format: "%.2f 米/像素", gsd)
                        : String(format: "%.1f 厘米/像素", gsd * 100))
                }
                LabeledContent("压缩", value: "\(raster.compression) · \(raster.bitsPerSample) 位"
                    + (raster.hasAlpha ? " · 含 alpha" : ""))
                LabeledContent("文件大小", value: raster.fileSizeText)
                LabeledContent("内建概览", value: raster.hasOverviews ? "有（缩放取低分辨率级）" : "无")
                if let note = raster.placementNote {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func extentSection(_ extent: DatasetExtent) -> some View {
        Section(model.selectedRaster == nil ? "覆盖范围" : "影像范围") {
            LabeledContent("西经 / 东经") {
                Text(String(
                    format: "%.5f … %.5f",
                    extent.boundingBox.southWest.longitude,
                    extent.boundingBox.northEast.longitude
                ))
                .monospacedDigit()
            }
            LabeledContent("南纬 / 北纬") {
                Text(String(
                    format: "%.5f … %.5f",
                    extent.boundingBox.southWest.latitude,
                    extent.boundingBox.northEast.latitude
                ))
                .monospacedDigit()
            }
            if model.selectedRaster == nil {
                LabeledContent("估算瓦片数", value: "\(extent.tileCount)")
            }
        }
    }

    @ViewBuilder
    private var viewSection: some View {
        Section("视图") {
            LabeledContent("中心坐标") {
                Text(CoordinateText.decimal(model.viewport.center, precision: 7))
                    .monospacedDigit()
                    .textSelection(.enabled)
            }
            LabeledContent("缩放层级", value: String(format: "z%.2f", model.viewport.zoomLevel))
            LabeledContent("分辨率") {
                Text(String(format: "%.3f m/px", model.viewport.metersPerPoint))
                    .monospacedDigit()
            }
            LabeledContent("视口瓦片", value: "\(model.viewport.visibleTiles) 片")
            LabeledContent("已缓存", value: "\(model.viewport.loadedTiles) 片")
            if model.viewport.missingTiles > 0 {
                LabeledContent("缺片", value: "\(model.viewport.missingTiles) 片")
            }
        }
    }

    private func directoryDescription(_ layout: TileLayout) -> String {
        switch layout.directoryAxis {
        case .xFirst: return "<z>/<x>/<y>"
        case .yFirst: return "<z>/<y>/<x>"
        }
    }
}
