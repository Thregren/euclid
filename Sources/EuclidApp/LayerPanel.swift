import SwiftUI
import TileKit
import UniformTypeIdentifiers

/// 左侧「图层」面板。
///
/// 版式照 Pixelmator Pro 的左栏：标题行右侧成组放「添加 / 复制 / 更多」，
/// 中间是可点选、可**按住拖动排序**的图层行（缩略图 + 名称 + 来源 + 显示开关），
/// 底部是所选层的混合模式、不透明度，以及按名字过滤的搜索框。
///
/// 面板自上而下的顺序 = 图层从最上到最下（画师习惯），模型里存的是「下 → 上」，
/// 二者的换算只在 `AppModel.panelOrder` / `moveLayer(_:toPanelRow:)` 一处做。
struct LayersPanel: View {
    @Environment(AppModel.self) private var model

    /// 搜索框里的名字过滤。
    @State private var query = ""
    /// 搜索框右侧漏斗按钮的种类过滤。
    @State private var kindFilter: LayerKindFilter = .all
    /// 正在被拖动的那一层（拖动期间才认自己的拖放）。
    @State private var draggingID: String?
    /// 当前落点提示（插到哪一行、在该行的上半还是下半）。
    @State private var dropTarget: DropTarget?
    /// 正在改名的图层（右键菜单里的「重命名…」）。
    @State private var renamingLayerID: String?
    @State private var renameText = ""

