import Foundation
import TileKit

private final class MemoryCredentials: WorkspaceCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var fail = false
    func setFailure(_ value: Bool) { lock.withLock { fail = value } }
    func data(for reference: String) throws -> Data? {
        try lock.withLock {
            if fail { throw WorkspaceSessionError.credentialMissing }
            return values[reference]
        }
    }
    func store(_ data: Data, for reference: String) throws {
        try lock.withLock {
            if fail { throw WorkspaceSessionError.credentialMissing }
            values[reference] = data
        }
    }
}

private actor ArchiveProbe {
    var values: [String: [GeoMeasurement]] = [:]
    var fail = false
    var failPath: String?
    var delay = false
    func setFailure(_ value: Bool) { fail = value }
    func setFailedPath(_ path: String?) { failPath = path }
    func setDelay(_ value: Bool) { delay = value }
    func write(_ measurements: [GeoMeasurement], path: String) async -> String? {
        if delay { try? await Task.sleep(for: .milliseconds(40)) }
        if fail || path == failPath { return "simulated disk failure" }
        values[path] = measurements
        return nil
    }
    func read(_ path: String) -> [GeoMeasurement]? { values[path] }
}

@main
@MainActor
enum AppStateRegression {
    private static var checks = 0
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
        checks += 1
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("euclid-app-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await offlineEdits(at: root.appendingPathComponent("offline/workspace.json"))
        try await secrets(at: root.appendingPathComponent("secrets/workspace.json"))
        try await assetLifetimes(at: root.appendingPathComponent("assets/workspace.json"))
        try await corruptRecovery(at: root.appendingPathComponent("corrupt/workspace.json"))
        try await pendingMeasurements()
        print("App state regression: \(checks) checks passed")
    }

    private static func tab(layers: [SessionLayer] = []) -> SessionTab {
        SessionTab(id: UUID(), title: "original", customName: nil, selectedSourceID: nil,
                   selectedLayerID: nil, rootPath: nil, center: nil, zoom: nil,
                   measurements: [], layers: layers, measurementSourcePath: nil)
    }
    private static func offlineEdits(at url: URL) async throws {
        let missing = SessionLayer(id: "unavailable", sourceID: "/tmp/nonexistent-euclid-audit-volume/image.tif",
            kind: "raster", name: "offline", opacity: 1, isVisible: true, isAnchor: true, datum: .wgs84)
        var edited = tab(layers: [missing])
        let original = SessionDocument(activeTab: edited.id, tabs: [edited])
        try RecoverableFile.write(JSONEncoder().encode(original), to: url)
        let disk = WorkspaceSessionDisk(url: url, credentials: MemoryCredentials())
        let loaded = try await disk.restore()
        try check(loaded?.1.first?.layers.isEmpty == true, "offline layer should remain unavailable")
        edited.customName = "edited while disk offline"
        edited.zoom = 12
        edited.layers = []
        edited.measurements = [GeoMeasurement(kind: .point, points: [GeoCoordinate(longitude: 120, latitude: 25)])]
        let document = SessionDocument(activeTab: edited.id, tabs: [edited])
        try await disk.save(document, assets: [])
        let saved = RecoverableFile.read(SessionDocument.self, from: url)!.value.tabs[0]
        try check(saved.customName == edited.customName && saved.zoom == 12, "offline preservation discarded tab edits")
        try check(saved.measurements == edited.measurements, "offline preservation discarded new measurements")
        try check(saved.layers.map(\.id) == [missing.id], "offline recipe should survive independently of tab state")
        let identity = FileIdentity(url: url)
        for _ in 0..<10 { try await disk.save(document, assets: []) }
        try check(FileIdentity(url: url) == identity, "unchanged session should not rotate backups or rewrite")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        try check(permissions?.intValue == 0o600, "session permissions must be owner-only")
        edited.layers = [missing]
        try await disk.save(SessionDocument(activeTab: edited.id, tabs: [edited]), assets: [])
        edited.layers = []
        try await disk.save(SessionDocument(activeTab: edited.id, tabs: [edited]), assets: [])
        let removed = RecoverableFile.read(SessionDocument.self, from: url)!.value.tabs[0]
        try check(removed.layers.isEmpty, "a reconnected layer was resurrected after the user removed it")
        try await disk.save(SessionDocument(activeTab: nil, tabs: []), assets: [])
        let closed = RecoverableFile.read(SessionDocument.self, from: url)!.value
        try check(closed.tabs.isEmpty, "closed tabs must not be resurrected by missing-layer preservation")
    }

