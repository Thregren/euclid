import SwiftUI
import TileKit

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
