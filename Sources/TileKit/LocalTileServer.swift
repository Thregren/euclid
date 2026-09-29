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

    /// 已读过的瓦片（键是请求路径）。
    private struct CachedTile {
        var data: Data
        var contentType: String
        var cachedAt: Date
    }

    private var cache: [String: CachedTile] = [:]
    /// 插入顺序，用来按「最老的先扔」淘汰。
    private var cacheOrder: [String] = []
    private var cacheBytes = 0

    /// 允许的文件后缀（与瓦片目录里可能出现的保持一致）。
    private static let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]
    /// 响应缓存的上限：浏览器一次要一屏几十张瓦片，每次都从磁盘读一遍纯属浪费。
    /// 上限压在 64 MB / 512 条：瓦片通常几十 KB，够放好几屏，又不会把内存吃出坑。
    private static let cacheLimitBytes = 64 << 20
    private static let cacheLimitEntries = 512
    private static let cacheLifetime: TimeInterval = 600
    /// 单张瓦片的读取上限：正常瓦片撑死几 MB，超过这个数说明这不是瓦片（或文件被写坏了），
    /// 与其把几百 MB 塞进内存再发出去，不如直接当 404。
    private static let maximumTileBytes = 32 << 20

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
    ///
    /// 会阻塞到监听器就绪（最多 3 秒）。主线程上别用它 —— 用 `startAsync`。
    @discardableResult
    public func start(rootURL: URL, port: UInt16 = 0) throws -> UInt16 {
        stop()
        let listener = try makeListener(port: port)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.start(queue: queue)

        // 等它真的起来（超时也不至于卡住界面）。
        _ = ready.wait(timeout: .now() + 3)
        return try adopt(listener, rootURL: rootURL)
    }

    /// 异步启动：等就绪的那三秒挂在 `await` 上，不再占着调用线程（主 actor 上尤其重要）。
    @discardableResult
    public func startAsync(rootURL: URL, port: UInt16 = 0) async throws -> UInt16 {
        stop()
        let listener = try makeListener(port: port)
        do {
            try await Self.waitUntilReady(listener, queue: queue)
        } catch {
            // 没起来就把监听器收掉，别留一个还在后台重试的半拉服务。
            listener.cancel()
            throw error
        }
        return try adopt(listener, rootURL: rootURL)
    }

    /// 等监听器就绪（`NWListener` 的三种终局状态任一到达，或者 5 秒超时）。
    private static func waitUntilReady(_ listener: NWListener, queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.setIfUnset() { continuation.resume() }
                case .failed, .cancelled:
                    if resumed.setIfUnset() { continuation.resume(throwing: TileServerError.cannotStart) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
            // 兜底超时：`NWListener` 万一既不就绪也不报错（端口被某种方式占着时会这样），
            // 不能让这个 await 永远挂着 —— 那就成了「点了启动，界面一直转圈」。
            queue.asyncAfter(deadline: .now() + 5) {
                if resumed.setIfUnset() { continuation.resume(throwing: TileServerError.cannotStart) }
            }
        }
    }

    /// 建监听器（两种启动路径共用）。
    private func makeListener(port: UInt16) throws -> NWListener {
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
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        return listener
    }

    /// 记录已经就绪的监听器；端口取不到就收摊报错。
    private func adopt(_ listener: NWListener, rootURL: URL) throws -> UInt16 {
        guard let actualPort = listener.port?.rawValue else {
            listener.cancel()
            throw TileServerError.cannotStart
        }
        lock.lock()
        self.listener = listener
        root = rootURL
        boundPort = actualPort
        requestCount = 0
        cache.removeAll()
        cacheOrder.removeAll()
        cacheBytes = 0
        lock.unlock()
        return actualPort
    }

    public func stop() {
        lock.lock()
        let current = listener
        listener = nil
        cache.removeAll()
        cacheOrder.removeAll()
        cacheBytes = 0
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
        guard let tile = cachedTile(for: path, fileURL: fileURL) else {
            return Self.httpResponse(status: 404, contentType: "text/plain", body: Data("no such tile".utf8))
        }
        return Self.httpResponse(
            status: 200,
            contentType: tile.contentType,
            body: tile.data,
            extra: ["Cache-Control": "public, max-age=600"]
        )
    }

    /// 取一张瓦片：先查缓存，没有再读盘并放进缓存。
    ///
    /// 编辑器拉一屏就是几十个请求，缓存命中时既省磁盘、也省得起一次 `Data(contentsOf:)`。
    /// 读盘与写缓存都在锁外算好、锁内只做字典操作。
    private func cachedTile(for path: String, fileURL: URL) -> CachedTile? {
        let now = Date()
        lock.lock()
        if let hit = cache[path] {
            if now.timeIntervalSince(hit.cachedAt) < Self.cacheLifetime {
                lock.unlock()
                return hit
            }
            cache[path] = nil
            cacheOrder.removeAll { $0 == path }
            cacheBytes -= hit.data.count
        }
        lock.unlock()

        // 先看大小再读：一份被写坏的「瓦片」可能几百 MB，读进来再判断就晚了。
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 0, size <= Self.maximumTileBytes else { return nil }
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe), !data.isEmpty else { return nil }
        let tile = CachedTile(
            data: data,
            contentType: Self.contentType(for: fileURL.pathExtension),
            cachedAt: now
        )

        lock.lock()
        if cache[path] == nil {
            cache[path] = tile
            cacheOrder.append(path)
            cacheBytes += data.count
        }
        // 超出预算就从最老的开始扔（FIFO 足够：瓦片的大小与访问热度都很均匀）。
        while cacheBytes > Self.cacheLimitBytes || cacheOrder.count > Self.cacheLimitEntries {
            guard let oldest = cacheOrder.first else { break }
            cacheOrder.removeFirst()
            if let dropped = cache.removeValue(forKey: oldest) {
                cacheBytes -= dropped.data.count
            }
        }
        lock.unlock()
        return tile
    }

    /// 把 `/z/x/y.ext` 解析成磁盘路径；不是合法瓦片路径就返回 nil（顺带挡掉目录穿越）。
    public static func tileFile(for path: String, root: URL) -> URL? {
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

    public static func contentType(for fileExtension: String) -> String {
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

/// 只允许「第一个到的」通过的开关（用来给 `CheckedContinuation` 收口）。
///
/// `NWListener` 的状态回调可能连着来两次（ready 之后紧跟着 cancelled），
/// 而 continuation 只能 resume 一次 —— 第二次直接丢弃。
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    /// 第一次调用返回 true，之后都返回 false。
    func setIfUnset() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isSet else { return false }
        isSet = true
        return true
    }
}
