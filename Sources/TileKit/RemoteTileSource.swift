import Foundation

/// 在线瓦片来源：按 `TileSourceTemplate` 的 URL 模板逐张取图。
///
/// 只做「取字节」这一件事，解码与缓存交给 `TileProvider`：
/// 因此在线浏览与离线目录共用同一套渲染路径，失败也自然退化成「缺片」。
public struct RemoteTileSource: TileImageSource {
    public let template: TileSourceTemplate
    public let key: String?
    private let fetcher: any TileFetching
    private let retryLimit: Int
    private let headers: [String: String]

    public init(
        template: TileSourceTemplate,
        key: String? = nil,
        fetcher: any TileFetching = URLSessionTileFetcher(),
        retryLimit: Int = 1,
        headers: [String: String] = [:]
    ) {
        self.template = template
        self.key = key
        self.fetcher = fetcher
        self.retryLimit = max(0, retryLimit)
        self.headers = TileRequestDefaults.headers(headers)
    }

    public var availableZoomRange: ClosedRange<Int> {
        0...max(0, min(30, template.maximumZoom))
    }

    /// 配置是否够用：模板不能为空，需要密钥的源必须填了密钥。
    public var isValid: Bool {
        guard !template.urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard template.needsKey else { return true }
        return !(key ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func data(for tile: SlippyTile) async -> Data? {
        guard availableZoomRange.contains(tile.zoom) else { return nil }
        guard let url = try? TileURLTemplate.url(
            for: tile,
            template: template.urlTemplate,
            subdomains: template.subdomains,
            key: key
        ) else { return nil }

        var attempt = 0
        while true {
            if Task.isCancelled { return nil }
            do {
                let result = try await fetcher.fetch(TileRequest(url: url, headers: headers))
                return result.data
            } catch let error as TileFetchError where error.isRetryable && attempt < retryLimit {
                attempt += 1
                try? await Task.sleep(for: .seconds(TileDownloader.backoff(attempt: attempt)))
            } catch {
                // 404 与其它失败一律当作「这一格没有」，由渲染层显示为空。
                return nil
            }
        }
    }
}
