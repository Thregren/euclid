import SwiftUI
import TileKit

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List(selection: selection) {
            Section("底图") {
                Toggle("叠加在线底图", isOn: $model.usesOnlineBasemap)

                if model.usesOnlineBasemap {
                    Picker("数据源", selection: onlineSourceBinding) {
                        ForEach(TileSourceTemplate.presets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    if let basemap = model.onlineBasemap {
                        if basemap.needsKey {
                            HStack(spacing: 6) {
                                TextField("密钥 tk", text: Bindable(model.download).key)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { model.applyBasemap() }
                                Button("应用") { model.applyBasemap() }
                                    .controlSize(.small)
                            }
                        }
                        Picker("坐标基准", selection: Bindable(model.download).datum) {
                            ForEach(Datum.allCases) { datum in
                                Text(datum.shortTitle).tag(datum)
                            }
                        }
                        .pickerStyle(.menu)
                        .help("底图所在的大地基准：高德 / 腾讯选 GCJ-02、百度选 BD-09，选错会整体差几百米")

                        if basemap.datum != .wgs84 {
                            Text("已按 \(basemap.datum.shortTitle) 对齐：\(basemap.offsetText(at: model.viewport.center))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        opacityRow("底图不透明度", value: $model.onlineLayerOpacity)
                        if let reason = basemap.invalidReason {
                            Label(reason, systemImage: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if !basemap.terms.isEmpty {
                            Text(basemap.terms)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if model.selectedDataset != nil {
                    opacityRow("影像不透明度", value: $model.localLayerOpacity)
                }
            }

            Section {
                if model.datasets.isEmpty {
                    Text(model.isScanning ? "正在扫描…" : "尚未打开数据集")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.datasets) { dataset in
                        DatasetRow(dataset: dataset)
                            .tag(dataset.id)
                    }
                }
            } header: {
                // HIG：边栏底部不放关键操作（窗口下沿常被挡），把入口放到区块标题上。
                HStack {
                    Text("数据源")
                    Spacer()
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
            get: { model.selectedDatasetID },
            set: { model.selectDataset($0) }
        )
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
