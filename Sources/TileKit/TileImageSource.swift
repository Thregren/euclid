import CoreGraphics
import Foundation

/// 瓦片字节来源。
///
/// 本地散文件目录与在线瓦片服务都实现它，渲染层只跟这个协议打交道：
/// 换底图不必区分「磁盘还是网络」，内存缓存、并发闸门、缺片负缓存也都一套代码。
public protocol TileImageSource: Sendable {
    /// 该来源可能提供瓦片的层级范围。
    var availableZoomRange: ClosedRange<Int> { get }

    /// 取瓦片原始字节。本地文件缺失、服务返回 404 都返回 nil。
    ///
    /// 实现要自己保证不阻塞调用方的执行器：目录来源把阻塞读取放到后台，
    /// 在线来源走异步网络请求。
    func data(for tile: SlippyTile) async -> Data?

    /// 取瓦片图片。默认实现是「先取字节再解码」；
    /// 像单幅影像这种「按区域现解」的来源覆盖它，省掉一次编码往返。
    func image(for tile: SlippyTile) async -> CGImage?
}

public extension TileImageSource {
    func image(for tile: SlippyTile) async -> CGImage? {
        guard let data = await data(for: tile) else { return nil }
        return ImageDecoder.decode(data)
    }
}

/// 取图请求的公共默认参数。
public enum TileRequestDefaults {
    public static let userAgent = "Euclid/1.3 (local tile viewer)"

    /// 默认请求头：带一个可辨认的 UA，方便对方识别流量来源。
    public static func headers(_ extra: [String: String] = [:]) -> [String: String] {
        var merged = extra
        if merged["User-Agent"] == nil { merged["User-Agent"] = userAgent }
        if merged["Accept"] == nil { merged["Accept"] = "image/*,*/*;q=0.8" }
        return merged
    }
}
