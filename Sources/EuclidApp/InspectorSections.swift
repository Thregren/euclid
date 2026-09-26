import SwiftUI
import TileKit

/// 按钮标题后面缀上快捷键：界面上的实体按钮要能看出它对应哪个键。
/// （菜单里系统会自动显示快捷键，但检查器里的按钮不会，只能自己标。）
struct ShortcutButtonLabel: View {
    let title: String
    var symbol: String?
    var shortcut: String

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Label(title, systemImage: symbol)
            } else {
                Text(title)
            }
            Text(shortcut)
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

/// 可折叠小节。
///
/// 不用 `DisclosureGroup`：macOS 上它的**标签文字不响应点击**，只有左边那个小三角能点开，
/// 于是「点『顶点坐标』四个字没反应」，看上去就是折叠块点不开。这里整行都是按钮，
/// 行高 22 点、宽度撑满、`contentShape` 覆盖整块，点哪都能开合；三角自己画，展开时转 90°。
struct ExpandableRow<Content: View>: View {
    private let title: String
    @State private var isExpanded: Bool
    private let content: () -> Content

    init(_ title: String, initiallyExpanded: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self._isExpanded = State(initialValue: initiallyExpanded)
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if InterfaceStyle.reducesMotion {
                    isExpanded.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title)
                        .font(.callout)
                    Spacer(minLength: 0)
                }
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "收起「\(title)」" : "展开「\(title)」")
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "已展开" : "已收起")

            if isExpanded {
                content()
                    .padding(.leading, 18)
            }
        }
    }
}

/// 指针坐标分区。
///
/// 单独成视图，是为了让高频更新的指针坐标只重绘这一小块，不影响检查器其余部分。
struct CursorCoordinateSection: View {
    @Environment(AppModel.self) private var model

    @State private var goToLongitude = ""
    @State private var goToLatitude = ""