    private static func secrets(at url: URL) async throws {
        var layer = SessionLayer(id: "online", sourceID: "online-basemap", kind: "online", name: "custom",
                                 opacity: 1, isVisible: true, isAnchor: false, datum: .wgs84)
        layer.template = TileSourceTemplate(id: "private", name: "custom", urlTemplate: "https://example.invalid/{z}/{x}/{y}?token=embedded-secret")
        layer.key = "separate-secret"
        let savedTab = tab(layers: [layer])
        let legacy = SessionDocument(version: 1, activeTab: savedTab.id, tabs: [savedTab])
        for _ in 0..<4 { try RecoverableFile.write(JSONEncoder().encode(legacy), to: url) }
        let vault = MemoryCredentials()
        let disk = WorkspaceSessionDisk(url: url, credentials: vault)
        let restored = try await disk.restore()
        try check(restored?.1.first?.layers.first?.recipe.key == layer.key, "legacy key did not migrate into the credential vault")
        try check(restored?.1.first?.layers.first?.recipe.template?.urlTemplate == layer.template?.urlTemplate, "template was lost during migration")
        for index in 0...3 {
            let file = index == 0 ? url : RecoverableFile.backupURL(url, index: index)
            let content = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            try check(!content.contains("embedded-secret") && !content.contains("separate-secret"), "plaintext credential remains in generation \(index)")
        }
        let before = try Data(contentsOf: url)
        vault.setFailure(true)
        layer.key = "new-secret"
        var updated = savedTab
        updated.layers = [layer]
        do {
            try await disk.save(SessionDocument(activeTab: updated.id, tabs: [updated]), assets: [])
            throw Failure(description: "credential failure was silently accepted")
        } catch is WorkspaceSessionError { checks += 1 }
        try check(try Data(contentsOf: url) == before, "credential failure overwrote the durable session")
    }

