import SwiftUI
import TileKit

/// 检查器里的「可用数据」。
///
/// 这一份原先在左侧边栏，改版后左栏留给图层（照 Pixelmator Pro 的分工），
/// 数据源列表就搬到右栏：点一条把它设为**基准层**（测量、存档与相机尺度以它为准），
/// 想在画面上叠加显示则用左栏「图层」面板的 ＋ 添加。
struct DataSourceSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            if model.datasets.isEmpty && model.rasters.isEmpty {
                Text(model.isScanning ? "正在扫描…" : "尚未打开数据集")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.datasets) { dataset in
                    Button {
                        model.selectSource(dataset.id)
                    } label: {
                        DataSourceRow(
                            name: dataset.name,
                            detail: "z\(dataset.zoomRange.lowerBound)–z\(dataset.zoomRange.upperBound)"
                                + " · \(dataset.layout.tileSize)px",
                            symbol: "square.stack.3d.up.fill",
                            isSelected: model.selectedSourceID == dataset.id
                        )
                    }
                    .buttonStyle(.plain)
                    .help("设为当前数据（基准层）；要叠加显示请用左侧「图层」面板的 ＋")
                }
                ForEach(model.rasters) { raster in
                    Button {
                        model.selectSource(raster.id)
                    } label: {
                        DataSourceRow(
                            name: raster.name,
                            detail: rasterDetail(raster),
                            symbol: "photo",
                            isSelected: model.selectedSourceID == raster.id
                        )
                    }
                    .buttonStyle(.plain)
                    .help("设为当前数据（基准层）；要叠加显示请用左侧「图层」面板的 ＋")
                }
            }
        } header: {
            HStack {
                Text("可用数据")
                Spacer()
                Button {
                    model.promptForRaster()
                } label: {
                    Image(systemName: "photo.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("打开单幅影像（GeoTIFF / TIFF / 图片，⌘⇧O）")
                Button {
                    model.promptForFolder()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("打开瓦片目录（⌘O）")
            }
        }
    }

    /// 单幅影像的副标题：像素尺寸 + 地面分辨率（或「未配准」）。
    private func rasterDetail(_ raster: RasterDataset) -> String {
        guard raster.isGeoreferenced else { return "\(raster.pixelSizeText) · 未配准" }
        guard let gsd = raster.groundSampleDistance else { return raster.pixelSizeText }
        let resolution = gsd >= 1
            ? String(format: "%.2f 米/像素", gsd)
            : String(format: "%.1f 厘米/像素", gsd * 100)
        return "\(raster.pixelSizeText) · \(resolution)"
    }
}

/// 检查器里的「在线底图」。
///
/// 数据源、密钥与坐标基准与下载面板共用同一份参数（改哪边都是同一套），
/// 因此这里的改动会立刻作用到正在看的底图上：切源、填密钥、换基准都会重新装配在线那一层。
/// 基准这一项在上一轮界面重排时跟着侧栏一起丢了，这里补回来——高德 / 腾讯的底图不选基准，
/// 与 WGS84 的正射影像叠加会差几百米。
struct OnlineBasemapSection: View {
    @Environment(AppModel.self) private var model
    @State private var keyDraft = ""

    var body: some View {
        Section("在线底图") {
            Picker("数据源", selection: sourceBinding) {
                ForEach(TileSourceTemplate.presets) { preset in
                    Text(preset.name).tag(preset.id)
                }
            }

            if model.download.needsKey {
                LabeledContent("密钥") {
                    HStack(spacing: 6) {
                        TextField("tk", text: $keyDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(applyKey)
                        Button("应用", action: applyKey)
                            .controlSize(.small)
                    }
                }
                Text("天地图等数据源需要开发者密钥；密钥只放在内存里，退出程序后需要重填。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Picker("坐标基准", selection: Bindable(model.download).datum) {
                ForEach(Datum.allCases) { datum in
                    Text(datum.shortTitle).tag(datum)
                }
            }
            .help("在线底图的坐标基准：高德 / 腾讯选 GCJ-02、百度选 BD-09，其余保持 WGS84")

            if let basemap = model.onlineBasemap {
                if basemap.datum != .wgs84 {
                    Label(
                        basemap.offsetHint(at: model.viewport.center),
                        systemImage: "arrow.left.arrow.right"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if !basemap.attribution.isEmpty {
                    Text(basemap.attribution)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                model.showDownloadSheet = true
            } label: {
                ShortcutButtonLabel(title: "下载在线瓦片…", symbol: "square.and.arrow.down", shortcut: "⌘⇧D")
            }
        }
        .onAppear { keyDraft = model.download.key }
    }

    /// 选在线数据源时顺手把底图切到在线，省一步（与下载面板共用同一个 `sourceID`）。
    private var sourceBinding: Binding<String> {
        Binding(
            get: { model.download.sourceID },
            set: { id in
                model.download.sourceID = id
                model.usesOnlineBasemap = true
            }
        )
    }

    private func applyKey() {
        model.download.key = keyDraft
    }
}

/// 最近打开过的目录与影像。
struct RecentDataSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.recentFolders.isEmpty {
            Section("最近打开") {
                ForEach(model.recentFolders, id: \.self) { url in
                    Button {
                        model.open(url)
                    } label: {
                        Label {
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } icon: {
                            Image(systemName: model.rootFolder == url
                                  ? "folder.fill"
                                  : "clock.arrow.circlepath")
                        }
                        .font(.body)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.rootFolder == url ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .help(url.path(percentEncoded: false))
                }
            }
        }
    }
}

/// 数据源一行：图标 + 名称 + 副标题。
private struct DataSourceRow: View {
    let name: String
    let detail: String
    let symbol: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                    .help("这是当前的基准层")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
