import SwiftUI
import TileKit

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        // 版式照 Pixelmator Pro：画布铺满窗口，两侧面板与右侧工具条浮在画布之上，
        // 底部再留一条状态栏。面板之间不挤压画布，因此窗口拉大时看到的始终是整幅影像。
        VStack(spacing: 0) {
            ZStack {
                MapScreen()
                floatingPanels
            }
            StatusBarView()
        }
        // 标题给的是「当前在看什么」；没有内容时留空，避免拿 App 名当标题。
        .navigationTitle(model.hasMapContent ? model.basemapName : "")
        .navigationSubtitle(subtitle)
        .modifier(DebugColorSchemeOverride())
        .toolbar { toolbarContent }
        .sheet(isPresented: $model.showDownloadSheet) {
            DownloadSheet()
                .environment(model)
        }
        .sheet(isPresented: $model.showTileExportSheet) {
            TileExportSheet()
                .environment(model)
        }
        .sheet(isPresented: $model.showTileServerSheet) {
            TileServerSheet()
                .environment(model)
        }
        .task {
            model.activateInitialDataset()
            DebugDownloadScript.runIfRequested(model: model)
            DebugBasemapScript.runIfRequested(model: model)
            DebugExportScript.runIfRequested(model: model)
            DebugTileExportScript.runIfRequested(model: model)
            DebugVerifyScript.runIfRequested(model: model)
            DebugTileServerScript.runIfRequested(model: model)
            DebugLayerScript.runIfRequested(model: model)
        }
    }

    /// 浮在画布上的三块：左侧图层、右侧检查器、右缘工具条。
    private var floatingPanels: some View {
        HStack(alignment: .top, spacing: 10) {
            LayersPanel()
            Spacer(minLength: 0)
            if model.showInspector {
                InspectorView()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            ToolStrip()
        }
        .padding(.top, 12)
        .padding(.bottom, 12)
        .padding(.leading, 14)
        .padding(.trailing, 2)
        .animation(InterfaceStyle.reducesMotion ? nil : .easeInOut(duration: 0.18), value: model.showInspector)
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
            exportMenu

            Toggle(isOn: Bindable(model).showInspector) {
                Label("检查器", systemImage: "sidebar.right")
            }
            .help("显示检查器（⌘⌥I）")
        }
    }

    /// 图层菜单：添加图层、在线底图设置、瓦片工具（参照 Pixelmator 把同类操作收在一个菜单里）。
    private var basemapMenu: some View {
        Menu {
            Section("添加图层") {
                ForEach(TileSourceTemplate.presets) { preset in
                    Button("在线 · \(preset.name)") {
                        model.download.sourceID = preset.id
                        model.usesOnlineBasemap = true
                    }
                }
                ForEach(model.rasters) { raster in
                    Button("本地 · \(raster.name)") { model.addLayer(model.makeLayer(raster: raster)) }
                }
                ForEach(model.datasets) { dataset in
                    Button("本地 · \(dataset.name)") { model.addLayer(model.makeLayer(dataset: dataset)) }
                }
            }
            Divider()
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
            Button("本地瓦片服务…") { model.showTileServerSheet = true }
        } label: {
            Label("图层", systemImage: "square.3.layers.3d")
        }
        .help("添加图层、切换在线底图与瓦片工具（当前：\(model.basemapName)）")
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
            // 画布铺到窗口边缘：浮层的面板与底部状态栏都压在它上面。
            .ignoresSafeArea()

            if model.hasMapContent {
                MapControls()
                    // 左栏浮着「图层」面板，画布左下角要让开它的宽度。
                    .padding(.leading, 14 + InterfaceStyle.layersPanelWidth + 12)
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
                ControlButton(symbol: "minus", help: "缩小（⌘-）") { model.canvas.zoomOut() }
                Divider().frame(height: 18)
                ControlButton(symbol: "plus", help: "放大（⌘=）") { model.canvas.zoomIn() }
                Divider().frame(height: 18)
                ControlButton(symbol: "arrow.up.left.and.arrow.down.right", help: "适配窗口（⌘0）") {
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

/// 最右侧的竖直工具条（照 Pixelmator Pro 的右缘工具栏）。
///
/// 五个工具与「显示瓦片网格 / 适配窗口」都是高频动作，放在画布右缘一点就到；
/// 上排是工具（互斥，当前工具有底色），下排是视图开关。
struct ToolStrip: View {
    @Environment(AppModel.self) private var model
    @State private var hovered: String?

    var body: some View {
        VStack(spacing: 2) {
            ForEach(MapTool.allCases, id: \.self) { tool in
                toolButton(tool)
            }

            Divider()
                .padding(.vertical, 4)

            viewButton(
                id: "grid",
                symbol: "grid",
                title: model.showTileGrid ? "隐藏瓦片网格（⌘G）" : "显示瓦片网格（⌘G）",
                isOn: model.showTileGrid
            ) {
                model.showTileGrid.toggle()
            }

            viewButton(
                id: "fit",
                symbol: "arrow.up.left.and.arrow.down.right",
                title: "适配窗口（⌘0）",
                isOn: false
            ) {
                model.canvas.fit()
            }
        }
        .padding(.vertical, 8)
        .frame(width: InterfaceStyle.toolStripWidth)
        .panelSurface()
    }

    private func toolButton(_ tool: MapTool) -> some View {
        let isActive = model.measurements.tool == tool
        return Button {
            model.measurements.tool = tool
        } label: {
            Image(systemName: tool.symbolName)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(fill(isActive: isActive, id: tool.rawValue))
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(tool.help)
        .accessibilityLabel(tool.title)
        .onHover { hovered = $0 ? tool.rawValue : (hovered == tool.rawValue ? nil : hovered) }
    }

    private func viewButton(
        id: String,
        symbol: String,
        title: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(fill(isActive: isOn, id: id))
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
    }

    /// 底色：当前工具/开关用强调色，指针悬停时给一点灰，其余透明。
    private func fill(isActive: Bool, id: String) -> Color {
        if isActive { return .accentColor }
        if hovered == id { return Color.primary.opacity(0.10) }
        return .clear
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
                .frame(width: 30, height: InterfaceStyle.controlHeight)
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
                ShortcutButtonLabel(title: "选择文件夹…", shortcut: "⌘O")
            }
            .help("选择瓦片目录（⌘O）")
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
