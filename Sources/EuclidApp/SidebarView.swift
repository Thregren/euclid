import SwiftUI
import TileKit

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: selection) {
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
