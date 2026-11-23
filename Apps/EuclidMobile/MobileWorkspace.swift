import Foundation
import Observation
import TileKit

struct MobileViewpoint: Codable, Equatable, Sendable {
    let center: CGPoint
    let pointsPerWorldUnit: Double

    init(_ camera: MapCamera) {
        center = camera.center
        pointsPerWorldUnit = camera.pixelsPerWorldUnit
    }

    func camera(tileSize: Int) -> MapCamera? {
        guard center.x.isFinite, center.y.isFinite, pointsPerWorldUnit.isFinite,
              pointsPerWorldUnit > 0 else { return nil }
        return MapCamera(center: center, pixelsPerWorldUnit: pointsPerWorldUnit,
                         viewportSize: .zero, tilePixelSize: Double(tileSize))
    }
}

private struct MobileSession: Codable, Sendable {
    var bookmark: Data
    var name: String
    var fingerprint: RasterFingerprint?
    var viewpoint: MobileViewpoint?
    var isMeasuring = false
    var draft: [GeoCoordinate] = []
    var measurements: [GeoMeasurement] = []
}

private struct RasterFingerprint: Codable, Equatable, Sendable {
    let bytes: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let pixelWidth: Int
    let pixelHeight: Int
    let extent: CGRect

    init?(url: URL, dataset: RasterDataset) {
        guard let file = FileIdentity(url: url) else { return nil }
        bytes = file.bytes
        modifiedSeconds = file.seconds
        modifiedNanoseconds = file.nanoseconds
        pixelWidth = dataset.pixelWidth
        pixelHeight = dataset.pixelHeight
        extent = dataset.worldRect
    }
}

struct MobileRaster: Identifiable, Sendable {
    let id = UUID()
    let dataset: RasterDataset
    let source: ScopedTileSource

    fileprivate static func open(_ url: URL) throws -> (MobileRaster, Data, RasterFingerprint?) {
        let access = ScopedFileAccess(url: url)
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var opened: Result<(RasterDataset, RasterFingerprint?), any Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            opened = Result {
                let dataset = try RasterLoader.load(url: readableURL)
                return (dataset, RasterFingerprint(url: readableURL, dataset: dataset))
            }
        }
        if let coordinationError { throw coordinationError }
        guard let (dataset, fingerprint) = try opened?.get() else { throw CocoaError(.fileReadUnknown) }
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
        return (MobileRaster(dataset: dataset, source: ScopedTileSource(source: dataset.source, access: access)),
                bookmark, fingerprint)
    }
}

@MainActor @Observable
final class MobileWorkspace {
    private(set) var raster: MobileRaster?
    private(set) var isLoading = true
    private(set) var missingFile: String?
    private(set) var isMeasuring = false
    private(set) var draft: [GeoCoordinate] = []
    private(set) var measurements: [GeoMeasurement] = []
    var errorMessage: String?

    @ObservationIgnored private let file: URL
    @ObservationIgnored private var session: MobileSession?
    @ObservationIgnored private var viewpoint: MobileViewpoint?
    @ObservationIgnored private var opening: UUID?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var needsSave = false
    @ObservationIgnored private var didRestore = false

    init() {
        file = URL.applicationSupportDirectory.appending(path: "Euclid/mobile-workspace.json")
    }