    /// 行高：拖动落点判断「上半还是下半」也要用它。
    static let rowHeight: CGFloat = 46

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            rows
            Divider()
            footer
        }
        .frame(width: InterfaceStyle.layersPanelWidth)
        .frame(maxHeight: .infinity)
        .panelSurface()
        .alert("重命名图层", isPresented: isRenaming) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) { renamingLayerID = nil }
            Button("重命名") {
                if let id = renamingLayerID { model.renameLayer(id, to: renameText) }
                renamingLayerID = nil
            }
        } message: {
            Text("只改显示名，不影响数据来源。")
        }
    }

    private var isRenaming: Binding<Bool> {
        Binding(
            get: { renamingLayerID != nil },
            set: { if !$0 { renamingLayerID = nil } }
        )
    }

    // MARK: - 标题行

    private var header: some View {
        HStack(spacing: 10) {
            Text("图层")
                .font(.headline)
            Spacer(minLength: 4)
            addMenu
            Button {
                if let id = model.selectedLayer?.id { model.duplicateLayer(id) }
            } label: {
                Image(systemName: "plus.square.on.square")
                    .frame(
                        width: InterfaceStyle.iconButtonHitSize,
                        height: InterfaceStyle.iconButtonHitSize
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(model.selectedLayer == nil)
            .help("复制选中的图层")
            moreMenu
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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
                .frame(
                    width: InterfaceStyle.iconButtonHitSize,
                    height: InterfaceStyle.iconButtonHitSize
                )
                .contentShape(Rectangle())
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
            Button("设为基准层") { if let id = model.selectedLayer?.id { model.setAnchorLayer(id) } }
                .disabled(model.selectedLayer.map { $0.kind == .online } ?? true)
            Divider()
            Button("全部显示") { model.setAllLayersVisible(true) }
            Button("全部隐藏") { model.setAllLayersVisible(false) }
            Divider()
            Button("移除选中的图层", role: .destructive) { model.removeSelectedLayer() }
                .disabled(model.selectedLayer == nil)
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(
                    width: InterfaceStyle.iconButtonHitSize,
                    height: InterfaceStyle.iconButtonHitSize
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("图层排序与显示")
    }

    // MARK: - 图层列表

    private var visibleLayers: [MapLayer] {
        model.panelOrder.filter { layer in
            guard kindFilter.matches(layer.kind) else { return false }
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return true }
            return layer.name.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var rows: some View {
        ScrollView {
            VStack(spacing: 0) {
                if model.layers.isEmpty {
                    placeholder("还没有图层。点标题旁的 ＋ 添加本地数据或在线底图。")
                } else if visibleLayers.isEmpty {
                    placeholder("没有匹配的图层。")
                } else {
                    ForEach(Array(visibleLayers.enumerated()), id: \.element.id) { index, layer in
                        row(layer, at: index)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 一行图层：可点选、可拖动排序（拖到哪一行的上／下半就插到那一侧）。
    private func row(_ layer: MapLayer, at index: Int) -> some View {
        LayerRow(
            layer: layer,
            isSelected: layer.id == model.selectedLayerID,
            thumbnail: model.thumbnails.image(for: layer),
            // 点一下 = 把这份数据设为「当前数据」（本地数据会重建基准层、恢复它自己的测量存档）。
            onSelect: { model.activateLayer(layer.id) }
        )
        .overlay(alignment: .top) {
            if dropTarget == DropTarget(row: index, above: true) { insertionLine }
        }
        .overlay(alignment: .bottom) {
            if dropTarget == DropTarget(row: index, above: false) { insertionLine }
        }
        // 选中手势只挂在「缩略图 + 名称」那块，行尾的勾选框与不透明度要能正常点。
        .contextMenu { contextMenu(for: layer) }
        // 拖动排序：AppKit 的拖放（onDrag / onDrop）比 SwiftUI 的 draggable 更可靠 ——
        // 后者在带按钮的行里经常起不来。载荷走自定义类型，别的应用拖来的东西一律不认。
        .onDrag {
            draggingID = layer.id
            // 拖动排序只改选中态，别顺手把当前数据换掉。
            model.selectLayer(layer.id)
            return LayerDragPayload.provider(for: layer.id)
        }
        .onDrop(
            of: [LayerDragPayload.contentType],
            delegate: LayerDropDelegate(
                row: index,
                model: model,
                draggingID: $draggingID,
                dropTarget: $dropTarget
            )
        )
        .help("按住这一行拖动可以调整叠放顺序（列表最上面 = 画面最上层）")
        .task(id: thumbnailKey(layer)) {
            model.thumbnails.request(
                layer,
                fallbackCenter: WebMercator.normalized(model.viewport.center),
                fallbackZoom: model.viewport.dataZoom
            )
        }
    }

    /// 缩略图的取图键：来源 + 覆盖范围是否已知。
    ///
    /// 范围还没算出来时先不取，等它到位后键一变，`task` 自然会带着真实范围再取一次。
    private func thumbnailKey(_ layer: MapLayer) -> String {
        "\(layer.sourceKey)|\(layer.fitRect == nil ? "unknown" : "known")"
    }

    private var insertionLine: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, 2)
    }

    /// 图层行的右键菜单：改名、复制、设为基准、显示隐藏、上下移、移除。
    ///
    /// 原先这一排操作只能靠面板顶上的 ⋯ 菜单（还得先点中那一行），
    /// 对着哪一层想要什么操作，右键是最直接的路子。
    @ViewBuilder
    private func contextMenu(for layer: MapLayer) -> some View {
        Button("重命名…") {
            renameText = layer.name
            renamingLayerID = layer.id
        }
        Button("复制这一层") { model.duplicateLayer(layer.id) }
        Button(layer.isAnchor ? "已经是基准层" : "设为基准层") {
            model.setAnchorLayer(layer.id)
        }
        .disabled(layer.isAnchor || layer.kind == .online)

        Divider()

        Button(layer.isVisible ? "隐藏这一层" : "显示这一层") {
            model.setVisible(!layer.isVisible, of: layer.id)
        }
        Button("上移一层") { model.moveLayer(layer.id, up: true) }
            .disabled(model.panelOrder.first?.id == layer.id)
        Button("下移一层") { model.moveLayer(layer.id, up: false) }
            .disabled(model.panelOrder.last?.id == layer.id)

        Divider()

        Button("移除这一层", role: .destructive) { model.removeLayer(layer.id) }
    }

    // MARK: - 底部：不透明度 / 搜索

    private var footer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("不透明度")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(percentText(model.selectedLayer?.opacity ?? 1))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("选中层的不透明度：叠加对照时把上层影像淡下去看底图")
            }

            Slider(value: opacityBinding, in: 0...1)
                .controlSize(.small)

            searchField
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05))
        .disabled(model.selectedLayer == nil)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("搜索", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("清空搜索")
            }
            Menu {
                Picker("只显示", selection: $kindFilter) {
                    ForEach(LayerKindFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: kindFilter.symbolName)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(kindFilter == .all ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            .help("按种类过滤：全部 / 本地数据 / 单幅影像 / 在线底图")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
    }

    // MARK: - 绑定

    private var opacityBinding: Binding<Double> {
        Binding(
            get: { model.selectedLayer?.opacity ?? 1 },
            set: { model.setOpacity(of: model.selectedLayer?.id, to: $0) }
        )
    }

    private func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

// MARK: - 搜索框里的种类过滤

private enum LayerKindFilter: String, CaseIterable, Identifiable {
    case all
    case dataset
    case raster
    case online

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部图层"
        case .dataset: return "本地瓦片目录"
        case .raster: return "单幅影像"
        case .online: return "在线底图"
        }
    }

    var symbolName: String {
        switch self {
        case .all: return "line.3.horizontal.decrease.circle"
        case .dataset: return "square.stack.3d.up"
        case .raster: return "photo"
        case .online: return "globe"
        }
    }

    func matches(_ kind: MapLayer.Kind) -> Bool {
        switch self {
        case .all: return true
        case .dataset: return kind == .dataset
        case .raster: return kind == .raster
        case .online: return kind == .online
        }
    }
}

// MARK: - 拖动排序

/// 拖动载荷：面板内部自己约定一个前缀。
///
/// 走自定义类型（`Resources/Info.plist` 里声明成「导出的类型」）而不是纯文本，
/// 这样只有本应用自己面板里拖出来的东西才会被接住：文件、文字、图片拖进来都不会误判成图层。
private enum LayerDragPayload {
    static let contentType = UTType(exportedAs: "com.thregren.euclid.layer-id")

    static func provider(for id: String) -> NSItemProvider {
        NSItemProvider(
            item: Data(id.utf8) as NSData,
            typeIdentifier: contentType.identifier
        )
    }
}

/// 落点提示：插到第 `row` 行的上方（`above`）还是下方。
private struct DropTarget: Equatable {
    var row: Int
    var above: Bool
}

/// 图层行的拖放代理：拖动到哪一行的上／下半，就插到那一侧。
private struct LayerDropDelegate: DropDelegate {
    let row: Int
    let model: AppModel
    @Binding var draggingID: String?
    @Binding var dropTarget: DropTarget?

    func validateDrop(info: DropInfo) -> Bool {
        draggingID != nil && info.hasItemsConforming(to: [LayerDragPayload.contentType])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard draggingID != nil else { return nil }
        dropTarget = DropTarget(row: row, above: isUpperHalf(info))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dropTarget?.row == row { dropTarget = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let above = isUpperHalf(info)
        defer {
            dropTarget = nil
            draggingID = nil
        }
        guard let draggingID else { return false }
        model.moveLayer(draggingID, toPanelRow: above ? row : row + 1)
        model.selectLayer(draggingID)
        return true
    }

    private func isUpperHalf(_ info: DropInfo) -> Bool {
        info.location.y < LayersPanel.rowHeight / 2
    }
}

// MARK: - 一行

/// 一行图层：缩略图 + 名称 + 来源 + 显示开关。
private struct LayerRow: View {
    @Environment(AppModel.self) private var model
    let layer: MapLayer
    let isSelected: Bool
    let thumbnail: CGImage?
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            // 只有「缩略图 + 名称 + 来源」这块响应点击选中，
            // 行尾的不透明度与勾选框要能各点各的。
            HStack(spacing: 9) {
                thumbnailView

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(layer.name)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if layer.isAnchor {
                            anchorBadge
                        }
                    }
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)

            // 不透明度只在非 100% 时占一格：它是「修饰」而不是主信息，
            // 挤进副标题会把「512px」这类关键信息截掉（11 点下副标题只剩 90 点宽）。
            if layer.opacity < 0.999 {
                Text("\(Int((layer.opacity * 100).rounded()))%")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
                    .help("这一层的不透明度")
            }

            visibilityToggle
        }
        .padding(.horizontal, 8)
        .frame(height: LayersPanel.rowHeight)
        .background(
            // 选中底比之前的 0.20 略淡：11 点的二级文字压在强调色底上时，
            // 底色越淡对比度越好（实测 0.20 → 3.65:1，0.15 → 4.0:1），
            // 选中态本身还靠那圈描边与缩略图一起表达。
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isSelected ? 0.35 : 0), lineWidth: 1)
        )
        .opacity(layer.isVisible ? 1 : 0.5)
    }

    /// 缩略图：拿到来源里的一张瓦片就画出来，取不到就退回类型图标。
    private var thumbnailView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.07))
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tint)
            }
        }
        .frame(width: 36, height: 26)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(.separator.opacity(0.7), lineWidth: 0.5)
        )
    }

    /// 「基准」标记。
    ///
    /// 这是一条**有信息量**的标签（哪一层是测量与相机的依据），所以不能只画成浅灰小字：
    /// 之前是 10 点 + 三级色，实测对比度只有 1.9:1（浅色）/ 2.3:1（深色），远低于 HIG 对
    /// 17 点以下文字要求的 4.5:1。现在做成带底的小胶囊：字号 11 点、二级文字色，
    /// 形状本身也能在缩略图、名称旁边一眼看到（不靠颜色单独传达）。
    private var anchorBadge: some View {
        Text("基准")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous).fill(Color.primary.opacity(0.10))
            )
    }

    private var visibilityToggle: some View {
        Button {
            model.setVisible(!layer.isVisible, of: layer.id)
        } label: {
            Image(systemName: layer.isVisible ? "checkmark.square.fill" : "square")
                .font(.system(size: 14))
                // 未勾选的方框也用二级色：三级色在浅色下只有 1.9:1，控件本身不该这么淡。
                .foregroundStyle(layer.isVisible ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(
                    width: InterfaceStyle.iconButtonHitSize,
                    height: InterfaceStyle.iconButtonHitSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(layer.isVisible ? "隐藏这一层" : "显示这一层")
        .accessibilityLabel(layer.isVisible ? "隐藏这一层" : "显示这一层")
    }

    /// 副标题：来源说明（层级范围、像素尺寸之类）。
    private var subtitle: String { layer.detail }

    private var symbol: String {
        switch layer.kind {
        case .dataset: return "square.stack.3d.up"
        case .raster: return "photo"
        case .online: return "globe"
        }
    }
}

/// 选中层的属性：跟在检查器里的「图层属性」那一段。
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
