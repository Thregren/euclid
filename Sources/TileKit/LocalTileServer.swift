import Foundation
import Network

/// 只读的本地瓦片服务：把目录里的 `<z>/<x>/<y>.<ext>` 通过 HTTP 暴露给本机其它程序。
///
/// 用途是给 OSM 在线编辑器（iD）、QGIS 这类工具当底图源：填一行
/// `http://127.0.0.1:端口/{z}/{x}/{y}.png` 就能把本地正射影像当底图用。
///
/// 只绑回环地址（别的机器连不上），只读、只认瓦片路径，另外带上 CORS 头，
/// 否则浏览器里的编辑器会被同源策略挡住。
public final class LocalTileServer: @unchecked Sendable {
    public struct Status: Sendable {
        public var isRunning: Bool
        public var port: UInt16
        public var requests: Int
        public var rootName: String
    }

    private let queue = DispatchQueue(label: "euclid.local-tile-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var requestCount = 0
    private var root: URL?
    private var boundPort: UInt16 = 0

    /// 允许的文件后缀（与瓦片目录里可能出现的保持一致）。
    private static let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]

    public init() {}

    deinit { stop() }

    /// 当前地址模板，直接粘进别的工具即可。
    public var urlTemplate: String {
        "http://127.0.0.1:\(status.port)/{z}/{x}/{y}.png"
    }

    public var status: Status {
        lock.lock()
        defer { lock.unlock() }
        return Status(
            isRunning: listener != nil,
            port: boundPort,
            requests: requestCount,
            rootName: root?.lastPathComponent ?? ""
        )
    }

    /// 启动服务。`port` 传 0 时让系统分配一个空闲端口，返回实际端口。
    @discardableResult
    public func start(rootURL: URL, port: UInt16 = 0) throws -> UInt16 {
        stop()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // 只监听回环地址：这是本机工具之间的桥，不该暴露到局域网。
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)

        let listener: NWListener
        if port == 0 {
            listener = try NWListener(using: parameters)
        } else {
            guard let value = NWEndpoint.Port(rawValue: port) else {
                throw TileServerError.invalidPort(Int(port))
            }
            listener = try NWListener(using: parameters, on: value)
        }

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)

        // 等它真的起来（超时也不至于卡住界面）。
        _ = ready.wait(timeout: .now() + 3)
        guard let actualPort = listener.port?.rawValue else {
            listener.cancel()
            throw TileServerError.cannotStart
        }
        lock.lock()
        self.listener = listener
        root = rootURL
        boundPort = actualPort
        requestCount = 0
        lock.unlock()
        return actualPort
    }

    public func stop() {
        lock.lock()
        let current = listener
        listener = nil
        lock.unlock()
        current?.cancel()
    }

    // MARK: - 请求处理

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self, error == nil, let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            let response = self.response(for: data)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func response(for request: Data) -> Data {
        guard let text = String(data: request, encoding: .utf8),
              let requestLine = text.split(separator: "\r\n", maxSplits: 1).first else {
            return Self.httpResponse(status: 400, contentType: "text/plain", body: Data("bad request".utf8))
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return Self.httpResponse(status: 400, contentType: "text/plain", body: Data("bad request".utf8))
        }
        let method = String(parts[0]).uppercased()
        var path = String(parts[1])
        if let query = path.firstIndex(of: "?") { path = String(path[path.startIndex..<query]) }

        lock.lock()
        requestCount += 1
        let currentRoot = root
        lock.unlock()

        if method == "OPTIONS" {
            return Self.httpResponse(status: 204, contentType: "text/plain", body: Data(), extra: [:])
        }
        if path == "/" || path.isEmpty {
            return Self.httpResponse(
                status: 200,
                contentType: "text/html; charset=utf-8",
                body: Data(Self.indexHTML(rootName: currentRoot?.lastPathComponent ?? "—").utf8)
            )
        }
        guard let currentRoot, let fileURL = Self.tileFile(for: path, root: currentRoot) else {
            return Self.httpResponse(status: 404, contentType: "text/plain", body: Data("no such tile".utf8))
        }
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe), !data.isEmpty else {
            return Self.httpResponse(status: 404, contentType: "text/plain", body: Data("no such tile".utf8))
        }
        return Self.httpResponse(
            status: 200,
            contentType: Self.contentType(for: fileURL.pathExtension),
            body: data,
            extra: ["Cache-Control": "public, max-age=600"]
        )
    }

    /// 把 `/z/x/y.ext` 解析成磁盘路径；不是合法瓦片路径就返回 nil（顺带挡掉目录穿越）。
    static func tileFile(for path: String, root: URL) -> URL? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count == 3,
              let zoom = Int(components[0]), let column = Int(components[1]), zoom >= 0, column >= 0,
              !components[0].hasPrefix("-"), !components[1].hasPrefix("-") else { return nil }
        let file = components[2]
        let name = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension.lowercased()
        guard let row = Int(name), row >= 0, !name.hasPrefix("-"),
              allowedExtensions.contains(ext) else { return nil }
        return root
            .appending(path: String(zoom))
            .appending(path: String(column))
            .appending(path: "\(row).\(ext)")
    }

    static func contentType(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }

    static func httpResponse(
        status: Int,
        contentType: String,
        body: Data,
        extra: [String: String] = [:]
    ) -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        default: reason = "OK"
        }
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        // 浏览器里的编辑器（iD）需要这个头，否则跨源取图会被拦。
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Access-Control-Allow-Methods: GET, OPTIONS\r\n"
        header += "Access-Control-Allow-Headers: *\r\n"
        for (key, value) in extra { header += "\(key): \(value)\r\n" }
        header += "Connection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return data
    }

    static func indexHTML(rootName: String) -> String {
        """
        <!doctype html>
        <html lang="zh-CN"><head><meta charset="utf-8"><title>尺规 · 本地瓦片服务</title>
        <style>body{font:14px/1.6 -apple-system,system-ui,sans-serif;margin:32px;color:#111}
        code{background:#f2f2f2;padding:2px 6px;border-radius:4px}</style></head>
        <body>
        <h1>本地瓦片服务</h1>
        <p>正在提供目录：<strong>\(rootName)</strong></p>
        <p>在支持 XYZ 瓦片的工具里填：</p>
        <p><code>/{{z}}/{{x}}/{{y}}.png</code>（把前缀换成本机地址与端口）</p>
        <p>例：OSM 在线编辑器 iD → 背景设置 → 自定义 → 粘贴完整模板。</p>
        <p>只监听 127.0.0.1，只读，只响应瓦片路径。</p>
        </body></html>
        """
    }
}

public enum TileServerError: Error, CustomStringConvertible {
    case invalidPort(Int)
    case cannotStart

    public var description: String {
        switch self {
        case .invalidPort(let port): return "端口不可用：\(port)"
        case .cannotStart: return "本地服务没能启动（端口可能被占用）"
        }
    }
}
