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
        .navigationTitle(model.selectedDataset?.name ?? "尺规")
        .navigationSubtitle(subtitle)
        .inspector(isPresented: $model.showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
        }
        .toolbar { toolbarContent }
        .task {
            model.activateInitialDataset()
        }
    }

    private var subtitle: String {
        guard let dataset = model.selectedDataset else { return "未打开数据集" }
        return "z\(dataset.zoomRange.lowerBound)–z\(dataset.zoomRange.upperBound) · \(dataset.layout.tileSize)px"
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
        }

        ToolbarItemGroup(placement: .primaryAction) {
            toolPicker

            Button {
                model.clearMeasurements()
            } label: {
                Label("清除测量", systemImage: "trash")
            }
            .help("清除所有测量")
            .disabled(!model.measurements.hasContent)

            exportMenu

            Button {
                model.canvas.zoomOut()
            } label: {
                Label("缩小", systemImage: "minus.magnifyingglass")
            }
            .help("缩小（⌘-）")
            .disabled(model.selectedDataset == nil)

            Button {
                model.canvas.zoomIn()
            } label: {
                Label("放大", systemImage: "plus.magnifyingglass")
            }
            .help("放大（⌘=）")
            .disabled(model.selectedDataset == nil)

            Button {
                model.canvas.fit()
            } label: {
                Label("适配窗口", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help("适配窗口（⌘0）")
            .disabled(model.selectedDataset == nil)

            Toggle(isOn: Bindable(model).showTileGrid) {
                Label("瓦片网格", systemImage: "grid")
            }
            .help("显示瓦片网格（⌘G）")

            Toggle(isOn: Bindable(model).showInspector) {
                Label("检查器", systemImage: "sidebar.right")
            }
            .help("显示检查器（⌘⌥I）")
        }
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

    private var exportMenu: some View {
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
        } label: {
            Label("导出测量结果", systemImage: "square.and.arrow.up")
        }
        .help("导出或复制测量结果")
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

            if model.selectedDataset != nil {
                MapControls()
                    .padding(.leading, 16)
                    .padding(.bottom, 16)
                    .transition(.opacity)

                if let hint = toolHint {
                    Text(hint)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
                        .padding(.bottom, 16)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
        .overlay {
            if model.selectedDataset == nil {
                EmptyStateView()
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

    private var toolHint: String? {
        model.measurements.tool.hint(draftCount: model.measurements.draft.count)
    }
}

struct MapControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
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
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 34)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
            )

            ScaleBarView(metersPerPoint: model.viewport.metersPerPoint)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
                )
        }
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
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
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
