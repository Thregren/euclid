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
        .sheet(isPresented: $model.showTileExportSheet) {
            TileExportSheet()
                .environment(model)
        }
        .task {
            model.activateInitialDataset()
            DebugDownloadScript.runIfRequested(model: model)
            DebugBasemapScript.runIfRequested(model: model)
            DebugExportScript.runIfRequested(model: model)
            DebugTileExportScript.runIfRequested(model: model)
            DebugVerifyScript.runIfRequested(model: model)
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

            basemapMenu
        }

        ToolbarItemGroup(placement: .primaryAction) {
            toolPicker
            exportMenu

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
            Button("从影像生成瓦片…") { model.showTileExportSheet = true }
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

    /// 出图、测量导出与测量存档收在同一个菜单里：
    /// 「把东西拿出去」和「彻底清理 / 彻底保存」都在这一个地方，工具栏也不必堆项。
    private var exportMenu: some View {
        Menu {
            Section("当前视图") {
                Button("快速导出当前视图（含标注）") { model.quickExportView() }
                    .keyboardShortcut("e", modifiers: .command)
                Button("导出当前视图为图片…") { model.exportViewAsImage() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("复制当前视图到剪贴板") { model.copyViewToClipboard() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("在访达中显示导出目录") { model.revealQuickExportFolder() }
            }
            .disabled(!model.hasMapContent)

            Section("测量结果") {
                ForEach(MeasurementExportFormat.textFormats) { format in
                    Button("复制为 \(format.title)") {
                        model.copyMeasurements(as: format)
                    }
                }
                ForEach(MeasurementExportFormat.allCases) { format in
                    Button(exportTitle(for: format)) {
                        model.exportMeasurements(as: format)
                    }
                }
            }

            Section("测量存档") {
                Button("保存测量到文件…") { model.saveMeasurementsToFile() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("从文件载入测量…") { model.loadMeasurementsFromFile() }
                Button("在访达中显示自动存档") { model.revealMeasurementArchive() }
                Text("改动会按数据集 / 影像自动存档，下次打开自动恢复；也可以另存为文件带走吧。")
            }

            Section {
                Button("清除全部测量", role: .destructive) {
                    model.clearMeasurements()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        } label: {
            Label("导出", systemImage: "square.and.arrow.up")
        }
        .help("出图、导出测量结果、保存 / 载入测量存档、清除全部测量")
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
