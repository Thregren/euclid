import SwiftUI
import TileKit
import UniformTypeIdentifiers

@main
struct EuclidMobileApp: App {
    var body: some Scene {
        WindowGroup {
            MobileWorkspaceView()
        }
    }
}

private struct MobileWorkspaceView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var workspace = MobileWorkspace()
    @State private var showsFiles = false
    @State private var reconnectsFile = false

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack(alignment: .bottomTrailing) {
                    if let raster = workspace.raster {
                        MobileMap(workspace: workspace, raster: raster)
                        measurementPanel(in: geometry)
                    } else if let file = workspace.missingFile {
                        ContentUnavailableView {
                            Label("找不到影像", systemImage: "doc.badge.ellipsis")
                        } description: {
                            Text(file)
                        } actions: {
                            Button("重新选择影像") { chooseFile(reconnect: true) }
                                .buttonStyle(.borderedProminent)
                        }
                    } else if !workspace.isLoading {
                        ContentUnavailableView {
                            Label("打开影像", systemImage: "map")
                        } description: {
                            Text("从「文件」选择 GeoTIFF、TIFF、PNG 或 JPEG。")
                        } actions: {
                            Button("浏览文件") { chooseFile() }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("browseFiles")
                        }
                    }
                    if workspace.isLoading {
                        ProgressView("正在读取影像…")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(uiColor: .secondarySystemBackground))
            .navigationTitle(workspace.raster?.dataset.name ?? "尺规")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { chooseFile() } label: { Label("文件", systemImage: "folder") }
                        .accessibilityIdentifier("openFiles")
                        .disabled(workspace.isLoading)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if workspace.isMeasuring {
                        Menu {
                            Button("撤销最后一点", systemImage: "arrow.uturn.backward", action: workspace.undoPoint)
                                .disabled(workspace.draft.isEmpty)
                            Button("取消测距", systemImage: "xmark", role: .destructive) {
                                workspace.endMeasurement(keep: false)
                            }
                        } label: {
                            Label("测距操作", systemImage: "ellipsis.circle")
                        }
                        Button { workspace.endMeasurement(keep: true) } label: {
                            Label("完成测距", systemImage: "checkmark")
                        }
                        .accessibilityIdentifier("finishDistance")
                        .disabled(workspace.draft.count < 2)
                    } else if workspace.raster?.dataset.isGeoreferenced == true {
                        Button(action: workspace.startMeasuring) { Label("测距", systemImage: "ruler") }
                            .accessibilityIdentifier("startDistance")
                    }
                }
            }
        }
        .task { await workspace.restore() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { workspace.flush() }
        }
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.tiff, .png, .jpeg]) { result in
            switch result {
            case .success(let url):
                let reconnect = reconnectsFile
                Task { await workspace.open(url, reconnect: reconnect) }
            case .failure(let error):
                workspace.errorMessage = error.localizedDescription
            }
        }
        .alert("尺规", isPresented: Binding(
            get: { workspace.errorMessage != nil },
            set: { if !$0 { workspace.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { workspace.errorMessage = nil }
        } message: {
            Text(workspace.errorMessage ?? "")
        }
    }

    private func chooseFile(reconnect: Bool = false) {
        reconnectsFile = reconnect
        showsFiles = true
    }

    private func measurementPanel(in geometry: GeometryProxy) -> some View {
        let spacing: CGFloat = 12
        var width = geometry.size.width
        var bottomPadding = spacing
        if #available(iOS 27.1, *) {
            for region in geometry.reservedRegions(kind: .division, layoutDirectionBehavior: .fixed) {
                if region.frame.height > region.frame.width, region.frame.maxX < width {
                    width = min(width, geometry.size.width - region.frame.maxX)
                } else if region.frame.width >= region.frame.height,
                          geometry.size.height - region.frame.maxY < 110 {
                    bottomPadding = max(bottomPadding, geometry.size.height - region.frame.minY + spacing)
                }
            }
        }
        return VStack(alignment: .leading, spacing: 4) {
            if workspace.isMeasuring {
                Text("测距 · \(workspace.draft.count) 个点")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("draftPointCount")
                if let distance = workspace.distanceText {
                    Text(distance).monospacedDigit().accessibilityIdentifier("draftDistance")
                } else {
                    Text("轻点影像添加测点").font(.footnote).foregroundStyle(.secondary)
                }
            } else if let distance = workspace.distanceText {
                Text("最近一次测距").font(.subheadline.weight(.semibold))
                Text(distance).monospacedDigit().accessibilityIdentifier("savedDistance")
            } else if workspace.raster?.dataset.isGeoreferenced == false {
                Text("未配准影像").font(.subheadline.weight(.semibold))
                Text("地面测距需要地理参考").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(workspace.isMeasuring || workspace.distanceText != nil || workspace.raster?.dataset.isGeoreferenced == false ? 12 : 0)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: max(0, min(280, width - 2 * spacing)), alignment: .trailing)
        .padding(.trailing, spacing)
        .padding(.bottom, bottomPadding)
    }
}