    var body: some View {
        Section("指针坐标") {
            if let cursor = model.measurements.cursorInfo {
                LabeledContent("经度") {
                    Text(CoordinateText.dms(cursor.coordinate.longitude, axis: .longitude))
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
                LabeledContent("纬度") {
                    Text(CoordinateText.dms(cursor.coordinate.latitude, axis: .latitude))
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
                LabeledContent("十进制") {
                    Text(CoordinateText.decimal(cursor.coordinate, precision: 7))
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
                LabeledContent("瓦片") {
                    Text("z\(cursor.zoom) / \(cursor.tileX) / \(cursor.tileY)")
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
                LabeledContent("瓦片内像素") {
                    Text("\(cursor.pixelX), \(cursor.pixelY)")
                        .monospacedDigit()
                }
                LabeledContent("墨卡托") {
                    Text(CoordinateText.mercator(cursor.coordinate))
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
                Button {
                    model.copyCursorCoordinate()
                } label: {
                    ShortcutButtonLabel(title: "复制坐标", symbol: "doc.on.doc", shortcut: "⌥⌘C")
                }
                .help("复制当前指针坐标（⌥⌘C）")
                // 与「点坐标」工具落的是同一种测量：把指针放到目标上按 P 就好。
                Button {
                    model.dropPointAtCursor()
                } label: {
                    ShortcutButtonLabel(title: "记下这个点", symbol: "mappin.and.ellipse", shortcut: "P")
                }
                .help("把指针所在的坐标记成一个点（快捷键 P），与「点坐标」工具共用同一份测量数据")
            } else {
                Text("把指针移到地图上即可读取坐标；把指针放到目标上按 P 可以记下这个点")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ExpandableRow("跳转到坐标") {
                TextField("经度（十进制度）", text: $goToLongitude)
                    .textFieldStyle(.roundedBorder)
                TextField("纬度（十进制度）", text: $goToLatitude)
                    .textFieldStyle(.roundedBorder)
                Button("跳转") {
                    guard let longitude = Double(goToLongitude.trimmingCharacters(in: .whitespaces)),
                          let latitude = Double(goToLatitude.trimmingCharacters(in: .whitespaces)) else {
                        model.setStatus("坐标格式不正确，请输入十进制度")
                        return
                    }
                    guard (-180...180).contains(longitude) else {
                        model.setStatus("经度应在 -180 到 180 之间")
                        return
                    }
                    guard (-90...90).contains(latitude) else {
                        model.setStatus("纬度应在 -90 到 90 之间")
                        return
                    }
                    model.goToCoordinate(longitude: longitude, latitude: latitude)
                }
                .disabled(goToLongitude.isEmpty || goToLatitude.isEmpty)
            }
        }
    }
}

/// 测量结果分区。
struct MeasurementSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.measurements
        Section {
            if !store.draft.isEmpty {
                draftBlock(store)
            }

            // 新的在最上面：画完一条抬头就能看到它，不用滚到列表底部。
            ForEach(store.measurements.reversed()) { measurement in
                row(measurement, store: store)
            }

            if store.measurements.isEmpty && store.draft.isEmpty {
                Text("选择工具栏中的「测距」「测面积」或「画圆」，在地图上点击即可开始")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if store.hasContent {
                // 「彻底保存」与「彻底清理」明确摆在一起：存档是自动的，另外还能另存为文件带走。
                HStack(spacing: 8) {
                    Button {
                        model.saveMeasurementsToFile()
                    } label: {
                        ShortcutButtonLabel(title: "保存到文件…", shortcut: "⌘S")
                    }
                    .help("把当前测量另存为一个 JSON 文件（⌘S）")
                    Button {
                        model.loadMeasurementsFromFile()
                    } label: {
                        ShortcutButtonLabel(title: "从文件载入…", shortcut: "⌥⌘O")
                    }
                    .help("从文件里追加测量（⌥⌘O）")
                    Spacer()
                    Button(role: .destructive) {
                        model.clearMeasurements()
                    } label: {
                        ShortcutButtonLabel(title: "清除全部", shortcut: "⌘⇧K")
                    }
                    .help("清除全部测量（⌘⇧K），清完可以用 ⌘Z 撤销")
                }
                .controlSize(.small)
                Text("改动按数据集 / 影像自动存档，下次打开自动恢复；也可以另存为文件带走。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("测量")
        }
    }

    @ViewBuilder
    private func draftBlock(_ store: MeasurementStore) -> some View {
        let result = store.draftResult
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: store.draftKind.symbolName)
                    .foregroundStyle(.tint)
                Text("正在\(store.draftKind.displayName)")
                    .font(.callout.weight(.medium))
                Spacer()
                Text("\(store.draft.count) 点")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let area = result.area {
                LabeledContent("面积", value: MeasureFormat.area(area))
            }
            if result.totalLength > 0 {
                LabeledContent(lengthTitle(for: store.draftKind),
                               value: MeasureFormat.distance(result.totalLength))
            }
            if store.draftKind == .circle {
                RadiusField(meters: store.draftCircleRadius) { store.setDraftCircleRadius($0) }
                if store.draftCircleRadius == nil, let preview = store.draftLiveRadius {
                    LabeledContent("预览半径", value: MeasureFormat.distance(preview))
                }
            }
            HStack {
                Button {
                    store.finishDraft()
                    model.canvas.refreshOverlay()
                } label: {
                    ShortcutButtonLabel(title: "结束", shortcut: "↩")
                }
                .disabled(store.draft.count < (store.draftKind == .area ? 3 : 2))
                .help("结束当前测量（回车）")
                Button {
                    store.removeLastDraftPoint()
                    model.canvas.refreshOverlay()
                } label: {
                    ShortcutButtonLabel(title: "撤销一点", shortcut: "⌫")
                }
                .help("撤掉刚点下的那个点（退格）")
                Button {
                    store.cancelDraft()
                    model.canvas.refreshOverlay()
                } label: {
                    ShortcutButtonLabel(title: "取消", shortcut: "esc")
                }
                .help("取消整条草稿（Esc）")
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func row(_ measurement: GeoMeasurement, store: MeasurementStore) -> some View {
        let isSelected = measurement.id == store.selectedID
        let color = Color(nsColor: MeasurementPalette.strokeColor(of: measurement))
        VStack(alignment: .leading, spacing: 6) {
            header(measurement, store: store, isSelected: isSelected, color: color)

            if isSelected {
                details(of: measurement, store: store)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("定位到该测量") {
                model.zoomToMeasurement(measurement)
            }
            Button("复制坐标") {
                model.copyToClipboard(MeasurementExporter.csv([measurement]), message: "已复制测量坐标")
            }
            Divider()
            Button("恢复默认样式") {
                store.resetStyle(of: measurement.id)
                model.canvas.refreshOverlay()
            }
            Button("删除", role: .destructive) {
                store.delete(measurement.id)
                model.canvas.refreshOverlay()
            }
        }
    }

    /// 行标题：图标、类型、摘要、定位按钮。
    ///
    /// 选中手势只挂在这一行，**不能**挂到整条（含展开的明细）：那样点「样式」三角、
    /// 拖粗细滑杆、开颜色面板都会被这层手势吃掉 —— 点一下就把这条测量取消选中、
    /// 明细整块收起来，看上去就是「单独编辑样式坏了」。
    private func header(
        _ measurement: GeoMeasurement,
        store: MeasurementStore,
        isSelected: Bool,
        color: Color
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: measurement.kind.symbolName)
                .foregroundStyle(color)
            Text(measurement.kind.displayName)
                .font(.callout.weight(.medium))
            Spacer()
            Text(summary(of: measurement))
                .font(.callout)
                .monospacedDigit()
            if isSelected {
                Button {
                    model.zoomToMeasurement(measurement)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help("定位到该测量")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedID = isSelected ? nil : measurement.id
            model.canvas.refreshOverlay()
        }
    }

    @ViewBuilder
    private func details(of measurement: GeoMeasurement, store: MeasurementStore) -> some View {
        let result = measurement.result
        if measurement.kind == .point, let coordinate = measurement.points.first {
            LabeledContent("坐标", value: CoordinateText.decimal(coordinate, precision: 7))
        }
        if let area = result.area {
            LabeledContent("面积", value: MeasureFormat.area(area))
        }
        if measurement.kind != .point {
            LabeledContent(lengthTitle(for: measurement.kind),
                           value: MeasureFormat.distance(result.totalLength))
        }
        if let straight = result.straightDistance, measurement.points.count > 2 {
            LabeledContent("起点到终点", value: MeasureFormat.distance(straight))
        }
        if let closing = result.closingError, measurement.kind == .area {
            LabeledContent("闭合边长", value: MeasureFormat.distance(closing))
        }

        if measurement.kind == .circle {
            RadiusField(meters: result.radius) { meters in
                store.setCircleRadius(meters, of: measurement.id)
                model.canvas.refreshOverlay()
            }
        }

        if measurement.points.count >= 2 {
            ExpandableRow("顶点坐标") {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(measurement.points.enumerated()), id: \.offset) { index, coordinate in
                        HStack(spacing: 6) {
                            Text(measurement.pointLabel(at: index))
                                .frame(width: 34, alignment: .leading)
                                .foregroundStyle(.secondary)
                            Text(CoordinateText.decimal(coordinate, precision: 6))
                                .monospacedDigit()
                                .textSelection(.enabled)
                            Spacer()
                        }
                        .font(.subheadline)
                    }
                }
            }

            ExpandableRow(measurement.kind == .circle ? "半径" : "分段明细") {
                // 一行放不下四列（面板只有 250 点宽，之前「18.84 m」会被折成两行、各列错位），
                // 改成两行：主行给「段 + 长度 + 方位」，转角单独一行。
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(result.segments, id: \.index) { segment in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(segmentLabel(measurement, index: segment.index))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .leading)
                                    .lineLimit(1)
                                Text(MeasureFormat.distance(segment.length))
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .layoutPriority(1)
                                Spacer(minLength: 2)
                                Text(MeasureFormat.bearing(segment.bearing))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(MeasureFormat.compass(segment.bearing))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            if let turn = segment.turn {
                                Text(String(format: "转角 %+.0f°", turn))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 50)
                            }
                        }
                        .font(.subheadline)
                    }
                }
            }
        }

        // 样式编辑最长（颜色、粗细、填充、批量按钮），默认折叠：
        // 展开时它会把「图层」「数据源」顶到很下面，每次调不透明度都要滚到底。
        ExpandableRow("样式") {
            MeasurementStyleEditor(measurement: measurement)
        }
    }

    private func segmentLabel(_ measurement: GeoMeasurement, index: Int) -> String {
        "\(measurement.pointLabel(at: index))–\(measurement.pointLabel(at: index + 1))"
    }

    private func lengthTitle(for kind: MeasurementKind) -> String {
        switch kind {
        case .area, .circle: return "周长"
        case .distance: return "总长度"
        case .point: return "长度"
        }
    }

    private func summary(of measurement: GeoMeasurement) -> String {
        let result = measurement.result
        switch measurement.kind {
        case .point:
            return measurement.points.first.map { CoordinateText.decimal($0, precision: 5) } ?? "—"
        case .distance:
            return MeasureFormat.distance(result.totalLength)
        case .area:
            return result.area.map { MeasureFormat.area($0) } ?? "—"
        case .circle:
            return result.radius.map { "R " + MeasureFormat.distance($0) } ?? "—"
        }
    }
}

// MARK: - 半径输入

/// 半径输入框：可以直接输入数值，也可以选单位（米 / 公里）。
///
/// 不编辑时显示的是模型里的实时半径，因此拖动半径点也会同步反映在这里。
struct RadiusField: View {
    let meters: Double?
    let onApply: (Double) -> Void

    @State private var typed: String?
    @State private var unitIndex = 0

    private static let units: [(name: String, factor: Double)] = [("米", 1), ("公里", 1000)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("半径")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("半径", text: displayText)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .onSubmit(apply)
                Picker("单位", selection: $unitIndex) {
                    ForEach(Self.units.indices, id: \.self) { index in
                        Text(Self.units[index].name).tag(index)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 74)
                Button("应用", action: apply)
                    .disabled(parsedValue == nil)
            }
            .controlSize(.small)
            Text("拖动地图上的半径点，或在这里输入精确半径")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// 未编辑时跟随模型，编辑时保留用户输入。
    private var displayText: Binding<String> {
        Binding(
            get: {
                if let typed { return typed }
                guard let meters else { return "" }
                return String(format: "%.2f", meters / Self.units[unitIndex].factor)
            },
            set: { typed = $0 }
        )
    }

    private var parsedValue: Double? {
        let raw = (typed ?? meters.map { String(format: "%.2f", $0 / Self.units[unitIndex].factor) } ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, let value = Double(raw), value > 0, value.isFinite else { return nil }
        return value * Self.units[unitIndex].factor
    }

    private func apply() {
        guard let value = parsedValue else {
            if typed != nil { typed = nil }
            return
        }
        onApply(value)
        // 交还给模型显示，保证单位切换后数字与单位一致。
        typed = nil
    }
}

// MARK: - 样式

/// 单条测量的样式编辑：描边颜色、线宽、填充颜色与填充不透明度。
struct MeasurementStyleEditor: View {
    @Environment(AppModel.self) private var model
    let measurement: GeoMeasurement

    private var store: MeasurementStore { model.measurements }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ColorPicker("描边颜色", selection: strokeBinding, supportsOpacity: false)

            LabeledContent("描边粗细") {
                HStack(spacing: 8) {
                    Slider(value: widthBinding, in: 0.5...6)
                    Text(String(format: "%.1f", MeasurementPalette.lineWidth(of: measurement)))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .trailing)
                }
            }

            if measurement.kind.hasFill {
                ColorPicker("填充颜色", selection: fillBinding, supportsOpacity: false)

                LabeledContent("填充不透明度") {
                    HStack(spacing: 8) {
                        Slider(value: fillOpacityBinding, in: 0...1)
                        Text("\(Int((MeasurementPalette.fillOpacity(of: measurement) * 100).rounded()))%")
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            } else {
                Text("折线与点没有填充；填充颜色与不透明度对测面积和多边形／圆生效")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("应用到全部") {
                    store.applyStyleToAll(measurement.style)
                    model.canvas.refreshOverlay()
                }
                .disabled(store.measurements.count < 2)
                Button("恢复默认") {
                    store.resetStyle(of: measurement.id)
                    model.canvas.refreshOverlay()
                }
                Spacer()
            }
            .controlSize(.small)
        }
        .font(.callout)
        .padding(.top, 2)
    }

    private var strokeBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: MeasurementPalette.strokeColor(of: measurement)) },
            set: { value in
                let components = NSColor(value).colorComponents
                store.updateStyle(of: measurement.id) { $0.stroke = components }
                model.canvas.refreshOverlay()
            }
        )
    }

    private var fillBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: MeasurementPalette.fillColor(of: measurement)) },
            set: { value in
                let components = NSColor(value).colorComponents
                store.updateStyle(of: measurement.id) { $0.fill = components }
                model.canvas.refreshOverlay()
            }
        )
    }

    private var widthBinding: Binding<Double> {
        Binding(
            get: { Double(MeasurementPalette.lineWidth(of: measurement)) },
            set: { value in
                store.updateStyle(of: measurement.id) { $0.strokeWidth = value }
                model.canvas.refreshOverlay()
            }
        )
    }

    private var fillOpacityBinding: Binding<Double> {
        Binding(
            get: { Double(MeasurementPalette.fillOpacity(of: measurement)) },
            set: { value in
                store.updateStyle(of: measurement.id) { $0.fillOpacity = value }
                model.canvas.refreshOverlay()
            }
        )
    }
}
