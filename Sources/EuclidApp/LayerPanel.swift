import SwiftUI
import TileKit

/// 右侧「图层」面板。
///
/// 参照 Pixelmator Pro 的做法：标题行右侧成组放「添加 / 复制 / 更多」，
/// 下面是可拖拽排序、可点选的图层行；选中层的属性（不透明度等）紧跟在下一段。
struct LayerPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            ForEach(model.layers) { layer in
                LayerRow(layer: layer, isSelected: layer.id == model.selectedLayerID)
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectLayer(layer.id) }
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(layer.id == model.selectedLayerID ? Color.accentColor.opacity(0.18) : .clear)
                    )
            }
            if model.layers.isEmpty {
                Text("还没有图层。点标题旁的 ＋ 添加本地数据或在线底图。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 12) {
                Text("图层")
                Spacer()
                addMenu
                Button {
                    if let id = model.selectedLayer?.id { model.duplicateLayer(id) }
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .buttonStyle(.borderless)
                .disabled(model.selectedLayer == nil)
                .help("复制选中的图层")
                moreMenu
            }
        }
    }

    /// ＋：添加图层（在线底图预设 / 已打开的本地数据 / 直接打开新的）。
    private var addMenu: some View {
        Menu {
            Section("在线底图") {
                ForEach(TileSourceTemplate.presets) { preset in
                    Button(preset.name) {
                        model.download.sourceID = preset.id
                        model.usesOnlineBasemap = true
                    }
                }
            }
            Section("本地数据") {
                ForEach(model.rasters) { raster in
                    Button(raster.name) { model.addLayer(model.makeLayer(raster: raster)) }
                }
                ForEach(model.datasets) { dataset in
                    Button(dataset.name) { model.addLayer(model.makeLayer(dataset: dataset)) }
                }
                Divider()
                Button("打开单幅影像…") { model.promptForRaster() }
                Button("打开瓦片目录…") { model.promptForFolder() }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("添加图层：在线底图或本地数据")
    }

    /// ⋯：排序、显示与移除。
    private var moreMenu: some View {
        Menu {
            Button("上移一层") { if let id = model.selectedLayer?.id { model.moveLayer(id, up: true) } }
                .disabled(!model.canMoveSelectedLayer(up: true))
            Button("下移一层") { if let id = model.selectedLayer?.id { model.moveLayer(id, up: false) } }
                .disabled(!model.canMoveSelectedLayer(up: false))
            Divider()
            Button("全部显示") { model.setAllLayersVisible(true) }
            Button("全部隐藏") { model.setAllLayersVisible(false) }
            Divider()
            Button("移除选中的图层", role: .destructive) { model.removeSelectedLayer() }
                .disabled(model.selectedLayer == nil)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("图层排序与显示")
    }
}

/// 一行图层：显示开关 + 图标 + 名称 + 基准标记。
private struct LayerRow: View {
    @Environment(AppModel.self) private var model
    let layer: MapLayer
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.setVisible(!layer.isVisible, of: layer.id)
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(layer.isVisible ? .primary : .tertiary)
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .help(layer.isVisible ? "隐藏这一层" : "显示这一层")

            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(layer.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if layer.isAnchor {
                        Text("基准")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(layer.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text("\(Int((layer.opacity * 100).rounded()))%")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .opacity(layer.isVisible ? 1 : 0.55)
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch layer.kind {
        case .dataset: return "square.stack.3d.up"
        case .raster: return "photo"
        case .online: return "globe"
        }
    }
}

/// 选中层的属性：Pixelmator 里跟在图层列表下面那一段。
struct LayerPropertiesSection: View {
    @Environment(AppModel.self) private var model
    let layer: MapLayer

    var body: some View {
        Section("图层属性") {
            LabeledContent("名称") {
                Text(layer.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            LabeledContent("不透明度") {
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { layer.opacity },
                        set: { model.setOpacity(of: layer.id, to: $0) }
                    ), in: 0...1)
                    Text("\(Int((layer.opacity * 100).rounded()))%")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            LabeledContent("来源", value: layer.detail)
            HStack {
                Button("移除这一层", role: .destructive) { model.removeLayer(layer.id) }
                    .controlSize(.small)
                Spacer()
            }
        }
    }
}
