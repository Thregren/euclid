import SwiftUI
import TileKit

/// 右侧检查器：一块浮在画布上的面板（照 Pixelmator Pro 的右栏）。
///
/// 分区顺序也按同一套逻辑：文档（数据源）→ 选中对象（图层属性）→ 任务（测量）→
/// 读数（指针坐标 / 视图）→ 来源详情（覆盖范围、数据集、最近打开）。
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if model.hasMapContent {
                MeasurementSection()
                CursorCoordinateSection()
                if let extent = model.extent {
                    extentSection(extent)
                }
                ViewReadoutsSection()
                datasetSection
            } else {
                Section {
                    Text("打开一个瓦片目录（⌘O）或单幅影像（⌘⇧O），或用左下角「图层」面板的 ＋ 加一层在线底图；"
                         + "这里会显示图层属性、测量结果、指针坐标与数据源信息。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            RecentDataSection()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(width: InterfaceStyle.inspectorPanelWidth)
        .frame(maxHeight: .infinity)
        .clipShape(
            RoundedRectangle(cornerRadius: InterfaceStyle.panelCornerRadius, style: .continuous)
        )
        .panelSurface()
    }

    // MARK: - 数据集信息

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

    private func directoryDescription(_ layout: TileLayout) -> String {
        switch layout.directoryAxis {
        case .xFirst: return "<z>/<x>/<y>"
        case .yFirst: return "<z>/<y>/<x>"
        }
    }
}

/// 检查器里的「视图」读数。
///
/// 单独成视图不是为了让代码好看：这些数字**每个滚轮事件都在变**，
/// 如果它们在 `InspectorView` 的 body 里读，SwiftUI 就得整块重算这个 Form
/// （面板里有几十行），双指拖动就是这么卡起来的。拆出来之后只有这一小节重绘。
struct ViewReadoutsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
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

}
