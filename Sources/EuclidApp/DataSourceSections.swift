import SwiftUI
import TileKit

/// 最近打开过的目录与影像。
struct RecentDataSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.recentFolders.isEmpty {
            Section {
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
            } header: {
                HStack(spacing: 6) {
                    Text("最近打开")
                    Spacer(minLength: 8)
                    Button("清空") {
                        model.clearRecentFolders()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("清掉这份列表，同时取消下次启动自动打开上次的数据（不会删除任何文件）")
                }
            }
        }
    }
}
