import SwiftUI
import TileKit

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List(selection: selection) {
            Section("底图") {
                Picker("底图", selection: $model.usesOnlineBasemap) {
                    Text("本地数据").tag(false)
                    Text("在线底图").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)

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
            }

            Section("数据源") {
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                Button {
                    model.promptForFolder()
                } label: {
                    Label("打开瓦片目录…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.bar)
            }
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
                .font(.system(size: 13))
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
