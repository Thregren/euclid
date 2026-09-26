import SwiftUI
import TileKit

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
