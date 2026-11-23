import Foundation
import ImageIO
import TileKit
import UniformTypeIdentifiers

struct SessionLayer: Codable, Sendable {
    var id: String
    var sourceID: String
    var kind: String
    var name: String
    var opacity: Double
    var isVisible: Bool
    var isAnchor: Bool
    var datum: Datum
    // Legacy fields are accepted for migration; save always moves both into Keychain first.
    var template: TileSourceTemplate?
    var key: String?
    var credentialReference: String?
    var image: String?
    var georeference: RasterGeoreference?
    var pixelWidth: Int?
    var pixelHeight: Int?
}

struct MeasurementDraft: Codable, Equatable, Sendable {
    var kind: MeasurementKind
    var points: [GeoCoordinate]
    var style: MeasurementStyle
}

struct WorkspaceViewpoint: Equatable {
    let center: GeoCoordinate
    let zoomLevel: Double
    let mapViewpoint: MapViewpoint?
}

extension WorkspaceViewpoint {
    init(camera: MapCamera) {
        self.init(center: WebMercator.coordinate(fromNormalized: camera.center),
                  zoomLevel: camera.zoomLevel, mapViewpoint: MapViewpoint(camera))
    }
}

struct SessionTab: Codable, Sendable {
    var id: UUID
    var title: String
    var customName: String?
    var selectedSourceID: String?
    var selectedLayerID: String?
    var rootPath: String?
    var center: GeoCoordinate?
    var zoom: Double?
    var measurements: [GeoMeasurement]
    var layers: [SessionLayer]
    var measurementSourcePath: String?
    var draft: MeasurementDraft? = nil
    var mapViewpoint: MapViewpoint? = nil

    var workspaceViewpoint: WorkspaceViewpoint? {
        guard let center, let zoom, center.longitude.isFinite, center.latitude.isFinite, zoom.isFinite else { return nil }
        return WorkspaceViewpoint(center: center, zoomLevel: zoom, mapViewpoint: mapViewpoint)
    }
}

struct SessionDocument: Codable, Sendable {
    var version = 2
    var activeTab: UUID?
    var tabs: [SessionTab]
}
struct SessionAsset: @unchecked Sendable { let name: String; let image: CGImage }
struct SessionLoadedLayer: Sendable {
    let recipe: SessionLayer
    let dataset: TileDataset?
    let raster: RasterDataset?
    let image: ImageTileSource?
    var extent: DatasetExtent? = nil
}
struct SessionLoadedTab: Sendable { let recipe: SessionTab; let layers: [SessionLoadedLayer] }

enum WorkspaceSessionError: LocalizedError {
    case unavailable, unreadable, invalidAsset, credentialMissing, tooManyTabs
    var errorDescription: String? {
        switch self {
        case .unavailable: return "找不到工作区存档目录"
        case .unreadable: return "工作区存档和备份无法读取，原文件已保留，尚未覆盖"
        case .invalidAsset: return "分析图层图像未能保存，工作区尚未更新"
        case .credentialMissing: return "在线服务凭据暂时无法读取；该图层配置已保留"
        case .tooManyTabs: return "工作区超过 100 个标签页的存档上限，请先关闭部分标签页"
        }
    }
}

