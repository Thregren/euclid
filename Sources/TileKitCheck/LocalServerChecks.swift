import Darwin
import Foundation
import TileKit

@MainActor
func runLocalServerChecks() async throws {
    section("本地服务：真实 socket 分片、路径安全、连接预算与启停竞态")
    let directory = FileManager.default.temporaryDirectory.appending(path: "euclid-http-safety-\(UUID().uuidString)")
    let root = directory.appending(path: "root")
    let other = directory.appending(path: "other")
    try FileManager.default.createDirectory(at: root.appending(path: "1/0"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    guard let png = makeCheckPNG(size: 32) else { throw POSIXError(.EIO) }
    try png.write(to: root.appending(path: "1/0/0.png"))
    try png.write(to: root.appending(path: "1/0/0.jpg"))
    try png.write(to: other.appending(path: "0.png"))
    try Data("<html>private data</html>".utf8).write(to: root.appending(path: "1/0/1.jpg"))
    try FileManager.default.createSymbolicLink(at: root.appending(path: "1/0/1.png"), withDestinationURL: other.appending(path: "0.png"))
    try FileManager.default.createSymbolicLink(at: root.appending(path: "1/1"), withDestinationURL: other)
    try FileManager.default.createDirectory(at: root.appending(path: "1/\(Int.max)"), withIntermediateDirectories: true)
    try png.write(to: root.appending(path: "1/0/\(Int.max).png"))
    guard mkfifo(root.appending(path: "1/0/1.webp").path, 0o600) == 0 else { throw POSIXError(.EIO) }
    let server = LocalTileServer()
    defer { server.stop() }
    let port = try await server.startAsync(rootURL: root)
    func request(_ target: String, method: String = "GET") async throws -> SocketReply {
        try await socketRequest(port: port, fragments: [Data("\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)])
    }
    let fragmented = try await socketRequest(port: port, fragments: [Data("GET /1/0/0.png HTTP/1.1\r\n".utf8),
                                                                        Data("Host: 127.0.0.1\r\nX-Test: fragmented\r\n".utf8), Data("\r\n".utf8)])
    expect(fragmented.status == 200 && fragmented.body == png, "分片 HTTP 请求应等待完整请求头再响应")
    let query = try await request("/1/0/0.png?cache=1")
    expect(query.status == 200 && query.body == png, "查询参数应安全剥离")
    for path in ["/", "/tilejson.json", "/preview", "/1/0/0.png"] {
        let get = try await request(path)
        let head = try await request(path, method: "HEAD")
        expect(get.status == 200 && head.status == 200 && head.body.isEmpty && head.contentLength == get.body.count,
               "HEAD \(path) 应返回正文长度但不发送正文")
    }
    let options = try await request("/1/0/0.png", method: "OPTIONS")
    let post = try await request("/1/0/0.png", method: "POST")
    expect(options.status == 204 && options.body.isEmpty, "OPTIONS 应正常响应")
    expect(post.status == 405 && post.headers.lowercased().contains("allow: get, head, options"), "写方法应返回405及Allow")
    for path in ["?/", "/1/0/.png", "/1/0/..png", "/1/0/0..png", "/1//0.png", "/../../secret.png", "/1/9/0.png"] {
        let reply = try await request(path)
        expect(reply.status == 400 || reply.status == 404, "畸形路径 \(path) 应拒绝且不崩溃")
    }
    let overlong = Data(("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 8192)).utf8)
    let largeReply = try await socketRequest(port: port, fragments: [overlong])
    expect(largeReply.status == 431, "超长请求头应返回431")
    let malformed = try await socketRequest(port: port, fragments: [Data("GET / HTTP/1.1\r\ninvalid-header\r\n\r\n".utf8)])
    expect(malformed.status == 400, "无冒号的畸形请求头应拒绝")
    let fileLink = try await request("/1/0/1.png")
    let folderLink = try await request("/1/1/0.png")
    let disguised = try await request("/1/0/1.jpg")
    let actualType = try await request("/1/0/0.jpg")
    let fifo = try await request("/1/0/1.webp")
    expect(fileLink.status == 404 && folderLink.status == 404, "文件与目录符号链接均不可越出服务根目录")
    expect(fifo.status == 404, "FIFO伪装瓦片应立即拒绝，不可阻塞请求槽")
    expect(disguised.status == 404, "文本伪装为图片应拒绝")
    expect(actualType.status == 200 && actualType.headers.contains("Content-Type: image/png"), "MIME必须来自实际图片内容")
    let metadata = try await request("/tilejson.json")
    let metadataJSON = try JSONSerialization.jsonObject(with: metadata.body) as? [String: Any]
    let bounds = metadataJSON?["bounds"] as? [Double]
    expect(bounds?.count == 4 && bounds?.allSatisfy({ $0.isFinite && abs($0) <= 180 }) == true,
           "Int.max目录和行号不能使元数据溢出或生成超范围边界")
    let idle = try await Task.detached { try openHTTPTestSocket(port: port) }.value
    defer { close(idle) }
    _ = await waitForServer { server.activeConnectionCount == 1 }
    server.stop()
    expect(!server.status.isRunning && server.activeConnectionCount == 0, "stop必须立即清空活动连接")

    let shortLived = LocalTileServer(requestTimeout: 0.2, maximumConnections: 2)
    defer { shortLived.stop() }
    let shortPort = try await shortLived.startAsync(rootURL: root)
    let sockets = try await Task.detached { try (0..<3).map { _ in try openHTTPTestSocket(port: shortPort) } }.value
    defer { sockets.forEach { close($0) } }
    _ = await waitForServer { shortLived.activeConnectionCount > 0 }
    expect(shortLived.activeConnectionCount <= 2, "连接数应受预算限制")
    let expired = await waitForServer { shortLived.activeConnectionCount == 0 }
    expect(expired, "不发送完整头的连接应超时释放")

    for _ in 0..<5 {
        let pending = Task { try await server.startAsync(rootURL: root) }
        _ = await waitForServer { server.isStarting || server.status.isRunning }
        server.stop()
        _ = try? await pending.value
        expect(!server.status.isRunning, "stop之后未完成的启动不能重新挂回服务")
    }
    let firstStart = Task { try await server.startAsync(rootURL: root) }
    _ = await waitForServer { server.isStarting || server.status.isRunning }
    let secondPort = try await server.startAsync(rootURL: other)
    _ = try? await firstStart.value
    expect(server.status.isRunning && server.status.port == secondPort && server.status.rootName == "other",
           "并发启动应只保留最后一次请求")

    let fifoRoot = directory.appending(path: "fifo-only")
    try FileManager.default.createDirectory(at: fifoRoot.appending(path: "0/0"), withIntermediateDirectories: true)
    guard mkfifo(fifoRoot.appending(path: "0/0/0.png").path, 0o600) == 0 else { throw POSIXError(.EIO) }
    let fifoPort = try await server.startAsync(rootURL: fifoRoot)
    for path in ["/preview", "/tilejson.json", "/preview", "/tilejson.json"] {
        let reply = try await socketRequest(port: fifoPort, fragments: [Data("GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)])
        expect(reply.status == 200, "只有FIFO瓦片的目录也不可阻塞预览元数据")
    }
}

private struct SocketReply: Sendable {
    let status: Int
    let headers: String
    let body: Data
    var contentLength: Int? {
        headers.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }
    }
}

private func openHTTPTestSocket(port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSignal: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard result == 0 else { let error = errno; close(fd); throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
    return fd
}

private func socketRequest(port: UInt16, fragments: [Data]) async throws -> SocketReply {
    try await Task.detached {
        let fd = try openHTTPTestSocket(port: port)
        defer { close(fd) }
        for (index, fragment) in fragments.enumerated() {
            try fragment.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let sent = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                    if sent < 0 && errno == EINTR { continue }
                    guard sent > 0 else { throw POSIXError(.EIO) }
                    offset += sent
                }
            }
            if index < fragments.count - 1 { usleep(20_000) }
        }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = recv(fd, &bytes, bytes.count, 0)
            if count < 0 && errno == EINTR { continue }
            // Rejecting an overlong request leaves unread TCP input, so Darwin may deliver RST
            // after the complete 431 response. Accept that terminal state only with the full body.
            if count < 0, errno == ECONNRESET,
               let end = data.range(of: Data("\r\n\r\n".utf8)),
               let headers = String(data: data[..<end.lowerBound], encoding: .utf8),
               let length = SocketReply(status: 0, headers: headers, body: Data()).contentLength,
               length >= 0, data.count - end.upperBound >= length { break }
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if count == 0 { break }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count <= 4 << 20 else { throw POSIXError(.EFBIG) }
        }
        guard let range = data.range(of: Data("\r\n\r\n".utf8)),
              let headers = String(data: data[..<range.lowerBound], encoding: .utf8),
              let status = headers.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { throw POSIXError(.EBADMSG) }
        return SocketReply(status: status, headers: headers, body: Data(data[range.upperBound...]))
    }.value
}

@MainActor
private func waitForServer(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
