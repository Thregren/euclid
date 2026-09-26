import SwiftUI
import TileKit
import UniformTypeIdentifiers

/// 「从单幅影像生成瓦片」面板。
struct TileExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var export = model.tileExport
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("从影像生成瓦片", systemImage: "square.grid.3x3.square")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sourceSection
                    outputSection
                    rangeSection
                    formatSection
                    if let reason = export.blockingReason, !export.isRunning {
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    progressSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            Divider()
            footer
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            export.prepare(
                source: model.selectedRaster,
                outputDirectory: export.outputDirectory
            )
        }
    }

    // MARK: - 分区

    /// 分区外框：内容左对齐铺满、上下留一点，避免每个分区各写一遍。
    @ViewBuilder
    private var sourceSection: some View {
        @Bindable var export = model.tileExport
        sheetSection("影像") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(export.sourceURL?.lastPathComponent ?? "未选择")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("选择…") { export.chooseSource() }
                        .controlSize(.small)
                }
                if let raster = export.raster {
                    Text("\(raster.pixelSizeText) px · \(raster.crsName)"
                        + (raster.isGeoreferenced ? "" : " · 未配准（生成的瓦片会按 1 像素 = 1 米摆放）"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let gsd = raster.groundSampleDistance {
                        Text(gsd >= 1
                            ? String(format: "地面分辨率 %.2f 米/像素（最大层级建议 ≤ %d）", gsd, export.maximumZoomLimit)
                            : String(format: "地面分辨率 %.1f 厘米/像素（最大层级建议 ≤ %d）", gsd * 100, export.maximumZoomLimit))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else if let error = export.sourceError {
                    Text(error).font(.subheadline).foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var outputSection: some View {
        @Bindable var export = model.tileExport
        sheetSection("输出") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(export.outputDirectory?.path(percentEncoded: false) ?? "未选择")
                        .font(.subheadline)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer()
                    Button("选择…") { export.chooseOutputDirectory() }
                        .controlSize(.small)
                }
                Toggle("覆盖已存在的瓦片", isOn: $export.overwriteExisting)
                    .toggleStyle(.checkbox)
                    .help("默认跳过已存在的瓦片，中断后可以接着跑")
                Text("落成 `<z>/<x>/<y>.<ext>`，生成完可以直接用本程序打开离线浏览。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var rangeSection: some View {
        @Bindable var export = model.tileExport
        sheetSection("层级与规模") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Stepper("最小层级 z\(export.minimumZoom)", value: $export.minimumZoom, in: 0...export.maximumZoomLimit)
                    Stepper("最大层级 z\(export.maximumZoom)", value: $export.maximumZoom, in: 0...export.maximumZoomLimit)
                }
                Text("预计 \(export.tileCount) 张，约 \(ByteCountFormatter.string(fromByteCount: Int64(export.estimatedBytes), countStyle: .file))")
                    .font(.callout)
                    .monospacedDigit()
                Text("层级每多一级，瓦片数大约翻两番。上限取「一个影像像素对一个瓦片像素」的那一级。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var formatSection: some View {
        @Bindable var export = model.tileExport
        sheetSection("瓦片") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("尺寸", selection: $export.tileSize) {
                    Text("512 像素（默认，本地浏览 1:1）").tag(512)
                    Text("256 像素（通用地图约定）").tag(256)
                }
                .pickerStyle(.radioGroup)

                Picker("格式", selection: $export.format) {
                    ForEach(TileImageFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .pickerStyle(.segmented)

                if export.format == .jpeg {
                    LabeledContent("JPEG 质量") {
                        HStack(spacing: 8) {
                            Slider(value: $export.quality, in: 0.4...1)
                            Text("\(Int((export.quality * 100).rounded()))")
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 30, alignment: .trailing)
                        }
                    }
                } else {
                    Text("PNG 无损、保留透明区（无数据的地方不会变成白底），体积约为 JPEG 的八倍。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        let export = model.tileExport
        if export.isRunning, let progress = export.progress {
            sheetSection("进度") {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress.fraction)
                    HStack(spacing: 12) {
                        Text("\(progress.completed)/\(progress.total)")
                            .monospacedDigit()
                        Text("写出 \(progress.written)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        if progress.failed > 0 {
                            Text("失败 \(progress.failed)").foregroundStyle(.orange)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(progress.bytes), countStyle: .file))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        } else if let summary = export.summary {
            sheetSection("完成") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary.cancelled ? "已停止" : "已生成")
                        .font(.callout.weight(.medium))
                    Text("写出 \(summary.written) 张 · 跳过 \(summary.skipped) 张 · 失败 \(summary.failed) 张")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(String(
                        format: "%.1f MB，用时 %.1f 秒",
                        Double(summary.bytes) / 1_000_000, summary.elapsed
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
        } else if let error = export.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let exportDirectory = model.tileExport.outputPreviewURL, model.tileExport.summary != nil {
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([exportDirectory])
                }
                Button("打开这个数据集") {
                    model.tileExport.openResult(using: model)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer()
            if model.tileExport.isRunning {
                Button("停止生成") { model.tileExport.cancel() }
            } else {
                Button("完成") { dismiss() }
                Button("开始生成") { model.tileExport.start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.tileExport.canStart)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
