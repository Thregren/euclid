import AppKit
import Foundation
import Observation
import TileKit

/// 「本地瓦片服务」面板的状态。
///
/// 服务本身在 `TileKit/LocalTileServer.swift`：只绑回环地址、只读、只认瓦片路径，
/// 目的是把本地正射影像当成别的工具（OSM 在线编辑器 iD、QGIS…）的底图源。
@MainActor
@Observable
final class TileServerModel {
    /// 要对外提供的目录；默认取当前打开的数据集。
    var rootURL: URL?
    var port: Int = 8766
    private(set) var isRunning = false
    private(set) var actualPort = 0
    private(set) var servedRequests = 0
    private(set) var errorMessage: String?

    private let server = LocalTileServer()
    private var pollTask: Task<Void, Never>?

    var urlTemplate: String {
        isRunning ? server.urlTemplate : "http://127.0.0.1:\(port)/{z}/{x}/{y}.png"
    }

    var rootName: String { rootURL?.lastPathComponent ?? "未选择" }

    /// 打开面板时按当前数据集预填。
    func prepare(source: URL?) {
        if rootURL == nil { rootURL = source }
    }

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择要对外提供的瓦片目录（`<z>/<x>/<y>` 结构）"
        panel.prompt = "选择"
        if let rootURL { panel.directoryURL = rootURL }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        rootURL = url
    }

    func toggle() {
        isRunning ? stop() : start()
    }

    func start() {
        guard let rootURL else {
            errorMessage = "请先选择要提供的瓦片目录"
            return
        }
        errorMessage = nil
        do {
            actualPort = Int(try server.start(rootURL: rootURL, port: UInt16(clamping: port)))
            isRunning = true
            startPolling()
        } catch {
            isRunning = false
            errorMessage = (error as? TileServerError)?.description ?? error.localizedDescription
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        server.stop()
        isRunning = false
        servedRequests = 0
    }

    /// 请求计数每 0.5 秒刷一次，够用又不折腾。
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.isRunning else { return }
                self.servedRequests = self.server.status.requests
            }
        }
    }

    func copyTemplate() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlTemplate, forType: .string)
    }
}