    func restore() async {
        guard !didRestore else { return }
        didRestore = true
        guard let saved = RecoverableFile.read(MobileSession.self, from: file)?.value else {
            isLoading = false
            if FileManager.default.fileExists(atPath: file.path) {
                errorMessage = "工作区无法读取。可以从「文件」重新选择影像。"
            }
            return
        }
        session = saved
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: saved.bookmark, options: .withoutUI,
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            await load(url, restoring: saved)
        } catch {
            missingFile = saved.name
            isLoading = false
        }
    }

    func open(_ url: URL, reconnect: Bool = false) async {
        didRestore = true
        await load(url, restoring: reconnect ? session : nil, reconnecting: reconnect)
    }

    private func load(_ url: URL, restoring saved: MobileSession?, reconnecting: Bool = false) async {
        let request = UUID()
        opening = request
        isLoading = true
        defer {
            if opening == request { opening = nil; isLoading = false }
        }
        do {
            let (openedRaster, bookmark, fingerprint) = try await Task.detached(priority: .userInitiated) {
                try MobileRaster.open(url)
            }.value
            guard opening == request else { return }
            if reconnecting, let saved, saved.fingerprint == nil || saved.fingerprint != fingerprint {
                errorMessage = "所选文件与原影像不同。请重新选择原影像，或通过「文件」打开新的影像。"
                return
            }
            let restored = saved?.fingerprint == fingerprint ? saved : nil
            let dataset = openedRaster.dataset
            let updated = MobileSession(bookmark: bookmark, name: url.lastPathComponent,
                                        fingerprint: fingerprint, viewpoint: restored?.viewpoint,
                                        isMeasuring: dataset.isGeoreferenced && (restored?.isMeasuring ?? false),
                                        draft: dataset.isGeoreferenced ? restored?.draft ?? [] : [],
                                        measurements: dataset.isGeoreferenced ? restored?.measurements ?? [] : [])
            session = updated
            missingFile = nil
            viewpoint = updated.viewpoint
            isMeasuring = updated.isMeasuring
            draft = updated.draft
            measurements = updated.measurements
            raster = openedRaster
            if restored == nil || bookmark != restored?.bookmark || updated.name != restored?.name
                || restored?.isMeasuring != isMeasuring { saveChange() }
        } catch {
            guard opening == request else { return }
            if let saved, raster == nil { missingFile = saved.name }
            else { errorMessage = "无法打开影像。\(error.localizedDescription)" }
        }
    }

    func initialCamera(for raster: MobileRaster) -> MapCamera? {
        viewpoint?.camera(tileSize: raster.dataset.tileSize)
    }

    func updateCamera(_ camera: MapCamera, rasterID: UUID) {
        guard rasterID == raster?.id else { return }
        let newViewpoint = MobileViewpoint(camera)
        guard newViewpoint != viewpoint else { return }
        viewpoint = newViewpoint
        needsSave = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            self?.flush()
        }
    }

    func startMeasuring() {
        guard raster?.dataset.isGeoreferenced == true else { return }
        isMeasuring = true
        saveChange()
    }

    func addPoint(_ coordinate: GeoCoordinate, rasterID: UUID) {
        guard isMeasuring, let raster, raster.id == rasterID,
              let pixel = raster.dataset.georeference.pixel(for: coordinate),
              (0...Double(raster.dataset.pixelWidth)).contains(pixel.x),
              (0...Double(raster.dataset.pixelHeight)).contains(pixel.y),
              coordinate != draft.last else { return }
        draft.append(coordinate)
        saveChange()
    }

    func undoPoint() {
        guard !draft.isEmpty else { return }
        draft.removeLast()
        saveChange()
    }

    func endMeasurement(keep: Bool) {
        if keep {
            guard draft.count >= 2 else { return }
            measurements.append(GeoMeasurement(kind: .distance, points: draft))
        }
        draft.removeAll()
        isMeasuring = false
        saveChange()
    }

    var distanceText: String? {
        let points = isMeasuring ? draft : measurements.last?.points ?? []
        guard points.count >= 2 else { return nil }
        return MeasureFormat.distance(GeoMeasurement(kind: .distance, points: points).result.totalLength)
    }

    private func saveChange() {
        needsSave = true
        flush()
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard needsSave, var session else { return }
        session.viewpoint = viewpoint
        session.isMeasuring = isMeasuring
        session.draft = draft
        session.measurements = measurements
        do {
            try RecoverableFile.write(JSONEncoder().encode(session), to: file, backups: 1)
            self.session = session
            needsSave = false
        } catch {
            errorMessage = "工作区保存失败。\(error.localizedDescription)"
        }
    }
}
