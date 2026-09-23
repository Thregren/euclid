import SwiftUI
import TileKit

/// 指针坐标分区。
///
/// 单独成视图，是为了让高频更新的指针坐标只重绘这一小块，不影响检查器其余部分。
struct CursorCoordinateSection: View {
    @Environment(AppModel.self) private var model

    @State private var goToLongitude = ""
    @State private var goToLatitude = ""
    @State private var showsJumpField = false

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
                    model.copyToClipboard(
                        CoordinateText.decimal(cursor.coordinate, precision: 7),
                        message: "已复制坐标"
                    )
                } label: {
                    Label("复制坐标", systemImage: "doc.on.doc")
                }
            } else {
                Text("把指针移到地图上即可读取坐标")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("跳转到坐标", isExpanded: $showsJumpField) {
                TextField("经度（十进制度）", text: $goToLongitude)
                    .textFieldStyle(.roundedBorder)
                TextField("纬度（十进制度）", text: $goToLatitude)
                    .textFieldStyle(.roundedBorder)
                Button("跳转") {
                    guard let longitude = Double(goToLongitude.trimmingCharacters(in: .whitespaces)),
                          let latitude = Double(goToLatitude.trimmingCharacters(in: .whitespaces)) else {
                        model.statusMessage = "坐标格式不正确，请输入十进制度"
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

            ForEach(store.measurements) { measurement in
                row(measurement, store: store)
            }

            if store.measurements.isEmpty && store.draft.isEmpty {
                Text("选择工具栏中的「测距」或「测面积」，在地图上点击即可开始")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if store.hasContent {
                Button("清除全部", role: .destructive) {
                    model.clearMeasurements()
                }
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
                LabeledContent(store.draftKind == .area ? "周长" : "当前长度",
                               value: MeasureFormat.distance(result.totalLength))
            }
            HStack {
                Button("结束") {
                    store.finishDraft()
                    model.canvas.refreshOverlay()
                }
                .disabled(store.draft.count < (store.draftKind == .area ? 3 : 2))
                Button("撤销一点") {
                    store.removeLastDraftPoint()
                    model.canvas.refreshOverlay()
                }
                Button("取消") {
                    store.cancelDraft()
                    model.canvas.refreshOverlay()
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func row(_ measurement: GeoMeasurement, store: MeasurementStore) -> some View {
        let isSelected = measurement.id == store.selectedID
        let color = Color(nsColor: MeasurementPalette.color(at: measurement.colorIndex))
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: measurement.kind.symbolName)
                    .foregroundStyle(color)
                Text(measurement.kind.displayName)
                    .font(.callout.weight(.medium))
                Spacer()
                Text(summary(of: measurement))
                    .font(.callout)
                    .monospacedDigit()
            }

            if isSelected {
                details(of: measurement)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedID = isSelected ? nil : measurement.id
            model.canvas.refreshOverlay()
        }
        .contextMenu {
            Button("复制坐标") {
                model.copyToClipboard(MeasurementExporter.csv([measurement]), message: "已复制测量坐标")
            }
            Button("删除", role: .destructive) {
                store.delete(measurement.id)
                model.canvas.refreshOverlay()
            }
        }
    }

    @ViewBuilder
    private func details(of measurement: GeoMeasurement) -> some View {
        let result = measurement.result
        if measurement.kind == .point, let coordinate = measurement.points.first {
            LabeledContent("坐标", value: CoordinateText.decimal(coordinate, precision: 7))
        }
        if let area = result.area {
            LabeledContent("面积", value: MeasureFormat.area(area))
        }
        if measurement.kind != .point {
            LabeledContent(measurement.kind == .area ? "周长" : "总长度",
                           value: MeasureFormat.distance(result.totalLength))
        }
        if let straight = result.straightDistance, measurement.points.count > 2 {
            LabeledContent("起点到终点", value: MeasureFormat.distance(straight))
        }
        if let closing = result.closingError, measurement.kind == .area {
            LabeledContent("闭合边长", value: MeasureFormat.distance(closing))
        }
        if measurement.points.count >= 2 {
            DisclosureGroup("分段明细") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(result.segments, id: \.index) { segment in
                        HStack(spacing: 8) {
                            Text(segmentLabel(measurement, index: segment.index))
                                .frame(width: 34, alignment: .leading)
                                .foregroundStyle(.secondary)
                            Text(MeasureFormat.distance(segment.length))
                                .monospacedDigit()
                            Spacer()
                            Text(MeasureFormat.bearing(segment.bearing))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Text(MeasureFormat.compass(segment.bearing))
                                .foregroundStyle(.tertiary)
                            if let turn = segment.turn {
                                Text(String(format: "转角 %+.0f°", turn))
                                    .foregroundStyle(.quaternary)
                            }
                        }
                        .font(.caption)
                    }
                }
            }
            .font(.callout)
        }
    }

    private func segmentLabel(_ measurement: GeoMeasurement, index: Int) -> String {
        "\(measurement.pointLabel(at: index))–\(measurement.pointLabel(at: index + 1))"
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
        }
    }
}
