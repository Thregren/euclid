import AppKit
import Darwin
import Foundation
import TileKit

private actor MeasurementReadGate {
    private var released = false
    private var continuation: CheckedContinuation<[GeoMeasurement], Never>?
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private let values: [GeoMeasurement]
    init(_ values: [GeoMeasurement]) { self.values = values }
    func read() async -> [GeoMeasurement] {
        started = true; startWaiter?.resume(); startWaiter = nil
        if released { return values }
        return await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilRead() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func release() { released = true; continuation?.resume(returning: values); continuation = nil }
}

private final class OpenProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    func failFirst(_ url: URL) -> RasterSampleReader? {
        let first = lock.withLock { attempts += 1; return attempts == 1 }
        return first ? nil : RasterSampleReader.open(url: url, forceReload: true)
    }
}

private actor RasterLoadGate {
    private var continuation: CheckedContinuation<RasterDataset?, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var started = false
    func read() async -> RasterDataset? {
        started = true; startWaiter?.resume(); startWaiter = nil
        return await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilRead() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func release(_ raster: RasterDataset) { continuation?.resume(returning: raster); continuation = nil }
}

@main
@MainActor
enum AppModelRegression {
    private static var checks = 0
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
        checks += 1
    }

    static func main() async throws {
        guard let domain = Bundle.main.bundleIdentifier, domain.hasPrefix("com.euclid.regression.") else {
            throw Failure(description: "Run via check-app-models.sh to isolate UserDefaults from the installed app")
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("euclid-model-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("EUCLID_DEBUG_ARCHIVE_PATH", root.appendingPathComponent("measurements.json").path, 1)
        setenv("EUCLID_DEBUG_ARCHIVE_WRITE", "1", 1)
        setenv("EUCLID_DISABLE_SESSION", "1", 1)
        _ = NSApplication.shared
        let first = GeoMeasurement(kind: .point, points: [GeoCoordinate(longitude: 120, latitude: 25)])
        let second = GeoMeasurement(kind: .point, points: [GeoCoordinate(longitude: 121, latitude: 26)])
        try await measurementOwners(first, second)
        try await clearDuringLoad(first)
        try await importTarget(first)
        try await vectorImportTarget(first)
        try await restoredSessionMeasurements(first, second)
        try await restoredTabDraft(first, second)
        try await loadCompletesAfterSwitch(first, second)
        try loadingCancellation()
        try smallRasterZoom()
        try await elevation(at: root)
        print("App model regression: \(checks) checks passed")
    }

    private static func measurementOwners(_ first: GeoMeasurement, _ second: GeoMeasurement) async throws {
        let model = AppModel()
        model.changeMeasurementDocument(to: "dataset-a", initial: [first])
        model.measurements.addFinished(second)
        model.changeMeasurementDocument(to: "dataset-b", initial: [])
        model.measurements.addFinished(second)
        try check(model.measurements.measurements == [second], "switching measurement owner retained another dataset's values")
        try check(await model.measurementPersistence.flush() == nil, "measurement owners could not flush")
        try check(await MeasurementArchive.shared.measurements(for: "dataset-a") == [first, second], "dataset A pending save was cancelled")
        try check(await MeasurementArchive.shared.measurements(for: "dataset-b") == [second], "dataset B archive was contaminated by A")
        model.changeMeasurementDocument(to: "dataset-a")
        try check(model.measurements.measurements == [first, second], "switching back lost the original document")
    }

    private static func clearDuringLoad(_ first: GeoMeasurement) async throws {
        let gate = MeasurementReadGate([first])
        let model = AppModel()
        model.measurementReader = { _ in (await gate.read(), nil) }
        model.changeMeasurementDocument(to: "clear-during-load")
        model.measurements.clearAll()
        let read = model.measurementLoadTasks["clear-during-load"]
        await gate.release()
        await read?.value
        try check(model.measurements.measurements.isEmpty, "clear-all while loading resurrected archived measurements")
        try check(await model.measurementPersistence.flush() == nil, "clear intent did not flush")
        try check(await MeasurementArchive.shared.measurements(for: "clear-during-load") == [], "clear intent was not persisted")
    }

    private static func importTarget(_ first: GeoMeasurement) async throws {
        let gate = MeasurementReadGate([first])
        let model = AppModel()
        model.ensureWorkspaceTabs()
        let originalTab = model.activeWorkspaceTabID
        let importing = Task {
            await model.loadMeasurements(from: URL(fileURLWithPath: "/tmp/injected-measurement-input.json"), reader: { _ in await gate.read() })
        }
        await gate.waitUntilRead()
        model.addWorkspaceTab()
        await gate.release()
        try check(await importing.value == nil, "an import targeting the old tab was accepted in the new tab")
        try check(model.measurements.measurements.isEmpty, "stale import modified the newly active tab")
        try check(model.workspaceTabs.first(where: { $0.id == originalTab })?.measurements.isEmpty == true, "cancelled import modified its old tab")
    }

    private static func vectorImportTarget(_ first: GeoMeasurement) async throws {
        let gate = MeasurementReadGate([first])
        let model = AppModel()
        model.ensureWorkspaceTabs()
        let importing = Task {
            await model.importVectorOverlays(from: [URL(fileURLWithPath: "/tmp/injected.geojson")], reader: { _ in .success(await gate.read()) })
        }
        await gate.waitUntilRead()
        model.addWorkspaceTab()
        await gate.release()
        try check(await importing.value == nil && model.measurements.measurements.isEmpty, "vector import crossed tab ownership while parsing")
    }

    private static func restoredSessionMeasurements(_ first: GeoMeasurement, _ second: GeoMeasurement) async throws {
        _ = await MeasurementArchive.shared.save([first, second], for: "crash-window")
        let model = AppModel()
        model.changeMeasurementDocument(to: "crash-window", initial: [first], recoverArchive: true)
        await model.measurementLoadTasks["crash-window"]?.value
        try check(model.measurements.measurements == [first, second], "older session copy replaced the latest measurement archive after a crash")
        _ = await MeasurementArchive.shared.save([], for: "saved-empty")
        model.changeMeasurementDocument(to: "saved-empty", initial: [first], recoverArchive: true)
        await model.measurementLoadTasks["saved-empty"]?.value
        try check(model.measurements.measurements.isEmpty, "explicitly saved empty archive resurrected session measurements")
        model.changeMeasurementDocument(to: "archive-missing", initial: [first], recoverArchive: true)
        await model.measurementLoadTasks["archive-missing"]?.value
        try check(model.measurements.measurements == [first], "missing independent archive discarded session fallback")
    }

    private static func loadCompletesAfterSwitch(_ first: GeoMeasurement, _ second: GeoMeasurement) async throws {
        let gate = MeasurementReadGate([first])
        let model = AppModel()
        model.measurementReader = { _ in (await gate.read(), nil) }
        model.changeMeasurementDocument(to: "loading-original")
        model.measurements.addFinished(second)
        let read = model.measurementLoadTasks["loading-original"]
        model.changeMeasurementDocument(to: "loading-next", initial: [])
        await gate.release()
        await read?.value
        try check(model.measurements.measurements.isEmpty, "completed read overwrote another active document")
        model.changeMeasurementDocument(to: "loading-original")
        try check(model.measurements.measurements == [first, second], "edits made during archive loading were discarded")
        _ = await model.measurementPersistence.flush()
    }

    private static func restoredTabDraft(_ first: GeoMeasurement, _ second: GeoMeasurement) async throws {
        let model = AppModel()
        model.ensureWorkspaceTabs()
        let firstTab = model.workspaceTabs[0].id
        let gate = MeasurementReadGate([first])
        model.measurementReader = { _ in (await gate.read(), nil) }
        model.changeMeasurementDocument(to: "draft-owner")
        model.measurements.tool = .distance
        for point in first.points + second.points { model.measurements.addPoint(point) }
        let expected = model.measurements.workspaceDraft
        try check(expected?.points.count == 2, "test did not create an unfinished distance measurement")
        model.addWorkspaceTab()
        try check(model.measurements.draft.isEmpty, "switching tabs showed another tab's draft")
        model.measurements.tool = .browse
        model.activateWorkspaceTab(firstTab)
        let read = model.measurementLoadTasks["draft-owner"]
        await gate.release()
        await read?.value
        try check(model.measurements.tool == .distance && model.measurements.workspaceDraft == expected,
                  "restoring a tab or loading its archive changed the draft or measurement tool")
        try check(model.measurements.measurements == [first], "restoring the draft replaced the finished measurements")
        try check(model.measurements.finishDraft()?.points == expected?.points && model.measurements.workspaceDraft == nil,
                  "restored draft could not be finished")
        _ = await model.measurementPersistence.flush()
    }

    private static func loadingCancellation() throws {
        let model = AppModel()
        model.isScanning = true
        model.isResolvingExtent = true
        let task = Task<Void, Never> { do { try await Task.sleep(for: .seconds(10)) } catch {} }
        model.sourceTask = task
        let generation = model.sourceGeneration
        model.applyWorkspaceTab(WorkspaceTab())
        try check(!model.isScanning && !model.isResolvingExtent, "tab switch left busy flags that disable autosave")
        try check(task.isCancelled && model.sourceGeneration > generation, "tab switch did not cancel and invalidate source work")
    }

    private static func smallRasterZoom() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/TIFF/geo_utm50_deflate.tif")
        let raster = try RasterLoader.load(url: fixture)
        var layer = AppModel().makeLayer(raster: raster)
        layer.isAnchor = true
        let canvas = TileCanvasNSView(frame: CGRect(x: 0, y: 0, width: 1340, height: 800))
        canvas.setLayers([layer], focus: raster.worldRect)
        let fitted = canvas.currentZoomLevel
        canvas.zoomIn()
        try check(canvas.currentZoomLevel > fitted, "a fitted small GeoTIFF could not be enlarged")
    }

    private static func sample(_ model: AppModel, coordinate: GeoCoordinate) async -> Float? {
        _ = model.elevationReading(at: coordinate)
        await model.elevationTask?.value
        return model.elevationReading(at: coordinate)
    }

    private static func elevation(at root: URL) async throws {
        let a = root.appendingPathComponent("dem-a.tif"), b = root.appendingPathComponent("dem-b.tif")
        try dem(value: 100).write(to: a)
        try dem(value: 200).write(to: b)
        let rasterA = try RasterLoader.load(url: a), rasterB = try RasterLoader.load(url: b)
        try await exportSourceIdentity(rasterA, rasterB)
        let model = AppModel()
        model.rasters = [rasterA, rasterB]
        let coordinate = GeoCoordinate(longitude: 120.05, latitude: 25.95)
        model.selectSource(rasterA.id)
        try check(model.elevationReading(at: coordinate) == nil && model.elevationTask != nil, "pointer getter performed a synchronous sample")
        await model.elevationTask?.value
        try check(model.elevationReading(at: coordinate) == 100, "first DEM sample was incorrect")
        model.selectSource(rasterB.id)
        try check(await sample(model, coordinate: coordinate) == 200, "same-pixel source switch returned the preceding DEM value")
        try dem(value: 300).write(to: b, options: .atomic)
        try await Task.sleep(for: .milliseconds(300))
        try check(await sample(model, coordinate: coordinate) == 300, "same URL and coordinate never refreshed after the file changed")
        let probe = OpenProbe()
        let sampler = PointElevationSampler(openReader: { probe.failFirst($0) })
        try check(await sampler.sample(url: a, coordinate: coordinate) == nil, "injected first open should fail")
        try check(await sampler.sample(url: a, coordinate: coordinate) == 100, "a transient open failure poisoned the file identity cache")
        model.selectSource(rasterA.id)
        try check(model.analysisReader == nil && model.analysisReaderLoadTask != nil, "analysis capability getter did synchronous file work")
        await model.analysisReaderLoadTask?.value
        try check(model.supportsElevationAnalysis, "asynchronous analysis capabilities did not publish")
        let bounds = GeoBounds(west: 119.99, south: 25.59, east: 120.41, north: 26.01)
        model.calculateVolume(over: bounds)
        await model.analysisTask?.value
        let oldVolume = model.analysis.volume?.cutVolume ?? 0
        try check(oldVolume > 0, "analysis fixture did not produce a volume")
        try dem(value: 100, scale: 0.2).write(to: a, options: .atomic)
        model.calculateVolume(over: bounds)
        await model.analysisTask?.value
        let newVolume = model.analysis.volume?.cutVolume ?? 0
        try check(newVolume > oldVolume * 3.8 && newVolume < oldVolume * 4.2, "analysis used cached pixel scale after replacing the source TIFF")
        _ = await model.flushPersistentState()
    }

    private static func exportSourceIdentity(_ a: RasterDataset, _ b: RasterDataset) async throws {
        let gate = RasterLoadGate()
        let export = TileExportModel()
        export.sourceLoader = { url in url == a.fileURL ? await gate.read() : b }
        export.loadSource(a.fileURL)
        await gate.waitUntilRead()
        let oldTask = export.sourceLoadTask
        export.loadSource(b.fileURL)
        try check(export.raster == nil && !export.canStart, "export could start with a previous source while a new source was loading")
        await export.sourceLoadTask?.value
        await gate.release(a)
        await oldTask?.value
        try check(export.raster?.id == b.id && export.sourceURL == b.fileURL, "out-of-order export source loading replaced the user's newer choice")
    }

    /// Minimal, georeferenced unsigned 16-bit DEM with four equal samples.
    private static func dem(value: UInt16, scale: Double = 0.1) -> Data {
        func short(_ value: UInt16) -> Data { var little = value.littleEndian; return withUnsafeBytes(of: &little) { Data($0) } }
        func long(_ value: UInt32) -> Data { var little = value.littleEndian; return withUnsafeBytes(of: &little) { Data($0) } }
        func doubles(_ values: [Double]) -> Data {
            var data = Data()
            for value in values { var bits = value.bitPattern.littleEndian; data.append(withUnsafeBytes(of: &bits) { Data($0) }) }
            return data
        }
        let tags: [(UInt16, UInt16, UInt32, UInt32)] = [
            (256, 4, 1, 2), (257, 4, 1, 2), (258, 3, 1, 16), (259, 3, 1, 1),
            (262, 3, 1, 1), (273, 4, 1, 286), (277, 3, 1, 1), (278, 4, 1, 2),
            (279, 4, 1, 8), (284, 3, 1, 1), (339, 3, 1, 1),
            (33550, 12, 3, 182), (33922, 12, 6, 206), (34735, 3, 16, 254)
        ]
        var data = Data([0x49, 0x49, 42, 0]); data.append(long(8)); data.append(short(UInt16(tags.count)))
        for (tag, type, count, payload) in tags {
            data.append(short(tag)); data.append(short(type)); data.append(long(count)); data.append(long(payload))
        }
        data.append(long(0))
        data.append(doubles([scale, scale, 0]))
        data.append(doubles([0, 0, 0, 120, 26, 0]))
        let keys: [UInt16] = [1, 1, 0, 3, 1024, 0, 1, 2, 1025, 0, 1, 1, 2048, 0, 1, 4326]
        for key in keys { data.append(short(key)) }
        for _ in 0..<4 { data.append(short(value)) }
        return data
    }
}
