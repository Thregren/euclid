import CoreGraphics
import Observation
import TileKit

/// 图层面板里那一小张缩略图。
///
/// 面板要像 Pixelmator 那样在每行左边给一张小图。这里直接向图层自己的来源要**一张瓦片**
/// （挑不太高的层级，免得为了缩略图去解一整块大图），拿到后缩到行高大小；
/// 取不到（缺片、没网、密钥不对）就退回类型图标，界面不会因此空一块。
///
/// 缓存按「来源签名」存：同一份数据被加进多个图层时只取一次。
@MainActor
@Observable
final class LayerThumbnailStore {
    private var images: [String: CGImage] = [:]
    private var loading: Set<String> = []
    /// 取过一次没取到就不再反复试（否则每次面板刷新都会再打一轮磁盘或网络）。
    private var failed: Set<String> = []
    /// 缩略图缓存上限：图层不会太多，但用户反复打开数据集时别让它无限长。
    private static let maximumCachedImages = 32

    /// 某一层的缩略图；还没取到时为 nil。
    func image(for layer: MapLayer) -> CGImage? {
        images[layer.sourceKey]
    }

    /// 请求某一层的缩略图。
    ///
    /// `fallbackCenter` / `fallbackZoom` 是「覆盖范围未知」时用的兜底（在线底图就是这种），
    /// 一般传当前视图的中心与层级 —— 缩略图跟着用户正在看的地方走最直观。
    func request(_ layer: MapLayer, fallbackCenter: CGPoint, fallbackZoom: Int) {
        let key = layer.sourceKey
        guard images[key] == nil, !loading.contains(key), !failed.contains(key) else { return }
        // 本地数据的覆盖范围还没算出来时先不取：那时的中心是猜的，多半取到缺片，
        // 白试一次还会把这一层记成「取不到」。范围到位后界面会带着新的键再请求一次。
        guard layer.fitRect != nil || layer.kind == .online else { return }
        let tile = Self.thumbnailTile(for: layer, center: fallbackCenter, zoom: fallbackZoom)
        loading.insert(key)
        let source = layer.source
        Task { [weak self] in
            let image = await source.image(for: tile)
            guard let self else { return }
            self.loading.remove(key)
            if let image, let small = Self.downscaled(image) {
                self.images[key] = small
                // 简单淘汰：超了就把最早存进去的那个丢掉（字典没有顺序，这里用 keys 的第一个）。
                if self.images.count > Self.maximumCachedImages,
                   let oldest = self.images.keys.first(where: { $0 != key }) {
                    self.images.removeValue(forKey: oldest)
                }
            } else {
                self.failed.insert(key)
            }
        }
    }

    /// 用来当缩略图的那张瓦片。
    ///
    /// 位置取图层覆盖范围的中心；层级取「整份数据差不多正好落在一张瓦片里」的那一级 ——
    /// 这样缩略图里是影像本身，而不是低层级那种大片空白（稀疏数据尤其明显）。
    /// 没有覆盖范围（在线底图，或范围还没算出来）时，就用当前视图的中心与层级。
    private static func thumbnailTile(
        for layer: MapLayer,
        center fallbackCenter: CGPoint,
        zoom fallbackZoom: Int
    ) -> SlippyTile {
        let center = layer.fitRect.map { CGPoint(x: $0.midX, y: $0.midY) } ?? fallbackCenter
        let span = layer.fitRect.map { max($0.width, $0.height) } ?? 0
        // 层级夹在数据源给的范围里，再夹到 slippy 能表达的 0…22（`1 << zoom` 不能乱来）。
        let lower = max(0, min(layer.zoomRange.lowerBound, 22))
        let upper = max(lower, min(layer.zoomRange.upperBound, 22))
        let zoom: Int
        if span > 0, span.isFinite {
            let fitting = Int(log2(1 / span).rounded())
            zoom = min(max(fitting, lower), upper)
        } else {
            zoom = min(max(fallbackZoom, lower), upper)
        }
        let count = Double(1 << zoom)
        let maximum = (1 << zoom) - 1
        let x = min(max(Int((center.x * count).rounded(.down)), 0), maximum)
        let y = min(max(Int((center.y * count).rounded(.down)), 0), maximum)
        return SlippyTile(zoom: zoom, x: x, y: y)
    }

    /// 缩到行高附近就够：面板上的缩略图只有 40×28 点（Retina 上 80×56 像素）。
    private static func downscaled(_ image: CGImage, maximumPixel: Int = 96) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > 0 else { return nil }
        let scale = min(1, Double(maximumPixel) / Double(longest))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
