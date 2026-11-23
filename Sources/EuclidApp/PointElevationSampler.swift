import Foundation
import TileKit

/// File identity checks, TIFF opening and chunk decoding all run away from MainActor.
actor PointElevationSampler {
    private let openReader: @Sendable (URL) -> RasterSampleReader?
    private var identity: FileIdentity?
    private var reader: RasterSampleReader?
    private var pixel: (column: Double, row: Double, value: Float?)?

    init(openReader: @escaping @Sendable (URL) -> RasterSampleReader? = { RasterSampleReader.open(url: $0, forceReload: true) }) {
        self.openReader = openReader
    }

    func sample(url: URL, coordinate: GeoCoordinate) -> Float? {
        guard !Task.isCancelled, let current = FileIdentity(url: url) else { return nil }
        if current != identity || reader == nil {
            reader = openReader(url)
            identity = current
            pixel = nil
        }
        guard !Task.isCancelled, let reader, reader.isElevationLike,
              let position = reader.georeference.pixel(for: coordinate),
              position.x.isFinite, position.y.isFinite else { return nil }
        let column = position.x.rounded(.down), row = position.y.rounded(.down)
        if let pixel, pixel.column == column, pixel.row == row { return pixel.value }
        let value = reader.value(column: position.x, row: position.y)
        guard !Task.isCancelled else { return nil }
        pixel = (column, row, value)
        return value
    }

    func reset() {
        identity = nil
        reader = nil
        pixel = nil
    }
}

struct PointElevationRequest: Equatable, Sendable {
    let url: URL
    let coordinate: GeoCoordinate
    let generation: Int
}