    private static func assetLifetimes(at url: URL) async throws {
        let directory = url.deletingLastPathComponent().appendingPathComponent("workspace-assets")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = directory.appendingPathComponent("deadbeef.png")
        try Data([1, 2, 3]).write(to: image)
        let unmanaged = directory.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: unmanaged)
        var layer = SessionLayer(id: "analysis", sourceID: "analysis", kind: "raster", name: "result",
                                 opacity: 1, isVisible: true, isAnchor: false, datum: .wgs84)
        layer.image = image.lastPathComponent
        var value = tab(layers: [layer])
        let disk = WorkspaceSessionDisk(url: url, credentials: MemoryCredentials())
        try await disk.save(SessionDocument(activeTab: value.id, tabs: [value]), assets: [])
        value.layers = []
        try await disk.save(SessionDocument(activeTab: value.id, tabs: [value]), assets: [])
        try check(FileManager.default.fileExists(atPath: image.path), "asset referenced by a backup was deleted")
        for index in 0..<3 {
            value.customName = "revision \(index)"
            try await disk.save(SessionDocument(activeTab: value.id, tabs: [value]), assets: [])
        }
        try check(!FileManager.default.fileExists(atPath: image.path), "unreferenced analysis asset was not collected")
        try check(FileManager.default.fileExists(atPath: unmanaged.path), "asset collection deleted an unmanaged file")
    }

    private static func corruptRecovery(at url: URL) async throws {
        let value = tab()
        let valid = SessionDocument(activeTab: value.id, tabs: [value])
        try RecoverableFile.write(JSONEncoder().encode(valid), to: url)
        var future = valid
        future.version = 999
        try RecoverableFile.write(JSONEncoder().encode(future), to: url)
        let fallback = RecoverableFile.read(SessionDocument.self, from: url, validate: { $0.version == 2 })
        try check(fallback?.recovered == true, "semantic validation did not fall back to a supported backup")
        let disk = WorkspaceSessionDisk(url: url, credentials: MemoryCredentials())
        try check(try await disk.restore() != nil, "supported backup could not restore the session")
        let broken = url.deletingLastPathComponent().appendingPathComponent("broken.json")
        try Data("unrecoverable".utf8).write(to: broken)
        let unreadable = WorkspaceSessionDisk(url: broken, credentials: MemoryCredentials())
        do { _ = try await unreadable.restore(); throw Failure(description: "unreadable document was accepted") }
        catch WorkspaceSessionError.unreadable { checks += 1 }
        do { try await unreadable.save(valid, assets: []); throw Failure(description: "unreadable document was overwritten") }
        catch WorkspaceSessionError.unreadable { checks += 1 }
        try check(String(decoding: try Data(contentsOf: broken), as: UTF8.self) == "unrecoverable", "original corrupt document was modified")
        let huge = url.deletingLastPathComponent().appendingPathComponent("huge.json")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(RecoverableFile.maximumDocumentBytes + 1))
        try handle.close()
        do { try RecoverableFile.write(Data("small".utf8), to: huge); throw Failure(description: "oversized primary was rotated without a bound") }
        catch RecoverableFileError.tooLarge { checks += 1 }
        try check(FileIdentity(url: huge)?.bytes == Int64(RecoverableFile.maximumDocumentBytes + 1), "oversized primary was overwritten")
        let hugeBackup = RecoverableFile.backupURL(url, index: 1)
        try FileManager.default.removeItem(at: hugeBackup)
        try FileManager.default.copyItem(at: huge, to: hugeBackup)
        let primary = try Data(contentsOf: url)
        do { try RecoverableFile.write(Data("small".utf8), to: url); throw Failure(description: "oversized backup was silently ignored") }
        catch RecoverableFileError.tooLarge { checks += 1 }
        try check(try Data(contentsOf: url) == primary, "backup rotation failure replaced the current document")
    }

    private static func pendingMeasurements() async throws {
        let probe = ArchiveProbe()
        let coordinator = MeasurementPersistenceCoordinator { values, path in await probe.write(values, path: path) }
        let first = GeoMeasurement(kind: .point, points: [GeoCoordinate(longitude: 120, latitude: 25)])
        let second = GeoMeasurement(kind: .point, points: [GeoCoordinate(longitude: 121, latitude: 26)])
        coordinator.record([first], for: "dataset-a")
        coordinator.record([second], for: "dataset-b")
        try check(await coordinator.flush() == nil, "flushing separate dataset writes failed")
        try check(await probe.read("dataset-a") == [first], "editing dataset B cancelled pending dataset A save")
        try check(await probe.read("dataset-b") == [second], "dataset B was saved with another dataset's measurements")
        await probe.setFailure(true)
        coordinator.record([], for: "dataset-a")
        try check(await coordinator.flush() != nil && coordinator.hasPendingWrites, "failed write was dropped instead of remaining retryable")
        await probe.setFailure(false)
        try check(await coordinator.flush() == nil && !coordinator.hasPendingWrites, "retry did not drain pending writes")
        try check(await probe.read("dataset-a") == [], "retry did not persist an empty measurement document")
        await probe.setDelay(true)
        coordinator.record([first], for: "dataset-a")
        let flushing = Task { await coordinator.flush() }
        try await Task.sleep(for: .milliseconds(10))
        coordinator.record([first, second], for: "dataset-a")
        _ = await flushing.value
        try check(await probe.read("dataset-a") == [first, second], "an in-flight old write discarded a newer edit")
        await probe.setFailedPath("dataset-a")
        coordinator.record([], for: "dataset-a")
        coordinator.record([first, second], for: "dataset-b")
        try check(await coordinator.flush() != nil, "per-document write failure was hidden")
        try check(await probe.read("dataset-b") == [first, second], "one failing document prevented an unrelated document from being saved")
        await probe.setFailedPath(nil)
        try check(await coordinator.flush() == nil, "isolated document failure could not be retried")
    }
}
