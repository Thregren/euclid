import SwiftUI

/// 「本地瓦片服务」面板：把本地瓦片以 HTTP 提供给别的工具（例如 OSM 在线编辑器 iD）。
struct TileServerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var server = model.tileServer
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("本地瓦片服务", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 14) {
                GroupBox("提供的目录") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(server.rootURL?.path(percentEncoded: false) ?? "未选择")
                                .font(.caption)
                                .lineLimit(2)
                                .truncationMode(.middle)
                            Spacer()
                            Button("选择…") { server.chooseRoot() }
                                .controlSize(.small)
                                .disabled(server.isRunning)
                        }
                        HStack(spacing: 8) {
                            Text("端口")
                            TextField("端口", value: $server.port, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .disabled(server.isRunning)
                            Text("（默认 8766；被占用会提示换一个）")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }

                GroupBox("地址模板") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(server.urlTemplate)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("复制") { server.copyTemplate() }
                                .controlSize(.small)
                        }
                        Text("在别的工具里填这一行即可（OSM 在线编辑器：背景设置 → 自定义 → 粘贴）。"
                            + "只监听 127.0.0.1，别的机器连不上；服务是只读的，只响应瓦片路径。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if server.isRunning {
                            Label("正在提供：\(server.rootName) · 已响应 \(server.servedRequests) 次请求",
                                  systemImage: "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let error = server.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
            }
            .padding(.horizontal, 16)

            Divider().padding(.top, 14)
            HStack(spacing: 10) {
                if server.isRunning {
                    Button("打开 http://127.0.0.1:\(server.actualPort)/") {
                        if let url = URL(string: "http://127.0.0.1:\(server.actualPort)/") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Spacer()
                Button("完成") {
                    server.stop()
                    dismiss()
                }
                Button(server.isRunning ? "停止服务" : "启动服务") { server.toggle() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 480)
        .onAppear { server.prepare(source: model.selectedDataset?.rootURL) }
    }
}
