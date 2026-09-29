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
        let port = boundPort
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
        if path == "/tilejson.json" {
            let metadata = self.metadata(for: currentRoot)
            let body = Self.tileJSON(
                root: currentRoot,
                rootName: currentRoot?.lastPathComponent ?? "—",
                port: port,
                metadata: metadata
            ) ?? Data("{}".utf8)
            return Self.httpResponse(status: 200, contentType: "application/json; charset=utf-8", body: body)
        }
        if path == "/preview" || path == "/preview.html" {
            let metadata = self.metadata(for: currentRoot)
            return Self.httpResponse(
                status: 200,
                contentType: "text/html; charset=utf-8",
                body: Data(
                    Self.previewHTML(
                        rootName: currentRoot?.lastPathComponent ?? "—",
                        start: metadata.start,
                        tileSize: metadata.tileSize
                    ).utf8
                )
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

    // MARK: - 元数据与预览页

    /// 一个数据集的元数据（层级 / 默认落点 / 瓦片边长）。
    ///
    /// 扫目录是有成本的（z18 的列目录可能有几万项），所以按根目录缓存一份，
    /// 只在换数据集时重扫 —— `/tilejson.json` 与 `/preview` 不必每次请求都扫盘。
    package struct RootMetadata {
        package var zoomRange: ClosedRange<Int>?
        package var start: (zoom: Int, x: Int, y: Int)?
        package var tileSize: Int = 256

        package init() {}
    }

    private var metadataRootPath: String?
    private var metadataCache: RootMetadata?

    /// 取（必要时重算）根目录元数据。锁内只做字典/指针级操作，扫盘在锁外。
    func metadata(for root: URL?) -> RootMetadata {
        guard let root else { return RootMetadata() }
        lock.lock()
        let cached = metadataRootPath == root.path ? metadataCache : nil
        lock.unlock()
        if let cached { return cached }

        var fresh = RootMetadata()
        fresh.zoomRange = Self.zoomRange(of: root)
        fresh.start = Self.previewStart(of: root)
        if let start = fresh.start,
           let size = Self.tileSize(of: root, zoom: start.zoom, column: start.x, row: start.y) {
            fresh.tileSize = size
        }

        lock.lock()
        metadataRootPath = root.path
        metadataCache = fresh
        lock.unlock()
        return fresh
    }

    /// 目录里实际存在的层级（只看根目录下的一层数字目录名，带条数上限）。
    ///
    /// 不给「全盘扫描」留口子：只枚举根目录，最多看 128 项，够用又不会在大数据集上卡住。
    static func zoomRange(of root: URL?) -> ClosedRange<Int>? {
        guard let root else { return nil }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var zooms: [Int] = []
        for entry in entries.prefix(128) {
            guard !entry.hasPrefix("."), !entry.hasPrefix("-"), let zoom = Int(entry),
                  (0...30).contains(zoom) else { continue }
            var isDirectory: ObjCBool = false
            let path = root.appending(path: entry).path
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            zooms.append(zoom)
        }
        guard let lower = zooms.min(), let upper = zooms.max() else { return nil }
        return lower...upper
    }

    /// 预览页的默认落点：取最高层级中「最中间」的那张瓦片，避免一打开就是空白边界。
    static func previewStart(of root: URL) -> (zoom: Int, x: Int, y: Int)? {
        guard let range = zoomRange(of: root) else { return nil }
        let zoom = range.upperBound
        let zoomURL = root.appending(path: String(zoom))
        let columns = Self.numericEntries(at: zoomURL, limit: 4096)
        guard !columns.isEmpty else { return nil }
        let column = columns[columns.count / 2]
        let rows = Self.tileRows(at: root, zoom: zoom, column: column, limit: 4096)
        guard !rows.isEmpty else { return nil }
        return (zoom, column, rows[rows.count / 2])
    }

    /// 取某个 `<z>/<x>` 目录里的行号（只认允许的图片后缀）。
    private static func tileRows(at root: URL, zoom: Int, column: Int, limit: Int) -> [Int] {
        let directory = root.appending(path: String(zoom)).appending(path: String(column))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var rows: [Int] = []
        for name in names.prefix(limit) {
            guard Self.allowedExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            let stem = (name as NSString).deletingPathExtension
            guard !stem.hasPrefix("-"), let row = Int(stem), row >= 0 else { continue }
            rows.append(row)
        }
        return rows.sorted()
    }

    /// 目录下名字是纯数字的子目录，升序返回。
    private static func numericEntries(at url: URL, limit: Int) -> [Int] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return [] }
        var values: [Int] = []
        for name in names.prefix(limit) {
            guard !name.hasPrefix("."), !name.hasPrefix("-"), let value = Int(name), value >= 0 else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.appending(path: name).path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            values.append(value)
        }
        return values.sorted()
    }

    /// 从一张真实瓦片里嗅出瓦片边长（PNG 的 IHDR / JPEG 的 SOFn）。
    ///
    /// 报错尺寸会让外部编辑器整幅错位，所以宁可不报（返回 nil）也不猜。
    static func tileSize(of root: URL, zoom: Int, column: Int, row: Int) -> Int? {
        let directory = root.appending(path: String(zoom)).appending(path: String(column))
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        for name in names.prefix(64) {
            let stem = (name as NSString).deletingPathExtension
            guard Int(stem) == row else { continue }
            let url = directory.appending(path: name)
            guard let size = Self.imageSize(of: url), size.width == size.height, (16...4096).contains(size.width) else {
                return nil
            }
            return size.width
        }
        return nil
    }

    /// 读文件头解析图片宽高：PNG 看 IHDR，JPEG 扫 SOFn 段。只读前 64 KB。
    private static func imageSize(of url: URL) -> (width: Int, height: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 65536), head.count >= 24 else { return nil }
        let bytes = [UInt8](head)
        if bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
            func be32(_ offset: Int) -> Int {
                (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
                    | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            }
            guard bytes[12] == 0x49, bytes[13] == 0x48, bytes[14] == 0x44, bytes[15] == 0x52 else { return nil }
            return (be32(16), be32(20))
        }
        if bytes[0] == 0xFF, bytes[1] == 0xD8 {
            var index = 2
            while index + 9 < bytes.count {
                guard bytes[index] == 0xFF else { index += 1; continue }
                let marker = bytes[index + 1]
                // SOF0…SOF15（跳过 DHT/DAC/DRI 这些非 SOF 的 0xC4/0xC8/0xCC）。
                if (0xC0...0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC {
                    let height = (Int(bytes[index + 5]) << 8) | Int(bytes[index + 6])
                    let width = (Int(bytes[index + 7]) << 8) | Int(bytes[index + 8])
                    return (width, height)
                }
                // 其它段一律跳过：拿段长往后走，段长小于 2 说明文件已经乱了。
                let length = (Int(bytes[index + 2]) << 8) | Int(bytes[index + 3])
                guard length >= 2 else { return nil }
                index += 2 + length
            }
        }
        return nil
    }

    /// TileJSON 2.2：给 QGIS / MapLibre 这类工具直接「加一个源」用。
    ///
    /// `bounds` 只在能廉价拿到时给出：数据集的最高层级列目录过深（>4096 项）就直接省略这个可选字段，
    /// 不用一次「为元数据而扫全盘」的代价换一个边界框。
    package static func tileJSON(root: URL?, rootName: String, port: UInt16, metadata: RootMetadata) -> Data? {
        var payload: [String: Any] = [
            "tilejson": "2.2.0",
            "name": rootName,
            "scheme": "xyz",
            "format": "png",
            "tileSize": metadata.tileSize,
            "attribution": "尺规 · 本地瓦片服务",
            "tiles": ["http://127.0.0.1:\(port)/{z}/{x}/{y}.png"],
        ]
        if let range = metadata.zoomRange {
            payload["minzoom"] = range.lowerBound
            payload["maxzoom"] = range.upperBound
        }
        if let root, let start = metadata.start {
            let columns = Self.numericEntries(at: root.appending(path: String(start.zoom)), limit: 4096)
            let rows = Self.tileRows(at: root, zoom: start.zoom, column: start.x, limit: 4096)
            if let minColumn = columns.first, let maxColumn = columns.last,
               let minRow = rows.first, let maxRow = rows.last {
                let n = Double(1 << min(start.zoom, 30))
                let west = Double(minColumn) / n * 360 - 180
                let east = Double(maxColumn + 1) / n * 360 - 180
                let north = Self.latitude(row: Double(minRow), of: n)
                let south = Self.latitude(row: Double(maxRow + 1), of: n)
                payload["bounds"] = [west, south, east, north]
            }
        }
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    /// Web 墨卡托行号 → 纬度。
    private static func latitude(row: Double, of n: Double) -> Double {
        let ratio = 1 - 2 * row / n
        return atan(sinh(.pi * ratio)) * 180 / .pi
    }

    /// 自带预览页：不依赖网络（不引任何 CDN），拖拽平移、滚轮缩放，用来快速确认「服务真的通了」。
    package static func previewHTML(
        rootName: String,
        start: (zoom: Int, x: Int, y: Int)?,
        tileSize: Int
    ) -> String {
        let title = Self.escaped(rootName)
        let startZoom = start?.zoom ?? 0
        let startX = start?.x ?? 0
        let startY = start?.y ?? 0
        let startBlock: String
        if start == nil {
            startBlock = "document.getElementById('hint').textContent = '这个目录里没有找到瓦片。';"
        } else {
            startBlock = "view.z = \(startZoom); view.x = \(startX) + 0.5; view.y = \(startY) + 0.5; draw();"
        }
        return """
        <!doctype html>
        <html lang="zh-CN"><head><meta charset="utf-8"><title>预览 · \(title)</title>
        <style>
        html,body{margin:0;height:100%;overflow:hidden;background:#14161a;color:#e8eaed;
        font:13px/1.6 -apple-system,system-ui,sans-serif}
        #stage{position:absolute;inset:0;cursor:grab}
        #stage.dragging{cursor:grabbing}
        #stage img{position:absolute;width:\(tileSize)px;height:\(tileSize)px;user-select:none;-webkit-user-drag:none}
        #hud{position:absolute;left:12px;top:12px;padding:6px 10px;border-radius:8px;
        background:rgba(20,22,26,.72);backdrop-filter:blur(8px);pointer-events:none}
        #hint{position:absolute;left:12px;bottom:12px;color:#9aa0a6}
        </style></head>
        <body>
        <div id="stage"></div>
        <div id="hud">\(title) · <span id="z">z\(startZoom)</span></div>
        <div id="hint">拖拽平移 · 滚轮缩放</div>
        <script>
        const stage = document.getElementById('stage');
        const size = \(tileSize);
        const view = { z: \(startZoom), x: \(startX) + 0.5, y: \(startY) + 0.5 };
        const pool = new Map();
        function draw() {
          const w = innerWidth, h = innerHeight, n = Math.pow(2, view.z);
          const cx = view.x * size, cy = view.y * size;
          const x0 = Math.floor((cx - w / 2) / size), x1 = Math.floor((cx + w / 2) / size);
          const y0 = Math.floor((cy - h / 2) / size), y1 = Math.floor((cy + h / 2) / size);
          const live = new Set();
          for (let ty = y0; ty <= y1; ty++) {
            for (let tx = x0; tx <= x1; tx++) {
              if (tx < 0 || ty < 0 || tx >= n || ty >= n) continue;
              const key = view.z + '/' + tx + '/' + ty;
              live.add(key);
              let img = pool.get(key);
              if (!img) {
                img = new Image();
                img.decoding = 'async';
                img.src = '/' + key + '.png';
                pool.set(key, img);
                stage.appendChild(img);
              }
              img.style.transform = 'translate(' + Math.round(tx * size - cx + w / 2) + 'px,'
                + Math.round(ty * size - cy + h / 2) + 'px)';
            }
          }
          for (const [key, img] of pool) {
            if (!live.has(key)) { img.remove(); pool.delete(key); }
          }
          document.getElementById('z').textContent = 'z' + view.z;
        }
        let dragging = false, lastX = 0, lastY = 0;
        stage.addEventListener('pointerdown', e => {
          dragging = true; lastX = e.clientX; lastY = e.clientY;
          stage.classList.add('dragging'); stage.setPointerCapture(e.pointerId);
        });
        stage.addEventListener('pointermove', e => {
          if (!dragging) return;
          view.x -= (e.clientX - lastX) / size; view.y -= (e.clientY - lastY) / size;
          lastX = e.clientX; lastY = e.clientY; draw();
        });
        stage.addEventListener('pointerup', e => {
          dragging = false; stage.classList.remove('dragging');
          try { stage.releasePointerCapture(e.pointerId); } catch (_) {}
        });
        stage.addEventListener('wheel', e => {
          e.preventDefault();
          const step = e.deltaY < 0 ? 1 : -1;
          const next = Math.min(24, Math.max(0, view.z + step));
          if (next === view.z) return;
          const factor = Math.pow(2, next - view.z);
          view.x *= factor; view.y *= factor;
          view.z = next; draw();
        }, { passive: false });
        addEventListener('resize', draw);
        \(startBlock)
        </script>
        </body></html>
        """
    }

    /// 拼 HTML 前的转义（目录名可能带 `&`、`<` 这类字符）。
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
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
        <p>本机自测入口：<a href="/preview">打开预览页</a> ·
        元数据：<a href="/tilejson.json">/tilejson.json</a></p>
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