/// Handles durable documents, secret migration and asset lifetimes independently of the UI model.
actor WorkspaceSessionDisk {
    static let shared = WorkspaceSessionDisk()
    static let url: URL? = {
        if let path = ProcessInfo.processInfo.environment["EUCLID_SESSION_PATH"] { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "Euclid/workspace.json")
    }()
    private struct OnlineConfiguration: Codable { let template: TileSourceTemplate; let key: String? }
    private let fileURL: URL?
    private let credentials: any WorkspaceCredentialStore
    private var previous: Data?
    private var missingLayers: [UUID: [SessionLayer]] = [:]
    private var credentialReferences: [Data: String] = [:]
    private var notice: String?
    private var unreadableDocument = false

    init(url: URL? = WorkspaceSessionDisk.url, credentials: any WorkspaceCredentialStore = KeychainWorkspaceCredentials()) {
        fileURL = url
        self.credentials = credentials
    }

    func takeNotice() -> String? { defer { notice = nil }; return notice }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func protectedDocument(_ document: SessionDocument) throws -> SessionDocument {
        var result = document
        result.version = 2
        for tabIndex in result.tabs.indices {
            for layerIndex in result.tabs[tabIndex].layers.indices {
                var layer = result.tabs[tabIndex].layers[layerIndex]
                if let template = layer.template {
                    let bytes = try encode(OnlineConfiguration(template: template, key: layer.key))
                    let reference: String
                    if let existing = credentialReferences[bytes] {
                        reference = existing
                    } else {
                        reference = UUID().uuidString
                        try credentials.store(bytes, for: reference)
                        credentialReferences[bytes] = reference
                    }
                    layer.credentialReference = reference
                    layer.template = nil
                    layer.key = nil
                } else {
                    // A malformed old document must not leak a standalone key into the new file.
                    layer.key = nil
                }
                result.tabs[tabIndex].layers[layerIndex] = layer
            }
        }
        return result
    }

    func save(_ document: SessionDocument, assets: [SessionAsset]) throws {
        guard !unreadableDocument else { throw WorkspaceSessionError.unreadable }
        guard document.tabs.count <= 100 else { throw WorkspaceSessionError.tooManyTabs }
        guard let url = fileURL else { throw WorkspaceSessionError.unavailable }
        let ids = Set(document.tabs.map(\.id))
        var retainedMissing = missingLayers.filter { ids.contains($0.key) }
        var merged = document
        for index in merged.tabs.indices {
            let visible = merged.tabs[index].layers
            let retained = (missingLayers[merged.tabs[index].id] ?? []).filter { missing in
                !visible.contains { $0.id == missing.id || ($0.kind == missing.kind && $0.sourceID == missing.sourceID) }
            }
            merged.tabs[index].layers.append(contentsOf: retained)
            retainedMissing[merged.tabs[index].id] = retained
        }
        let protected = try protectedDocument(merged)
        let data = try encode(protected)
        let directory = url.deletingLastPathComponent().appending(path: "workspace-assets")
        if !assets.isEmpty { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        // Repair a missing asset even if the document itself has not changed.
        for asset in assets {
            guard Self.validAssetName(asset.name) else { throw WorkspaceSessionError.invalidAsset }
            let destination = directory.appending(path: asset.name)
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            let bytes = NSMutableData()
            guard let encoder = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else {
                throw WorkspaceSessionError.invalidAsset
            }
            CGImageDestinationAddImage(encoder, asset.image, nil)
            guard CGImageDestinationFinalize(encoder) else { throw WorkspaceSessionError.invalidAsset }
            try RecoverableFile.write(bytes as Data, to: destination, backups: 0)
        }
        guard previous != data || !FileManager.default.fileExists(atPath: url.path) else {
            missingLayers = retainedMissing
            return
        }
        try RecoverableFile.write(data, to: url)
        previous = data
        missingLayers = retainedMissing
        do { try collectUnusedAssets(at: url) }
        catch { notice = "工作区已保存，但旧分析图像未能清理：\(error.localizedDescription)" }
    }

    func restore() throws -> (SessionDocument, [SessionLoadedTab])? {
        guard let url = fileURL else { return nil }
        // Scrub every readable generation before normal rotation can copy legacy plaintext again.
        do { try migrateCredentialFiles(at: url) }
        catch { notice = error.localizedDescription }
        guard let recovered = RecoverableFile.read(SessionDocument.self, from: url, validate: {
            (1...2).contains($0.version) && $0.tabs.count <= 100
        }) else {
            if (0...3).contains(where: { FileManager.default.fileExists(atPath: Self.generationURL(url, $0).path) }) {
                unreadableDocument = true
                throw WorkspaceSessionError.unreadable
            }
            return nil
        }
        let document = recovered.value
        missingLayers.removeAll()
        var loaded: [SessionLoadedTab] = []
        for tab in document.tabs {
            var layers: [SessionLoadedLayer] = []
            for original in tab.layers.prefix(256) {
                var layer = original
                if layer.kind == "online" {
                    do {
                        if let reference = layer.credentialReference {
                            guard let bytes = try credentials.data(for: reference) else { throw WorkspaceSessionError.credentialMissing }
                            let configuration = try JSONDecoder().decode(OnlineConfiguration.self, from: bytes)
                            layer.template = configuration.template
                            layer.key = configuration.key
                            credentialReferences[try encode(configuration)] = reference
                        }
                        guard layer.template != nil else { throw WorkspaceSessionError.credentialMissing }
                        layers.append(SessionLoadedLayer(recipe: layer, dataset: nil, raster: nil, image: nil))
                    } catch { notice = error.localizedDescription }
                } else if let asset = layer.image, Self.validAssetName(asset), let reference = layer.georeference {
                    let file = url.deletingLastPathComponent().appending(path: "workspace-assets/" + asset)
                    if let data = try? RecoverableFile.boundedData(from: file), let image = ImageDecoder.decode(data) {
                        layers.append(SessionLoadedLayer(recipe: layer, dataset: nil, raster: nil,
                            image: ImageTileSource(image: image, georeference: reference,
                                                   pixelWidth: layer.pixelWidth, pixelHeight: layer.pixelHeight)))
                    }
                } else if layer.kind == "dataset", let dataset = DatasetLocator.makeDataset(at: URL(fileURLWithPath: layer.sourceID)) {
                    layers.append(SessionLoadedLayer(recipe: layer, dataset: dataset, raster: nil, image: nil,
                                                     extent: DatasetLocator.extent(of: dataset)))
                } else if layer.kind == "raster", let raster = try? RasterLoader.load(url: URL(fileURLWithPath: layer.sourceID)) {
                    layers.append(SessionLoadedLayer(recipe: layer, dataset: nil, raster: raster, image: nil))
                }
            }
            let loadedIDs = Set(layers.map { $0.recipe.id })
            missingLayers[tab.id] = tab.layers.filter { !loadedIDs.contains($0.id) }
            loaded.append(SessionLoadedTab(recipe: tab, layers: layers))
        }
        // Do not rewrite an unchanged restored workspace merely because JSON key ordering differed.
        previous = recovered.recovered ? nil : try? encode(document)
        return (document, loaded)
    }

    private func migrateCredentialFiles(at url: URL) throws {
        for index in 0...3 {
            let file = Self.generationURL(url, index)
            guard let document = readDocument(file) else { continue }
            let sanitized = try protectedDocument(document)
            let bytes = try encode(sanitized)
            if try RecoverableFile.boundedData(from: file) != bytes { try RecoverableFile.write(bytes, to: file, backups: 0) }
        }
    }

    private func readDocument(_ url: URL) -> SessionDocument? {
        guard let data = try? RecoverableFile.boundedData(from: url), let document = try? JSONDecoder().decode(SessionDocument.self, from: data),
              (1...2).contains(document.version), document.tabs.count <= 100 else { return nil }
        return document
    }

    private func collectUnusedAssets(at url: URL) throws {
        var referenced: Set<String> = []
        for index in 0...3 {
            let file = Self.generationURL(url, index)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            // A damaged backup may still be manually recoverable: keep its assets conservatively.
            guard let document = readDocument(file) else { return }
            for tab in document.tabs {
                referenced.formUnion(tab.layers.compactMap(\.image))
            }
        }
        let directory = url.deletingLastPathComponent().appending(path: "workspace-assets")
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where Self.validAssetName(file.lastPathComponent) && !referenced.contains(file.lastPathComponent) {
            try FileManager.default.removeItem(at: file)
        }
    }

    private static func generationURL(_ url: URL, _ index: Int) -> URL {
        index == 0 ? url : RecoverableFile.backupURL(url, index: index)
    }
    private static func validAssetName(_ name: String) -> Bool {
        name.hasSuffix(".png") && (1...64).contains(name.count - 4) &&
            name.dropLast(4).allSatisfy { $0.isHexDigit && $0.isASCII }
    }
}
