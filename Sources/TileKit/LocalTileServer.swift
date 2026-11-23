import Foundation
import CoreGraphics
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
    private var pendingListener: NWListener?
    private var startupTask: Task<SourceContext?, Never>?
    private var generation: UInt64 = 0
    private var connections: [UUID: ConnectionState] = [:]
    private let maximumConnections: Int
    private let requestTimeout: TimeInterval
    private var requestCount = 0
    private var root: URL?
    private var servedDataset: TileDataset?
    private var servedSource: (any TileImageSource)?
    private let requestLimiter = AsyncLimiter(limit: 4)
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

    public init() { maximumConnections = 64; requestTimeout = 15 }
    package init(requestTimeout: TimeInterval, maximumConnections: Int = 64) {
        self.requestTimeout = min(60, max(0.1, requestTimeout))
        self.maximumConnections = min(64, max(1, maximumConnections))
    }

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

    /// Start ownership is established before discovery, so stop() can invalidate an unfinished start.
    @discardableResult
    public func start(rootURL: URL, port: UInt16 = 0) throws -> UInt16 {
        let token = reset()
        do {
            let context = Self.discover(rootURL)
            let listener = try makeListener(port: port, generation: token)
            try installPending(listener, generation: token)
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                switch state { case .ready, .failed, .cancelled: ready.signal(); default: break }
            }
            listener.start(queue: queue)
            guard ready.wait(timeout: .now() + 3) == .success else { throw TileServerError.cannotStart }
            return try adopt(listener, rootURL: rootURL, context: context, generation: token)
        } catch { _ = reset(ifGeneration: token); throw error }
    }

    @discardableResult
    public func startAsync(rootURL: URL, port: UInt16 = 0) async throws -> UInt16 {
        let token = reset()
        let discovery = Task.detached(priority: .userInitiated) { Self.discover(rootURL) }
        let registered = lock.withLock {
            guard generation == token else { return false }
            startupTask = discovery
            return true
        }
        guard registered else { discovery.cancel(); throw CancellationError() }
        return try await withTaskCancellationHandler {
            do {
                let context = await discovery.value
                try Task.checkCancellation()
                let listener = try makeListener(port: port, generation: token)
                try installPending(listener, generation: token)
                try await Self.waitUntilReady(listener, queue: queue)
                try Task.checkCancellation()
                return try adopt(listener, rootURL: rootURL, context: context, generation: token)
            } catch { _ = reset(ifGeneration: token); throw error }
        } onCancel: {
            discovery.cancel()
            _ = self.reset(ifGeneration: token)
        }
    }

    private struct SourceContext: Sendable {
        let dataset: TileDataset
        let source: any TileImageSource
    }
    private static func discover(_ root: URL) -> SourceContext? {
        guard !Task.isCancelled, let dataset = DatasetLocator.makeDataset(at: root),
              !Task.isCancelled, dataset.zipInfo != nil || dataset.mbtilesInfo != nil else { return nil }
        return SourceContext(dataset: dataset, source: dataset.source)
    }

    private static func waitUntilReady(_ listener: NWListener, queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.setIfUnset() { continuation.resume() }
                case .failed, .cancelled:
                    if resumed.setIfUnset() { continuation.resume(throwing: TileServerError.cannotStart) }
                default: break
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) {
                if resumed.setIfUnset() {
                    listener.cancel()
                    continuation.resume(throwing: TileServerError.cannotStart)
                }
            }
        }
    }

    private func makeListener(port: UInt16, generation token: UInt64) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener: NWListener
        if port == 0 { listener = try NWListener(using: parameters) }
        else {
            guard let value = NWEndpoint.Port(rawValue: port) else { throw TileServerError.invalidPort(Int(port)) }
            listener = try NWListener(using: parameters, on: value)
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.handle(connection, generation: token)
        }
        return listener
    }

    private func installPending(_ listener: NWListener, generation token: UInt64) throws {
        let accepted = lock.withLock {
            guard generation == token else { return false }
            pendingListener = listener
            return true
        }
        guard accepted else { listener.cancel(); throw CancellationError() }
    }

    private func adopt(_ listener: NWListener, rootURL: URL, context: SourceContext?, generation token: UInt64) throws -> UInt16 {
        guard case .ready = listener.state, let actualPort = listener.port?.rawValue else { throw TileServerError.cannotStart }
        let adopted = lock.withLock {
            guard generation == token, pendingListener === listener else { return false }
            self.listener = listener
            pendingListener = nil; startupTask = nil
            root = rootURL; boundPort = actualPort; requestCount = 0
            servedDataset = context?.dataset; servedSource = context?.source
            return true
        }
        guard adopted else { listener.cancel(); throw CancellationError() }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: _ = self?.reset(ifGeneration: token)
            default: break
            }
        }
        return actualPort
    }

    public func stop() { _ = reset() }

    @discardableResult
    private func reset(ifGeneration expected: UInt64? = nil) -> UInt64 {
        let retired = lock.withLock { () -> (UInt64, NWListener?, NWListener?, Task<SourceContext?, Never>?, [ConnectionState]) in
            guard expected == nil || generation == expected else { return (generation, nil, nil, nil, []) }
            generation &+= 1
            let result = (generation, listener, pendingListener, startupTask, Array(connections.values))
            listener = nil; pendingListener = nil; startupTask = nil
            root = nil; boundPort = 0; servedDataset = nil; servedSource = nil
            connections.removeAll()
            cache.removeAll(); cacheOrder.removeAll(); cacheBytes = 0
            metadataRootPath = nil; metadataCache = nil
            return result
        }
        retired.1?.cancel(); retired.2?.cancel(); retired.3?.cancel()
        for state in retired.4 { state.timer?.cancel(); state.task?.cancel(); state.connection.cancel() }
        return retired.0
    }

    // MARK: - 请求处理

    private final class ConnectionState: @unchecked Sendable {
        let connection: NWConnection
        let generation: UInt64
        var task: Task<Void, Never>?
        var timer: DispatchWorkItem?
        init(_ connection: NWConnection, generation: UInt64) { self.connection = connection; self.generation = generation }
    }
    package var activeConnectionCount: Int { lock.withLock { connections.count } }
    package var isStarting: Bool { lock.withLock { startupTask != nil || pendingListener != nil } }

    private func handle(_ connection: NWConnection, generation token: UInt64) {
        let id = UUID()
        let state = ConnectionState(connection, generation: token)
        let timer = DispatchWorkItem { [weak self] in self?.finish(id) }
        state.timer = timer
        let accepted = lock.withLock {
            guard generation == token, listener != nil, connections.count < maximumConnections else { return false }
            connections[id] = state
            return true
        }
        guard accepted else { timer.cancel(); connection.cancel(); return }
        connection.stateUpdateHandler = { [weak self] state in
            switch state { case .failed, .cancelled: self?.finish(id); default: break }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + requestTimeout, execute: timer)
        receiveHeader(id, connection: connection, accumulated: Data())
    }

    private func finish(_ id: UUID) {
        guard let state = lock.withLock({ connections.removeValue(forKey: id) }) else { return }
        state.timer?.cancel(); state.task?.cancel(); state.connection.cancel()
    }

    private func receiveHeader(_ id: UUID, connection: NWConnection, accumulated: Data) {
        guard lock.withLock({ connections[id] != nil }) else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: LocalHTTPRequest.maximumHeaderBytes + 1 - accumulated.count) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            guard error == nil, let data, !data.isEmpty else { self.finish(id); return }
            var combined = accumulated; combined.append(data)
            if let delimiter = combined.range(of: Data("\r\n\r\n".utf8)) {
                let header = Data(combined[..<delimiter.upperBound])
                guard header.count <= LocalHTTPRequest.maximumHeaderBytes else {
                    self.send(Self.httpResponse(status: 431, contentType: "text/plain", body: Data()), id: id); return
                }
                guard let request = LocalHTTPRequest(header) else {
                    self.send(Self.httpResponse(status: 400, contentType: "text/plain", body: Data()), id: id); return
                }
                self.dispatch(request, id: id)
            } else if combined.count >= LocalHTTPRequest.maximumHeaderBytes {
                self.send(Self.httpResponse(status: 431, contentType: "text/plain", body: Data()), id: id)
            } else if complete {
                self.send(Self.httpResponse(status: 400, contentType: "text/plain", body: Data()), id: id)
            } else { self.receiveHeader(id, connection: connection, accumulated: combined) }
        }
    }

    private func send(_ bytes: Data, id: UUID) {
        guard let connection = lock.withLock({ connections[id]?.connection }) else { return }
        connection.send(content: bytes, completion: .contentProcessed { [weak self] _ in self?.finish(id) })
    }

    private struct RequestContext: Sendable {
        let generation: UInt64
        let root: URL
        let port: UInt16
        let dataset: TileDataset?
        let source: (any TileImageSource)?
    }
    private func dispatch(_ request: LocalHTTPRequest, id: UUID) {
        guard let context = lock.withLock({ () -> RequestContext? in
            guard let connection = connections[id], connection.generation == generation, let root, listener != nil else { return nil }
            requestCount += 1
            return RequestContext(generation: generation, root: root, port: boundPort, dataset: servedDataset, source: servedSource)
        }) else { finish(id); return }
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let bytes = await self.response(for: request, context: context)
            guard !Task.isCancelled else { self.finish(id); return }
            self.send(bytes, id: id)
        }
        let registered = lock.withLock {
            guard let state = connections[id] else { return false }
            state.task = task
            return true
        }
        if !registered { task.cancel() }
    }

    private func response(for request: LocalHTTPRequest, context: RequestContext) async -> Data {
        func reply(_ status: Int, _ type: String = "text/plain", _ body: Data = Data(), extra: [String: String] = [:]) -> Data {
            Self.httpResponse(status: status, contentType: type, body: request.method == "HEAD" ? Data() : body,
                              extra: extra, contentLength: body.count)
        }
        guard ["GET", "HEAD", "OPTIONS"].contains(request.method) else { return reply(405, extra: ["Allow": "GET, HEAD, OPTIONS"]) }
        if request.method == "OPTIONS" { return reply(204) }
        guard await requestLimiter.acquire() else { return reply(503) }
        let response = await limitedResponse(for: request, context: context)
        await requestLimiter.release()
        return response
    }

    private func limitedResponse(for request: LocalHTTPRequest, context: RequestContext) async -> Data {
        func reply(_ status: Int, _ type: String = "text/plain", _ body: Data = Data(), extra: [String: String] = [:]) -> Data {
            Self.httpResponse(status: status, contentType: type, body: request.method == "HEAD" ? Data() : body,
                              extra: extra, contentLength: body.count)
        }
        guard !Task.isCancelled, lock.withLock({ generation == context.generation }) else { return reply(503) }
        let path = request.path
        if path == "/" { return reply(200, "text/html; charset=utf-8", Data(Self.indexHTML(rootName: context.root.lastPathComponent).utf8)) }
        if path == "/tilejson.json" || path == "/preview" || path == "/preview.html" {
            let metadata = metadata(for: context.root, dataset: context.dataset, generation: context.generation)
            if path == "/tilejson.json" {
                let body = Self.tileJSON(root: context.root, rootName: context.root.lastPathComponent,
                                         port: context.port, metadata: metadata) ?? Data("{}".utf8)
                return reply(200, "application/json; charset=utf-8", body)
            }
            return reply(200, "text/html; charset=utf-8", Data(Self.previewHTML(rootName: context.root.lastPathComponent,
                         start: metadata.start, tileSize: metadata.tileSize).utf8))
        }
        guard let parsed = LocalHTTPRequest.tilePath(path) else { return reply(404) }
        let tile: CachedTile?
        if let source = context.source, let dataset = context.dataset {
            if let bytes = await TileServerReprojection.data(dataset: dataset, source: source, tile: parsed.tile),
               bytes.count <= Self.maximumTileBytes, let ext = ImageDecoder.fileExtension(for: bytes),
               await TileDecodeScheduler.decode(bytes) != nil {
                tile = CachedTile(data: bytes, contentType: Self.contentType(for: ext), cachedAt: Date())
            } else { tile = nil }
        } else {
            let relativePath = "\(parsed.tile.zoom)/\(parsed.tile.x)/\(parsed.tile.y).\(parsed.ext)"
            tile = await cachedTile(for: relativePath, root: context.root, generation: context.generation)
        }
        guard let tile else { return reply(404) }
        return reply(200, tile.contentType, tile.data, extra: ["Cache-Control": "public, max-age=600"])
    }

    private func cachedTile(for path: String, root: URL, generation token: UInt64) async -> CachedTile? {
        let now = Date()
        let cached = lock.withLock { () -> CachedTile? in
            guard generation == token else { return nil }
            if let hit = cache[path] {
                if now.timeIntervalSince(hit.cachedAt) < Self.cacheLifetime { return hit }
                cache[path] = nil; cacheOrder.removeAll { $0 == path }; cacheBytes -= hit.data.count
            }
            return nil
        }
        if let cached { return cached }
        guard !Task.isCancelled,
              let data = try? BoundedTileFile.read(root: root, relativePath: path, maximumBytes: Self.maximumTileBytes),
              let ext = ImageDecoder.fileExtension(for: data), await TileDecodeScheduler.decode(data) != nil else { return nil }
        let tile = CachedTile(data: data, contentType: Self.contentType(for: ext), cachedAt: now)
        return lock.withLock {
            guard generation == token, !Task.isCancelled else { return nil }
            if cache[path] == nil { cache[path] = tile; cacheOrder.append(path); cacheBytes += data.count }
            while cacheBytes > Self.cacheLimitBytes || cacheOrder.count > Self.cacheLimitEntries {
                guard let oldest = cacheOrder.first else { break }
                cacheOrder.removeFirst()
                if let dropped = cache.removeValue(forKey: oldest) { cacheBytes -= dropped.data.count }
            }
            return tile
        }
    }

    public static func tileFile(for path: String, root: URL) -> URL? {
        guard let parsed = LocalHTTPRequest.tilePath(path) else { return nil }
        return root.appending(path: "\(parsed.tile.zoom)/\(parsed.tile.x)/\(parsed.tile.y).\(parsed.ext)")
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
        extra: [String: String] = [:],
        contentLength: Int? = nil
    ) -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 431: reason = "Request Header Fields Too Large"
        case 503: reason = "Service Unavailable"
        default: reason = "OK"
        }
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(contentLength ?? body.count)\r\n"
        // 浏览器里的编辑器（iD）需要这个头，否则跨源取图会被拦。
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Access-Control-Allow-Methods: GET, HEAD, OPTIONS\r\n"
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
    package struct RootMetadata: Sendable {
        package var zoomRange: ClosedRange<Int>?
        package var start: (zoom: Int, x: Int, y: Int)?
        package var tileSize: Int = 256

        package init() {}
    }

    private var metadataRootPath: String?
    private var metadataCache: RootMetadata?

    /// 取（必要时重算）根目录元数据。锁内只做字典/指针级操作，扫盘在锁外。
    private func metadata(for root: URL?, dataset: TileDataset?, generation token: UInt64) -> RootMetadata {
        guard let root else { return RootMetadata() }
        lock.lock()
        let cached = generation == token && metadataRootPath == root.path ? metadataCache : nil
        lock.unlock()
        if let cached { return cached }

        var fresh = RootMetadata()
        if let dataset {
            fresh.zoomRange = dataset.zoomRange; fresh.tileSize = dataset.layout.tileSize
            if let rect = DatasetLocator.extent(of: dataset)?.worldRect {
                let zoom = dataset.zoomRange.lowerBound
                let coordinate = WebMercator.coordinate(fromNormalized: CGPoint(x: rect.midX, y: rect.midY))
                let tile = TileGrid.webMercator.tile(at: coordinate, zoom: zoom)
                fresh.start = (zoom, tile.column, tile.row)
            }
            return fresh
        }
        fresh.zoomRange = Self.zoomRange(of: root)
        fresh.start = Self.previewStart(of: root)
        if let start = fresh.start,
           let size = Self.tileSize(of: root, zoom: start.zoom, column: start.x, row: start.y) {
            fresh.tileSize = size
        }

        lock.lock()
        if generation == token { metadataRootPath = root.path; metadataCache = fresh }
        lock.unlock()
        return fresh
    }

    /// 目录里实际存在的层级（只看根目录下的一层数字目录名，带条数上限）。
    ///
    /// 不给「全盘扫描」留口子：只枚举根目录，最多看 128 项，够用又不会在大数据集上卡住。
    static func zoomRange(of root: URL?) -> ClosedRange<Int>? {
        guard let root else { return nil }
        let entries = (try? BoundedTileFile.entries(root: root, limit: 128)) ?? []
        var zooms: [Int] = []
        for entry in entries {
            guard entry.isDirectory, entry.name.utf8.allSatisfy({ (48...57).contains($0) }),
                  let zoom = Int(entry.name), (0...30).contains(zoom) else { continue }
            zooms.append(zoom)
        }
        guard let lower = zooms.min(), let upper = zooms.max() else { return nil }
        return lower...upper
    }

    /// 预览页的默认落点：取最高层级中「最中间」的那张瓦片，避免一打开就是空白边界。
    static func previewStart(of root: URL) -> (zoom: Int, x: Int, y: Int)? {
        guard let range = zoomRange(of: root) else { return nil }
        let zoom = range.upperBound
        let columns = Self.numericEntries(at: root, zoom: zoom, limit: 4096)
        guard !columns.isEmpty else { return nil }
        let column = columns[columns.count / 2]
        let rows = Self.tileRows(at: root, zoom: zoom, column: column, limit: 4096)
        guard !rows.isEmpty else { return nil }
        return (zoom, column, rows[rows.count / 2])
    }

    /// 取某个 `<z>/<x>` 目录里的行号（只认允许的图片后缀）。
    private static func tileRows(at root: URL, zoom: Int, column: Int, limit: Int) -> [Int] {
        guard (0...30).contains(zoom), (0..<(1 << zoom)).contains(column) else { return [] }
        let names = (try? BoundedTileFile.entries(root: root, relativePath: "\(zoom)/\(column)", limit: limit)) ?? []
        var rows: [Int] = []
        for entry in names {
            guard entry.isRegularFile else { continue }
            let name = entry.name
            guard Self.allowedExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            let stem = (name as NSString).deletingPathExtension
            guard stem.utf8.allSatisfy({ (48...57).contains($0) }), let row = Int(stem),
                  (0..<(1 << zoom)).contains(row) else { continue }
            rows.append(row)
        }
        return rows.sorted()
    }

    /// 目录下名字是纯数字的子目录，升序返回。
    private static func numericEntries(at root: URL, zoom: Int, limit: Int) -> [Int] {
        guard (0...30).contains(zoom),
              let names = try? BoundedTileFile.entries(root: root, relativePath: String(zoom), limit: limit) else { return [] }
        var values: [Int] = []
        for entry in names {
            guard entry.isDirectory, entry.name.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(entry.name), (0..<(1 << zoom)).contains(value) else { continue }
            values.append(value)
        }
        return values.sorted()
    }

    /// 从一张真实瓦片里嗅出瓦片边长（PNG 的 IHDR / JPEG 的 SOFn）。
    ///
    /// 报错尺寸会让外部编辑器整幅错位，所以宁可不报（返回 nil）也不猜。
    static func tileSize(of root: URL, zoom: Int, column: Int, row: Int) -> Int? {
        guard (0...30).contains(zoom), (0..<(1 << zoom)).contains(column), (0..<(1 << zoom)).contains(row),
              let names = try? BoundedTileFile.entries(root: root, relativePath: "\(zoom)/\(column)", limit: 4096) else { return nil }
        for entry in names {
            guard entry.isRegularFile else { continue }
            let name = entry.name
            let stem = (name as NSString).deletingPathExtension
            guard Int(stem) == row, allowedExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            guard let data = try? BoundedTileFile.read(root: root, relativePath: "\(zoom)/\(column)/\(name)", maximumBytes: maximumTileBytes),
                  let size = Self.imageSize(data), size.width == size.height, (16...4096).contains(size.width) else {
                return nil
            }
            return size.width
        }
        return nil
    }

    /// Parse only a bounded prefix of data already read through the safe file descriptor path.
    private static func imageSize(_ data: Data) -> (width: Int, height: Int)? {
        guard data.count >= 24 else { return nil }
        let bytes = [UInt8](data.prefix(65536))
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
            let columns = Self.numericEntries(at: root, zoom: start.zoom, limit: 4096)
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
        <p>正在提供目录：<strong>\(escaped(rootName))</strong></p>
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
