import CoreGraphics
import Foundation

/// 文件选择器 URL 的访问租约；调用方在整个读取/导出期间持有它。
/// iOS / iPadOS 可用于 Files 文档，macOS 可用于沙盒文件选择器。
/// false 也可能表示 URL 原本就属于应用容器，因此不据此拒绝读取。
public final class ScopedFileAccess: Sendable {
    public let url: URL
    public let hasSecurityScope: Bool

    public init(url: URL) {
        self.url = url
        hasSecurityScope = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
    }
}

/// 把文件访问租约与数据源绑定；取消视图后仍在收尾的读取也持有有效租约。
public struct ScopedTileSource: TileImageSource {
    private let source: any TileImageSource
    private let access: ScopedFileAccess

    public init(source: any TileImageSource, access: ScopedFileAccess) {
        self.source = source
        self.access = access
    }

    public var availableZoomRange: ClosedRange<Int> { source.availableZoomRange }
    public func data(for tile: SlippyTile) async -> Data? {
        defer { withExtendedLifetime(access) {} }
        return await source.data(for: tile)
    }
    public func readData(for tile: SlippyTile) async throws -> Data? {
        defer { withExtendedLifetime(access) {} }
        return try await source.readData(for: tile)
    }
    public func loadTile(_ tile: SlippyTile) async -> TileLoadResult {
        defer { withExtendedLifetime(access) {} }
        return await source.loadTile(tile)
    }
    public func image(for tile: SlippyTile) async -> CGImage? {
        defer { withExtendedLifetime(access) {} }
        return await source.image(for: tile)
    }
}
