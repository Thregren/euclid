import SwiftUI
import TileKit

/// 「DEM 工具箱」面板：在一份影像上做高程类分析 —— 剖面、坡度、土方量、两期差异。
///
/// 面板本身不算数：所有取值与出图都在 `TileKit` 的 `RasterSampleReader` /
/// `DEMAnalysis` / `RasterDifference` 里，重活由 `AppModel+Analysis.swift` 丢到后台。
/// 这里只负责「显示状态 + 派活」，因此加一种分析是加一块分区，不用动别的界面。
struct RasterAnalysisSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// 「两期差异」里选中的另一期影像层。
    @State private var differenceTarget: String?

    var body: some View {
        @Bindable var analysis = model.analysis
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("DEM 工具箱", systemImage: "mountain.2")
                    .font(.headline)
                Spacer()
                if analysis.isWorking {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)

            Text("指针处的高程在右侧检查器「指针坐标」里实时显示。下面几项会生成叠加层或结果读数。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    profileSection
                    slopeSection
                    volumeSection
                    differenceSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 480)

            Divider().padding(.top, 10)
            HStack(spacing: 10) {
                if let message = analysis.message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 540)
        .onAppear {
            if differenceTarget == nil { differenceTarget = model.comparableRasterLayers.first?.id }
        }
    }

    /// 没有可分析的影像时的统一提示。
    private var needsRasterNote: some View {
        Text("先打开一份单幅影像（GeoTIFF / TIFF），再做分析。")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    // MARK: - 剖面

    private var profileSection: some View {
        sheetSection("剖面") {
            VStack(alignment: .leading, spacing: 8) {
                if model.analysisReader == nil {
                    needsRasterNote
                } else {
                    Button("用选中的测量生成剖面") {
                        model.buildProfileFromSelection()
                    }
                    .disabled(model.analysis.isWorking)
                    Text("先用「测距」画一条线（画圆 / 测面积也行：圆沿圆周走一圈），在列表里选中它，"
                        + "再点上面的按钮。图中横向是沿线位置，纵向是高层。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let profile = model.analysis.profile {
                        Divider()
                        ProfileChart(profile: profile)
                        profileSummary(profile)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func profileSummary(_ profile: RasterAnalysisModel.ProfileReading) -> some View {
        let number = { (value: Float) -> String in
            value.isFinite ? String(format: "%.2f", value) : "—"
        }
        VStack(alignment: .leading, spacing: 4) {
            Text(profile.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                GridRow {
                    Text("长度").foregroundStyle(.secondary)
                    Text(MeasureFormat.distance(profile.lengthMeters))
                    Text("高差").foregroundStyle(.secondary)
                    Text("\(number(profile.start)) → \(number(profile.end))")
                }
                GridRow {
                    Text("最低").foregroundStyle(.secondary)
                    Text(number(profile.minimum))
                    Text("最高").foregroundStyle(.secondary)
                    Text(number(profile.maximum))
                }
                GridRow {
                    Text("累计爬升").foregroundStyle(.secondary)
                    Text(MeasureFormat.distance(profile.gain))
                    Text("累计下降").foregroundStyle(.secondary)
                    Text(MeasureFormat.distance(profile.loss))
                }
            }
            .font(.callout)
            .monospacedDigit()
        }
    }

    // MARK: - 坡度

    private var slopeSection: some View {
        sheetSection("坡度") {
            VStack(alignment: .leading, spacing: 8) {
                if !model.supportsElevationAnalysis {
                    Text(model.analysisReader == nil
                         ? "先打开一份单幅影像，再算坡度。"
                         : "这份影像没有高程数据（需要单波段浮点或 ≥16 位整数），算不出坡度。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 8) {
                        ForEach(RasterAnalysisScope.allCases) { scope in
                            Button("算\(scope.title)") {
                                model.addSlopeLayer(scope: scope)
                            }
                            .disabled(model.analysis.isWorking)
                        }
                    }
                    Text("算出来会作为一张彩色叠加层加进图层列表（绿缓 → 红陡）。"
                        + "「当前视野」快，「整幅影像」完整但慢一些。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let statistics = model.analysis.slopeStatistics, !statistics.isEmpty {
                        Divider()
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                            GridRow {
                                Text("平均").foregroundStyle(.secondary)
                                Text(String(format: "%.1f°", statistics.mean))
                                Text("最大").foregroundStyle(.secondary)
                                Text(String(format: "%.1f°", statistics.maximum))
                            }
                            GridRow {
                                Text("最小").foregroundStyle(.secondary)
                                Text(String(format: "%.1f°", statistics.minimum))
                                Text("采样点").foregroundStyle(.secondary)
                                Text("\(statistics.validCount)")
                            }
                        }
                        .font(.callout)
                        .monospacedDigit()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
    }

    // MARK: - 土方量

    private var volumeSection: some View {
        sheetSection("土方量") {
            @Bindable var analysis = model.analysis
            return VStack(alignment: .leading, spacing: 8) {
                if !model.supportsElevationAnalysis {
                    Text("先打开一份带高程的影像，再算土方量。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        SheetFieldLabel("基准高程")
                        TextField("米", text: $analysis.baseElevationText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Text("米（高于它算挖方，低于它算填方）")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        Button("用选中的面 / 圆计算") {
                            model.calculateVolumeFromSelection()
                        }
                        Button("在视图上框选范围…") {
                            model.pickVolumeBoundsFromView()
                        }
                    }
                    .disabled(model.analysis.isWorking)
                    Text("「选中的面 / 圆」先画一块面积或用「画圆」，再在列表里选中它；"
                        + "框选会临时收起这个面板，在画布上拉一个矩形即可。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let volume = model.analysis.volume {
                        Divider()
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                            GridRow {
                                Text("挖方").foregroundStyle(.secondary)
                                Text(AppModel.volumeText(volume.cutVolume))
                                Text("填方").foregroundStyle(.secondary)
                                Text(AppModel.volumeText(volume.fillVolume))
                            }
                            GridRow {
                                Text("净方量").foregroundStyle(.secondary)
                                Text(AppModel.volumeText(volume.netVolume))
                                Text("面积").foregroundStyle(.secondary)
                                Text(MeasureFormat.area(volume.sampledArea, unit: model.areaUnit))
                            }
                            GridRow {
                                Text("基准").foregroundStyle(.secondary)
                                Text(String(format: "%.2f m", volume.baseElevation))
                                Text("采样格").foregroundStyle(.secondary)
                                Text("\(volume.sampledCells)")
                            }
                        }
                        .font(.callout)
                        .monospacedDigit()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
    }

    // MARK: - 两期差异

    private var differenceSection: some View {
        let options = model.comparableRasterLayers
        return sheetSection("两期差异") {
            VStack(alignment: .leading, spacing: 8) {
                if options.isEmpty {
                    Text("再打开一期同区域的影像（字段 / 波段不必相同），这里会出现可对比的图层。"
                        + "基准期用当前打开的那份。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 8) {
                        SheetFieldLabel("对比")
                        Picker("", selection: $differenceTarget) {
                            ForEach(options) { layer in
                                Text(layer.name).tag(Optional(layer.id))
                            }
                        }
                        .labelsHidden()
                    }
                    Button("生成差异图") {
                        if let id = differenceTarget { model.addDifferenceLayer(against: id) }
                    }
                    .disabled(differenceTarget == nil || model.analysis.isWorking)
                    Text("相减结果会作为叠加层加入图层列表：蓝 = 变低，红 = 变高，透明 = 几乎没变。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
    }
}

/// 剖面折线图：自绘一条折线，够用又不引入依赖。
private struct ProfileChart: View {
    let profile: RasterAnalysisModel.ProfileReading

    var body: some View {
        Canvas { context, size in
            let samples = profile.samples.filter { $0.value.isFinite }
            guard samples.count >= 2 else { return }
            var low = Float.greatestFiniteMagnitude
            var high = -Float.greatestFiniteMagnitude
            for sample in samples {
                low = min(low, sample.value)
                high = max(high, sample.value)
            }
            // 太平的地方给一点高度，别让线贴成一条。
            let span = max(high - low, 0.001)
            func point(_ sample: (fraction: Double, value: Float)) -> CGPoint {
                let x = CGFloat(sample.fraction) * size.width
                let normalized = CGFloat((sample.value - low) / span)
                let y = size.height - normalized * (size.height - 6) - 3
                return CGPoint(x: x, y: y)
            }
            var line = Path()
            line.move(to: point(samples[0]))
            for sample in samples.dropFirst() {
                line.addLine(to: point(sample))
            }
            context.stroke(line, with: .color(.accentColor), lineWidth: 1.5)
        }
        .frame(height: 120)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.10)))
    }
}
