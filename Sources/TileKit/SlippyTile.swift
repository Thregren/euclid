import CoreGraphics
import Foundation

/// 一个 XYZ 瓦片。
public struct SlippyTile: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let zoom: Int
    public let x: Int
    public let y: Int

    public init(zoom: Int, x: Int, y: Int) {
        self.zoom = zoom
        self.x = x
        self.y = y
    }

    public var tileCountAtZoom: Int { 1 << zoom }

    public var description: String { "\(zoom)/\(x)/\(y)" }

    public static func < (lhs: SlippyTile, rhs: SlippyTile) -> Bool {
        (lhs.zoom, lhs.y, lhs.x) < (rhs.zoom, rhs.y, rhs.x)
    }

    /// 该瓦片覆盖的归一化世界范围。
    public var worldRect: CGRect {
        let n = Double(tileCountAtZoom)
        return CGRect(x: Double(x) / n, y: Double(y) / n, width: 1 / n, height: 1 / n)
    }
}

/// 瓦片在磁盘上的目录组织方式。
public enum TileDirectoryAxis: String, Sendable, Codable, CaseIterable {
    /// `<z>/<x>/<y>.<ext>` —— WebODM / ODM 默认输出。
    case xFirst
    /// `<z>/<y>/<x>.<ext>` —— 部分下载器的默认输出。
    case yFirst
}

/// 行号的零点方向。
public enum TileRowOrigin: String, Sendable, Codable, CaseIterable {
    /// XYZ / Google 约定：y 自北向南递增。
    case north
    /// TMS 约定：y 自南向北递增。
    case south
}

/// 数据集在磁盘上的布局描述。
public struct TileLayout: Hashable, Sendable, Codable {
    public var directoryAxis: TileDirectoryAxis
    public var rowOrigin: TileRowOrigin
    public var fileExtensions: [String]
    public var tileSize: Int

    public init(
        directoryAxis: TileDirectoryAxis = .xFirst,
        rowOrigin: TileRowOrigin = .north,
        fileExtensions: [String] = ["png", "jpg", "jpeg", "webp"],
        tileSize: Int = 512
    ) {
        self.directoryAxis = directoryAxis
        self.rowOrigin = rowOrigin
        self.fileExtensions = fileExtensions
        self.tileSize = tileSize
    }

    /// WebODM / ODM 默认输出：`<z>/<x>/<y>.png`，XYZ 北起源。
    public static let webODM = TileLayout()

    /// 返回瓦片在数据集根目录下的相对路径。
    public func relativePath(for tile: SlippyTile, fileExtension ext: String) -> String {
        let n = tile.tileCountAtZoom
        let row = rowOrigin == .north ? tile.y : n - 1 - tile.y
        switch directoryAxis {
        case .xFirst:
            return "\(tile.zoom)/\(tile.x)/\(row).\(ext)"
        case .yFirst:
            return "\(tile.zoom)/\(row)/\(tile.x).\(ext)"
        }
    }
}
