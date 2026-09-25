import SwiftUI
import TileKit

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            MapScreen()
        }
        // 标题给的是「当前在看什么」；没有内容时留空，避免拿 App 名当标题。
        .navigationTitle(model.hasMapContent ? model.basemapName : "")
        .navigationSubtitle(subtitle)
        .inspector(isPresented: $model.showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $model.showDownloadSheet) {
            DownloadSheet()
                .environment(model)
        }
        .task {
            model.activateInitialDataset()
            DebugDownloadScript.runIfRequested(model: model)
            DebugBasemapScript.runIfRequested(model: model)
            DebugExportScript.runIfRequested(model: model)
        }
    }

    private var subtitle: String {
        if let basemap = model.onlineBasemap {
            let attribution = basemap.attribution.isEmpty ? "" : " · \(basemap.attribution)"
            return "在线底图 z0–z\(basemap.zoomRange.upperBound)\(attribution)"
        }
        if let dataset = model.selectedDataset {
            return "z\(dataset.zoomRange.lowerBound)–z\(dataset.zoomRange.upperBound) · \(dataset.layout.tileSize)px"
        }
        if let raster = model.selectedRaster {
            let shape = raster.isGeoreferenced ? raster.crsName : "未配准"
            return "单幅影像 \(raster.pixelSizeText) · \(shape)"
        }
        return "未打开数据集"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                model.promptForFolder()
            } label: {
                Label("打开瓦片目录", systemImage: "folder")
            }
            .help("打开瓦片目录（⌘O）")

            Button {
                model.showDownloadSheet = true
            } label: {
                Label("下载在线瓦片", systemImage: "square.and.arrow.down.on.square")
            }
            .help("从在线瓦片源下载指定范围的瓦片（⌘⇧D）")

            basemapMenu
        }

        ToolbarItemGroup(placement: .primaryAction) {
            toolPicker

            Button {
                model.canvas.zoomOut()
            } label: {
                Label("缩小", systemImage: "minus.magnifyingglass")
            }
            .help("缩小（⌘-）")
            .disabled(!model.hasMapContent)

            Button {
                model.canvas.zoomIn()
            } label: {
                Label("放大", systemImage: "plus.magnifyingglass")
            }
            .help("放大（⌘=）")
            .disabled(!model.hasMapContent)

            Button {
                model.canvas.fit()
            } label: {
                Label("适配窗口", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help("适配窗口（⌘0）")
            .disabled(!model.hasMapContent)

            measurementMenu

            Toggle(isOn: Bindable(model).showInspector) {
                Label("检查器", systemImage: "sidebar.right")
            }
            .help("显示检查器（⌘⌥I）")
        }
    }

    /// 底图切换：本地数据集或某个在线瓦片源。
    private var basemapMenu: some View {
        Menu {
            Picker("底图", selection: Bindable(model).usesOnlineBasemap) {
                Text("本地数据").tag(false)
                Text("在线底图").tag(true)
            }
            .pickerStyle(.inline)
            Divider()
            Picker("在线数据源", selection: Binding(
                get: { model.download.sourceID },
                set: { id in
                    model.download.sourceID = id
                    model.usesOnlineBasemap = true
                }
            )) {
                ForEach(TileSourceTemplate.presets) { preset in
                    Text(preset.name).tag(preset.id)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("显示瓦片网格", isOn: Bindable(model).showTileGrid)
                .keyboardShortcut("g", modifiers: .command)
            Divider()
            Button("下载在线瓦片…") { model.showDownloadSheet = true }
        } label: {
            Label("底图", systemImage: model.onlineBasemap == nil ? "square.stack.3d.up" : "globe")
        }
        .help("当前底图：\(model.basemapName)")
    }

    private var toolPicker: some View {
        Picker("工具", selection: Binding(
            get: { model.measurements.tool },
            set: { model.measurements.tool = $0 }
        )) {
            ForEach(MapTool.allCases, id: \.self) { tool in
                Text(tool.title)
                    .tag(tool)
                    .help(tool.help)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 232)
        .help("工具（⌘1–⌘5，或按 \(MapTool.allCases.map(\.shortcut).joined(separator: " / "))）：浏览、点坐标、测距、测面积、画圆")
    }

    /// 测量相关操作：复制 / 导出 / 清除。收在一个菜单里，避免工具栏堆项。
    private var measurementMenu: some View {
        Menu {
            Section("复制到剪贴板") {
                ForEach(MeasurementExportFormat.textFormats) { format in
                    Button("复制为 \(format.title)") {
                        model.copyMeasurements(as: format)
                    }
                }
            }
            Section("导出文件") {
                ForEach(MeasurementExportFormat.allCases) { format in
                    Button(exportTitle(for: format)) {
                        model.exportMeasurements(as: format)
                    }
                }
            }
            Section {
                Button("清除全部测量", role: .destructive) {
                    model.clearMeasurements()
                }
            }
        } label: {
            Label("测量结果", systemImage: "ruler")
        }
        .help("导出、复制或清除测量结果")
        .disabled(!model.measurements.hasContent)
    }

    private func exportTitle(for format: MeasurementExportFormat) -> String {
        switch format {
        case .excel: return "导出为 Excel 表格 (.xlsx)…"
        default: return "导出为 \(format.title)…"
        }
    }
}

struct MapScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            TileMapView(
                controller: model.canvas,
                viewport: model.viewport,
                measurements: model.measurements,
                showGrid: model.showTileGrid
            )
            .ignoresSafeArea(edges: .bottom)

            if model.hasMapContent {
                MapControls()
                    .padding(.leading, 16)
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
        .overlay {
            if !model.hasMapContent {
                EmptyStateView()
            } else if let message = model.loadingMessage {
                LoadingOverlay(message: message)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBarView()
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url)
            return true
        }
    }

}

struct MapControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // 缩放与比例尺合成**一张**控制卡：左下角原本叠了两张玻璃卡 + 状态栏，三层信息挤在
        // 同一个角落，视觉上很重。合成一张后角落只剩「控制卡 + 状态栏」两层，也少一层材质。
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 2) {
                ControlButton(symbol: "minus", help: "缩小") { model.canvas.zoomOut() }
                Divider().frame(height: 18)
                ControlButton(symbol: "plus", help: "放大") { model.canvas.zoomIn() }
                Divider().frame(height: 18)
                ControlButton(symbol: "arrow.up.left.and.arrow.down.right", help: "适配窗口") {
                    model.canvas.fit()
                }
                Divider().frame(height: 18)
                Text("z\(model.viewport.dataZoom)")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 34)
                    .padding(.horizontal, 4)
            }

            ScaleBarView(metersPerPoint: model.viewport.metersPerPoint)
                .padding(.horizontal, 8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .controlSurface()
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

struct ControlButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .frame(width: 28, height: InterfaceStyle.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
        .help(help)
    }
}

/// 画布还没内容时的加载态：转圈加一句说明，别让用户对着空白猜。
struct LoadingOverlay: View {
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .controlSurface()
        .allowsHitTesting(false)
    }
}

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.tint)
            Text("打开本地瓦片")
                .font(.title2.weight(.semibold))
            Text("选择包含 `<z>/<x>/<y>` 目录结构的瓦片文件夹，\n支持 WebODM、ODM 等标准 XYZ 输出。\n也可以直接把文件夹拖到这里。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                model.promptForFolder()
            } label: {
                Text("选择文件夹…")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)

            if let statusMessage = model.statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
