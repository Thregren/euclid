import SwiftUI
import TileKit

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List(selection: selection) {
            Section {
                if model.datasets.isEmpty && model.rasters.isEmpty {
                    Text(model.isScanning ? "正在扫描…" : "尚未打开数据集")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    // 点一下 = 把这份数据设为「基准层」（测量与相机以它为准）；
                    // 想叠加显示就用上面的「添加本地数据为图层」。
                    ForEach(model.datasets) { dataset in
                        DatasetRow(dataset: dataset)
                            .tag(dataset.id)
                            .help("设为当前数据（基准层）；要叠加显示请用「添加本地数据为图层」")
                    }
                    ForEach(model.rasters) { raster in
                        RasterRow(raster: raster)
                            .tag(raster.id)
                            .help("设为当前数据（基准层）；要叠加显示请用「添加本地数据为图层」")
                    }
                }
            } header: {
                // HIG：边栏底部不放关键操作（窗口下沿常被挡），把入口放到区块标题上。
                HStack {
                    Text("可用数据")
                        .help("点一条即把它设为基准层；叠加显示请用右侧「图层」面板的「插入图层」")
                    Spacer()
                    Button {
                        model.promptForRaster()
                    } label: {
                        Image(systemName: "photo.badge.plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .help("打开单幅影像（GeoTIFF / TIFF / 图片，⌘⇧O）")
                    .accessibilityLabel("打开单幅影像")
                    Button {
                        model.promptForFolder()
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .help("打开瓦片目录（⌘O）")
                    .accessibilityLabel("打开瓦片目录")
                }
            }

            if let rootFolder = model.rootFolder {
                Section("位置") {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(rootFolder.lastPathComponent, systemImage: "folder")
                            .font(.callout)
                        Text(rootFolder.path(percentEncoded: false))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(3)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 2)
                }
            }

            if model.recentFolders.count > 1 {
                Section("最近打开") {
                    ForEach(model.recentFolders.dropFirst(), id: \.self) { url in
                        Button {
                            model.open(url)
                        } label: {
                            Label {
                                Text(url.lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } icon: {
                                Image(systemName: "clock.arrow.circlepath")
                            }
                            .font(.callout)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// 不透明度一行：标签 + 滑杆 + 百分比（HIG：滑杆配实时数值）。
    private func opacityRow(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Slider(value: value, in: 0...1)
                .controlSize(.small)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }

    /// 选在线数据源时顺带打开在线底图，省一步；下载面板与这里共用同一个 `sourceID`。
    private var onlineSourceBinding: Binding<String> {
        Binding(
            get: { model.download.sourceID },
            set: { id in
                model.download.sourceID = id
                model.usesOnlineBasemap = true
            }
        )
    }

    private var selection: Binding<TileDataset.ID?> {
        Binding(
            get: { model.selectedSourceID },
            set: { model.selectSource($0) }
        )
    }
}

/// 单幅影像一行：像素尺寸 + 地面分辨率（或未配准提示）。
private struct RasterRow: View {
    let raster: RasterDataset

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "photo")
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(raster.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        guard raster.isGeoreferenced else { return "\(raster.pixelSizeText) · 未配准" }
        guard let gsd = raster.groundSampleDistance else { return raster.pixelSizeText }
        let resolution = gsd >= 1
            ? String(format: "%.2f 米/像素", gsd)
            : String(format: "%.1f 厘米/像素", gsd * 100)
        return "\(raster.pixelSizeText) · \(resolution)"
    }
}

private struct DatasetRow: View {
    let dataset: TileDataset

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(dataset.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("z\(dataset.zoomRange.lowerBound)–z\(dataset.zoomRange.upperBound) · \(dataset.layout.tileSize)px")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 一层：名称、显示开关、不透明度、移除。
private struct LayerRow: View {
    @Environment(AppModel.self) private var model
    let layer: MapLayer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                Text(layer.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if layer.isAnchor {
                    Text("基准")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    model.setVisible(!layer.isVisible, of: layer.id)
                } label: {
                    Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                }
                .buttonStyle(.plain)
                .help(layer.isVisible ? "隐藏这一层" : "显示这一层")
                Button {
                    model.removeLayer(layer.id)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .help("移除这一层")
            }
            HStack(spacing: 8) {
                Slider(value: Binding(
                    get: { layer.opacity },
                    set: { model.setOpacity(of: layer.id, to: $0) }
                ), in: 0...1)
                .controlSize(.small)
                Text("\(Int((layer.opacity * 100).rounded()))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            Text(layer.detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch layer.kind {
        case .dataset: return "square.stack.3d.up"
        case .raster: return "photo"
        case .online: return "globe"
        }
    }
}
