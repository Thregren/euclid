import SwiftUI
import TileKit

/// 底部状态栏：当前底图、指针坐标、比例尺、层级、瓦片数、提示与下载进度。
struct StatusBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            sourceLabel

            if model.hasMapContent {
                Divider().frame(height: 12)
                coordinateReadout
                Spacer(minLength: 8)
                readout(String(format: "%.3f m/px", model.viewport.metersPerPoint))
                readout("z\(model.viewport.dataZoom)", weight: .medium)
                readout("\(model.viewport.visibleTiles) 片")
                measurementCount
                statusMessage
                downloadProgress
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.separator.opacity(0.6))
                .frame(height: 0.5)
        }
    }

    // MARK: - 左端：当前看的是什么

    @ViewBuilder
    private var sourceLabel: some View {
        if let basemap = model.onlineBasemap {
            Label(basemap.name, systemImage: "globe")
                .font(.subheadline)
                .lineLimit(1)
                .help(basemap.attribution)
        } else if let dataset = model.selectedDataset {
            Label(dataset.name, systemImage: "square.stack.3d.up")
                .font(.subheadline)
                .lineLimit(1)
        } else if let raster = model.selectedRaster {
            Label(raster.name, systemImage: "photo")
                .font(.subheadline)
                .lineLimit(1)
                .help(raster.isGeoreferenced ? raster.crsName : (raster.placementNote ?? ""))
        } else {
            Text(model.statusMessage ?? "就绪")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 中间：坐标读取

    @ViewBuilder
    private var coordinateReadout: some View {
        if let cursor = model.measurements.cursorInfo {
            Label(CoordinateText.decimal(cursor.coordinate), systemImage: "scope")
                .font(.subheadline)
                .monospacedDigit()
            Text(CoordinateText.dms(cursor.coordinate))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } else {
            Text("移动指针查看坐标")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 右端：读数与提示

    private func readout(_ text: String, weight: Font.Weight = .regular) -> some View {
        Text(text)
            .font(.subheadline.weight(weight))
            .foregroundStyle(weight == .medium ? .primary : .secondary)
            .monospacedDigit()
    }

    @ViewBuilder
    private var measurementCount: some View {
        if !model.measurements.measurements.isEmpty {
            Divider().frame(height: 12)
            readout("\(model.measurements.measurements.count) 条测量")
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        if let message = model.statusMessage, model.hasMapContent {
            Divider().frame(height: 12)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.tint)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var downloadProgress: some View {
        if model.download.isRunning, let progress = model.download.progress {
            Divider().frame(height: 12)
            Label("下载 \(progress.completed)/\(progress.total)", systemImage: "arrow.down.circle")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.tint)
        }
    }
}
