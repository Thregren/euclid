import AppKit
import SwiftUI
import TileKit

/// 在线瓦片下载面板。
struct DownloadSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var download = model.download

        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // 进度与结果放最上面：开始下载后不用往下滚就能看到。
                    if download.isRunning || download.summary != nil || download.errorMessage != nil {
                        statusSection(model.download)
                    }
                    sourceSection(model.download)
                    regionSection(model.download)
                    zoomSection(model.download)
                    outputSection(model.download)
                }
                .padding(20)
            }
            Divider()
            footer(download)
        }
        .frame(width: 580, height: 700)
        .onAppear {
            model.download.prepare(
                currentBounds: model.canvas.visibleBounds(),
                datasetBounds: model.extent.map { GeoBounds($0.boundingBox.southWest, $0.boundingBox.northEast) },
                currentZoom: model.viewport.dataZoom
            )
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("下载在线瓦片")
                    .font(.headline)
                Text("按范围与层级取图，落成本程序可直接打开的 <z>/<x>/<y> 目录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - 数据源

    private func sourceSection(_ target: TileDownloadModel) -> some View {
        @Bindable var download = target
        return sectionBox("数据源") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    label("预设")
                    Picker("", selection: $download.sourceID) {
                        ForEach(TileSourceTemplate.presets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240, alignment: .leading)
                }
                GridRow {
                    label("URL 模板")
                    TextField("https://…/{z}/{x}/{y}.png", text: $download.template)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .help("支持 {z} {x} {y}，另有 {-y}（TMS 行号）、{s}（子域）、{key}（密钥）")
                }
                if download.needsKey {
                    GridRow {
                        label("密钥")
                        TextField("tk=…", text: $download.key)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: 260, alignment: .leading)
                    }
                    GridRow {
                        label("")
                        Text("密钥只保存在内存里，退出程序后需要重新填写。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !download.terms.isEmpty {
                Divider()
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text(download.terms)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 区域

    private func regionSection(_ target: TileDownloadModel) -> some View {
        @Bindable var download = target
        return sectionBox("区域（WGS84 经纬度）") {
            HStack(spacing: 8) {
                Button("用当前视图") {
                    model.download.useCurrentView(model.canvas.visibleBounds())
                }
                Button("用数据范围") {
                    if let extent = model.extent {
                        model.download.bounds = GeoBounds(extent.boundingBox.southWest, extent.boundingBox.northEast)
                    }
                }
                .disabled(model.extent == nil)
                Button("整个世界") {
                    model.download.bounds = GeoBounds(west: -180, south: -85, east: 180, north: 85)
                }
                Spacer()
                Button("复制范围") { model.download.copyBounds() }
                Button("用剪贴板范围") { model.download.pasteBounds() }
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    label("西经")
                    coordinateField($download.bounds.west)
                    label("东经")
                    coordinateField($download.bounds.east)
                }
                GridRow {
                    label("南纬")
                    coordinateField($download.bounds.south)
                    label("北纬")
                    coordinateField($download.bounds.north)
                }
            }
            if !download.bounds.isValid {
                Text("范围无效：需要西 < 东、南 < 北，且纬度在 ±90 以内。")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func coordinateField(_ value: Binding<Double>) -> some View {
        TextField("", value: value, format: .number.precision(.fractionLength(0...6)))
            .textFieldStyle(.roundedBorder)
            .frame(width: 110)
            .monospacedDigit()
    }

    // MARK: - 层级

    private func zoomSection(_ target: TileDownloadModel) -> some View {
        @Bindable var download = target
        return sectionBox("层级与规模") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    label("最小层级")
                    Stepper(value: $download.minimumZoom, in: 0...min(download.maximumZoomLimit, 30)) {
                        Text("z\(download.minimumZoom)").monospacedDigit()
                    }
                    .frame(width: 130, alignment: .leading)
                    label("最大层级")
                    Stepper(value: $download.maximumZoom, in: 0...min(download.maximumZoomLimit, 30)) {
                        Text("z\(download.maximumZoom)").monospacedDigit()
                    }
                    .frame(width: 130, alignment: .leading)
                }
            }
            HStack(spacing: 8) {
                Text("预计")
                    .foregroundStyle(.secondary)
                Text("\(download.tileCount) 张瓦片")
                    .fontWeight(.semibold)
                    .monospacedDigit()
                if download.tileCount > 0 {
                    Text("· 约 \(byteText(download.estimatedBytes))")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("该数据源上限 z\(download.maximumZoomLimit)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button("复制瓦片清单") { model.download.copyTileList() }
                    .controlSize(.small)
                    .disabled(download.tileCount == 0)
            }
            if download.tileCount > TileDownloader.defaultTileLimit {
                Text("数量超过单次上限（\(TileDownloader.defaultTileLimit) 张），请缩小范围或降低层级。")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - 输出

    private func outputSection(_ target: TileDownloadModel) -> some View {
        @Bindable var download = target
        return sectionBox("输出") {
            HStack(spacing: 8) {
                Button("选择目录…") { model.download.chooseOutputDirectory() }
                Text(download.outputDirectory?.path(percentEncoded: false) ?? "未选择")
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(download.outputDirectory == nil ? .secondary : .primary)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    label("并发")
                    Stepper(value: $download.concurrency, in: 1...16) {
                        Text("\(download.concurrency) 路").monospacedDigit()
                    }
                    .frame(width: 110, alignment: .leading)
                    label("限速")
                    Stepper(value: $download.requestsPerSecond, in: 0...60, step: 4) {
                        Text(download.requestsPerSecond < 1
                             ? "不限"
                             : "\(Int(download.requestsPerSecond)) 次/秒")
                            .monospacedDigit()
                    }
                    .frame(width: 150, alignment: .leading)
                }
            }
            HStack(spacing: 18) {
                Toggle("覆盖已有瓦片", isOn: $download.overwriteExisting)
                    .toggleStyle(.switch)
                Toggle("写来源说明", isOn: $download.writesManifest)
                    .toggleStyle(.switch)
                Spacer()
            }
            .padding(.leading, 70)
        }
    }

    // MARK: - 进度与结果

    private func statusSection(_ target: TileDownloadModel) -> some View {
        @Bindable var download = target
        return sectionBox("进度") {
            if download.isRunning, let progress = download.progress {
                ProgressView(value: progress.fraction)
                HStack(spacing: 10) {
                    Text("\(progress.completed) / \(progress.total)")
                        .monospacedDigit()
                        .fontWeight(.medium)
                    Text("z\(progress.zoom)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text("已存 \(progress.downloaded)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if progress.failed > 0 {
                        Text("失败 \(progress.failed)")
                            .monospacedDigit()
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    if let remaining = progress.estimatedRemaining {
                        Text("约剩 \(durationText(remaining))")
                            .foregroundStyle(.secondary)
                    }
                    Text("\(byteText(progress.bytes))")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            }

            if let summary = download.summary {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.cancelled ? "已停止" : "已完成")
                        .fontWeight(.semibold)
                    Text(summaryText(summary))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if let failure = summary.failures.first {
                        Text("示例失败：\(failure)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }
            }

            if let error = download.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }

    private func summaryText(_ summary: TileDownloadSummary) -> String {
        var parts = ["落地 \(summary.downloaded) 张", "跳过 \(summary.skipped) 张"]
        if summary.missing > 0 { parts.append("缺片 \(summary.missing)") }
        if summary.failed > 0 { parts.append("失败 \(summary.failed)") }
        parts.append(byteText(summary.bytes))
        parts.append(durationText(summary.elapsed))
        return parts.joined(separator: " · ")
    }

    // MARK: - 底栏

    private func footer(_ target: TileDownloadModel) -> some View {
        @Bindable var download = target
        return HStack(spacing: 10) {
            if let directory = download.lastOutputDirectory, !download.isRunning {
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([directory])
                }
                Button("打开这个数据集") {
                    model.open(directory)
                    dismiss()
                }
            }
            Spacer()
            if let reason = download.blockingReason, !download.isRunning {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if download.isRunning {
                Button("停止下载") { model.download.cancel() }
            } else {
                Button("关闭") { dismiss() }
                Button("开始下载") { model.download.start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!download.canStart)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - 小工具

    private func sectionBox<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(width: 58, alignment: .trailing)
    }

    private func byteText(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func durationText(_ interval: TimeInterval) -> String {
        if interval < 60 {
            return String(format: "%.0f 秒", interval)
        }
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        if minutes < 60 {
            return "\(minutes) 分 \(seconds) 秒"
        }
        return "\(minutes / 60) 小时 \(minutes % 60) 分"
    }
}
