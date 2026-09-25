import Foundation
import TileKit

/// 在线底图配置：一个瓦片源模板加上可选的密钥。
///
/// 画布需要的元信息（瓦片边长、层级范围、名称、归属）都从模板里取，
/// 因此新增一个源只需要加一条 `TileSourceTemplate`。
struct OnlineBasemap: Hashable, Sendable {
    var template: TileSourceTemplate
    var key: String

    var name: String { template.name }
    var attribution: String { template.attribution }
    var terms: String { template.terms }
    var needsKey: Bool { template.needsKey }
    var tileSize: Int { max(1, template.tileSize) }
    var zoomRange: ClosedRange<Int> { 0...max(0, min(30, template.maximumZoom)) }

    /// 模板可用、且需要密钥时密钥已填。
    var isValid: Bool { makeSource().isValid }

    func makeSource(fetcher: any TileFetching = URLSessionTileFetcher()) -> RemoteTileSource {
        RemoteTileSource(template: template, key: key, fetcher: fetcher)
    }

    /// 配置不完整时给出的提示。
    var invalidReason: String? {
        if template.urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "这个在线源还没有填 URL 模板"
        }
        if needsKey, key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(name) 需要填写密钥后才能显示"
        }
        return nil
    }
}
